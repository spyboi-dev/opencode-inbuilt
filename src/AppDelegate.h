// AppDelegate - tab bar: Sessions, Files, Engine, Settings.
// The engine is started from the Engine tab (first-launch setup, then Start).
// No network work happens at launch beyond the engine health check.
#import <UIKit/UIKit.h>

@interface OCAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong, nullable) UIWindow *window;
@end
