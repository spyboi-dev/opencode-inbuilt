// AppDelegate - FreeMilk's two home tabs: Threads and Integrations.
// The chat opens over them; Files lives inside the chat (Chat/Files
// switch) and the Engine and Settings screens live in Integrations.
#import "AppDelegate.h"
#import "OCCrashLog.h"
#import "OCSessionsViewController.h"
#import "OCIntegrationsViewController.h"
#import "OCStartupViewController.h"
#import "OCEngine.h"

#ifdef OC_KERNARIUM_LINKED
#import "KernGlue.h"
#endif

@implementation OCAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // Crash recorder first, before anything else runs: a launch
    // crash must leave one line in the engine log, or there is
    // nothing to diagnose it with. The log file is
    // Documents/Engine/engine.log; the Engine tab shows it, and
    // the Files app can open it (UIFileSharingEnabled).
    OCCrashLogInstall([[OCEngine shared] engineLogPath]);
    [[OCEngine shared] appendEngineLogSync:@"--- App launch ---"];
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

    OCSessionsViewController *sessions = [[OCSessionsViewController alloc] init];
    UINavigationController *sessionsNav = [[UINavigationController alloc] initWithRootViewController:sessions];
    sessionsNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Threads" image:[UIImage systemImageNamed:@"bubble.left.and.bubble.right"] tag:0];

    OCIntegrationsViewController *integrations = [[OCIntegrationsViewController alloc] init];
    UINavigationController *integrationsNav = [[UINavigationController alloc] initWithRootViewController:integrations];
    integrationsNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Integrations" image:[UIImage systemImageNamed:@"square.grid.2x2"] tag:1];

    UITabBarController *tabs = [[UITabBarController alloc] init];
    tabs.viewControllers = @[sessionsNav, integrationsNav];
    self.window.rootViewController = tabs;
    [self.window makeKeyAndVisible];

    // Background execution: Always location keeps the app (and the
    // in-process guest engine) alive in the background. The prompt
    // copy in Info.plist says plainly what it is for. Location
    // updates start once permission is granted; until then the app
    // behaves as before.
    [self startLocationForBackground];

    // Engine state only, then auto-start when it can start: the
    // guest core is linked and first-launch setup already saved the
    // guest image. A first launch never blocks on a download:
    // auto-start does nothing until setup is done, and nothing at
    // all in a build where the core is not linked.
    [[OCEngine shared] refreshState];
#ifdef OC_KERNARIUM_LINKED
    // The core is linked: register the guest executor so
    // OCEngine.guestCoreLinked is YES and Start boots the guest.
    // Without the define this line does not exist and the no-core
    // path (core pending link) is unchanged. The guest framebuffer
    // view parks behind the tab bar; the Desktop screen moves it
    // into its own view while visible.
    [[OCKernGlue shared] installGuestExecutor];
    [[OCKernGlue shared] parkGuestView];
#endif
    [[OCEngine shared] maybeAutoStartEngine];
    // Boot screen: Andarium-style, shows the real-time engine and
    // server start, with a Log button opening the Engine tab's live
    // log. It dismisses itself once the server is listening, and the
    // user can always continue to the app from it, so a failed start
    // never traps anyone on this screen.
    OCStartupViewController *startup = [[OCStartupViewController alloc] init];
    startup.modalPresentationStyle = UIModalPresentationFullScreen;
    dispatch_async(dispatch_get_main_queue(), ^{
        [tabs presentViewController:startup animated:NO completion:nil];
    });
    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    // iOS may suspend or kill the app; the guest dies with it. With
    // the location background mode the app is kept alive instead, so
    // the guest keeps running; the GPU hold keeps the guest from
    // touching the host GPU while the app is in the background, where
    // the GPU is revoked within seconds.
#ifdef OC_KERNARIUM_LINKED
    [[OCKernGlue shared] setGpuHold:YES];
#endif
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
#ifdef OC_KERNARIUM_LINKED
    [[OCKernGlue shared] setGpuHold:NO];
#endif
}

#pragma mark - Background location

- (void)startLocationForBackground {
    CLLocationManager *manager = [[CLLocationManager alloc] init];
    manager.delegate = self;
    // Coarse fixes are enough: location is only the reason iOS
    // keeps the app alive, not data the app uses. No automatic
    // pausing: a paused update session would let the app suspend.
    manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers;
    manager.distanceFilter = kCLDistanceFilterNone;
    manager.pausesLocationUpdatesAutomatically = NO;
    manager.allowsBackgroundLocationUpdates = YES;
    self.locationManager = manager;
    CLAuthorizationStatus status = manager.authorizationStatus;
    if (status == kCLAuthorizationStatusAuthorizedAlways) {
        [manager startUpdatingLocation];
    } else if (status == kCLAuthorizationStatusNotDetermined) {
        [manager requestAlwaysAuthorization];
    }
    // When-in-use only, or denied: no background keep-alive. The
    // app still works; the engine just stops with the app, as
    // before. Nothing nags the user again from here.
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    if (manager.authorizationStatus == kCLAuthorizationStatusAuthorizedAlways) {
        [manager startUpdatingLocation];
    }
}

// Location fixes are never stored, never sent, and never used for
// anything except keeping the app alive in the background.
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    (void)manager; (void)locations;
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    (void)manager; (void)error;
}

@end
