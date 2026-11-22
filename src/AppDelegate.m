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

// Diagnostic markers (2026-11-21): the 10:50:17 af64d5b device log
// proves the death is INSIDE UIApplicationMain, before
// didFinishLaunching step 1 — clean path, "Calling
// UIApplicationMain" present, no step 1, no CRASH line. This class
// previously had no +initialize and no -init, so NOTHING in the app
// ran between the marker and step 1 except UIKit itself and
// LiveContainer's hooks. These two markers bracket the delegate:
//   +initialize missing          -> died in UIApplication creation,
//                                   before the delegate class was
//                                   even messaged;
//   +initialize, no -init        -> died during delegate alloc/init;
//   both present, no step 1      -> died in setDelegate: (LC's
//                                   hook_setDelegate body, which runs
//                                   BEFORE didFinishLaunching and does
//                                   4 swizzles for a delegate without
//                                   scene methods), scene connection
//                                   (LC's hook__connectUISceneFromFB-
//                                   SScene), or the runloop turn into
//                                   didFinishLaunching.
// Pure logging, no behaviour change. +initialize fires on the first
// message to this class (the NSStringFromClass argument in main());
// -init fires when UIKit instantiates the delegate.
+ (void)initialize {
    OCCrashLogMarkDelegateStage("AppDelegate +initialize");
}

- (instancetype)init {
    self = [super init];
    if (self) {
        OCCrashLogMarkDelegateStage("AppDelegate -init done");
    }
    return self;
}

// Scene-session configuration (2026-11-22): LiveContainer's
// hook_setDelegate (TweakLoader/UIKit+GuestHooks.m:638) runs four
// method_exchangeImplementations swizzles when the delegate does
// NOT implement application:configurationForConnectingSceneSession:
// options:. The 6240a51 device log proves the death is after
// -init done and before didFinishLaunching step 1 — in setDelegate:
// (the swizzles), scene connection, or the runloop turn. Implementing
// this method makes the hook skip the swizzles entirely; only the
// method's existence is checked (respondsToSelector:), the hook
// never calls it.
// Returning nil is the documented fallback: UIKit uses the
// configuration from Info.plist, and we have none, so UIKit uses
// its default — exactly what happens today without the method. The
// classic window path in didFinishLaunching is unchanged, and there
// is no scene delegate class in the app. The marker logs the call
// so the next device log shows whether UIKit entered the scene path
// at all (in the standard lifecycle the scene connects after
// didFinishLaunching, so a still-crashing run may not show it — the
// fix works by flipping the respondsToSelector check at
// setDelegate: time, not by the method being called).
- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
    options:(UISceneConnectionOptions *)options {
    (void)application; (void)connectingSceneSession; (void)options;
    OCCrashLogMarkDelegateStage("Scene config requested");
    return nil;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // Crash recording is already installed in main(), before
    // UIApplicationMain: OCCrashLogInstallEarly() wrote the launch
    // line and checked the previous run. Step markers below are
    // synchronous (appendEngineLogSync writes to
    // Documents/Engine/engine.log before returning), so a launch
    // death leaves the exact step that died as the last line.
    [[OCEngine shared] appendEngineLogSync:@"Launch step 1/7: didFinishLaunching entered"];
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
    [[OCEngine shared] appendEngineLogSync:@"Launch step 2/7: window and tabs shown"];

    // Background execution: Always location keeps the app (and the
    // in-process guest engine) alive in the background. The prompt
    // copy in Info.plist says plainly what it is for. Location
    // updates start once permission is granted; until then the app
    // behaves as before.
    [self startLocationForBackground];
    [[OCEngine shared] appendEngineLogSync:@"Launch step 3/7: location started"];

    // Engine state only, then auto-start when it can start. The
    // runtime framework is NOT loaded here: it loads on the first
    // Start (see KernGlue ensureRuntimeLoaded), never at launch, so
    // a framework that dies while loading cannot kill the launch.
    // At launch the guest executor is nil, so auto-start skips
    // cleanly and the app opens to the tabs and startup screen.
    [[OCEngine shared] refreshState];
    [[OCEngine shared] appendEngineLogSync:@"Launch step 4/7: engine state refreshed"];
#ifdef OC_KERNARIUM_LINKED
    // The guest framebuffer view (MTKView) is NOT created here any
    // more: creating Metal work at launch is the last untested
    // piece of the launch window, and the 9e5e9bb device log showed
    // the app dying before this point anyway. The view is created
    // and parked in bootWithCompletion, where run() actually needs
    // it; the Desktop screen moves it into its own view while
    // visible, as before. No Metal work happens at launch now.
    [[OCEngine shared] appendEngineLogSync:@"Launch step 5/7: guest view deferred until first Start (no Metal at launch)"];
#endif
    [[OCEngine shared] maybeAutoStartEngine];
    [[OCEngine shared] appendEngineLogSync:@"Launch step 6/7: auto-start check done"];
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
    [[OCEngine shared] appendEngineLogSync:@"Launch step 7/7: didFinishLaunching done"];
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
