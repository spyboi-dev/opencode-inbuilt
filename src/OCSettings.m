// OCSettings - inbuilt-engine app settings.
#import "OCSettings.h"
#import "OCKeychain.h"

static NSString *const kServerURL = @"oc.serverURL";
static NSString *const kModel = @"oc.model";
static NSString *const kModelProvider = @"oc.modelProvider";
static NSString *const kAgent = @"oc.agent";
static NSString *const kEngineMode = @"oc.engineMode";
static NSString *const kPasswordAccount = @"opencode-server-password";

@implementation OCSettings

+ (instancetype)shared {
    static OCSettings *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[OCSettings alloc] init]; [s load]; });
    return s;
}

- (void)load {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    _serverURL = [d stringForKey:kServerURL] ?: @"http://127.0.0.1:4096";
    _model = [d stringForKey:kModel] ?: @"";
    _modelProviderID = [d stringForKey:kModelProvider] ?: @"";
    _agent = [d stringForKey:kAgent] ?: @"build";
    _engineMode = [d stringForKey:kEngineMode] ?: @"cli";
    if (![_engineMode isEqualToString:@"desktop"]) _engineMode = @"cli";
}

- (void)save {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:_serverURL forKey:kServerURL];
    [d setObject:_model forKey:kModel];
    [d setObject:_modelProviderID forKey:kModelProvider];
    [d setObject:_agent forKey:kAgent];
    [d setObject:_engineMode forKey:kEngineMode];
    [d synchronize];
}

- (nullable NSString *)serverPassword {
    return [OCKeychain valueForAccount:kPasswordAccount];
}

- (void)setServerPassword:(nullable NSString *)password {
    [OCKeychain setValue:password ?: @"" forAccount:kPasswordAccount];
}

- (BOOL)hasServerPassword { return [self serverPassword].length > 0; }

- (NSString *)ensureServerPassword {
    NSString *existing = [self serverPassword];
    if (existing.length) return existing;
    // 32 hex chars from the secure random source. Never logged.
    uint8_t bytes[16];
    arc4random_buf(bytes, sizeof(bytes));
    NSMutableString *pw = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < 16; i++) [pw appendFormat:@"%02x", bytes[i]];
    [self setServerPassword:pw];
    return pw;
}

@end
