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

static NSData *my_UIImageJPEGRepresentation(UIImage *img, CGFloat q) {
    static jpeg_fn orig = NULL;
    if (!orig) orig = (jpeg_fn)dlsym(RTLD_DEFAULT, "UIImageJPEGRepresentation");
    if (bg_swap_on()) {
        NSData *d = bg_custom_data();
        if (d) { L(@"[bg] JPEG swapped -> custom %lu bytes", (unsigned long)d.length); return d; }
    }
    return orig ? orig(img, q) : nil;
}
static NSData *my_UIImagePNGRepresentation(UIImage *img) {
    static png_fn orig = NULL;
    if (!orig) orig = (png_fn)dlsym(RTLD_DEFAULT, "UIImagePNGRepresentation");
    if (bg_swap_on()) {
        NSData *d = bg_custom_data();
        if (d) { L(@"[bg] PNG swapped -> custom %lu bytes", (unsigned long)d.length); return d; }
    }
    return orig ? orig(img) : nil;
}
__attribute__((used, section("__DATA,__interpose")))
static const void *_ip_jpeg[2] = { (const void *)my_UIImageJPEGRepresentation,
                                   (const void *)UIImageJPEGRepresentation };
__attribute__((used, section("__DATA,__interpose")))
static const void *_ip_png[2]  = { (const void *)my_UIImagePNGRepresentation,
                                   (const void *)UIImagePNGRepresentation };

// interpose を回避して“本物の”JPEGエンコードを使う（保存用）
static NSData *bg_real_jpeg(UIImage *img) {
    static jpeg_fn r = NULL;
    if (!r) r = (jpeg_fn)dlsym(RTLD_DEFAULT, "UIImageJPEGRepresentation");
    return r ? r(img, 0.95) : nil;
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
    [b setTitle:@"🖼 背景" forState:UIControlStateNormal];
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
- (void)tap {
    L(@"[bg] button tapped");
    UIViewController *host = bg_top_vc() ?: self;
    BOOL on = [self swapOn];
    BOOL hasImg = [[NSFileManager defaultManager] fileExistsAtPath:docs_path(@"custom_bg.jpg")];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"背景画像ツール"
        message:[NSString stringWithFormat:@"差し替え: %@ / 画像: %@", on?@"ON":@"OFF", hasImg?@"設定済":@"未設定"]
        preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"アルバムから画像を選ぶ" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ [self pickPhoto]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"ファイルから画像を選ぶ" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ [self pickFile]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:(on?@"差し替えを OFF にする":@"差し替えを ON にする") style:on?UIAlertActionStyleDestructive:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ [self setSwap:!on]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"閉じる" style:UIAlertActionStyleCancel handler:nil]];
    // iPad: popover のアンカーを host のビューに（別ウィンドウのボタンは使えない）
    ac.popoverPresentationController.sourceView = host.view;
    ac.popoverPresentationController.sourceRect = CGRectMake(40, 160, 1, 1);
    [host presentViewController:ac animated:YES completion:nil];
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
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (!results.count) return;
    NSItemProvider *ip = results.firstObject.itemProvider;
    if ([ip canLoadObjectOfClass:UIImage.class]) {
        [ip loadObjectOfClass:UIImage.class completionHandler:^(id<NSItemProviderReading> obj, NSError *err){
            if ([obj isKindOfClass:UIImage.class]) [self saveImage:(UIImage *)obj];
        }];
    }
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
- (void)saveImage:(UIImage *)img {
    NSData *jpg = bg_real_jpeg(img);   // ← interpose を回避して本物でエンコード
    BOOL ok = [jpg writeToFile:docs_path(@"custom_bg.jpg") atomically:YES];
    L(@"[bg] saved custom_bg.jpg ok=%d bytes=%lu", ok, (unsigned long)jpg.length);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setSwap:YES];   // 保存したら自動でONにする
        [self alert:@"セット完了" msg:@"画像を保存し『差し替えON』にしました。クローゼットで背景に設定してください。設定後はもう一度BG→OFFにしてください。"];
    });
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

    // 4) IDFV を新しい偽値に更新
    regenerate_fake_idfv();

    L(@"wiped -> new device this launch");
}

// dylib ロード時（アプリの main より前）に1回だけ実行される
__attribute__((constructor))
static void reset_gate(void) {
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];

        BOOL bySetting = [[NSUserDefaults standardUserDefaults] boolForKey:@"reset_on_next_launch"];
        BOOL byFile  = [fm fileExistsAtPath:docs_path(@"RESET_ON")];    // 1回だけ（自動削除）
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

        // アプリ起動後にフローティングUI(BGボタン)を設置
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *n){ bg_install_ui(); }];
    }
}
