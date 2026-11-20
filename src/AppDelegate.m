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
    // Crash recording is already installed in main(), before
    // UIApplicationMain: OCCrashLogInstallEarly() wrote the launch
    // line and checked the previous run. Nothing to do here.
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

    // Engine state only, then auto-start when it can start. The
    // runtime framework is NOT loaded here: it loads on the first
    // Start (see KernGlue ensureRuntimeLoaded), never at launch, so
    // a framework that dies while loading cannot kill the launch.
    // At launch the guest executor is nil, so auto-start skips
    // cleanly and the app opens to the tabs and startup screen.
    [[OCEngine shared] refreshState];
#ifdef OC_KERNARIUM_LINKED
    // The guest framebuffer view parks behind the tab bar; the
    // Desktop screen moves it into its own view while visible.
    // Creating the Metal view here is safe: it touches no runtime
    // code (the framework loads later, on Start).
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
    // Clean-shutdown marker for the unclean-exit check: a later
    // launch can tell a clean backgrounding from a kill. iOS may
    // suspend or kill the app after this; the guest dies with it.
    // With the location background mode the app is kept alive
    // instead, so the guest keeps running; the GPU hold keeps the
    // guest from touching the host GPU while the app is in the
    // background, where the GPU is revoked within seconds.
    OCCrashLogMarkCleanShutdown();
#ifdef OC_KERNARIUM_LINKED
    [[OCKernGlue shared] setGpuHold:YES];
#endif
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    // Foreground marker: a clean-shutdown marker from an earlier
    // backgrounding must not mask work done after returning.
    OCCrashLogMarkForeground();
#ifdef OC_KERNARIUM_LINKED
    [[OCKernGlue shared] setGpuHold:NO];
#endif
}

- (void)applicationWillTerminate:(UIApplication *)application {
    (void)application;
    OCCrashLogMarkCleanShutdown();
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
