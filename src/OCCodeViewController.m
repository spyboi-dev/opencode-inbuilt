// OCCodeViewController - FreeMilk's line-numbered code view. A
// gutter of line numbers beside a monospaced code text view, both
// scrolling together, so each number stays on its own line. Wrapping
// is off, so one source line is one visual line and the numbers
// never drift.
#import "OCCodeViewController.h"

@interface OCCodeViewController ()
@property (nonatomic, copy) NSString *codeContent;
@end

@implementation OCCodeViewController

- (instancetype)initWithTitle:(NSString *)title content:(NSString *)content {
    if ((self = [super init])) {
        self.title = title ?: @"File";
        self.codeContent = content ?: @"";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    if (!self.codeContent.length) {
        // An empty file is not a blank screen: say so in the view.
        UILabel *label = [[UILabel alloc] init];
        label.text = @"This file is empty.";
        label.font = [UIFont systemFontOfSize:15];
        label.textColor = [UIColor secondaryLabelColor];
        label.textAlignment = NSTextAlignmentCenter;
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:label];
        [NSLayoutConstraint activateConstraints:@[
            [label.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
            [label.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        ]];
        return;
    }
    UIFont *mono = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    NSArray *lines = [self.codeContent componentsSeparatedByString:@"\n"];
    // The gutter: one right-aligned number per line, faint.
    NSMutableString *numbers = [NSMutableString string];
    for (NSUInteger i = 0; i < lines.count; i++) [numbers appendFormat:@"%lu\n", (unsigned long)(i + 1)];
    // The widest line decides the code width, so nothing wraps.
    CGFloat maxWidth = 0;
    for (NSString *line in lines) {
        CGFloat w = [line sizeWithAttributes:@{NSFontAttributeName: mono}].width;
        if (w > maxWidth) maxWidth = w;
    }
    CGFloat lineHeight = mono.lineHeight;
    CGFloat codeHeight = MAX(lineHeight * lines.count, 1);
    CGFloat gutterWidth = 44;

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scroll.contentSize = CGSizeMake(gutterWidth + 8 + maxWidth + 16, codeHeight + 16);
    [self.view addSubview:scroll];

    UILabel *gutter = [[UILabel alloc] initWithFrame:CGRectMake(0, 8, gutterWidth, codeHeight)];
    gutter.text = numbers;
    gutter.font = mono;
    gutter.textColor = [UIColor tertiaryLabelColor];
    gutter.textAlignment = NSTextAlignmentRight;
    gutter.numberOfLines = 0;
    [scroll addSubview:gutter];

    UITextView *code = [[UITextView alloc] initWithFrame:CGRectMake(gutterWidth + 8, 8, maxWidth + 16, codeHeight)];
    code.text = self.codeContent;
    code.font = mono;
    code.textColor = [UIColor labelColor];
    code.backgroundColor = [UIColor clearColor];
    code.editable = NO;
    code.selectable = YES;
    code.textContainer.lineBreakMode = NSLineBreakByClipping;
    code.textContainerInset = UIEdgeInsetsZero;
    code.textContainer.lineFragmentPadding = 0;
    [scroll addSubview:code];
}

@end
