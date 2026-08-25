#import <Foundation/Foundation.h>
#import <Security/Security.h>

// dylib ロード時（アプリの main より前）に1回だけ実行される
__attribute__((constructor))
static void wipe_device_identity(void) {
    @autoreleasepool {
        // 1. App Group UserDefaults の deviceUUID を削除
        NSUserDefaults *ud = [[NSUserDefaults alloc]
            initWithSuiteName:@"group.com.dena.mirrativ.shared"];
        [ud removeObjectForKey:@"deviceUUID"];
        [ud synchronize];

        // 2. Keychain の generic password (account=com.dena.mirrativ.uuid) を削除
        NSDictionary *q = @{
            (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrAccount: @"com.dena.mirrativ.uuid",
        };
        OSStatus st = SecItemDelete((__bridge CFDictionaryRef)q);

        NSLog(@"[uuid-reset] keychain delete status=%d (0=deleted, -25300=none) "
              @"-> new device this launch", (int)st);
    }
}
