#import <Foundation/Foundation.h>
#import <Security/Security.h>

static void L(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[uuid-reset] %@", m);
}

static void do_wipe(void) {
    NSString *SUITE = @"group.com.dena.mirrativ.shared";
    NSString *KEY   = @"deviceUUID";

    NSUserDefaults *std = [NSUserDefaults standardUserDefaults];
    NSUserDefaults *grp = [[NSUserDefaults alloc] initWithSuiteName:SUITE];
    L(@"before: std[%@]=%@", KEY, [std stringForKey:KEY]);
    L(@"before: grp[%@]=%@", KEY, [grp stringForKey:KEY]);
    L(@"runtime bundleID = %@", [[NSBundle mainBundle] bundleIdentifier]);

    // 1) Keychain: generic password の該当 account のみ（配信/TLS鍵は温存）
    NSDictionary *q = @{
        (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccount: @"com.dena.mirrativ.uuid",
    };
    OSStatus st = SecItemDelete((__bridge CFDictionaryRef)q);
    L(@"keychain(generic,uuid) delete=%d", (int)st);

    // 2) deviceUUID キーを直接削除
    [std removeObjectForKey:KEY]; [std synchronize];
    [grp removeObjectForKey:KEY]; [grp synchronize];

    // 3) Preferences: "mirrativ" を含む plist のみ削除（無関係SDKは温存）
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
    L(@"wiped -> new device this launch");
}

// dylib ロード時（アプリの main より前）に1回だけ実行される
__attribute__((constructor))
static void reset_gate(void) {
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];

        // トグル手段A：iOS設定アプリのスイッチ（Settings.bundle の Key）
        BOOL bySetting = [[NSUserDefaults standardUserDefaults] boolForKey:@"reset_on_next_launch"];

        // トグル手段B：Documents/RESET_ON（ファイル/フォルダの有無）— 設定を使わない場合の代替
        NSString *flag = [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"]
                          stringByAppendingPathComponent:@"RESET_ON"];
        BOOL byFile = [fm fileExistsAtPath:flag];

        L(@"gate: setting=%d file=%d", bySetting, byFile);

        if (bySetting || byFile) {
            L(@"ARMED -> wiping once");
            do_wipe();  // ← std の <bundleID>.plist を消すので設定スイッチは自動でOFFに戻る
            if (byFile) {
                NSError *e = nil;
                BOOL removed = [fm removeItemAtPath:flag error:&e];
                L(@"disarm file: removed RESET_ON=%d (%@)", removed, e ? e.localizedDescription : @"ok");
            }
            L(@"-> stable from next launch. Toggle ON again to reset again.");
        } else {
            L(@"OFF: keep current device (stable/verified)");
        }
    }
}
