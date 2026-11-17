// AppDelegate - FreeMilk's two home tabs: Threads and Integrations.
// The chat opens over them; Files lives inside the chat (Chat/Files
// switch) and the Engine and Settings screens live in Integrations.
#import "AppDelegate.h"
#import "OCSessionsViewController.h"
#import "OCIntegrationsViewController.h"
#import "OCEngine.h"

#ifdef OC_CORE_LINKED
#import "CoreGlue.h"
#endif

@implementation OCAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
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
