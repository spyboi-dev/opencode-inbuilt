// OCEngineViewController - engine status, first-launch setup, start/stop.
#import "OCEngineViewController.h"
#import "OCEngine.h"
#import "OCSettings.h"
#import "OCLogViewController.h"

@interface OCEngineViewController ()
@property (nonatomic, strong) UILabel *stateLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UILabel *progressLabel;
@property (nonatomic, strong) UIButton *setupButton;
@property (nonatomic, strong) UIButton *startButton;
@property (nonatomic, strong) UIButton *stopButton;
@property (nonatomic, strong) UIButton *logsButton;
@end

@implementation OCEngineViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Engine";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.stateLabel = [self labelWithFont:[UIFont boldSystemFontOfSize:20]];
    self.detailLabel = [self labelWithFont:[UIFont systemFontOfSize:14]];
    self.detailLabel.numberOfLines = 0;
    self.progressLabel = [self labelWithFont:[UIFont systemFontOfSize:13]];
    self.progressLabel.numberOfLines = 0;
    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressView.hidden = YES;

    self.setupButton = [self buttonWithTitle:@"Run first-launch setup" action:@selector(setupTapped)];
    self.startButton = [self buttonWithTitle:@"Start engine" action:@selector(startTapped)];
    self.stopButton = [self buttonWithTitle:@"Stop engine" action:@selector(stopTapped)];
    self.logsButton = [self buttonWithTitle:@"View logs" action:@selector(logsTapped)];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.stateLabel, self.detailLabel, self.progressView, self.progressLabel,
        self.setupButton, self.startButton, self.stopButton, self.logsButton]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:24],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
    ]];

    __weak typeof(self) weakSelf = self;
    [OCEngine shared].stateDidChange = ^(OCEngineState state) {
        (void)state;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf refresh]; });
    };
    // Live serve progress: the guest writes PROGRESS lines to the
    // exchange dir's serve.log and OCEngine polls them while the
    // engine is starting. This drives the same progress bar the
    // setup download already uses.
    [OCEngine shared].serveProgressDidChange = ^(double progress, NSString * _Nullable status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.progressView.hidden = NO;
            strongSelf.progressView.progress = (float)progress;
            if (status.length) strongSelf.progressLabel.text = status;
            if (progress >= 1.0) {
                // Engine running: leave the bar visible at full for a
                // beat so the user sees it finish, then hide it.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    strongSelf.progressView.hidden = YES;
                    strongSelf.progressLabel.text = @"Engine running";
                });
            }
        });
    };
}

- (UILabel *)labelWithFont:(UIFont *)font {
    UILabel *label = [[UILabel alloc] init];
    label.font = font;
    label.textColor = [UIColor labelColor];
    label.numberOfLines = 1;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

- (UIButton *)buttonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    button.backgroundColor = [UIColor secondarySystemBackgroundColor];
    button.layer.cornerRadius = 10;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.heightAnchor constraintEqualToConstant:44].active = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[OCEngine shared] refreshState];
    [self refresh];
}

- (void)refresh {
    OCEngine *engine = [OCEngine shared];
    self.stateLabel.text = [NSString stringWithFormat:@"Engine: %@", engine.stateDescription];
    if (engine.guestCoreLinked) {
        self.detailLabel.text = @"Guest core linked. Debian 13 guest with Node and OpenCode 2.3.0. Server on 127.0.0.1:4096.";
    } else {
        self.detailLabel.text = @"Guest core is not linked in this build. The engine host, the Debian package cache and the server client are ready; the core link is the remaining step (see BUILD-NOTE.md). The app will start the guest as soon as the core is linked.";
    }
    self.setupButton.hidden = ([OCEngine shared].state != OCEngineStateNotInstalled && [OCEngine shared].state != OCEngineStateError);
    self.startButton.hidden = ([OCEngine shared].state == OCEngineStateRunning || [OCEngine shared].state == OCEngineStateStarting);
    self.stopButton.hidden = ([OCEngine shared].state != OCEngineStateRunning);
}

- (void)setupTapped {
    // Guard: ignore the tap while a setup chain is already running.
    // Without this, a second tap started a second download chain over
    // the same files and the completion block could fire twice.
    if ([OCEngine shared].state == OCEngineStateInstalling) return;
    self.setupButton.enabled = NO;
    self.progressView.hidden = NO;
    self.progressView.progress = 0;
    if (![OCEngine shared].guestCoreLinked) {
        // Setup only caches the Debian packages in this build; the
        // guest core is not linked yet, so the engine cannot start
        // after setup. Say so up front instead of implying otherwise.
        self.progressLabel.text = @"Engine core is pending link. This setup only caches the Debian packages (37 MB, 103 packages); the engine cannot start yet.";
    } else {
        self.progressLabel.text = @"Downloading Debian 13.7 packages (37 MB, 103 packages)…";
    }
    [[OCEngine shared] runFirstLaunchSetupWithProgress:^(double fraction, NSString *message) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.progressView.progress = (float)fraction;
            self.progressLabel.text = message;
        });
    } completion:^(BOOL done, NSError *error) {
        // OCEngine already calls completion on the main queue; dispatch
        // again defensively, so a UI update can never run off-main
        // even if a future caller invokes setup from a background queue.
        dispatch_async(dispatch_get_main_queue(), ^{
            self.setupButton.enabled = YES;
            self.progressView.hidden = YES;
            if (done) {
                if (![OCEngine shared].guestCoreLinked) {
                    self.progressLabel.text = @"Setup done. Debian packages cached and verified. Engine core is still pending link, so Start is not available yet.";
                    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Engine core pending link" message:@"Debian packages are cached and verified. The engine itself cannot start in this build: the LinuxRunner guest core still needs to be linked (see BUILD-NOTE.md). The app will work as a client as soon as a server is reachable at 127.0.0.1:4096." preferredStyle:UIAlertControllerStyleAlert];
                    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                    [self presentViewController:alert animated:YES completion:nil];
                } else {
                    self.progressLabel.text = @"Setup done. Debian packages cached and verified.";
                }
                [[OCEngine shared] refreshState];
                [self refresh];
            } else {
                NSString *msg = error.localizedDescription ?: @"Unknown error";
                self.progressLabel.text = [NSString stringWithFormat:@"Setup failed: %@", msg];
                [[OCEngine shared] refreshState];
                [self refresh];
            }
        });
    }];
}

- (void)startTapped {
    // Show the progress bar right away; the serve progress callback
    // takes over from here (boot, Node download, OpenCode install,
    // server start) and hides it once the engine is running.
    self.progressView.hidden = NO;
    self.progressView.progress = 0;
    self.progressLabel.text = @"Starting engine...";
    [[OCEngine shared] startEngineWithCompletion:^(BOOL started, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!started) {
                NSString *msg = error.localizedDescription ?: @"Unknown error";
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Engine did not start" message:msg preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
            }
            [self refresh];
        });
    }];
}

- (void)stopTapped {
    [[OCEngine shared] stopEngine];
    [self refresh];
}

- (void)logsTapped {
    OCLogViewController *logs = [[OCLogViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:logs];
    [self presentViewController:nav animated:YES completion:nil];
}

@end
