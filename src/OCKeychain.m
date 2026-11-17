#import "OCKeychain.h"
#import <Security/Security.h>

static NSString *const kService = @"com.spyboy.opencode";

@implementation OCKeychain

+ (NSMutableDictionary *)queryForAccount:(NSString *)account {
    return [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kService,
        (__bridge id)kSecAttrAccount: account,
    } mutableCopy];
}

+ (BOOL)setValue:(NSString *)value forAccount:(NSString *)account {
    if (!value.length) return [self deleteValueForAccount:account];
    NSMutableDictionary *q = [self queryForAccount:account];
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    OSStatus s = SecItemUpdate((__bridge CFDictionaryRef)q,
        (__bridge CFDictionaryRef)@{(__bridge id)kSecValueData: data});
    if (s == errSecItemNotFound) {
        [q setObject:data forKey:(__bridge id)kSecValueData];
        s = SecItemAdd((__bridge CFDictionaryRef)q, NULL);
    }
    return s == errSecSuccess;
}

+ (nullable NSString *)valueForAccount:(NSString *)account {
    NSMutableDictionary *q = [self queryForAccount:account];
    q[(__bridge id)kSecReturnData] = @YES;
    q[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef out = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &out) != errSecSuccess) return nil;
    NSData *d = (__bridge_transfer NSData *)out;
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

+ (BOOL)deleteValueForAccount:(NSString *)account {
    return SecItemDelete((__bridge CFDictionaryRef)[self queryForAccount:account]) == errSecSuccess;
}

@end
