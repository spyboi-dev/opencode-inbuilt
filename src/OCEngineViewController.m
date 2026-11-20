// OCEngineViewController - engine status, first-launch setup, start/stop,
// live log (PancakeStore-style dark card, on this screen) and progress.
#import "OCEngineViewController.h"
#import "OCEngine.h"
#import "OCSettings.h"
#import "OCDesktopViewController.h"

@interface OCEngineViewController ()
@property (nonatomic, strong) UILabel *stateLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UISegmentedControl *modeSegment;
@property (nonatomic, strong) UIButton *showDesktopButton;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UILabel *progressLabel;
@property (nonatomic, strong) UIButton *setupButton;
@property (nonatomic, strong) UIButton *startButton;
@property (nonatomic, strong) UIButton *stopButton;
@property (nonatomic, strong) UITextView *logTextView;
@property (nonatomic, strong) UIButton *shareLogButton;
@property (nonatomic, strong, nullable) NSTimer *logRefreshTimer;
@property (nonatomic, strong, nullable) id engineStateToken;
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

    // Engine mode: CLI (native iOS UI talks to `opencode serve`) or
    // Desktop UI (the real OpenCode desktop app in the guest, shown
    // on its own screen). The choice is saved, and switching while
    // the engine runs restarts it in the new mode.
    self.modeSegment = [[UISegmentedControl alloc] initWithItems:@[@"CLI", @"Desktop UI"]];
    self.modeSegment.translatesAutoresizingMaskIntoConstraints = NO;
    [self.modeSegment addTarget:self action:@selector(modeChanged) forControlEvents:UIControlEventValueChanged];
    self.showDesktopButton = [self buttonWithTitle:@"Show desktop" action:@selector(showDesktopTapped)];

    // Live log, PancakeStore style: a "Logs" header with a terminal icon
    // over a dark rounded card holding the monospace log. It sits on this
    // screen and refreshes every second while the tab is visible, so
    // there is nothing to tap to see what the engine is doing.
    UIStackView *logHeader = [[UIStackView alloc] init];
    logHeader.axis = UILayoutConstraintAxisHorizontal;
    logHeader.spacing = 8;
    logHeader.alignment = UIStackViewAlignmentCenter;
    UIImageView *logIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"terminal"]];
    logIcon.tintColor = [UIColor secondaryLabelColor];
    logIcon.contentMode = UIViewContentModeScaleAspectFit;
    logIcon.translatesAutoresizingMaskIntoConstraints = NO;
    [logIcon.widthAnchor constraintEqualToConstant:22].active = YES;
    [logIcon.heightAnchor constraintEqualToConstant:22].active = YES;
    UILabel *logTitle = [self labelWithFont:[UIFont boldSystemFontOfSize:18]];
    logTitle.text = @"Logs";
    logTitle.textColor = [UIColor secondaryLabelColor];
    [logHeader addArrangedSubview:logIcon];
    [logHeader addArrangedSubview:logTitle];

    self.logTextView = [[UITextView alloc] init];
    self.logTextView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.logTextView.textColor = [UIColor labelColor];
    self.logTextView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.logTextView.layer.cornerRadius = 18;
    self.logTextView.layer.masksToBounds = YES;
    self.logTextView.textContainerInset = UIEdgeInsetsMake(16, 16, 16, 16);
    self.logTextView.editable = NO;
    self.logTextView.selectable = YES;
    self.logTextView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.logTextView.heightAnchor constraintEqualToConstant:260].active = YES;

    self.shareLogButton = [self buttonWithTitle:@"Copy log" action:@selector(shareLogTapped)];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.stateLabel, self.detailLabel, self.modeSegment, self.progressView, self.progressLabel,
        self.setupButton, self.startButton, self.stopButton, self.showDesktopButton,
        logHeader, self.logTextView, self.shareLogButton]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    // The log makes the content taller than a small screen, so the whole
    // stack scrolls.
    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40],
    ]];

    __weak typeof(self) weakSelf = self;
    // Multicast observer: the Integrations screen observes the same
    // engine, and a single callback here used to steal it from
    // there (or the other way round).
    self.engineStateToken = [[OCEngine shared] addStateChangeObserver:^(OCEngineState state) {
        (void)state;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf refresh]; });
    }];
    // Live serve progress: the guest writes PROGRESS lines to the
    // exchange dir's serve.log and OCEngine polls them while the
    // engine is starting. This drives the same progress bar the
    // setup download already uses.
    [OCEngine shared].serveProgressDidChange = ^(double progress, NSString * _Nullable status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            // A stop resets progress to 0 with no status: hide the
            // bar instead of leaving an empty one on screen. (Stop
            // calls setServeProgress:0, and this callback used to
            // unhide the bar for it.)
            if (progress <= 0 && !status.length) {
                strongSelf.progressView.hidden = YES;
                return;
            }
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

- (void)dealloc {
    [[OCEngine shared] removeStateChangeObserver:self.engineStateToken];
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
    [self refreshLog];
    [self startLogRefreshTimer];
    // An auto-start (or a start from Integrations) can be in flight
    // while this screen opens: show its progress instead of a bare
    // "Starting engine" with no bar. The progress callback takes
    // over from the next poll tick.
    if ([OCEngine shared].state == OCEngineStateStarting) {
        self.progressView.hidden = NO;
        self.progressView.progress = (float)[OCEngine shared].serveProgress;
        if ([OCEngine shared].serveStatus.length) self.progressLabel.text = [OCEngine shared].serveStatus;
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopLogRefreshTimer];
}

- (void)startLogRefreshTimer {
    [self stopLogRefreshTimer];
    __weak typeof(self) weakSelf = self;
    self.logRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
        (void)timer;
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf refreshLog];
    }];
}

- (void)stopLogRefreshTimer {
    [self.logRefreshTimer invalidate];
    self.logRefreshTimer = nil;
}

// Refresh the live log card. Only auto-scrolls to the newest lines if
// the user is already near the bottom, so reading an earlier line is
// not yanked away.
- (void)refreshLog {
    NSString *text = [[OCEngine shared] fullLogText];
    if ([text isEqualToString:self.logTextView.text]) return;
    CGFloat bottom = self.logTextView.contentOffset.y + self.logTextView.bounds.size.height;
    BOOL nearBottom = (self.logTextView.contentSize.height - bottom) < 60;
    self.logTextView.text = text;
    if (nearBottom) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSRange end = NSMakeRange(self.logTextView.text.length, 0);
            [self.logTextView scrollRangeToVisible:end];
        });
    }
}

- (void)shareLogTapped {
    [UIPasteboard generalPasteboard].string = self.logTextView.text ?: @"";
    [self.shareLogButton setTitle:@"Copied" forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.shareLogButton setTitle:@"Copy log" forState:UIControlStateNormal];
    });
}

- (void)refresh {
    OCEngine *engine = [OCEngine shared];
    self.stateLabel.text = [NSString stringWithFormat:@"Engine: %@", engine.stateDescription];
    BOOL desktop = [[engine engineMode] isEqualToString:OCEngineModeDesktop];
    self.modeSegment.selectedSegmentIndex = desktop ? 1 : 0;
    if (engine.guestCoreLinked) {
        if (desktop) {
            self.detailLabel.text = @"Guest core linked. Debian 13 guest with the OpenCode desktop app. Open the desktop from below once it is running.";
        } else {
            self.detailLabel.text = @"Guest core linked. Debian 13 guest with Node and OpenCode 2.3.0. Server on 127.0.0.1:4096.";
        }
    } else {
        self.detailLabel.text = @"Engine not ready yet. Setup downloads the guest image first. The engine cannot start in this build.";
    }
    self.setupButton.hidden = ([OCEngine shared].state != OCEngineStateNotInstalled && [OCEngine shared].state != OCEngineStateError);
    self.startButton.hidden = ([OCEngine shared].state == OCEngineStateRunning || [OCEngine shared].state == OCEngineStateStarting);
    // When the engine cannot start, the button looks unavailable
    // (dimmed and disabled) instead of looking tappable and then
    // popping an alert. The reason is already on screen, inline.
    BOOL canStart = [OCEngine shared].guestCoreLinked;
    self.startButton.enabled = canStart;
    self.startButton.alpha = canStart ? 1.0 : 0.4;
    // Stop stays available while starting, not just once running:
    // a start can hang on a big download, and stopping it has to
    // work. The engine ignores the late start result after a stop.
    self.stopButton.hidden = ([OCEngine shared].state != OCEngineStateRunning && [OCEngine shared].state != OCEngineStateStarting);
    // The desktop screen only makes sense once the desktop app is
    // up (or starting) in Desktop UI mode.
    BOOL showDesktop = desktop && ([OCEngine shared].state == OCEngineStateRunning || [OCEngine shared].state == OCEngineStateStarting);
    self.showDesktopButton.hidden = !showDesktop;
}

- (void)modeChanged {
    NSString *mode = self.modeSegment.selectedSegmentIndex == 1 ? OCEngineModeDesktop : OCEngineModeCLI;
    [[OCEngine shared] setEngineMode:mode];
    [self refresh];
}

- (void)showDesktopTapped {
    OCDesktopViewController *desktop = [[OCDesktopViewController alloc] init];
    [self.navigationController pushViewController:desktop animated:YES];
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
        // Setup only downloads the guest image in this build; the
        // guest core is not linked yet, so the engine cannot start
        // after setup. Say so up front instead of implying otherwise.
        self.progressLabel.text = @"Setup only downloads the guest image. The engine cannot start yet.";
    } else {
        self.progressLabel.text = @"Downloading the Debian guest image (Node and OpenCode baked in)…";
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
                    self.progressLabel.text = @"Setup done. Guest image saved. The engine cannot start yet.";
                } else {
                    self.progressLabel.text = @"Setup done. Guest image downloaded and verified.";
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
    // The button is disabled while the engine cannot start, but
    // guard anyway: a tap must never pop an alert for this normal
    // state. The reason stays on screen, inline.
    if (![OCEngine shared].guestCoreLinked) {
        self.progressLabel.text = @"Engine cannot start yet. Setup is done, but the engine is not ready in this build.";
        return;
    }
    // Show the progress bar right away; the serve progress callback
    // takes over from here (boot, Node download, OpenCode install,
    // server start) and hides it once the engine is running.
    self.progressView.hidden = NO;
    self.progressView.progress = 0;
    self.progressLabel.text = @"Starting engine...";
    [OCEngine shared].userStoppedEngineThisSession = NO;
    [[OCEngine shared] startEngineWithCompletion:^(BOOL started, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!started) {
                NSString *msg = error.localizedDescription ?: @"Unknown error";
                self.progressView.hidden = YES;
                self.progressLabel.text = [NSString stringWithFormat:@"Engine did not start: %@", msg];
            }
            [self refresh];
        });
    }];
}

- (void)stopTapped {
    // The user stopped it on purpose: auto-start must not restart
    // it behind him on a foreground return.
    [OCEngine shared].userStoppedEngineThisSession = YES;
    [[OCEngine shared] stopEngine];
    [self refresh];
}

@end
