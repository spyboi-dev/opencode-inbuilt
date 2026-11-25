// OCSettings - app settings.
// Server URL points at the in-app engine (OpenCode on 127.0.0.1:4096).
// The server password lives in the Keychain only, never in a file or a log.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface OCSettings : NSObject
+ (instancetype)shared;
@property (nonatomic, copy) NSString *serverURL; // default http://127.0.0.1:4096
@property (nonatomic, copy) NSString *model;     // model id, "" = server default
@property (nonatomic, copy) NSString *modelProviderID;
@property (nonatomic, copy) NSString *agent;     // "build" or "plan"
- (nullable NSString *)serverPassword;
- (void)setServerPassword:(nullable NSString *)password;
- (NSString *)ensureServerPassword; // generates and stores one if missing
@property (nonatomic, readonly) BOOL hasServerPassword;
- (void)save;
- (void)load;
@end

NS_ASSUME_NONNULL_END
