// AppDelegate - tab bar: Sessions, Files, Engine, Settings.
// The engine auto-starts on launch when it can (core linked, setup
// done); otherwise it is started from the Engine tab.
// No network work happens at launch beyond the engine health check.
//
// Background: the app asks for Always location so iOS keeps it
// running in the background, and with it the in-process guest
// engine. Location is only used to keep the app alive; it is never
// stored or sent anywhere. See KERNARIUM-ENGINE.md, "Background".
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>

@interface OCAppDelegate : UIResponder <UIApplicationDelegate, CLLocationManagerDelegate>
@property (nonatomic, strong, nullable) UIWindow *window;
@property (nonatomic, strong, nullable) CLLocationManager *locationManager;
@end
