#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <sys/sysctl.h>

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

// 複垢用ラベル管理（実体は下部の dump セクションで定義）
static void acc_set_current_label(NSString *name);

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
// 既存と衝突しない自動スロット名（サブ1, サブ2, …）を返す
static NSString *acc_suggest_name(void) {
    NSSet *set = [NSSet setWithArray:acc_list()];
    for (int i = 1; i < 1000; i++) {
        NSString *n = [NSString stringWithFormat:@"サブ%d", i];
        if (![set containsObject:n]) return n;
    }
    return [NSString stringWithFormat:@"acct-%ld", (long)time(NULL)];
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
    acc_set_current_label(name);   // 複垢：今アクティブなラベルを記録（GUI抽出のラベル用）
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
        acc_set_current_label(name);   // 複垢：保存した新垢を今アクティブなラベルにする
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

// ==== 新規アカ自動作成：オンボーディングの「はじめる」を自動タップ ====
static void (*g_orig_onbo_vda)(id, SEL, BOOL) = NULL;
static void my_onbo_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (g_orig_onbo_vda) g_orig_onbo_vda(self, _cmd, animated);
    if (![[NSFileManager defaultManager] fileExistsAtPath:docs_path(@"AUTO_CREATE")]) return;
    [[NSFileManager defaultManager] removeItemAtPath:docs_path(@"AUTO_CREATE") error:nil];  // 一度だけ
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            SEL sel = NSSelectorFromString(@"createAccountButton");
            if (![self respondsToSelector:sel]) { L(@"[acc] no createAccountButton"); return; }
            UIButton *b = ((UIButton *(*)(id, SEL))objc_msgSend)(self, sel);
            [b sendActionsForControlEvents:UIControlEventTouchUpInside];
            L(@"[acc] auto-tapped createAccount (button=%@)", b);
        } @catch (NSException *e) { L(@"[acc] auto-tap failed: %@", e); }
    });
}
static void install_onbo_autocreate(void) {
    static BOOL done = NO; if (done) return;
    Class c = objc_getClass("_TtC8mirrativ39OnboardingRegisterOrLoginViewController");
    if (!c) return;   // まだクラス未登録。次の active で再試行
    done = YES;
    Method m = class_getInstanceMethod(c, @selector(viewDidAppear:));
    if (!m) { L(@"[acc] onbo viewDidAppear not found"); return; }
    g_orig_onbo_vda = (void (*)(id, SEL, BOOL))method_getImplementation(m);
    method_setImplementation(m, (IMP)my_onbo_viewDidAppear);
    L(@"[acc] onbo auto-create hook installed");
}

// ==== 名前などプロフィール編集の文字数上限を最低100文字に引き上げ ====
// ProfileEdit* クラスの入力制限デリゲートを差し替え、元がNGでも100文字までは許可（縮めはしない）
static struct { Class c; SEL s; IMP orig; } g_len_reg[128];
static int g_len_n = 0;
static IMP name_find_orig(id self, SEL _cmd) {
    for (Class k = object_getClass(self); k; k = class_getSuperclass(k))
        for (int i = 0; i < g_len_n; i++)
            if (g_len_reg[i].c == k && g_len_reg[i].s == _cmd) return g_len_reg[i].orig;
    return NULL;
}
static BOOL name_should(id self, SEL _cmd, id view, NSRange r, NSString *rep) {
    IMP o = name_find_orig(self, _cmd);
    BOOL ok = o ? ((BOOL (*)(id, SEL, id, NSRange, NSString *))o)(self, _cmd, view, r, rep) : YES;
    if (ok) return YES;                 // 元が許可ならそのまま（bio等の長い制限を縮めない）
    NSString *cur = @"";
    @try { cur = [view text] ?: @""; } @catch (__unused NSException *e) {}
    if (r.location > cur.length) return NO;
    NSInteger newLen = (NSInteger)cur.length - (NSInteger)r.length + (NSInteger)rep.length;
    return newLen <= 100;               // 元がNGでも100文字までは許可
}
static void install_name_limit_hook(void) {
    static BOOL done = NO; if (done) return;
    unsigned int n = 0; Class *cls = objc_copyClassList(&n); if (!cls) return;
    SEL selTF = @selector(textField:shouldChangeCharactersInRange:replacementString:);
    SEL selTV = @selector(textView:shouldChangeTextInRange:replacementText:);
    int hooked = 0;
    for (unsigned int i = 0; i < n; i++) {
        Class c = cls[i]; const char *nm = class_getName(c);
        if (!nm || !strstr(nm, "ProfileEdit")) continue;
        unsigned int mc = 0; Method *ms = class_copyMethodList(c, &mc);
        for (unsigned int j = 0; j < mc; j++) {
            SEL s = method_getName(ms[j]);
            if ((s == selTF || s == selTV) && g_len_n < 128) {
                g_len_reg[g_len_n].c = c; g_len_reg[g_len_n].s = s;
                g_len_reg[g_len_n].orig = method_getImplementation(ms[j]); g_len_n++;
                method_setImplementation(ms[j], (IMP)name_should);
                hooked++;
            }
        }
        if (ms) free(ms);
    }
    free(cls); done = YES;
    L(@"[namelimit] hooked %d ProfileEdit delegate methods (cap->100)", hooked);
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

// ==== 複垢アクション（アプリ内から HTTP を叩く：Pythonツールのネイティブ版）====
// mirrativ_accounts.json を読み、各垢を独立セッション(mr_id cookie + x-uuid)で叩く。
static NSArray<NSDictionary *> *mrv_load_accounts(void) {
    NSData *d = [NSData dataWithContentsOfFile:docs_path(@"mirrativ_accounts.json")];
    if (!d) return @[];
    id root = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    id arr = [root isKindOfClass:NSDictionary.class] ? root[@"accounts"] : root;
    if (![arr isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (id e in arr)
        if ([e isKindOfClass:NSDictionary.class] &&
            [e[@"mr_id"] isKindOfClass:NSString.class] && [e[@"mr_id"] length])
            [out addObject:e];
    return out;
}
static NSString *mrv_enc(NSString *s) {
    static NSCharacterSet *allowed; static dispatch_once_t once;
    dispatch_once(&once, ^{ allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"]; });
    return [([s isKindOfClass:NSString.class] ? s : [NSString stringWithFormat:@"%@", s])
            stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}
static NSString *mrv_form(NSDictionary *body) {
    NSMutableArray *p = [NSMutableArray array];
    for (NSString *k in body) [p addObject:[NSString stringWithFormat:@"%@=%@", mrv_enc(k), mrv_enc(body[k])]];
    return [p componentsJoinedByString:@"&"];
}
// 同期的に1リクエスト実行。JSON(dict)を返す。HTTPコードは httpOut に。
static NSDictionary *mrv_api(NSDictionary *acct, NSString *method, NSString *path,
                            NSDictionary *body, NSInteger *httpOut) {
    NSString *urlStr = [@"https://www.mirrativ.com" stringByAppendingString:path];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.HTTPMethod = method;
    req.HTTPShouldHandleCookies = NO;
    NSString *ua = [NSString stringWithFormat:@"MR_APP/%@/iOS/%@/%@",
                    acct[@"app_ver"] ?: @"", acct[@"model"] ?: @"iPhone", acct[@"os_ver"] ?: @""];
    [req setValue:ua forHTTPHeaderField:@"User-Agent"];
    [req setValue:(acct[@"device_id"] ?: @"") forHTTPHeaderField:@"x-uuid"];
    [req setValue:(acct[@"device_id"] ?: @"") forHTTPHeaderField:@"device_id"];
    [req setValue:(acct[@"idfv"] ?: @"") forHTTPHeaderField:@"x-idfv"];
    [req setValue:@"live_view" forHTTPHeaderField:@"x-referer"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [req setValue:[NSString stringWithFormat:@"mr_id=%@; lang=ja", acct[@"mr_id"] ?: @""]
        forHTTPHeaderField:@"Cookie"];
    [req setValue:[NSString stringWithFormat:@"%.6f", [[NSDate date] timeIntervalSince1970]]
        forHTTPHeaderField:@"x-client-unixtime"];
    if ([method caseInsensitiveCompare:@"POST"] == NSOrderedSame) {
        [req setValue:@"application/x-www-form-urlencoded; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
        req.HTTPBody = [mrv_form(body) dataUsingEncoding:NSUTF8StringEncoding];
    }
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.HTTPCookieStorage = nil; cfg.HTTPShouldSetCookies = NO;
    NSURLSession *sess = [NSURLSession sessionWithConfiguration:cfg];
    __block NSDictionary *result = nil; __block NSInteger code = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *t = [sess dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            if ([resp isKindOfClass:NSHTTPURLResponse.class]) code = [(NSHTTPURLResponse *)resp statusCode];
            if (data) {
                id j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([j isKindOfClass:NSDictionary.class]) result = j;
            }
            dispatch_semaphore_signal(sem);
        }];
    [t resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)));
    if (httpOut) *httpOut = code;
    return result;
}
static BOOL mrv_ok(NSDictionary *json, NSString **msgOut) {
    if (![json isKindOfClass:NSDictionary.class]) { if (msgOut) *msgOut = @"(no json)"; return NO; }
    NSDictionary *st = [json[@"status"] isKindOfClass:NSDictionary.class] ? json[@"status"] : json;
    id flag = st[@"ok"]; if (flag == nil) flag = json[@"ok"];
    NSString *msg = st[@"error"];
    if (![msg isKindOfClass:NSString.class] || !msg.length) msg = st[@"message"];
    if (![msg isKindOfClass:NSString.class] || !msg.length) msg = st[@"msg"];
    if (msgOut) *msgOut = [msg isKindOfClass:NSString.class] ? msg : @"";
    return ([flag isKindOfClass:NSNumber.class] && [flag integerValue] != 0) ||
           [flag isEqual:@"1"];
}
// gift/panels から指定 gift_id が属するパネルの panel_type / reason_id を返す
static NSDictionary *mrv_gift_panel_for(NSDictionary *panelsJson, NSString *giftId) {
    id panels = [panelsJson isKindOfClass:NSDictionary.class] ? panelsJson[@"panels"] : nil;
    if ([panels isKindOfClass:NSArray.class]) {
        for (id p in panels) {
            if (![p isKindOfClass:NSDictionary.class]) continue;
            id pt = p[@"panel_type"] ?: p[@"type"] ?: p[@"tab_type"];
            id rid = p[@"reason_id"] ?: p[@"panel_reason_id"];
            id gifts = p[@"gifts"];
            if (![gifts isKindOfClass:NSArray.class]) continue;
            for (id g in gifts) {
                if (![g isKindOfClass:NSDictionary.class]) continue;
                id gid = g[@"gift_id"] ?: g[@"id"];
                if (gid && [[NSString stringWithFormat:@"%@", gid] isEqualToString:giftId])
                    return @{ @"panel_type": pt  ? [NSString stringWithFormat:@"%@", pt]  : @"",
                              @"reason_id":  rid ? [NSString stringWithFormat:@"%@", rid] : @"" };
            }
        }
    }
    return @{ @"panel_type": @"", @"reason_id": @"" };
}
static void mrv_walk_missions(id o, NSMutableArray *ids) {
    if ([o isKindOfClass:NSDictionary.class]) {
        NSDictionary *d = o;
        if (d[@"id"] && (d[@"progress_status"] || d[@"reward_num"] || d[@"reward_text"] || d[@"status"]))
            [ids addObject:[NSString stringWithFormat:@"%@", d[@"id"]]];
        for (id v in [d allValues]) mrv_walk_missions(v, ids);
    } else if ([o isKindOfClass:NSArray.class]) {
        for (id v in o) mrv_walk_missions(v, ids);
    }
}
static NSArray *mrv_mission_ids(NSDictionary *json) {
    NSMutableArray *ids = [NSMutableArray array];
    mrv_walk_missions(json, ids);
    NSMutableArray *u = [NSMutableArray array];
    for (NSString *x in ids) if (![u containsObject:x]) [u addObject:x];
    return u;
}
// 配信URL/共有URL/素IDから live_id を取り出す
static NSString *mrv_parse_live_id(NSString *text) {
    NSString *t = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!t.length) return @"";
    if ([t rangeOfString:@"/"].location == NSNotFound &&
        [t rangeOfString:@"%"].location == NSNotFound &&
        [t rangeOfString:@":"].location == NSNotFound) return t;
    NSString *prev = @"", *cur = t;
    for (int i = 0; i < 5 && ![cur isEqualToString:prev]; i++) {
        prev = cur; cur = [cur stringByRemovingPercentEncoding] ?: cur;
    }
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"live/([A-Za-z0-9_-]+)"
                                                                       options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:cur options:0 range:NSMakeRange(0, cur.length)];
    if (m && m.numberOfRanges > 1) return [cur substringWithRange:[m rangeAtIndex:1]];
    return t;
}

@interface MRVBGTool : UIViewController <PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
@property(nonatomic,strong) UIButton *btn;
- (void)multiToolMenu;
- (void)giftFlow;
- (void)enterFlow;
- (void)runMissionAll;
- (void)doGiftLive:(NSString *)live gift:(NSString *)gid count:(NSInteger)n;
- (void)askText:(NSString *)title placeholder:(NSString *)ph completion:(void (^)(NSString *))cb;
- (void)showResult:(NSString *)title body:(NSString *)body;
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
    [ac addAction:[UIAlertAction actionWithTitle:@"🚀 複垢ツール（送信/ミッション）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ [self multiToolMenu]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"🌐 通信ログ（gift/send捕捉）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ [self netLogMenu]; }]];
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
    [[NSData data] writeToFile:docs_path(@"NEW_LIGHT") atomically:YES];    // 新UUID＋セッション消去
    [[NSData data] writeToFile:docs_path(@"AUTO_CREATE") atomically:YES];  // 「はじめる」を自動タップ
    [self confirmRelaunch:@"開き直すと、新しい匿名アカウントが自動で作成・ログインされます。"];
}
- (void)deviceResetNow {
    [[NSData data] writeToFile:docs_path(@"RESET_ON") atomically:YES];   // 完全初期化（prefs全消し＝オンボーディングから）
    [self confirmRelaunch:@"次に開いた時に完全初期化されます（初回起動状態）。通常は『新規アカにする』で十分です。"];
}
- (void)newAccountNamed {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"新規アカ作成（名前つき保存）" message:@"作る新アカのスロット名（自動入力済み・変更可）" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf){ tf.placeholder = @"例: サブ2"; tf.text = acc_suggest_name(); tf.clearButtonMode = UITextFieldViewModeWhileEditing; }];
    [a addAction:[UIAlertAction actionWithTitle:@"作成" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){
        NSString *name = [a.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        name = [name stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
        if (!name.length) { [self alert:@"失敗" msg:@"名前が空です"]; return; }
        [[NSData data] writeToFile:docs_path(@"NEW_LIGHT") atomically:YES];           // 新UUID＋セッション消去
        [[NSData data] writeToFile:docs_path(@"AUTO_CREATE") atomically:YES];         // 「はじめる」自動タップ
        [name writeToFile:docs_path(@"_autosave_name.txt") atomically:YES encoding:NSUTF8StringEncoding error:nil]; // 起動後に自動保存
        [self confirmRelaunch:[NSString stringWithFormat:@"開き直すと新規アカを自動作成し、少し使うと自動で「%@」に保存します。", name]];
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
// ==== 複垢ツール UI ====
- (void)askText:(NSString *)title placeholder:(NSString *)ph completion:(void (^)(NSString *))cb {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = ph;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        cb(a.textFields.firstObject.text ?: @"");
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    [self present:a];
}
- (void)showResult:(NSString *)title body:(NSString *)body {
    [body writeToFile:docs_path(@"run_log.txt") atomically:YES encoding:NSUTF8StringEncoding error:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:body preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self present:a];
    });
}
- (void)multiToolMenu {
    NSArray *accts = mrv_load_accounts();
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"複垢ツール"
        message:[NSString stringWithFormat:@"認証情報 %lu 垢（mirrativ_accounts.json）", (unsigned long)accts.count]
        preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"🎁 全垢ギフト送信" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ [self giftFlow]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"🎯 全垢ミッション受取(tutorial)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ [self runMissionAll]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"👀 全垢入室確認" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ [self enterFlow]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"閉じる" style:UIAlertActionStyleCancel handler:nil]];
    [self present:ac];
}
- (void)giftFlow {
    [self askText:@"配信URL または live_id" placeholder:@"https://... / cFb7..." completion:^(NSString *u) {
        NSString *live = mrv_parse_live_id(u);
        if (!live.length) { [self alert:@"エラー" msg:@"live_id を取得できません"]; return; }
        [self askText:@"gift_id" placeholder:@"例: 2" completion:^(NSString *gid) {
            NSString *g = [gid stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!g.length) { [self alert:@"エラー" msg:@"gift_id が空です"]; return; }
            [self askText:@"個数 (count)" placeholder:@"1" completion:^(NSString *c) {
                NSInteger n = [c integerValue]; if (n < 1) n = 1;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    [self doGiftLive:live gift:g count:n];
                });
            }];
        }];
    }];
}
- (void)doGiftLive:(NSString *)live gift:(NSString *)gid count:(NSInteger)n {
    NSArray *accts = mrv_load_accounts();
    NSMutableString *log = [NSMutableString stringWithFormat:@"live=%@ gift=%@ count=%ld\n\n", live, gid, (long)n];
    int okc = 0;
    for (NSDictionary *a in accts) {
        NSInteger http = 0;
        NSDictionary *panels = mrv_api(a, @"GET", [@"/api/gift/panels?live_id=" stringByAppendingString:live], nil, &http);
        NSDictionary *pinfo = mrv_gift_panel_for(panels, gid);
        mrv_api(a, @"GET", [@"/api/live/live?live_id=" stringByAppendingString:live], nil, &http);   // 入室
        NSDictionary *body = @{ @"count": [@(n) stringValue], @"gift_id": gid, @"live_id": live,
                                @"message": @"", @"panel_reason_id": pinfo[@"reason_id"], @"panel_type": pinfo[@"panel_type"] };
        NSString *msg = nil;
        BOOL ok = mrv_ok(mrv_api(a, @"POST", @"/api/gift/send", body, &http), &msg);
        if (ok) okc++;
        [log appendFormat:@"%@: %@ %@\n", a[@"label"] ?: @"?", ok ? @"✔成功" : @"✖",
            ok ? @"" : (msg.length ? msg : [NSString stringWithFormat:@"HTTP %ld", (long)http])];
    }
    [log appendFormat:@"\n成功 %d / %lu 垢", okc, (unsigned long)accts.count];
    [self showResult:@"ギフト送信結果" body:log];
}
- (void)runMissionAll {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray *accts = mrv_load_accounts();
        NSMutableString *log = [NSMutableString string];
        for (NSDictionary *a in accts) {
            NSInteger http = 0;
            NSArray *ids = mrv_mission_ids(mrv_api(a, @"GET", @"/api/mission/tutorial", nil, &http));
            int got = 0; NSString *lastErr = nil;
            for (NSString *mid in ids) {
                NSString *msg = nil;
                if (mrv_ok(mrv_api(a, @"POST", @"/api/mission/receive_reward",
                                   @{ @"mission_id": mid, @"mission_period": @"tutorial" }, &http), &msg))
                    got++;
                else if (msg.length) lastErr = msg;
            }
            [log appendFormat:@"%@: %d件受取%@\n", a[@"label"] ?: @"?", got,
                (got == 0 && lastErr) ? [@"  / " stringByAppendingString:lastErr] : @""];
        }
        [self showResult:@"ミッション受取結果" body:log];
    });
}
- (void)enterFlow {
    [self askText:@"配信URL または live_id" placeholder:@"..." completion:^(NSString *u) {
        NSString *live = mrv_parse_live_id(u);
        if (!live.length) { [self alert:@"エラー" msg:@"live_id 取得不可"]; return; }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSArray *accts = mrv_load_accounts();
            NSMutableString *log = [NSMutableString string];
            for (NSDictionary *a in accts) {
                NSInteger http = 0;
                NSDictionary *lv = mrv_api(a, @"GET", [@"/api/live/live?live_id=" stringByAppendingString:live], nil, &http);
                id onu = [lv isKindOfClass:NSDictionary.class] ? lv[@"online_user_num"] : nil;
                [log appendFormat:@"%@: HTTP%ld online=%@\n", a[@"label"] ?: @"?", (long)http, onu ?: @"?"];
            }
            [self showResult:@"入室確認結果" body:log];
        });
    }];
}
- (void)netLogMenu {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL on  = [fm fileExistsAtPath:docs_path(@"NET_LOG")];
    BOOL all = [fm fileExistsAtPath:docs_path(@"NET_LOG_ALL")];
    unsigned long long sz = [[fm attributesOfItemAtPath:docs_path(@"net_dump.txt") error:nil] fileSize];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"通信ログ"
        message:[NSString stringWithFormat:@"絞込(POST/gift): %@ / 全API(GETも): %@\nnet_dump.txt: %llu bytes\n\n全APIをONにして目的の操作（例: ミッション受け取り）を1回する→OFF→net_dump.txt を回収。",
                 on ? @"ON" : @"OFF", all ? @"ON" : @"OFF", sz]
        preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:(on ? @"絞込捕捉を OFF" : @"絞込捕捉を ON（POST/gift）") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        if (on) [fm removeItemAtPath:docs_path(@"NET_LOG") error:nil];
        else    [[NSData data] writeToFile:docs_path(@"NET_LOG") atomically:YES];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:(all ? @"全API捕捉を OFF" : @"全API捕捉を ON（GETも含む）") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        if (all) [fm removeItemAtPath:docs_path(@"NET_LOG_ALL") error:nil];
        else     [[NSData data] writeToFile:docs_path(@"NET_LOG_ALL") atomically:YES];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"net_dump.txt を消去" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        [fm removeItemAtPath:docs_path(@"net_dump.txt") error:nil];
        [self alert:@"消去しました" msg:@"net_dump.txt を削除しました。"];
    }]];
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
        acc_set_current_label(name);   // 複垢：以後この垢を「name」として GUI に記録
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
    NSArray<NSString *> *slots = acc_list();
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"削除するスロット" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    if (slots.count)
        [ac addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"⚠️ 全%lu件を一括削除", (unsigned long)slots.count]
            style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){ [self accDeleteAll]; }]];
    for (NSString *n in slots) {
        [ac addAction:[UIAlertAction actionWithTitle:n style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){
            [[NSFileManager defaultManager] removeItemAtPath:acc_slot(n) error:nil];
            [self alert:@"削除しました" msg:n];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    [self present:ac];
}
- (void)accDeleteAll {
    NSArray<NSString *> *slots = acc_list();
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"全スロット削除"
        message:[NSString stringWithFormat:@"保存済みの %lu 件をすべて削除します。元に戻せません。よろしいですか？", (unsigned long)slots.count]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"全部削除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){
        NSFileManager *fm = [NSFileManager defaultManager];
        NSUInteger n = 0;
        for (NSString *s in slots)
            if ([fm removeItemAtPath:acc_slot(s) error:nil]) n++;
        [self alert:@"削除しました" msg:[NSString stringWithFormat:@"%lu 件のスロットを削除しました。", (unsigned long)n]];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    [self present:a];
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
    acc_set_current_label(nil);   // 複垢：新規垢はまだ無名（名前付き保存されるまでラベル未確定）
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

// ==== device_id / User-Agent 抽出（Pythonクライアント用） ====
// アプリが実際に送る device_id を全ソースから読み、Documents/device_id.txt に吐く。
// httpHeaders の device_id は DeviceIDUtil.getUUID()（App-Group cache → Keychain の順）。
static NSString *read_keychain_uuid(void) {
    NSDictionary *q = @{ (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
                         (__bridge id)kSecAttrAccount:  @"com.dena.mirrativ.uuid",
                         (__bridge id)kSecReturnData:   @YES,
                         (__bridge id)kSecMatchLimit:   (__bridge id)kSecMatchLimitOne };
    CFTypeRef res = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &res) == errSecSuccess && res) {
        NSData *d = (NSData *)CFBridgingRelease(res);
        return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    }
    return nil;
}
static NSString *device_model(void) {
    char buf[64] = {0}; size_t len = sizeof(buf);
    if (sysctlbyname("hw.machine", buf, &len, NULL, 0) == 0 && buf[0])
        return [NSString stringWithUTF8String:buf];
    return @"iPhone";
}
static void dump_device_id(void) {
    NSString *SUITE = @"group.com.dena.mirrativ.shared";
    NSString *kc  = read_keychain_uuid();
    NSString *std = [[NSUserDefaults standardUserDefaults] stringForKey:@"deviceUUID"];
    NSString *grp = [[[NSUserDefaults alloc] initWithSuiteName:SUITE] stringForKey:@"deviceUUID"];
    NSString *eff = grp ?: (kc ?: std);   // 実効 device_id（getUUID の優先順）
    NSString *idfv = g_fakeIDFV ?: [[[UIDevice currentDevice] identifierForVendor] UUIDString];
    NSString *ver  = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSString *os   = [[UIDevice currentDevice] systemVersion];
    NSString *model = device_model();
    NSString *ua = [NSString stringWithFormat:@"MR_APP/%@/iOS/%@/%@", ver ?: @"?", model, os ?: @"?"];

    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"# Mirrativ device_id dump  %@\n", [NSDate date]];
    [s appendFormat:@"DEVICE_ID (effective) = %@\n", eff ?: @"(nil)"];
    [s appendFormat:@"  keychain(com.dena.mirrativ.uuid) = %@\n", kc  ?: @"(nil)"];
    [s appendFormat:@"  std.deviceUUID                   = %@\n", std ?: @"(nil)"];
    [s appendFormat:@"  group.deviceUUID                 = %@\n", grp ?: @"(nil)"];
    [s appendFormat:@"IDFV (x-idfv)         = %@\n", idfv ?: @"(nil)"];
    [s appendFormat:@"USER_AGENT            = %@\n", ua];
    [s appendString:@"\n--- mirrativ_login.py に貼る ---\n"];
    [s appendFormat:@"DEVICE_ID   = \"%@\"\n", eff ?: @""];
    [s appendFormat:@"IDFV        = \"%@\"\n", idfv ?: @""];
    [s appendFormat:@"APP_VERSION = \"%@\"\n", ver ?: @""];
    [s appendFormat:@"MODEL       = \"%@\"\n", model];
    [s appendFormat:@"OS_VERSION  = \"%@\"\n", os ?: @""];
    [s writeToFile:docs_path(@"device_id.txt") atomically:YES encoding:NSUTF8StringEncoding error:nil];
    L(@"[dump] device_id=%@ ua=%@ -> Documents/device_id.txt", eff, ua);
}

// ==== 認証 cookie(mr_id 等) を Documents/cookies.txt に吐く（本アカ固定用） ====
// AuthCookieStorage は NSHTTPCookieStorage に保存。mr_id が本アカのセッション identity。
static void dump_cookies(void) {
    NSHTTPCookieStorage *cs = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    NSMutableString *s   = [NSMutableString string];
    NSMutableString *hdr = [NSMutableString string];   // Cookie: ヘッダ形式
    NSMutableString *py  = [NSMutableString string];   // python dict
    [s appendFormat:@"# Mirrativ cookies  %@\n", [NSDate date]];
    int n = 0;
    for (NSHTTPCookie *c in cs.cookies) {
        NSString *dom = c.domain ?: @"";
        if ([dom rangeOfString:@"mirrativ" options:NSCaseInsensitiveSearch].location == NSNotFound)
            continue;   // mirrativ ドメインのみ
        n++;
        [s appendFormat:@"%@=%@   (domain=%@ path=%@ secure=%d expires=%@)\n",
            c.name, c.value, dom, c.path, c.isSecure, c.expiresDate ?: @"(session)"];
        if (hdr.length) [hdr appendString:@"; "];
        [hdr appendFormat:@"%@=%@", c.name, c.value];
        [py appendFormat:@"    \"%@\": \"%@\",\n", c.name, c.value];
    }
    [s appendFormat:@"\n--- Cookie ヘッダ形式 ---\n%@\n", hdr];
    [s appendFormat:@"\n--- python (mirrativ_login.py の COOKIES に貼る) ---\nCOOKIES = {\n%@}\n", py];
    [s appendFormat:@"\n(mirrativ cookies: %d 件)\n", n];
    [s writeToFile:docs_path(@"cookies.txt") atomically:YES encoding:NSUTF8StringEncoding error:nil];
    L(@"[dump] cookies -> Documents/cookies.txt (%d mirrativ cookies)", n);
}

// ==== mirrativ_gui.py 用に “入力フィールドの中身” を1ファイルに集約して吐く ====
// GUI の DEFAULTS と同じキー名(device_id/mr_id/idfv/app_ver/model/os_ver)で
//   Documents/mirrativ_gui.json … GUI が起動時に自動ロードする機械可読ファイル
//   Documents/mirrativ_gui.txt  … 手貼り用の人間可読ブロック
// を出力する。live_id / gift_* は実行時に手入力する項目なので含めない。
static NSString *read_mr_cookie(void) {   // 本アカのセッション identity = mr_id
    NSHTTPCookieStorage *cs = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    for (NSHTTPCookie *c in cs.cookies) {
        NSString *dom = c.domain ?: @"";
        if ([dom rangeOfString:@"mirrativ" options:NSCaseInsensitiveSearch].location == NSNotFound)
            continue;
        if ([c.name caseInsensitiveCompare:@"mr_id"] == NSOrderedSame) return c.value;
    }
    return nil;
}

// ==== 複垢対応：今アクティブなアカウントのラベル（スロット名）を保持 ====
static NSString *acc_current_label(void) {
    NSString *s = [NSString stringWithContentsOfFile:docs_path(@"_current_account.txt")
                                            encoding:NSUTF8StringEncoding error:nil];
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return s.length ? s : nil;
}
static void acc_set_current_label(NSString *name) {
    NSString *p = docs_path(@"_current_account.txt");
    NSString *n = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (n.length) [n writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
    else          [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
}

// mirrativ_accounts.json に、アクティブ垢の設定を mr_id をキーに upsert（複垢を蓄積）
static void gui_write_accounts(NSDictionary *cfg, NSString *label) {
    NSString *mr = cfg[@"mr_id"];
    if (![mr isKindOfClass:NSString.class] || mr.length == 0) return;   // アクティブ垢のみ記録

    NSString *path = docs_path(@"mirrativ_accounts.json");
    NSMutableArray *accts = [NSMutableArray array];
    NSData *old = [NSData dataWithContentsOfFile:path];
    if (old) {
        id root = [NSJSONSerialization JSONObjectWithData:old options:0 error:nil];
        id arr  = [root isKindOfClass:NSDictionary.class] ? root[@"accounts"] : root;
        if ([arr isKindOfClass:NSArray.class])
            for (id e in arr) if ([e isKindOfClass:NSDictionary.class]) [accts addObject:[e mutableCopy]];
    }

    NSMutableDictionary *entry = [cfg mutableCopy];
    entry[@"label"]   = label.length ? label
                        : [@"acct-" stringByAppendingString:(mr.length > 4 ? [mr substringFromIndex:mr.length - 4] : mr)];
    entry[@"updated"] = [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]];

    BOOL replaced = NO;
    for (NSUInteger i = 0; i < accts.count; i++) {
        id em = accts[i][@"mr_id"];
        if ([em isKindOfClass:NSString.class] && [em isEqualToString:mr]) {
            accts[i] = entry; replaced = YES; break;
        }
    }
    if (!replaced) [accts addObject:entry];

    NSData *jd = [NSJSONSerialization dataWithJSONObject:@{ @"accounts": accts }
                                                options:NSJSONWritingPrettyPrinted error:nil];
    if (jd) [jd writeToFile:path atomically:YES];
    L(@"[gui] accounts upsert label=%@ total=%lu", entry[@"label"], (unsigned long)accts.count);
}
static void dump_gui_config(void) {
    NSString *SUITE = @"group.com.dena.mirrativ.shared";
    NSString *kc  = read_keychain_uuid();
    NSString *std = [[NSUserDefaults standardUserDefaults] stringForKey:@"deviceUUID"];
    NSString *grp = [[[NSUserDefaults alloc] initWithSuiteName:SUITE] stringForKey:@"deviceUUID"];
    NSString *device_id = grp ?: (kc ?: std);   // 実効 device_id（getUUID の優先順）
    NSString *idfv  = g_fakeIDFV ?: [[[UIDevice currentDevice] identifierForVendor] UUIDString];
    NSString *ver   = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSString *os    = [[UIDevice currentDevice] systemVersion];
    NSString *model = device_model();
    NSString *mr_id = read_mr_cookie();

    // GUI の DEFAULTS キーに一致させる。値が無い項目は空文字（GUI 側で既定を残せる）。
    NSDictionary *cfg = @{
        @"device_id": device_id ?: @"",
        @"mr_id":     mr_id     ?: @"",
        @"idfv":      idfv      ?: @"",
        @"app_ver":   ver       ?: @"",
        @"model":     model     ?: @"",
        @"os_ver":    os        ?: @"",
    };

    NSError *je = nil;
    NSData *jd = [NSJSONSerialization dataWithJSONObject:cfg
                                                options:NSJSONWritingPrettyPrinted
                                                  error:&je];
    if (jd) {
        [jd writeToFile:docs_path(@"mirrativ_gui.json") atomically:YES];
    } else {
        L(@"[gui] json serialize failed: %@", je.localizedDescription);
    }

    // 手貼り用（GUI の DEFAULTS にそのまま写せる形）
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"# mirrativ_gui.py 用 抽出結果  %@\n", [NSDate date]];
    [s appendString:@"# Documents/mirrativ_gui.json を GUI が自動ロードします（手貼り不要）。\n"];
    [s appendString:@"# 手で入れる場合は下記を各フィールドへ。\n\n"];
    [s appendFormat:@"device_id = %@\n", device_id ?: @"(nil)"];
    [s appendFormat:@"mr_id     = %@\n", mr_id     ?: @"(nil / 未ログイン)"];
    [s appendFormat:@"idfv      = %@\n", idfv      ?: @"(nil)"];
    [s appendFormat:@"app_ver   = %@\n", ver       ?: @"(nil)"];
    [s appendFormat:@"model     = %@\n", model];
    [s appendFormat:@"os_ver    = %@\n", os        ?: @"(nil)"];
    [s writeToFile:docs_path(@"mirrativ_gui.txt") atomically:YES encoding:NSUTF8StringEncoding error:nil];

    // 複垢蓄積：アクティブ垢を mirrativ_accounts.json に upsert（現在のスロット名でラベル）
    gui_write_accounts(cfg, acc_current_label());

    L(@"[gui] config -> Documents/mirrativ_gui.json (mr_id=%@)",
      mr_id ? @"present" : @"none");
}

// ==== 通信ロガー：アプリ実物の gift/send 等リクエストを丸ごと吐く ====
// Documents/NET_LOG がある時だけ、mirrativ 宛の POST（と /gift 系）を
// URL・全ヘッダ（署名含む）・ボディ付きで Documents/net_dump.txt に追記する。
// これで gift/send の“本物”のパラメータ・署名ヘッダが分かり、Python から再現できる。
static BOOL net_log_on(void) {   // 絞り込み捕捉（POST と /gift のみ）
    return [[NSFileManager defaultManager] fileExistsAtPath:docs_path(@"NET_LOG")];
}
static BOOL net_log_all(void) {  // 全API捕捉（GETも含む。mission 調査用）
    return [[NSFileManager defaultManager] fileExistsAtPath:docs_path(@"NET_LOG_ALL")];
}
static void net_dump_request(NSURLRequest *req, NSData *bodyOverride) {
    @try {
        BOOL on = net_log_on(), all = net_log_all();
        if (!on && !all) return;
        NSString *url = req.URL.absoluteString ?: @"";
        if ([url rangeOfString:@"mirrativ" options:NSCaseInsensitiveSearch].location == NSNotFound) return;
        if ([url rangeOfString:@"cdn.mirrativ.com" options:NSCaseInsensitiveSearch].location != NSNotFound) return;   // 画像等は除外
        if ([url rangeOfString:@"clog.mirrativ.com" options:NSCaseInsensitiveSearch].location != NSNotFound) return;  // 分析ログは除外
        NSString *method = req.HTTPMethod ?: @"GET";
        BOOL isPost = [method caseInsensitiveCompare:@"POST"] == NSOrderedSame;
        BOOL isGift = [url rangeOfString:@"gift" options:NSCaseInsensitiveSearch].location != NSNotFound;
        if (!all && !isPost && !isGift) return;   // 絞り込み時は POST と gift だけ（全API時は全部）

        NSString *path = docs_path(@"net_dump.txt");
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attr = [fm attributesOfItemAtPath:path error:nil];
        if (attr && [attr fileSize] > 512 * 1024) [fm removeItemAtPath:path error:nil];  // 肥大化防止

        NSMutableString *s = [NSMutableString string];
        [s appendFormat:@"\n===== %@  %@ =====\n", [NSDate date], method];
        [s appendFormat:@"URL: %@\n", url];
        [s appendString:@"-- headers --\n"];
        [req.allHTTPHeaderFields enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
            [s appendFormat:@"%@: %@\n", k, v];
        }];
        NSData *body = bodyOverride ?: req.HTTPBody;
        [s appendString:@"-- body --\n"];
        if (body.length) {
            NSString *bs = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
            if (bs) [s appendFormat:@"%@\n", bs];
            else    [s appendFormat:@"(binary %lu bytes) base64=%@\n",
                     (unsigned long)body.length, [body base64EncodedStringWithOptions:0]];
        } else if (req.HTTPBodyStream) {
            [s appendString:@"(body via HTTPBodyStream, not captured)\n"];
        } else {
            [s appendString:@"(no body)\n"];
        }
        NSString *prev = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        [(prev ? [prev stringByAppendingString:s] : s)
            writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        L(@"[net] dumped %@ %@", method, url);
    } @catch (__unused NSException *e) {}
}

// NSURLSession の各送信メソッドを差し替え（元を呼ぶ前に丸ごとダンプ）
static id (*o_dtr_ch)(id, SEL, NSURLRequest *, id) = NULL;
static id s_dtr_ch(id self, SEL _cmd, NSURLRequest *req, id h) {
    net_dump_request(req, nil); return o_dtr_ch(self, _cmd, req, h);
}
static id (*o_dtr)(id, SEL, NSURLRequest *) = NULL;
static id s_dtr(id self, SEL _cmd, NSURLRequest *req) {
    net_dump_request(req, nil); return o_dtr(self, _cmd, req);
}
static id (*o_utr_d_ch)(id, SEL, NSURLRequest *, NSData *, id) = NULL;
static id s_utr_d_ch(id self, SEL _cmd, NSURLRequest *req, NSData *d, id h) {
    net_dump_request(req, d); return o_utr_d_ch(self, _cmd, req, d, h);
}
static id (*o_utr_d)(id, SEL, NSURLRequest *, NSData *) = NULL;
static id s_utr_d(id self, SEL _cmd, NSURLRequest *req, NSData *d) {
    net_dump_request(req, d); return o_utr_d(self, _cmd, req, d);
}
static void net_hook(Class c, SEL sel, IMP newImp, void *origStore) {
    if (!c) return;
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;
    if (*(IMP *)origStore) return;   // 二重フック防止
    *(IMP *)origStore = method_getImplementation(m);
    method_setImplementation(m, newImp);
}
static void install_net_logger(void) {
    static BOOL done = NO; if (done) return; done = YES;
    Class c = objc_getClass("NSURLSession");
    if (!c) { L(@"[net] NSURLSession not found"); return; }
    net_hook(c, @selector(dataTaskWithRequest:completionHandler:), (IMP)s_dtr_ch, &o_dtr_ch);
    net_hook(c, @selector(dataTaskWithRequest:),                   (IMP)s_dtr,    &o_dtr);
    net_hook(c, @selector(uploadTaskWithRequest:fromData:completionHandler:), (IMP)s_utr_d_ch, &o_utr_d_ch);
    net_hook(c, @selector(uploadTaskWithRequest:fromData:),        (IMP)s_utr_d,  &o_utr_d);
    L(@"[net] URLSession logger installed (gate: Documents/NET_LOG) -> Documents/net_dump.txt");
}

// dylib ロード時（アプリの main より前）に1回だけ実行される
__attribute__((constructor))
static void reset_gate(void) {
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];

        // オンボーディング自動タップのフックを早期に仕込む（間に合わなければ active で再試行）
        install_onbo_autocreate();

        // 通信ロガーを仕込む（実際に動くのは Documents/NET_LOG がある時だけ）
        install_net_logger();

        // アカウント切替が予約されていれば、デバイスリセットより優先して復元しこの起動は終了
        if (acc_restore_pending()) {
            L(@"[acc] switched account this launch -> skip device reset");
            load_fake_idfv();
            install_idfv_spoof();
            dump_device_id();   // 復元したアカウントの device_id も吐く
            dump_gui_config();  // GUI 用に device_id/idfv/... をまとめて吐く（mr_id は active で補完）
            [[NSNotificationCenter defaultCenter]
                addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *n){ bg_install_ui(); install_onbo_autocreate(); install_name_limit_hook(); dump_cookies(); dump_gui_config(); }];
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

        // 実効 device_id / User-Agent を Documents/device_id.txt に吐く（Pythonクライアント用）
        dump_device_id();
        // 永続化済み cookie(mr_id 等) を吐く（前回セッションの本アカ cookie を回収）
        dump_cookies();
        // GUI(mirrativ_gui.py)の入力フィールドの中身を1ファイルに集約して吐く
        dump_gui_config();

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
                    usingBlock:^(NSNotification *n){ bg_install_ui(); install_onbo_autocreate(); install_name_limit_hook(); dump_cookies(); dump_gui_config(); }];
    }
}
