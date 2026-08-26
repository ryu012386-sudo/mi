#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <objc/runtime.h>

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
    }
}
