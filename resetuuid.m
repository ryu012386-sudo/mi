#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static void L(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[uuid-reset] %@", m);
}

static NSString *docs_path(NSString *name) {
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"]
            stringByAppendingPathComponent:name];
}

// ---- IDFV スプーフ ----
static NSString *g_fakeIDFV = nil;   // 起動中この値を返す
static NSUUID *swizzled_identifierForVendor(id self, SEL _cmd) {
    if (g_fakeIDFV) return [[NSUUID alloc] initWithUUIDString:g_fakeIDFV];
    return nil;
}
static void install_idfv_spoof(void) {
    if (!g_fakeIDFV) return;
    Class c = objc_getClass("UIDevice");
    if (!c) { L(@"idfv: UIDevice not found, skip"); return; }
    Method m = class_getInstanceMethod(c, @selector(identifierForVendor));
    if (!m) { L(@"idfv: method not found, skip"); return; }
    method_setImplementation(m, (IMP)swizzled_identifierForVendor);
    L(@"idfv: spoof installed -> %@", g_fakeIDFV);
}
static void load_fake_idfv(void) {   // 既存の偽IDFVを読む（安定運用で一貫させる）
    NSString *s = [NSString stringWithContentsOfFile:docs_path(@"fake_idfv.txt")
                                            encoding:NSUTF8StringEncoding error:nil];
    g_fakeIDFV = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (g_fakeIDFV.length == 0) g_fakeIDFV = nil;
}
static void regenerate_fake_idfv(void) {   // リセット時に新しい偽IDFVを作る
    g_fakeIDFV = [[NSUUID UUID] UUIDString];
    [g_fakeIDFV writeToFile:docs_path(@"fake_idfv.txt")
                 atomically:YES encoding:NSUTF8StringEncoding error:nil];
    L(@"idfv: regenerated -> %@", g_fakeIDFV);
}

// ==== プロフィール背景 画像差し替えツール ====
// Documents/BG_SWAP_ON がある時だけ、UIImage->JPEG/PNG 変換を
// Documents/custom_bg.(jpg|jpeg|png|heic) の中身に差し替える。
// 「背景に設定」を押す直前に BG_SWAP_ON を作り、設定後に消す運用。
static BOOL bg_swap_on(void) {
    return [[NSFileManager defaultManager] fileExistsAtPath:docs_path(@"BG_SWAP_ON")];
}
static NSData *bg_custom_data(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *n in @[@"custom_bg.jpg", @"custom_bg.jpeg", @"custom_bg.png", @"custom_bg.heic"]) {
        NSString *p = docs_path(n);
        if ([fm fileExistsAtPath:p]) {
            NSData *d = [NSData dataWithContentsOfFile:p];
            if (d.length) return d;
        }
    }
    return nil;
}
typedef NSData *(*jpeg_fn)(UIImage *, CGFloat);
typedef NSData *(*png_fn)(UIImage *);

static jpeg_fn g_real_jpeg = NULL;     // 本物（interpose の replacee から取得）
static png_fn  g_real_png  = NULL;
static __thread int g_bg_inside = 0;   // 再帰ガード

static NSData *my_UIImageJPEGRepresentation(UIImage *img, CGFloat q) {
    if (!g_bg_inside && bg_swap_on()) {
        NSData *d = bg_custom_data();
        if (d) { L(@"[bg] JPEG swapped -> custom %lu bytes", (unsigned long)d.length); return d; }
    }
    if (!g_real_jpeg) return nil;
    g_bg_inside++; NSData *r = g_real_jpeg(img, q); g_bg_inside--;
    return r;
}
static NSData *my_UIImagePNGRepresentation(UIImage *img) {
    if (!g_bg_inside && bg_swap_on()) {
        NSData *d = bg_custom_data();
        if (d) { L(@"[bg] PNG swapped -> custom %lu bytes", (unsigned long)d.length); return d; }
    }
    if (!g_real_png) return nil;
    g_bg_inside++; NSData *r = g_real_png(img); g_bg_inside--;
    return r;
}
__attribute__((used, section("__DATA,__interpose")))
static const void *_ip_jpeg[2] = { (const void *)my_UIImageJPEGRepresentation,
                                   (const void *)UIImageJPEGRepresentation };
__attribute__((used, section("__DATA,__interpose")))
static const void *_ip_png[2]  = { (const void *)my_UIImagePNGRepresentation,
                                   (const void *)UIImagePNGRepresentation };

// interpose の replacee(_ip_*[1]) には dyld が“本物”のアドレスを入れる。そこから取得。
__attribute__((constructor))
static void bg_resolve_reals(void) {
    g_real_jpeg = (jpeg_fn)_ip_jpeg[1];
    g_real_png  = (png_fn)_ip_png[1];
    if (g_real_jpeg == (jpeg_fn)my_UIImageJPEGRepresentation) g_real_jpeg = NULL;  // 念のため自己参照防止
    if (g_real_png  == (png_fn)my_UIImagePNGRepresentation)   g_real_png  = NULL;
    NSLog(@"[uuid-reset] [bg] real jpeg=%p png=%p (self jpeg=%p)",
          (void *)g_real_jpeg, (void *)g_real_png, (void *)my_UIImageJPEGRepresentation);
}

// 保存用：本物でエンコード
static NSData *bg_real_jpeg(UIImage *img) {
    return g_real_jpeg ? g_real_jpeg(img, 0.95) : nil;
}

// ==== アカウント切替（丸ごとスナップショット＋起動時復元）====
static NSString *acc_dir(void)            { return docs_path(@"accounts"); }
static NSString *acc_slot(NSString *n)    { return [acc_dir() stringByAppendingPathComponent:n]; }

static NSArray<NSString *> *mirrativ_pref_files(void) {
    NSString *prefs = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences"];
    NSMutableArray *r = [NSMutableArray array];
    for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:prefs error:nil])
        if ([f hasSuffix:@".plist"] &&
            [f rangeOfString:@"mirrativ" options:NSCaseInsensitiveSearch].location != NSNotFound)
            [r addObject:f];
    return r;
}
static NSArray *acc_dump_keychain(void) {
    NSDictionary *q = @{ (id)kSecClass:(id)kSecClassGenericPassword,
                         (id)kSecReturnAttributes:@YES, (id)kSecReturnData:@YES,
                         (id)kSecMatchLimit:(id)kSecMatchLimitAll };
    CFTypeRef res = NULL;
    if (SecItemCopyMatching((CFDictionaryRef)q, &res) != errSecSuccess || !res) return @[];
    NSArray *items = (NSArray *)CFBridgingRelease(res);
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *it in items) {
        NSMutableDictionary *e = [NSMutableDictionary dictionary];
        if (it[(id)kSecAttrAccount])    e[@"acct"] = it[(id)kSecAttrAccount];
        if (it[(id)kSecAttrService])    e[@"svce"] = it[(id)kSecAttrService];
        if (it[(id)kSecValueData])      e[@"data"] = it[(id)kSecValueData];
        if (it[(id)kSecAttrAccessible]) e[@"acsb"] = it[(id)kSecAttrAccessible];
        if (e[@"data"]) [out addObject:e];
    }
    return out;
}
static void acc_restore_keychain(NSArray *items) {
    SecItemDelete((CFDictionaryRef)@{ (id)kSecClass:(id)kSecClassGenericPassword });
    for (NSDictionary *e in items) {
        NSMutableDictionary *add = [NSMutableDictionary dictionary];
        add[(id)kSecClass] = (id)kSecClassGenericPassword;
        if (e[@"acct"]) add[(id)kSecAttrAccount]    = e[@"acct"];
        if (e[@"svce"]) add[(id)kSecAttrService]    = e[@"svce"];
        if (e[@"data"]) add[(id)kSecValueData]      = e[@"data"];
        if (e[@"acsb"]) add[(id)kSecAttrAccessible] = e[@"acsb"];
        SecItemAdd((CFDictionaryRef)add, NULL);
    }
}
static NSArray<NSString *> *acc_list(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *r = [NSMutableArray array];
    for (NSString *n in [fm contentsOfDirectoryAtPath:acc_dir() error:nil]) {
        BOOL d = NO;
        if ([n hasPrefix:@"_"]) continue;
        if ([fm fileExistsAtPath:acc_slot(n) isDirectory:&d] && d) [r addObject:n];
    }
    return [r sortedArrayUsingSelector:@selector(compare:)];
}
// ★prefs は cfprefsd 管理なので、ファイル直書きでなく NSUserDefaults API 経由で保存/復元する
static void acc_snapshot(NSString *name) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *slot = acc_slot(name);
    [fm removeItemAtPath:slot error:nil];
    NSString *sp = [slot stringByAppendingPathComponent:@"prefs"];
    [fm createDirectoryAtPath:sp withIntermediateDirectories:YES attributes:nil error:nil];
    NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
    for (NSString *f in mirrativ_pref_files()) {
        NSString *domain = [f stringByDeletingPathExtension];
        NSDictionary *dom = [u persistentDomainForName:domain];   // cfprefsd の生値
        if (dom) [dom writeToFile:[sp stringByAppendingPathComponent:f] atomically:YES];
    }
    [acc_dump_keychain() writeToFile:[slot stringByAppendingPathComponent:@"keychain.plist"] atomically:YES];
    if ([fm fileExistsAtPath:docs_path(@"fake_idfv.txt")])
        [fm copyItemAtPath:docs_path(@"fake_idfv.txt")
                    toPath:[slot stringByAppendingPathComponent:@"fake_idfv.txt"] error:nil];
    L(@"[acc] snapshot saved (cfprefsd): %@", name);
}
static BOOL acc_restore(NSString *name) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *slot = acc_slot(name); BOOL d = NO;
    if (![fm fileExistsAtPath:slot isDirectory:&d] || !d) return NO;
    NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
    NSString *sp = [slot stringByAppendingPathComponent:@"prefs"];
    NSArray *slotFiles = [fm contentsOfDirectoryAtPath:sp error:nil] ?: @[];
    NSMutableSet *slotDomains = [NSMutableSet set];
    for (NSString *f in slotFiles) if ([f hasSuffix:@".plist"]) [slotDomains addObject:[f stringByDeletingPathExtension]];

    // 現在の mirrativ ドメインでスロットに無いものは削除（API経由でcfprefsd更新）
    for (NSString *f in mirrativ_pref_files()) {
        NSString *dom = [f stringByDeletingPathExtension];
        if (![slotDomains containsObject:dom]) [u removePersistentDomainForName:dom];
    }
    // スロットのドメインを丸ごと流し込む
    for (NSString *f in slotFiles) {
        if (![f hasSuffix:@".plist"]) continue;
        NSString *dom = [f stringByDeletingPathExtension];
        NSDictionary *dd = [NSDictionary dictionaryWithContentsOfFile:[sp stringByAppendingPathComponent:f]];
        if (dd) [u setPersistentDomain:dd forName:dom];
    }
    [u synchronize];

    NSArray *kc = [NSArray arrayWithContentsOfFile:[slot stringByAppendingPathComponent:@"keychain.plist"]];
    if (kc) acc_restore_keychain(kc);
    [fm removeItemAtPath:docs_path(@"fake_idfv.txt") error:nil];
    if ([fm fileExistsAtPath:[slot stringByAppendingPathComponent:@"fake_idfv.txt"]])
        [fm copyItemAtPath:[slot stringByAppendingPathComponent:@"fake_idfv.txt"]
                    toPath:docs_path(@"fake_idfv.txt") error:nil];
    L(@"[acc] restored (cfprefsd): %@", name);
    return YES;
}
// 起動時: 保留スロットがあれば復元（デバイスリセットより優先）
static BOOL acc_restore_pending(void) {
    NSString *p = [NSString stringWithContentsOfFile:docs_path(@"_pending_account.txt")
                                            encoding:NSUTF8StringEncoding error:nil];
    p = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [[NSFileManager defaultManager] removeItemAtPath:docs_path(@"_pending_account.txt") error:nil];
    if (!p.length) return NO;
    return acc_restore(p);
}
// 新規アカ作成の自動保存：リセット後、/me で垢が確立してからスナップショット
static void acc_schedule_autosave(void) {
    NSString *name = [[NSString stringWithContentsOfFile:docs_path(@"_autosave_name.txt")
                                                encoding:NSUTF8StringEncoding error:nil]
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!name.length) return;
    static BOOL scheduled = NO; if (scheduled) return; scheduled = YES;
    void (^doSave)(void) = ^{
        static BOOL done = NO; if (done) return; done = YES;
        acc_snapshot(name);
        [[NSFileManager defaultManager] removeItemAtPath:docs_path(@"_autosave_name.txt") error:nil];
        L(@"[acc] auto-saved new account as: %@", name);
    };
    // アプリをバックグラウンドにした時、または30秒後（先着）に保存
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n){ doSave(); }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ doSave(); });
}

// セッション/ユーザー系の prefs キーだけ消す（オンボーディング/設定は残す）
static void acc_clear_session_prefs(void) {
    NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
    NSArray *pat = @[@"user", @"session", @"token", @"auth", @"login", @"oauth", @"jwt",
                     @"credential", @"cookie", @"myself", @"account", @"uid",
                     @"access", @"refresh", @"currentuser", @"me_", @"_me", @"signin"];
    for (NSString *f in mirrativ_pref_files()) {
        NSString *dom = [f stringByDeletingPathExtension];
        NSDictionary *d = [u persistentDomainForName:dom];
        if (!d) continue;
        NSMutableDictionary *m = [d mutableCopy];
        for (NSString *k in d.allKeys) {
            NSString *lk = k.lowercaseString;
            for (NSString *p in pat) if ([lk containsString:p]) { [m removeObjectForKey:k]; break; }
        }
        if (m.count != d.count) {
            [u setPersistentDomain:m forName:dom];
            L(@"[acc] cleared %lu session keys in %@", (unsigned long)(d.count - m.count), dom);
        }
    }
    [u synchronize];
}
// 診断用：mirrativ prefs のキー一覧を Documents/prefs_dump.txt に出力
static void acc_dump_pref_keys(void) {
    NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
    NSMutableString *s = [NSMutableString string];
    for (NSString *f in mirrativ_pref_files()) {
        NSString *dom = [f stringByDeletingPathExtension];
        NSDictionary *d = [u persistentDomainForName:dom];
        [s appendFormat:@"== %@ (%lu keys) ==\n", dom, (unsigned long)d.count];
        for (NSString *k in [d.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            id v = d[k];
            NSString *vs = [v isKindOfClass:NSString.class] ? v : NSStringFromClass([v class]);
            if (vs.length > 70) vs = [[vs substringToIndex:70] stringByAppendingString:@"…"];
            [s appendFormat:@"  %@ = %@\n", k, vs];
        }
    }
    [s writeToFile:docs_path(@"prefs_dump.txt") atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// ==== アプリ内フローティングUI ====
@interface MRVPassthroughView : UIView @end
@implementation MRVPassthroughView
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    return v == self ? nil : v;   // ボタン以外はアプリに素通し
}
@end

// ウィンドウ自身も素通しにしないと、空き領域のタッチをこのウィンドウが食ってアプリが無反応になる
@interface MRVPassthroughWindow : UIWindow @end
@implementation MRVPassthroughWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    return v == self ? nil : v;   // window自身が返る=空き領域 → nilで下のアプリへ
}
@end

static UIWindow *g_bgWindow;   // 前方宣言（自分の小窓を除外するため）

// アプリ側(=自分の小窓以外)の最前面VC。ここから present しないとピッカーが小窓に潰れる
static UIViewController *bg_top_vc(void) {
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:UIWindowScene.class] &&
            s.activationState == UISceneActivationStateForegroundActive) { scene = (UIWindowScene *)s; break; }
    }
    if (!scene) return nil;
    UIWindow *best = nil;
    for (UIWindow *w in scene.windows) {
        if (w == g_bgWindow || w.hidden) continue;   // 自分の小窓は除外
        if (w.isKeyWindow) { best = w; break; }
        if (!best || w.windowLevel >= best.windowLevel) best = w;
    }
    if (!best) return nil;
    UIViewController *vc = best.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

@interface MRVBGTool : UIViewController <PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
@property(nonatomic,strong) UIButton *btn;
@end
@implementation MRVBGTool
- (void)loadView { self.view = [UIView new]; self.view.backgroundColor = UIColor.clearColor; }
- (void)viewDidLoad {
    [super viewDidLoad];
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = self.view.bounds;                       // 極小ウィンドウ全体を占める
    b.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    b.backgroundColor = [UIColor colorWithRed:0.15 green:0.5 blue:1 alpha:0.95];
    [b setTitle:@"⚙ ツール" forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    b.layer.cornerRadius = 12;
    b.layer.borderWidth = 1.5;
    b.layer.borderColor = UIColor.whiteColor.CGColor;
    [b addTarget:self action:@selector(tap) forControlEvents:UIControlEventTouchUpInside];
    [b addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]];
    [self.view addSubview:b];
    self.btn = b;
}
- (void)drag:(UIPanGestureRecognizer *)g {
    // 極小ウィンドウごと動かす（ボタンはウィンドウを埋めている）
    UIWindow *w = self.view.window;
    CGPoint t = [g translationInView:nil];
    w.center = CGPointMake(w.center.x + t.x, w.center.y + t.y);
    [g setTranslation:CGPointMake(0, 0) inView:nil];
}
- (BOOL)swapOn { return [[NSFileManager defaultManager] fileExistsAtPath:docs_path(@"BG_SWAP_ON")]; }
- (void)setSwap:(BOOL)on {
    if (on) [[NSData data] writeToFile:docs_path(@"BG_SWAP_ON") atomically:YES];
    else    [[NSFileManager defaultManager] removeItemAtPath:docs_path(@"BG_SWAP_ON") error:nil];
}
- (void)alert:(NSString *)t msg:(NSString *)m {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:t message:m preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [(bg_top_vc() ?: self) presentViewController:a animated:YES completion:nil];
}
- (void)present:(UIAlertController *)ac {
    UIViewController *host = bg_top_vc() ?: self;
    ac.popoverPresentationController.sourceView = host.view;
    ac.popoverPresentationController.sourceRect = CGRectMake(40, 160, 1, 1);
    [host presentViewController:ac animated:YES completion:nil];
}
- (void)tap {
    L(@"[bg] button tapped");
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"ツール"
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"🖼 背景画像ツール" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ [self bgMenu]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"👥 アカウント切替" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ [self accMenu]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"🔄 新規アカにする（自動ログイン）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ [self lightNewNow]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"🆕 新規アカ作成（名前つき保存）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ [self newAccountNamed]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"🧹 完全初期化（トラブル時）" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){ [self deviceResetNow]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"閉じる" style:UIAlertActionStyleCancel handler:nil]];
    [self present:ac];
}
// 予約して「今すぐ閉じる」ことでタスキル不要にする共通処理
- (void)confirmRelaunch:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"予約しました" message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"今すぐ閉じる（推奨）" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"あとで自分で再起動" style:UIAlertActionStyleCancel handler:nil]];
    [self present:a];
}
- (void)lightNewNow {
    [[NSData data] writeToFile:docs_path(@"NEW_LIGHT") atomically:YES];   // 軽量：新UUIDのみ、設定は維持
    [self confirmRelaunch:@"開き直すと、新しい匿名アカウントで自動ログイン状態になります（手動作成なし）。"];
}
- (void)deviceResetNow {
    [[NSData data] writeToFile:docs_path(@"RESET_ON") atomically:YES];   // 完全初期化（prefs全消し＝オンボーディングから）
    [self confirmRelaunch:@"次に開いた時に完全初期化されます（初回起動状態）。通常は『新規アカにする』で十分です。"];
}
- (void)newAccountNamed {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"新規アカ作成（名前つき保存）" message:@"作る新アカのスロット名を入力" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf){ tf.placeholder = @"例: サブ2"; }];
    [a addAction:[UIAlertAction actionWithTitle:@"作成" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){
        NSString *name = [a.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        name = [name stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
        if (!name.length) { [self alert:@"失敗" msg:@"名前が空です"]; return; }
        [[NSData data] writeToFile:docs_path(@"NEW_LIGHT") atomically:YES];           // 軽量：新規アカで自動ログイン
        [name writeToFile:docs_path(@"_autosave_name.txt") atomically:YES encoding:NSUTF8StringEncoding error:nil]; // 起動後に自動保存
        [self confirmRelaunch:[NSString stringWithFormat:@"開き直すと新規アカで自動ログインし、少し使うと自動で「%@」に保存します。", name]];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    [self present:a];
}
- (void)bgMenu {
    BOOL on = [self swapOn];
    BOOL hasImg = [[NSFileManager defaultManager] fileExistsAtPath:docs_path(@"custom_bg.jpg")];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"背景画像ツール"
        message:[NSString stringWithFormat:@"差し替え: %@ / 画像: %@", on?@"ON":@"OFF", hasImg?@"設定済":@"未設定"]
        preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"アルバムから画像を選ぶ" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ [self pickPhoto]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"ファイルから画像を選ぶ" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ [self pickFile]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:(on?@"差し替えを OFF にする":@"差し替えを ON にする") style:on?UIAlertActionStyleDestructive:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ [self setSwap:!on]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"閉じる" style:UIAlertActionStyleCancel handler:nil]];
    [self present:ac];
}
- (void)accMenu {
    NSArray<NSString *> *slots = acc_list();
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"アカウント切替"
        message:[NSString stringWithFormat:@"保存済み: %lu 個。切替はアプリ再起動で反映。", (unsigned long)slots.count]
        preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"＋ 今のアカウントを保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ [self accSave]; }]];
    for (NSString *n in slots) {
        [ac addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"▶ 「%@」に切替", n] style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ [self accSwitch:n]; }]];
    }
    if (slots.count)
        [ac addAction:[UIAlertAction actionWithTitle:@"🗑 スロットを削除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){ [self accDelete]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"閉じる" style:UIAlertActionStyleCancel handler:nil]];
    [self present:ac];
}
- (void)accSave {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"アカウントを保存" message:@"スロット名を入力" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf){ tf.placeholder = @"例: メイン"; }];
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){
        NSString *name = a.textFields.firstObject.text;
        name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        name = [name stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
        if (!name.length) { [self alert:@"失敗" msg:@"名前が空です"]; return; }
        acc_snapshot(name);
        [self alert:@"保存しました" msg:[NSString stringWithFormat:@"「%@」に現在のアカウントを保存しました。", name]];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    [self present:a];
}
- (void)accSwitch:(NSString *)name {
    [name writeToFile:docs_path(@"_pending_account.txt") atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self confirmRelaunch:[NSString stringWithFormat:@"次に開いた時に「%@」へ切り替わります。", name]];
}
- (void)accDelete {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"削除するスロット" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *n in acc_list()) {
        [ac addAction:[UIAlertAction actionWithTitle:n style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){
            [[NSFileManager defaultManager] removeItemAtPath:acc_slot(n) error:nil];
            [self alert:@"削除しました" msg:n];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    [self present:ac];
}
- (void)pickPhoto {
    dispatch_async(dispatch_get_main_queue(), ^{   // アクションシート dismiss 後に確実に出す
        if (@available(iOS 14.0, *)) {
            PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
            cfg.selectionLimit = 1;
            cfg.filter = [PHPickerFilter imagesFilter];
            PHPickerViewController *pk = [[PHPickerViewController alloc] initWithConfiguration:cfg];
            pk.delegate = self;
            UIViewController *h = bg_top_vc();
            L(@"[bg] present PHPicker on %@", h ? NSStringFromClass(h.class) : @"(nil!)");
            [(h ?: self) presentViewController:pk animated:YES completion:nil];
        } else {
            [self alert:@"非対応" msg:@"iOS 14 以上が必要です"];
        }
    });
}
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results API_AVAILABLE(ios(14.0)) {
    NSItemProvider *ip = results.firstObject.itemProvider;
    [picker dismissViewControllerAnimated:YES completion:^{   // 閉じ切ってから処理
        if (!ip || ![ip canLoadObjectOfClass:UIImage.class]) {
            [self alert:@"失敗" msg:@"この画像は読み込めません"]; return;
        }
        [ip loadObjectOfClass:UIImage.class completionHandler:^(id<NSItemProviderReading> obj, NSError *err){
            UIImage *img = [obj isKindOfClass:UIImage.class] ? (UIImage *)obj : nil;
            dispatch_async(dispatch_get_main_queue(), ^{ [self saveImage:img]; });  // 必ずメインで
        }];
    }];
}
- (void)pickFile {
    UIDocumentPickerViewController *dp;
    if (@available(iOS 14.0, *)) {
        dp = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeImage ]];
    } else {
        dp = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[ @"public.image" ] inMode:UIDocumentPickerModeImport];
    }
    dp.delegate = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [(bg_top_vc() ?: self) presentViewController:dp animated:YES completion:nil];
    });
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *u = urls.firstObject; if (!u) return;
    BOOL sec = [u startAccessingSecurityScopedResource];
    NSData *d = [NSData dataWithContentsOfURL:u];
    if (sec) [u stopAccessingSecurityScopedResource];
    UIImage *img = [UIImage imageWithData:d];
    if (img) [self saveImage:img]; else [self alert:@"失敗" msg:@"画像を読めませんでした"];
}
- (void)saveImage:(UIImage *)img {   // メインスレッド前提
    if (!img) { [self alert:@"失敗" msg:@"画像を取得できませんでした"]; return; }
    NSData *jpg = bg_real_jpeg(img);   // interpose を回避して本物でエンコード
    if (!jpg.length) { [self alert:@"失敗" msg:@"エンコードに失敗しました"]; return; }
    BOOL ok = [jpg writeToFile:docs_path(@"custom_bg.jpg") atomically:YES];
    L(@"[bg] saved custom_bg.jpg ok=%d bytes=%lu", ok, (unsigned long)jpg.length);
    [self setSwap:YES];   // 保存したら自動でON
    [self alert:@"セット完了" msg:@"画像を保存し『差し替えON』にしました。クローゼットで背景に設定してください。設定後は BG→OFF に。"];
}
@end

static UIWindow *g_bgWindow = nil;
static void bg_install_ui(void) {
    if (g_bgWindow) return;
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:UIWindowScene.class] &&
            s.activationState == UISceneActivationStateForegroundActive) { scene = (UIWindowScene *)s; break; }
    }
    if (!scene) return;   // まだ準備前。次の active で再試行
    // ボタンサイズだけの極小ウィンドウ。画面の他所にはウィンドウが無い＝アプリが普通にタッチ受ける
    g_bgWindow = [[UIWindow alloc] initWithWindowScene:scene];
    g_bgWindow.frame = CGRectMake(12, 130, 110, 48);
    g_bgWindow.windowLevel = UIWindowLevelAlert + 1;
    g_bgWindow.backgroundColor = UIColor.clearColor;
    g_bgWindow.rootViewController = [MRVBGTool new];
    g_bgWindow.hidden = NO;
    L(@"[bg] floating UI installed (small window)");
}

// 軽量リセット：deviceUUID だけ新しくして、オンボーディング/設定は残す。
// → アプリは起動時 /me を新UUIDで叩き、新しい匿名アカで“自動ログイン済み”になる（手動生成不要）
static void do_new_device_light(void) {
    NSString *SUITE = @"group.com.dena.mirrativ.shared";
    NSString *newUUID = [[NSUUID UUID] UUIDString];

    // 診断：消す前のキー一覧を保存
    acc_dump_pref_keys();

    // Keychain: セッション/認証を全消し（generic password 全部）→ 新 deviceUUID を追加
    SecItemDelete((__bridge CFDictionaryRef)@{ (__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword });
    SecItemAdd((__bridge CFDictionaryRef)@{ (__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
                                            (__bridge id)kSecAttrAccount:@"com.dena.mirrativ.uuid",
                                            (__bridge id)kSecValueData:[newUUID dataUsingEncoding:NSUTF8StringEncoding] }, NULL);
    // prefs の deviceUUID を差し替え（API経由でcfprefsd更新）
    NSUserDefaults *std = [NSUserDefaults standardUserDefaults];
    NSUserDefaults *grp = [[NSUserDefaults alloc] initWithSuiteName:SUITE];
    [std setObject:newUUID forKey:@"deviceUUID"]; [std synchronize];
    [grp setObject:newUUID forKey:@"deviceUUID"]; [grp synchronize];

    // セッション/ユーザー系の prefs キーだけ消す（オンボーディング/設定は残す）
    acc_clear_session_prefs();

    // Cookie を消して旧セッションを切る
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *ck = [[NSHomeDirectory() stringByAppendingPathComponent:@"Library"] stringByAppendingPathComponent:@"Cookies"];
    for (NSString *f in [fm contentsOfDirectoryAtPath:ck error:nil])
        [fm removeItemAtPath:[ck stringByAppendingPathComponent:f] error:nil];
    for (NSHTTPCookie *c in [[NSHTTPCookieStorage sharedHTTPCookieStorage].cookies copy])
        [[NSHTTPCookieStorage sharedHTTPCookieStorage] deleteCookie:c];

    regenerate_fake_idfv();
    L(@"[acc] light new-device (cleared session, kept onboarding) uuid=%@", newUUID);
}

static void do_wipe(void) {
    NSString *SUITE = @"group.com.dena.mirrativ.shared";
    NSString *KEY   = @"deviceUUID";

    NSUserDefaults *std = [NSUserDefaults standardUserDefaults];
    NSUserDefaults *grp = [[NSUserDefaults alloc] initWithSuiteName:SUITE];
    L(@"before: std[%@]=%@", KEY, [std stringForKey:KEY]);
    L(@"before: grp[%@]=%@", KEY, [grp stringForKey:KEY]);
    L(@"runtime bundleID = %@", [[NSBundle mainBundle] bundleIdentifier]);

    // 1) Keychain: generic password を「全部」削除（UUID＋セッショントークン等）。
    //    kSecClassKey/Certificate/Identity（TLS・配信鍵）は触らない＝重くならない。
    NSDictionary *q = @{ (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword };
    OSStatus st = SecItemDelete((__bridge CFDictionaryRef)q);
    L(@"keychain generic-password delete-all=%d", (int)st);

    // 2) UserDefaults: deviceUUID キー＋ suite ドメイン全消し
    [std removeObjectForKey:KEY]; [std synchronize];
    [grp removeObjectForKey:KEY];
    [grp removePersistentDomainForName:SUITE];
    [grp synchronize];

    // 3) Preferences: "mirrativ" を含む plist のみ削除
    NSString *prefs = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences"];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *f in [fm contentsOfDirectoryAtPath:prefs error:nil]) {
        if ([f hasSuffix:@".plist"] &&
            [f rangeOfString:@"mirrativ" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            NSString *p = [prefs stringByAppendingPathComponent:f];
            BOOL ok = [fm removeItemAtPath:p error:nil];
            L(@"rm pref %@ ok=%d", f, ok);
        }
    }

    // 4) Cookie を消して完全ログアウト（ソーシャルログインのセッションが残るのを防ぐ）
    NSString *lib = [NSHomeDirectory() stringByAppendingPathComponent:@"Library"];
    NSString *ck = [lib stringByAppendingPathComponent:@"Cookies"];
    for (NSString *f in [fm contentsOfDirectoryAtPath:ck error:nil]) {
        [fm removeItemAtPath:[ck stringByAppendingPathComponent:f] error:nil];
        L(@"rm cookie %@", f);
    }
    for (NSHTTPCookie *c in [[NSHTTPCookieStorage sharedHTTPCookieStorage].cookies copy])
        [[NSHTTPCookieStorage sharedHTTPCookieStorage] deleteCookie:c];

    // 5) IDFV を新しい偽値に更新
    regenerate_fake_idfv();

    L(@"wiped -> logged out + new device this launch");
}

// dylib ロード時（アプリの main より前）に1回だけ実行される
__attribute__((constructor))
static void reset_gate(void) {
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];

        // アカウント切替が予約されていれば、デバイスリセットより優先して復元しこの起動は終了
        if (acc_restore_pending()) {
            L(@"[acc] switched account this launch -> skip device reset");
            load_fake_idfv();
            install_idfv_spoof();
            [[NSNotificationCenter defaultCenter]
                addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *n){ bg_install_ui(); }];
            return;
        }

        // 軽量リセット（新規アカで自動ログイン・オンボーディング維持）
        if ([fm fileExistsAtPath:docs_path(@"NEW_LIGHT")]) {
            [fm removeItemAtPath:docs_path(@"NEW_LIGHT") error:nil];
            do_new_device_light();
        }

        BOOL bySetting = [[NSUserDefaults standardUserDefaults] boolForKey:@"reset_on_next_launch"];
        BOOL byFile  = [fm fileExistsAtPath:docs_path(@"RESET_ON")];    // 1回だけ（自動削除, 完全初期化）
        BOOL byEvery = [fm fileExistsAtPath:docs_path(@"RESET_EVERY")]; // 冷起動ごと（永続）
        BOOL armed = (bySetting || byFile || byEvery);
        L(@"gate: setting=%d once=%d every=%d armed=%d", bySetting, byFile, byEvery, armed);

        // 既存の偽IDFVを先に読む（安定運用でも一貫して返すため）
        load_fake_idfv();

        if (armed) {
            L(@"ARMED -> wiping");
            do_wipe();  // ここで偽IDFVも更新される
            if (byFile) {
                NSError *e = nil;
                BOOL removed = [fm removeItemAtPath:docs_path(@"RESET_ON") error:&e];
                L(@"disarm once: removed RESET_ON=%d (%@)", removed, e ? e.localizedDescription : @"ok");
            }
            if (byEvery) L(@"RESET_EVERY present -> reset again next cold launch");
        } else {
            L(@"OFF: keep current device (stable/verified)");
        }

        // 偽IDFVが設定済みなら（リセット後 or 過去にリセット済み）スプーフを有効化
        install_idfv_spoof();

        // 状態を Documents に追記（ログ不要の確認用）
        NSString *line = [NSString stringWithFormat:@"%@  armed=%d fakeIDFV=%@ bundleID=%@\n",
                          [NSDate date], armed, g_fakeIDFV ?: @"(none)",
                          [[NSBundle mainBundle] bundleIdentifier]];
        NSString *prev = [NSString stringWithContentsOfFile:docs_path(@"uuidreset_status.txt")
                                                   encoding:NSUTF8StringEncoding error:nil];
        [(prev ? [prev stringByAppendingString:line] : line)
            writeToFile:docs_path(@"uuidreset_status.txt")
             atomically:YES encoding:NSUTF8StringEncoding error:nil];

        // 新規アカ作成の自動保存が予約されていれば仕込む
        acc_schedule_autosave();

        // アプリ起動後にフローティングUI(BGボタン)を設置
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *n){ bg_install_ui(); }];
    }
}
