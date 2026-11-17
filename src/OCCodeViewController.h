// OCCodeViewController - FreeMilk's line-numbered code view. A
// gutter of line numbers beside a monospaced code text view, both
// scrolling together, so each number stays on its own line.
#import <UIKit/UIKit.h>

@interface OCCodeViewController : UIViewController
- (instancetype)initWithTitle:(NSString *)title content:(NSString *)content;
@end
