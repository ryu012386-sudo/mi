#import <Foundation/Foundation.h>
#import <Security/Security.h>

static void L(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[uuid-reset] %@", m);
}

// dylib ロード時（アプリの main より前）に1回だけ実行される
__attribute__((constructor))
static void wipe_device_identity(void) {
    @autoreleasepool {
        NSString *SUITE = @"group.com.dena.mirrativ.shared";
        NSString *KEY   = @"deviceUUID";

        // ---- 診断：削除前に値の在り処をログ ----
        NSUserDefaults *std = [NSUserDefaults standardUserDefaults];
        NSUserDefaults *grp = [[NSUserDefaults alloc] initWithSuiteName:SUITE];
        L(@"before: std[%@]=%@", KEY, [std stringForKey:KEY]);
        L(@"before: grp[%@]=%@", KEY, [grp stringForKey:KEY]);

        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        L(@"runtime bundleID = %@", bid);

        // ---- 1) Keychain 全クラスを account 指定なしで削除 ----
        CFTypeRef classes[] = {
            kSecClassGenericPassword, kSecClassInternetPassword,
            kSecClassCertificate, kSecClassKey, kSecClassIdentity
        };
        for (int i = 0; i < 5; i++) {
            NSDictionary *q = @{ (__bridge id)kSecClass: (__bridge id)classes[i] };
            OSStatus st = SecItemDelete((__bridge CFDictionaryRef)q);
            L(@"keychain class %d delete=%d", i, (int)st);
        }

        // ---- 2) standardUserDefaults（bundleID ドメイン）----
        [std removeObjectForKey:KEY];
        if (bid) [std removePersistentDomainForName:bid];
        [std synchronize];

        // ---- 3) App Group suite（フォールバック plist）----
        [grp removeObjectForKey:KEY];
        [grp removePersistentDomainForName:SUITE];
        [grp synchronize];

        // ---- 4) ファイルレベル：Library/Preferences の全 plist を削除 ----
        NSString *prefs = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences"];
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *f in [fm contentsOfDirectoryAtPath:prefs error:nil]) {
            if ([f hasSuffix:@".plist"]) {
                NSString *p = [prefs stringByAppendingPathComponent:f];
                BOOL ok = [fm removeItemAtPath:p error:nil];
                L(@"rm pref %@ ok=%d", f, ok);
            }
        }

        L(@"done -> new device this launch");
    }
}
