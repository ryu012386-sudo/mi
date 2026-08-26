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

        NSString *docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];

        // 手段B：Documents/RESET_ON（有無）— 1回だけリセット（モードB, 自動で消す）
        NSString *flagOnce = [docs stringByAppendingPathComponent:@"RESET_ON"];
        BOOL byFile = [fm fileExistsAtPath:flagOnce];

        // 手段C：Documents/RESET_EVERY（有無）— 冷起動ごとに毎回リセット（モードA, 消さず永続）
        NSString *flagEvery = [docs stringByAppendingPathComponent:@"RESET_EVERY"];
        BOOL byEvery = [fm fileExistsAtPath:flagEvery];

        BOOL armed = (bySetting || byFile || byEvery);
        L(@"gate: setting=%d once=%d every=%d armed=%d", bySetting, byFile, byEvery, armed);

        if (armed) {
            L(@"ARMED -> wiping");
            do_wipe();  // ← std の <bundleID>.plist を消すので設定スイッチは自動でOFFに戻る
            if (byFile) {
                NSError *e = nil;
                BOOL removed = [fm removeItemAtPath:flagOnce error:&e];
                L(@"disarm once: removed RESET_ON=%d (%@)", removed, e ? e.localizedDescription : @"ok");
            }
            if (byEvery) L(@"RESET_EVERY present -> will reset again on next cold launch");
            L(@"-> done");
        } else {
            L(@"OFF: keep current device (stable/verified)");
        }

        // ---- ログに頼らない確認用：毎起動 Documents に状態を追記 ----
        NSString *status = [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"]
                            stringByAppendingPathComponent:@"uuidreset_status.txt"];
        NSString *line = [NSString stringWithFormat:@"%@  setting=%d file=%d armed=%d  bundleID=%@\n",
                          [NSDate date], bySetting, byFile, armed,
                          [[NSBundle mainBundle] bundleIdentifier]];
        NSString *prev = [NSString stringWithContentsOfFile:status encoding:NSUTF8StringEncoding error:nil];
        NSString *out  = prev ? [prev stringByAppendingString:line] : line;
        [out writeToFile:status atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}
