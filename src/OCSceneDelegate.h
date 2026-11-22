// OCSceneDelegate - attaches the app's window to the UIWindowScene.
//
// Why this exists (2026-11-22): build d15b844 fixed the launch
// crash by implementing
// application:configurationForConnectingSceneSession:options: so
// LiveContainer's hook_setDelegate skips its four swizzles — but
// returning nil made UIKit create a UIWindowScene with no delegate,
// and the window created in didFinishLaunching was never attached
// to any scene. On iOS 13+ a window with no windowScene is not
// displayed: the app launched (all 7 steps, clean shutdown 24 s
// later) but the screen stayed black. This delegate's only job is
// to attach that window to the scene in willConnectToSession.
#import <UIKit/UIKit.h>

@interface OCSceneDelegate : UIResponder <UIWindowSceneDelegate>
@end
