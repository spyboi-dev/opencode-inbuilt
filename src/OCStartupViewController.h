// OCStartupViewController - Andarium-style boot screen, shown on app
// launch while the engine auto-starts. Real-time engine and server
// progress, a Log button opening the Engine tab's live log screen,
// and a Continue button that always gets the user into the app.
//
// The startup screen IS the app root (TermX-style, 2026-11-22): the
// window's root view controller is this screen, and the tabs are
// presented from it once the server is listening (or when the user
// taps Continue). Install lives here, on this screen — not in the
// Engine tab under Integrations. The tabs return here with a swipe
// down from the top edge (TermX's exit drag), so the user is never
// trapped in the tabs without Install.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface OCStartupViewController : UIViewController

// The tab bar controller this screen presents once the engine is
// running (or on Continue). Set by the app delegate at launch; the
// screen owns the presentation, the delegate owns the tabs.
@property (nonatomic, strong, nullable) UITabBarController *tabsViewController;

@end

NS_ASSUME_NONNULL_END
