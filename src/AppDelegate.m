// AppDelegate - FreeMilk's two home tabs: Threads and Integrations.
// The chat opens over them; Files lives inside the chat (Chat/Files
// switch) and the Engine and Settings screens live in Integrations.
#import "AppDelegate.h"
#import "OCSceneDelegate.h"
#import "OCCrashLog.h"
#import "OCSessionsViewController.h"
#import "OCIntegrationsViewController.h"
#import "OCStartupViewController.h"
#import "OCEngine.h"

#ifdef OC_KERNARIUM_LINKED
#import "KernGlue.h"
#endif

@interface OCAppDelegate ()
- (void)attachWindowToSceneIfNeeded;
- (void)startSceneAttachPoll;
- (void)stopSceneAttachPoll;
- (void)sceneAttachTimerFired:(NSTimer *)timer;
@end

@implementation OCAppDelegate {
    NSTimer *_sceneAttachTimer;
    int _sceneAttachAttempts;
}

// Attach the window to a connected scene, whenever one exists.
//
// Why this exists (2026-11-22 07:57 run, build 225ebc5): all 7
// launch steps ran, then CLEAN SHUTDOWN 19 s later — but UIKit
// NEVER called configurationForConnectingSceneSession, so no scene
// was ever connected and OCSceneDelegate's willConnect never ran.
// The d15b844 run the same morning DID connect a scene 1 s after
// step 7, same app family, same phone, same LiveContainer. So the
// system's scene delivery to an in-process LiveContainer guest is
// NOT guaranteed: it happens on some launches and never on others,
// and LiveContainer's hook__connectUISceneFromFBSScene does not
// gate it (read in full: it always calls the original at the end).
// The scene delegate alone therefore cannot be the only attach
// path. This routine mirrors LiveContainer's own updateWindowScene
// (TweakLoader/UIKit+GuestHooks.m:755) in our own code, with no
// swizzles: if a UIWindowScene is connected on the main screen,
// attach the window to it and make it key and visible again.
// Called at the end of didFinishLaunching, on becoming active, on
// entering the foreground, and once a second for the first 30 s by
// the poll, so a scene that connects late still gets attached
// within a second. If no scene ever connects, there is nothing to
// attach to — the lifecycle markers (didBecomeActive /
// willEnterForeground) then say whether the app even reached the
// foreground, which is the next fact the diagnosis needs.
// Callers must be on the main thread (all of them are).
- (void)attachWindowToSceneIfNeeded {
    if (!self.window || self.window.windowScene) {
        [self stopSceneAttachPoll];
        return;
    }
    UIWindowScene *target = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] &&
            ((UIWindowScene *)scene).screen == [UIScreen mainScreen]) {
            target = (UIWindowScene *)scene;
            break;
        }
    }
    if (!target) {
        // Fall back to any window scene if the main-screen match
        // fails (e.g. an external display is the main screen).
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                target = (UIWindowScene *)scene;
                break;
            }
        }
    }
    if (target) {
        self.window.windowScene = target;
        [self.window makeKeyAndVisible];
        OCCrashLogMarkDelegateStage("Window attached to scene (poll)");
        [self stopSceneAttachPoll];
    }
}

- (void)startSceneAttachPoll {
    [self stopSceneAttachPoll];
    _sceneAttachAttempts = 0;
    _sceneAttachTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                         target:self
                                                       selector:@selector(sceneAttachTimerFired:)
                                                       userInfo:nil
                                                        repeats:YES];
}

- (void)stopSceneAttachPoll {
    [_sceneAttachTimer invalidate];
    _sceneAttachTimer = nil;
}

- (void)sceneAttachTimerFired:(NSTimer *)timer {
    (void)timer;
    _sceneAttachAttempts++;
    if (_sceneAttachAttempts > 30) {
        [self stopSceneAttachPoll];
        return;
    }
    [self attachWindowToSceneIfNeeded];
}

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
// That fixed the crash (d15b844, 2026-11-22 07:15: all 7 launch
// steps, clean shutdown) — but returning nil left the screen
// black: UIKit created a UIWindowScene with no delegate, and the
// window from didFinishLaunching was never attached to any scene,
// so iOS did not display it. So this now returns a REAL
// configuration with OCSceneDelegate, whose willConnectToSession
// attaches the existing window to the scene (window.windowScene =
// scene, then makeKeyAndVisible again). The hook still skips its
// swizzles — it only checks respondsToSelector:, and this method
// still exists. The window itself is still created in
// didFinishLaunching (step 2); the scene delegate only attaches
// it, it does not rebuild the tab bar or the startup screen.
- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
    options:(UISceneConnectionOptions *)options {
    (void)application; (void)options;
    OCCrashLogMarkDelegateStage("Scene config requested");
    UISceneConfiguration *config = [[UISceneConfiguration alloc]
        initWithName:@"Default"
        sessionRole:connectingSceneSession.role];
    config.delegateClass = [OCSceneDelegate class];
    return config;
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
    // The startup screen IS the app root (TermX-style): the window
    // shows it first, with Install on it, and the tabs are
    // presented from it once the server is listening (or on
    // Continue). The tabs are built here so the startup screen can
    // present them without rebuilding the navigation stacks.
    OCStartupViewController *startup = [[OCStartupViewController alloc] init];
    startup.tabsViewController = tabs;
    self.window.rootViewController = startup;
    [self.window makeKeyAndVisible];
    [[OCEngine shared] appendEngineLogSync:@"Launch step 2/7: window and startup screen shown"];

    // Background execution: Always location keeps the app (and the
    // in-process guest engine) alive in the background. The prompt
    // copy in Info.plist says plainly what it is for. Location
    // updates start once permission is granted; until then the app
    // behaves as before.
    [self startLocationForBackground];
    [[OCEngine shared] appendEngineLogSync:@"Launch step 3/7: location started"];

    // Engine state only, then auto-start when it can start. The
    // runtime framework loads as part of the auto-start attempt
    // now (background thread inside maybeAutoStartEngine): the
    // 9e5e9bb trade-off of one manual Start per launch is gone —
    // the user directed auto-start, and the launch crash is fixed.
    // At launch the guest executor is nil, so the attempt loads it
    // first instead of skipping.
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
    [[OCEngine shared] appendEngineLogSync:@"Launch step 7/7: didFinishLaunching done"];
    // Scene attach, first attempt now, then the poll: the scene may
    // already be connected, or it may connect seconds later, or
    // never (2026-11-22 07:57 run). See attachWindowToSceneIfNeeded.
    [self attachWindowToSceneIfNeeded];
    [self startSceneAttachPoll];
    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    (void)application;
    // Lifecycle marker: the 2026-11-22 07:57 log has steps 1-7 and a
    // clean shutdown but no scene and no attach, and nothing in it
    // says whether the app ever reached the foreground. This line
    // answers that on the next log.
    OCCrashLogMarkDelegateStage("App became active");
    [self attachWindowToSceneIfNeeded];
    // A foreground return is an auto-start chance too: the install
    // may have finished while the app was backgrounded, or the
    // launch-time attempt may have been skipped for setup not done
    // yet. Guarded inside maybeAutoStartEngine (once per launch,
    // never after an explicit Stop), so repeat calls are no-ops.
    [[OCEngine shared] maybeAutoStartEngine];
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
    OCCrashLogMarkDelegateStage("App will enter foreground");
    [self attachWindowToSceneIfNeeded];
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
