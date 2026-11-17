// OCKeychain - thin SecItem wrapper. Key never leaves the device, never logged.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface OCKeychain : NSObject
+ (BOOL)setValue:(NSString *)value forAccount:(NSString *)account;
+ (nullable NSString *)valueForAccount:(NSString *)account;
+ (BOOL)deleteValueForAccount:(NSString *)account;
@end

NS_ASSUME_NONNULL_END
