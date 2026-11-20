// AppDelegate - tab bar: Sessions, Files, Engine, Settings.
// The engine auto-starts on launch when it can (core linked, setup
// done); otherwise it is started from the Engine tab.
// No network work happens at launch beyond the engine health check.
#import <UIKit/UIKit.h>

@interface OCAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong, nullable) UIWindow *window;
@end
