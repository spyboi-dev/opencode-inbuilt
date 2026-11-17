// OCLogViewController - in-app engine diagnostics log viewer.
// Shows the engine log (state changes, setup, serve launch) plus the
// guest boot.log and serve.log, so a failed Start can be diagnosed on
// the phone without sending files back and forth.
#import "OCLogViewController.h"
#import "OCEngine.h"

@interface OCLogViewController ()
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UIButton *shareLogButton;
@end

@implementation OCLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Engine logs";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(doneTapped)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refreshTapped)];

    self.textView = [[UITextView alloc] init];
    self.textView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.textView.editable = NO;
    self.textView.selectable = YES;
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.textView];

    self.shareLogButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.shareLogButton setTitle:@"Copy log" forState:UIControlStateNormal];
    self.shareLogButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    self.shareLogButton.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.shareLogButton.layer.cornerRadius = 10;
    self.shareLogButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.shareLogButton.heightAnchor constraintEqualToConstant:44].active = YES;
    [self.shareLogButton addTarget:self action:@selector(copyTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.shareLogButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.textView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.shareLogButton.topAnchor constraintEqualToAnchor:self.textView.bottomAnchor constant:12],
        [self.shareLogButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.shareLogButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.shareLogButton.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
    ]];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self loadLog];
}

- (void)loadLog {
    self.textView.text = [[OCEngine shared] fullLogText];
    // Scroll to the newest lines (the end of the log).
    dispatch_async(dispatch_get_main_queue(), ^{
        NSRange end = NSMakeRange(self.textView.text.length, 0);
        [self.textView scrollRangeToVisible:end];
    });
}

- (void)refreshTapped {
    [self loadLog];
}

- (void)copyTapped {
    [UIPasteboard generalPasteboard].string = self.textView.text ?: @"";
    [self.shareLogButton setTitle:@"Copied" forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.shareLogButton setTitle:@"Copy log" forState:UIControlStateNormal];
    });
}

- (void)doneTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
