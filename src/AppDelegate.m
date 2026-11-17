// AppDelegate - tab bar: Sessions, Files, Engine, Settings.
#import "AppDelegate.h"
#import "OCSessionsViewController.h"
#import "OCFilesViewController.h"
#import "OCEngineViewController.h"
#import "OCSettingsViewController.h"
#import "OCEngine.h"

#ifdef OC_CORE_LINKED
#import "CoreGlue.h"
#endif

@implementation OCAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

    OCSessionsViewController *sessions = [[OCSessionsViewController alloc] init];
    UINavigationController *sessionsNav = [[UINavigationController alloc] initWithRootViewController:sessions];
    sessionsNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Sessions" image:[UIImage systemImageNamed:@"bubble.left.and.bubble.right"] tag:0];

    OCFilesViewController *files = [[OCFilesViewController alloc] init];
    UINavigationController *filesNav = [[UINavigationController alloc] initWithRootViewController:files];
    filesNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Files" image:[UIImage systemImageNamed:@"folder"] tag:1];

    OCEngineViewController *engine = [[OCEngineViewController alloc] init];
    UINavigationController *engineNav = [[UINavigationController alloc] initWithRootViewController:engine];
    engineNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Engine" image:[UIImage systemImageNamed:@"cpu"] tag:2];

    OCSettingsViewController *settings = [[OCSettingsViewController alloc] init];
    UINavigationController *settingsNav = [[UINavigationController alloc] initWithRootViewController:settings];
    settingsNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Settings" image:[UIImage systemImageNamed:@"gear"] tag:3];

    UITabBarController *tabs = [[UITabBarController alloc] init];
    tabs.viewControllers = @[sessionsNav, filesNav, engineNav, settingsNav];
    self.window.rootViewController = tabs;
    [self.window makeKeyAndVisible];

    // Engine state only; the guest is started from the Engine tab so a
    // first launch never blocks on a download.
    [[OCEngine shared] refreshState];
#ifdef OC_CORE_LINKED
    // The core is linked: register the guest executor so
    // OCEngine.guestCoreLinked is YES and Start boots the guest.
    // Without the define this line does not exist and the no-core
    // path (core pending link) is unchanged.
    [[OCCoreGlue shared] installGuestExecutor];
#endif
    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    // iOS may suspend or kill the app; the guest dies with it (files
    // persist, processes do not). The engine health timer restarts the
    // server when the app comes back.
}

@end
