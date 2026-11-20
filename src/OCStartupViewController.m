// OCStartupViewController - Andarium-style boot screen, shown on app
// launch while the engine auto-starts.
//
// Layout copies the Andarium boot screen: a top row with a status
// dot plus "Starting" on the left and a live elapsed timer on the
// right, a big bold app title, and one rounded card holding
// checklist rows. Each row is a real boot stage, driven only by
// what the engine actually reports (OCEngine state and the PROGRESS
// lines the guest prints over the console): a row flips to a green
// check only when that stage really completed, the current stage
// shows a spinner, later stages stay dim. Nothing is faked.
//
// The Log button opens the SAME log screen already in the app: the
// Engine tab's live log view (OCEngineViewController, with its Copy
// log button), presented in a navigation controller with a Done
// button. No second log view exists.
//
// The screen dismisses itself into the normal tabs once the server
// is listening. It never traps the user: a Continue button is always
// on screen, and a failed, unlinked, or not-yet-set-up engine shows
// the honest reason in plain words.
#import "OCStartupViewController.h"
#import "OCEngine.h"
#import "OCEngineViewController.h"

// OpenCode's exact dark tokens (same as OCChatViewController):
// base #242424, layer-01 #2e2e2e, layer-02 #3a3a3a, text #f2f2f2,
// muted #aeaeae, faint #808080, accent #a2bcff dark / #3b5cf6 light.
static UIColor *OCStartupBase(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0x24/255.0 green:0x24/255.0 blue:0x24/255.0 alpha:1.0] : [UIColor systemBackgroundColor];
    }];
}
static UIColor *OCStartupLayer01(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0x2e/255.0 green:0x2e/255.0 blue:0x2e/255.0 alpha:1.0] : [UIColor secondarySystemBackgroundColor];
    }];
}
static UIColor *OCStartupLayer02(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0x3a/255.0 green:0x3a/255.0 blue:0x3a/255.0 alpha:1.0] : [UIColor systemGray5Color];
    }];
}
static UIColor *OCStartupText(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0xf2/255.0 green:0xf2/255.0 blue:0xf2/255.0 alpha:1.0] : [UIColor labelColor];
    }];
}
static UIColor *OCStartupMuted(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0xae/255.0 green:0xae/255.0 blue:0xae/255.0 alpha:1.0] : [UIColor secondaryLabelColor];
    }];
}
static UIColor *OCStartupFaint(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0x80/255.0 green:0x80/255.0 blue:0x80/255.0 alpha:1.0] : [UIColor tertiaryLabelColor];
    }];
}
static UIColor *OCStartupAccent(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0xa2/255.0 green:0xbc/255.0 blue:0xff/255.0 alpha:1.0] : [UIColor colorWithRed:0x3b/255.0 green:0x5c/255.0 blue:0xf6/255.0 alpha:1.0];
    }];
}

typedef NS_ENUM(NSInteger, OCStartupRowState) {
    OCStartupRowPending, // not started yet: dim hollow circle
    OCStartupRowActive,  // running now: spinner, detail in accent
    OCStartupRowDone,    // really finished: green check
    OCStartupRowBlocked  // cannot happen in this build: red outline
};

enum { OCStartupRowCore = 0, OCStartupRowBoot, OCStartupRowNode, OCStartupRowOpenCode, OCStartupRowServer, OCStartupRowCount };

@interface OCStartupViewController ()
@property (nonatomic, strong) UIView *statusDot;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *timerLabel;
@property (nonatomic, strong) UILabel *reasonLabel;
@property (nonatomic, strong) NSMutableArray<UIView *> *rowIcons;
@property (nonatomic, strong) NSMutableArray<UIImageView *> *rowChecks;
@property (nonatomic, strong) NSMutableArray<UIActivityIndicatorView *> *rowSpinners;
@property (nonatomic, strong) NSMutableArray<UILabel *> *rowTitles;
@property (nonatomic, strong) NSMutableArray<UILabel *> *rowDetails;
@property (nonatomic, strong, nullable) NSTimer *pollTimer;
@property (nonatomic, strong, nullable) id engineStateToken;
@property (nonatomic, strong) NSDate *startTime;
@property (nonatomic, assign) BOOL dismissScheduled;
@property (nonatomic, assign) BOOL dismissAfterLogCloses;
@end

@implementation OCStartupViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = OCStartupBase();
    self.startTime = [NSDate date];
    self.rowIcons = [NSMutableArray array];
    self.rowChecks = [NSMutableArray array];
    self.rowSpinners = [NSMutableArray array];
    self.rowTitles = [NSMutableArray array];
    self.rowDetails = [NSMutableArray array];

    // Top row: green dot + "Starting" left, elapsed timer right.
    self.statusDot = [[UIView alloc] init];
    self.statusDot.backgroundColor = OCStartupAccent();
    self.statusDot.layer.cornerRadius = 5;
    self.statusDot.translatesAutoresizingMaskIntoConstraints = NO;
    [self.statusDot.widthAnchor constraintEqualToConstant:10].active = YES;
    [self.statusDot.heightAnchor constraintEqualToConstant:10].active = YES;

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.font = [UIFont boldSystemFontOfSize:17];
    self.statusLabel.textColor = OCStartupAccent();
    self.statusLabel.text = @"Starting";
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.timerLabel = [[UILabel alloc] init];
    self.timerLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    self.timerLabel.textColor = OCStartupMuted();
    self.timerLabel.text = @"0:00";
    self.timerLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *statusRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.statusDot, self.statusLabel]];
    statusRow.axis = UILayoutConstraintAxisHorizontal;
    statusRow.spacing = 8;
    statusRow.alignment = UIStackViewAlignmentCenter;
    statusRow.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *topRow = [[UIStackView alloc] initWithArrangedSubviews:@[statusRow, self.timerLabel]];
    topRow.axis = UILayoutConstraintAxisHorizontal;
    topRow.alignment = UIStackViewAlignmentCenter;
    topRow.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.font = [UIFont boldSystemFontOfSize:36];
    titleLabel.textColor = OCStartupText();
    titleLabel.text = @"OpenCode";
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    // The checklist card: one rounded dark card holding the rows.
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = OCStartupLayer01();
    card.layer.cornerRadius = 24;
    card.layer.masksToBounds = YES;
    card.translatesAutoresizingMaskIntoConstraints = NO;

    NSArray<NSString *> *titles = @[@"Engine core", @"Guest boot", @"Node", @"OpenCode", @"Server"];
    UIView *previousRow = nil;
    for (NSInteger i = 0; i < OCStartupRowCount; i++) {
        UIView *row = [self makeRowWithTitle:titles[(NSUInteger)i]];
        [card addSubview:row];
        [NSLayoutConstraint activateConstraints:@[
            [row.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
            [row.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
            [row.heightAnchor constraintEqualToConstant:68],
            previousRow ? [row.topAnchor constraintEqualToAnchor:previousRow.bottomAnchor] : [row.topAnchor constraintEqualToAnchor:card.topAnchor],
        ]];
        if (previousRow) {
            UIView *sep = [[UIView alloc] init];
            sep.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
            sep.translatesAutoresizingMaskIntoConstraints = NO;
            [card addSubview:sep];
            [NSLayoutConstraint activateConstraints:@[
                [sep.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:60],
                [sep.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
                [sep.heightAnchor constraintEqualToConstant:1],
                [sep.topAnchor constraintEqualToAnchor:previousRow.bottomAnchor],
            ]];
        }
        previousRow = row;
    }
    [card.bottomAnchor constraintEqualToAnchor:previousRow.bottomAnchor].active = YES;

    // Plain-words reason, shown only when the engine cannot start
    // on its own (core not linked, setup not done, failed, stopped).
    self.reasonLabel = [[UILabel alloc] init];
    self.reasonLabel.font = [UIFont systemFontOfSize:14];
    self.reasonLabel.textColor = OCStartupMuted();
    self.reasonLabel.numberOfLines = 0;
    self.reasonLabel.hidden = YES;
    self.reasonLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *logButton = [self buttonWithTitle:@"View log" action:@selector(logTapped)];
    UIButton *continueButton = [self buttonWithTitle:@"Continue to app" action:@selector(continueTapped)];
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[logButton, continueButton]];
    buttons.axis = UILayoutConstraintAxisVertical;
    buttons.spacing = 12;
    buttons.translatesAutoresizingMaskIntoConstraints = NO;

    // A spacer holds the title and card low on the screen, the way
    // the Andarium screen does, instead of crowding the top row.
    UIView *spacer = [[UIView alloc] init];
    spacer.translatesAutoresizingMaskIntoConstraints = NO;
    [spacer.heightAnchor constraintEqualToConstant:120].active = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[topRow, spacer, titleLabel, card, self.reasonLabel, buttons]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 28;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-24],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-48],
    ]];

    __weak typeof(self) weakSelf = self;
    self.engineStateToken = [[OCEngine shared] addStateChangeObserver:^(OCEngineState state) {
        (void)state;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf refresh];
            [weakSelf maybeDismissForRunning];
        });
    }];
}

- (void)dealloc {
    [self.pollTimer invalidate];
    [[OCEngine shared] removeStateChangeObserver:self.engineStateToken];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self startPollTimer];
    [self refresh];
    [self maybeDismissForRunning];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.pollTimer invalidate];
    self.pollTimer = nil;
}

- (UIView *)makeRowWithTitle:(NSString *)title {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *icon = [[UIView alloc] init];
    icon.layer.cornerRadius = 14;
    icon.layer.borderWidth = 2;
    icon.layer.borderColor = [OCStartupFaint() CGColor];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [icon.widthAnchor constraintEqualToConstant:28].active = YES;
    [icon.heightAnchor constraintEqualToConstant:28].active = YES;

    UIImageView *check = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark"]];
    check.tintColor = [UIColor whiteColor];
    check.contentMode = UIViewContentModeScaleAspectFit;
    check.hidden = YES;
    check.translatesAutoresizingMaskIntoConstraints = NO;
    [icon addSubview:check];
    [NSLayoutConstraint activateConstraints:@[
        [check.centerXAnchor constraintEqualToAnchor:icon.centerXAnchor],
        [check.centerYAnchor constraintEqualToAnchor:icon.centerYAnchor],
        [check.widthAnchor constraintEqualToConstant:16],
        [check.heightAnchor constraintEqualToConstant:16],
    ]];

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.color = OCStartupAccent();
    spinner.hidden = YES;
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [icon addSubview:spinner];
    [NSLayoutConstraint activateConstraints:@[
        [spinner.centerXAnchor constraintEqualToAnchor:icon.centerXAnchor],
        [spinner.centerYAnchor constraintEqualToAnchor:icon.centerYAnchor],
    ]];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.font = [UIFont boldSystemFontOfSize:17];
    titleLabel.textColor = OCStartupText();
    titleLabel.text = title;
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *detailLabel = [[UILabel alloc] init];
    detailLabel.font = [UIFont systemFontOfSize:14];
    detailLabel.textColor = OCStartupMuted();
    detailLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *labels = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, detailLabel]];
    labels.axis = UILayoutConstraintAxisVertical;
    labels.spacing = 2;
    labels.translatesAutoresizingMaskIntoConstraints = NO;

    [row addSubview:icon];
    [row addSubview:labels];
    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:20],
        [icon.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [labels.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:16],
        [labels.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-20],
        [labels.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];

    [self.rowIcons addObject:icon];
    [self.rowChecks addObject:check];
    [self.rowSpinners addObject:spinner];
    [self.rowTitles addObject:titleLabel];
    [self.rowDetails addObject:detailLabel];
    return row;
}

- (UIButton *)buttonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [button setTitleColor:OCStartupText() forState:UIControlStateNormal];
    button.backgroundColor = OCStartupLayer02();
    button.layer.cornerRadius = 12;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.heightAnchor constraintEqualToConstant:48].active = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)startPollTimer {
    [self.pollTimer invalidate];
    __weak typeof(self) weakSelf = self;
    // Half a second: the guest writes PROGRESS lines at most once a
    // second, and the elapsed timer wants a fresh second anyway.
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer * _Nonnull timer) {
        (void)timer;
        [weakSelf refresh];
    }];
}

- (void)refresh {
    NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:self.startTime];
    self.timerLabel.text = [NSString stringWithFormat:@"%lu:%02lu",
                            (unsigned long)(elapsed / 60), (unsigned long)((NSInteger)elapsed % 60)];
    [self refreshHeader];
    [self refreshRows];
}

- (void)refreshHeader {
    OCEngine *engine = [OCEngine shared];
    NSString *text = @"Ready";
    UIColor *dot = OCStartupFaint();
    UIColor *labelColor = OCStartupMuted();
    switch (engine.state) {
        case OCEngineStateStarting:
            text = @"Starting"; dot = OCStartupAccent(); labelColor = OCStartupAccent();
            break;
        case OCEngineStateRunning:
            text = @"Running"; dot = [UIColor systemGreenColor]; labelColor = [UIColor systemGreenColor];
            break;
        case OCEngineStateError:
            text = @"Engine error"; dot = [UIColor systemRedColor]; labelColor = [UIColor systemRedColor];
            break;
        case OCEngineStateNotInstalled:
        case OCEngineStateInstalling:
            text = @"Setup needed"; dot = OCStartupFaint(); labelColor = OCStartupMuted();
            break;
        case OCEngineStateStopped:
            text = @"Stopped"; dot = OCStartupFaint(); labelColor = OCStartupMuted();
            break;
        case OCEngineStateCorePending:
            text = @"Not ready"; dot = OCStartupFaint(); labelColor = OCStartupMuted();
            break;
        case OCEngineStateInstalled:
            text = @"Ready"; dot = OCStartupFaint(); labelColor = OCStartupMuted();
            break;
    }
    self.statusLabel.text = text;
    self.statusLabel.textColor = labelColor;
    self.statusDot.backgroundColor = dot;

    // The honest reason, only when the engine cannot start on its
    // own. While it is starting or running there is nothing to say.
    NSString *reason = nil;
    if (!engine.guestCoreLinked && engine.guestCoreLoadable) {
        // Runtime not loaded yet: it loads when Start is tapped.
        // The engine CAN start, just not on its own at launch.
        reason = @"The engine loads when you start it. Continue to the app and tap Start engine on the Engine tab.";
    } else if (!engine.guestCoreLinked) {
        reason = @"The engine is not ready yet in this build. Setup downloads the guest image first, but the engine cannot start here.";
    } else if (engine.state == OCEngineStateNotInstalled) {
        reason = @"First-launch setup has not finished yet. Continue to the app to run setup from the Engine tab.";
    } else if (engine.state == OCEngineStateInstalling) {
        reason = @"First-launch setup is still running.";
    } else if (engine.state == OCEngineStateError) {
        reason = @"The engine did not start. Check the log for the exact reason.";
    } else if (engine.state == OCEngineStateStopped) {
        reason = @"The engine stopped. You can start it again from the Engine tab.";
    } else if (engine.state == OCEngineStateInstalled) {
        reason = @"The engine did not start on its own. You can start it from the Engine tab.";
    }
    self.reasonLabel.hidden = (reason == nil);
    self.reasonLabel.text = reason ?: @"";
}

// Each row is driven only by what the engine really reports.
// serveProgress is the guest's own PROGRESS percentage (0..1),
// monotonic: boot writes 5, Node ready is 55, OpenCode ready is 85,
// server starting is 90, and "server listening" completes it at 1.0
// and flips the state to Running. A row is Done only when its
// threshold is really passed, never on a guess.
- (void)refreshRows {
    OCEngine *engine = [OCEngine shared];
    double p = engine.serveProgress;
    BOOL running = engine.state == OCEngineStateRunning;
    BOOL starting = engine.state == OCEngineStateStarting;
    NSString *status = engine.serveStatus ?: @"";

    if (engine.guestCoreLinked) {
        [self setRow:OCStartupRowCore state:OCStartupRowDone detail:@"Linked, ready to boot"];
    } else if (engine.guestCoreLoadable) {
        [self setRow:OCStartupRowCore state:OCStartupRowPending detail:@"Loads when you start the engine"];
    } else {
        [self setRow:OCStartupRowCore state:OCStartupRowBlocked detail:@"Not ready in this build"];
    }

    if (running || p > 0.05) {
        [self setRow:OCStartupRowBoot state:OCStartupRowDone detail:@"Debian 13 guest"];
    } else if (starting) {
        [self setRow:OCStartupRowBoot state:OCStartupRowActive detail:@"Booting guest..."];
    } else {
        [self setRow:OCStartupRowBoot state:OCStartupRowPending detail:@"Debian 13 guest"];
    }

    if (running || p >= 0.55) {
        [self setRow:OCStartupRowNode state:OCStartupRowDone detail:@"Node 22 LTS"];
    } else if (starting && p > 0.05) {
        NSString *detail = [status containsString:@"Node"] ? status : @"Checking Node...";
        [self setRow:OCStartupRowNode state:OCStartupRowActive detail:detail];
    } else {
        [self setRow:OCStartupRowNode state:OCStartupRowPending detail:@"Node 22 LTS"];
    }

    if (running || p >= 0.85) {
        [self setRow:OCStartupRowOpenCode state:OCStartupRowDone detail:@"OpenCode 2.3.0"];
    } else if (starting && p >= 0.55) {
        NSString *detail = ([status containsString:@"OpenCode"] || [status containsString:@"Tools"] || [status containsString:@"bun"]) ? status : @"Installing OpenCode...";
        [self setRow:OCStartupRowOpenCode state:OCStartupRowActive detail:detail];
    } else {
        [self setRow:OCStartupRowOpenCode state:OCStartupRowPending detail:@"OpenCode 2.3.0"];
    }

    BOOL desktop = [[engine engineMode] isEqualToString:OCEngineModeDesktop];
    if (running) {
        [self setRow:OCStartupRowServer state:OCStartupRowDone detail:desktop ? @"Desktop window ready" : @"Listening on 127.0.0.1:4096"];
    } else if (starting && p >= 0.85) {
        [self setRow:OCStartupRowServer state:OCStartupRowActive detail:desktop ? @"Starting desktop..." : @"Starting server..."];
    } else {
        [self setRow:OCStartupRowServer state:OCStartupRowPending detail:desktop ? @"Desktop UI" : @"Port 4096"];
    }
}

- (void)setRow:(NSInteger)row state:(OCStartupRowState)state detail:(NSString *)detail {
    UIView *icon = self.rowIcons[(NSUInteger)row];
    UIImageView *check = self.rowChecks[(NSUInteger)row];
    UIActivityIndicatorView *spinner = self.rowSpinners[(NSUInteger)row];
    UILabel *title = self.rowTitles[(NSUInteger)row];
    UILabel *detailLabel = self.rowDetails[(NSUInteger)row];
    detailLabel.text = detail;
    switch (state) {
        case OCStartupRowDone:
            icon.backgroundColor = [UIColor systemGreenColor];
            icon.layer.borderWidth = 0;
            check.hidden = NO;
            [spinner stopAnimating];
            spinner.hidden = YES;
            title.textColor = OCStartupText();
            detailLabel.textColor = OCStartupMuted();
            break;
        case OCStartupRowActive:
            icon.backgroundColor = [UIColor clearColor];
            icon.layer.borderWidth = 0;
            check.hidden = YES;
            spinner.hidden = NO;
            [spinner startAnimating];
            title.textColor = OCStartupText();
            detailLabel.textColor = OCStartupAccent();
            break;
        case OCStartupRowBlocked:
            icon.backgroundColor = [UIColor clearColor];
            icon.layer.borderWidth = 2;
            icon.layer.borderColor = [[UIColor systemRedColor] CGColor];
            check.hidden = YES;
            [spinner stopAnimating];
            spinner.hidden = YES;
            title.textColor = OCStartupText();
            detailLabel.textColor = [UIColor systemRedColor];
            break;
        case OCStartupRowPending:
            icon.backgroundColor = [UIColor clearColor];
            icon.layer.borderWidth = 2;
            icon.layer.borderColor = [OCStartupFaint() CGColor];
            check.hidden = YES;
            [spinner stopAnimating];
            spinner.hidden = YES;
            title.textColor = OCStartupFaint();
            detailLabel.textColor = OCStartupMuted();
            break;
    }
}

// Dismiss into the normal tabs once the server is listening. A short
// beat at full green first, so the user sees every check done. If
// the log screen is open on top, wait until it closes instead of
// yanking it away.
- (void)maybeDismissForRunning {
    if ([OCEngine shared].state != OCEngineStateRunning) return;
    if (self.dismissScheduled) return;
    self.dismissScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.presentedViewController) {
            strongSelf.dismissAfterLogCloses = YES;
            return;
        }
        [strongSelf dismissViewControllerAnimated:YES completion:nil];
    });
}

- (void)logTapped {
    // The SAME log screen already in the app: the Engine tab's live
    // log view, with its Copy log button and its 1-second refresh.
    // Nothing is rebuilt here, only presented.
    OCEngineViewController *engineVC = [[OCEngineViewController alloc] init];
    engineVC.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(logDoneTapped)];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:engineVC];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)logDoneTapped {
    __weak typeof(self) weakSelf = self;
    [self dismissViewControllerAnimated:YES completion:^{
        // The server came up while the log was open: go to the app now.
        if (weakSelf.dismissAfterLogCloses) {
            weakSelf.dismissAfterLogCloses = NO;
            [weakSelf dismissViewControllerAnimated:YES completion:nil];
        }
    }];
}

- (void)continueTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
