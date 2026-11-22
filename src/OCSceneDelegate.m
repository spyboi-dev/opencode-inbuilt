// OCSceneDelegate - attaches the app's window to the UIWindowScene.
//
// The window already exists by the time this runs: didFinishLaunching
// (step 2) creates it and calls makeKeyAndVisible before UIKit
// connects the scene (device log 2026-11-22 07:15: the "Scene config
// requested" marker fires after step 7). It just has no windowScene,
// so iOS does not display it. Attach it here, then make it key and
// visible again in the scene — the standard pattern from Apple's
// scene templates (window.windowScene = scene, then
// makeKeyAndVisible). Re-attaching on a later reconnect (e.g. the
// scene disconnects and reconnects) is idempotent and harmless.
#import "OCSceneDelegate.h"
#import "AppDelegate.h"
#import "OCCrashLog.h"

@implementation OCSceneDelegate

- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
    options:(UISceneConnectionOptions *)connectionOptions {
    (void)session; (void)connectionOptions;
    OCAppDelegate *appDelegate = (OCAppDelegate *)[UIApplication sharedApplication].delegate;
    UIWindow *window = appDelegate.window;
    if (window && [scene isKindOfClass:[UIWindowScene class]]) {
        window.windowScene = (UIWindowScene *)scene;
        [window makeKeyAndVisible];
        OCCrashLogMarkDelegateStage("Window attached to scene (willConnect)");
    } else {
        // Defensive only: the standard lifecycle runs
        // didFinishLaunching before scene connection, so the window
        // exists by now. If it ever does not, say so in the log
        // instead of silently leaving a black screen.
        OCCrashLogMarkDelegateStage("Scene connected but window not ready");
    }
}

@end
