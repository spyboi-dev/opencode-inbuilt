// OCDesktopViewController - the desktop screen.
//
// Shows the guest's display (the same MTKView run() renders into)
// full-screen, with touch and keyboard input forwarded to the guest.
// The guest runs the real OpenCode Linux desktop app; this screen is
// its window on the phone.
//
// Input, first version: one finger taps and drags (touch slot 0,
// more fingers take slots 1..9), and the Keyboard button brings up
// the iOS keyboard, whose typed characters are sent as Linux key
// codes. There is no mouse cursor yet: a tap is a click where the
// finger lands. See KERNARIUM-ENGINE.md, "Engine modes".
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface OCDesktopViewController : UIViewController
@end

NS_ASSUME_NONNULL_END
