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
//
// One page, no scroll (user direction 2026-11-22): the whole
// stack measures ~735pt with the reason line showing, against
// ~839pt of safe area on iPhone 15 Plus, so Install and Continue
// to app are both on screen. The entrance is staggered (Install
// first, then the rows one by one, then Continue and Log), under
// one second — see prepareEntrance / runEntranceAnimation.
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

@interface OCStartupViewController () <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIView *statusDot;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *timerLabel;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UILabel *reasonLabel;
@property (nonatomic, strong) UIButton *actionButton; // Install (or Start), by state — TermX-style, only action button
@property (nonatomic, strong) UIButton *continueButton; // secondary: enter the tabs without installing
@property (nonatomic, strong) UIButton *logButton; // secondary: open the live log view
@property (nonatomic, strong) NSMutableArray<UIView *> *rowViews; // the five checklist rows, for the entrance animation
@property (nonatomic, assign) double installFraction; // live install progress 0..1, while Installing
@property (nonatomic, strong, nullable) NSString *installMessage; // live install step, while Installing
@property (nonatomic, strong) NSMutableArray<UIView *> *rowIcons;
@property (nonatomic, strong) NSMutableArray<UIImageView *> *rowChecks;
@property (nonatomic, strong) NSMutableArray<UIActivityIndicatorView *> *rowSpinners;
@property (nonatomic, strong) NSMutableArray<UILabel *> *rowTitles;
@property (nonatomic, strong) NSMutableArray<UILabel *> *rowDetails;
@property (nonatomic, strong, nullable) NSTimer *pollTimer;
@property (nonatomic, strong, nullable) id engineStateToken;
@property (nonatomic, strong) NSDate *startTime;
@property (nonatomic, assign) BOOL presentScheduled;
@property (nonatomic, assign) BOOL tabsPresented; // tabs shown once per Running state (TermX's terminalPresented)
@property (nonatomic, assign) BOOL presentTabsAfterLogCloses;
@property (nonatomic, assign) BOOL exitPanAttached; // the exit drag is attached to the tabs view once
@property (nonatomic, assign) CGPoint exitPanStart; // exit drag: where the pan began, in the tabs view
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
    self.rowViews = [NSMutableArray array];

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
            [row.heightAnchor constraintEqualToConstant:56],
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

    // All controls live here, on this screen, and nowhere else
    // (TermX-style, 2026-11-22): Install is the only action button
    // — one tap installs, then the engine boots itself and the tabs
    // open on their own. The Engine tab under Integrations has no
    // Install button any more. Log opens the live log view.
    // Continue gets the user into the tabs at any time; a swipe
    // down from the top edge of the tabs returns here.
    self.actionButton = [self buttonWithTitle:@"Install" action:@selector(actionTapped)];
    self.continueButton = [self buttonWithTitle:@"Continue to app" action:@selector(continueTapped)];
    self.logButton = [self buttonWithTitle:@"View log" action:@selector(logTapped)];
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[self.actionButton, self.continueButton, self.logButton]];
    buttons.axis = UILayoutConstraintAxisVertical;
    buttons.spacing = 12;
    buttons.translatesAutoresizingMaskIntoConstraints = NO;

    // A small spacer keeps the title and card from crowding the
    // top row. It was 120pt (TermX's value) and that, plus the
    // 64pt logo and 68pt rows, pushed Install below the fold on
    // iPhone 15 Plus — the 2026-11-22 09:46 device screenshot.
    // TermX has four rows and no logo; we have five rows and a
    // logo, so our spacer has to be far smaller for the same
    // one-page fit.
    UIView *spacer = [[UIView alloc] init];
    spacer.translatesAutoresizingMaskIntoConstraints = NO;
    [spacer.heightAnchor constraintEqualToConstant:16].active = YES;

    // The official OpenCode logo (resources/OpenCodeLogo.png, the
    // square dark 1024px avatar from dev.opencode.ai/brand), small
    // and centred above the Starting row. Same artwork as the app
    // icon. The wrap centres it: the stack's Fill alignment would
    // stretch a bare image view to full width.
    UIImageView *logoView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"OpenCodeLogo"]];
    logoView.contentMode = UIViewContentModeScaleAspectFit;
    logoView.layer.cornerRadius = 12;
    logoView.layer.masksToBounds = YES;
    logoView.translatesAutoresizingMaskIntoConstraints = NO;
    [logoView.widthAnchor constraintEqualToConstant:48].active = YES;
    [logoView.heightAnchor constraintEqualToConstant:48].active = YES;

    UIView *logoWrap = [[UIView alloc] init];
    logoWrap.translatesAutoresizingMaskIntoConstraints = NO;
    [logoWrap.heightAnchor constraintEqualToConstant:48].active = YES;
    [logoWrap addSubview:logoView];
    [NSLayoutConstraint activateConstraints:@[
        [logoView.centerXAnchor constraintEqualToAnchor:logoWrap.centerXAnchor],
        [logoView.centerYAnchor constraintEqualToAnchor:logoWrap.centerYAnchor],
    ]];

    // Thin progress bar under the title (TermX-style): real
    // progress only — the install fraction while downloading, the
    // serve progress once the engine is starting.
    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressView.trackTintColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    self.progressView.progressTintColor = OCStartupAccent();
    self.progressView.progress = 0;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[logoWrap, topRow, spacer, titleLabel, self.progressView, card, self.reasonLabel, buttons]];
    stack.axis = UILayoutConstraintAxisVertical;
    // One page, no scroll (user direction 2026-11-22): the whole
    // stack measures ~735pt with the reason line showing, against
    // ~839pt of safe area on iPhone 15 Plus, so Install and
    // Continue to app are both on screen. The default gap is 16,
    // not 28 — the old 28pt gaps plus the 120pt spacer are what
    // pushed Install below the fold.
    stack.spacing = 16;
    // The progress bar sits tight under the title, not a full
    // gap away.
    [stack setCustomSpacing:12 afterView:titleLabel];
    [stack setCustomSpacing:16 afterView:self.progressView];
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
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:12],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-24],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-16],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-48],
    ]];

    __weak typeof(self) weakSelf = self;
    self.engineStateToken = [[OCEngine shared] addStateChangeObserver:^(OCEngineState state) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf refresh];
            [weakSelf maybePresentTabs];
            // Install just finished (or the guest was already
            // installed): auto-start now. maybeAutoStartEngine is
            // once-per-launch and guarded, so repeat calls are
            // no-ops; the launch-time call skipped without
            // consuming the attempt when setup was not done yet.
            if (state == OCEngineStateInstalled) {
                [[OCEngine shared] maybeAutoStartEngine];
            }
        });
    }];
}

- (void)dealloc {
    [self.pollTimer invalidate];
    [[OCEngine shared] removeStateChangeObserver:self.engineStateToken];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Entrance animation (see runEntranceAnimation): reset the
    // animated views to their start state before the view is
    // visible, so the first frame never flashes them in place.
    [self prepareEntrance];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self runEntranceAnimation];
    [self startPollTimer];
    [self refresh];
    // A new Running state may auto-present the tabs once; coming
    // back from the tabs must not re-trigger it (TermX's
    // terminalPresented). The flag only resets when the engine is
    // not running — after a Stop, a later start presents again.
    if ([OCEngine shared].state != OCEngineStateRunning) {
        self.tabsPresented = NO;
    }
    [self maybePresentTabs];
    // The guest may have been installed while this screen was away
    // (or the app was backgrounded when it finished): auto-start
    // now, once per launch, guarded inside maybeAutoStartEngine.
    if ([OCEngine shared].state == OCEngineStateInstalled) {
        [[OCEngine shared] maybeAutoStartEngine];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.pollTimer invalidate];
    self.pollTimer = nil;
}

// Staggered entrance (user direction 2026-11-22 09:49 IST,
// TermX feel): the Install button shows first, then the five
// checklist rows light up one by one, then the secondary buttons
// (Continue to app, Log). Each row fades and slides up a little
// as it arrives, showing its live state (spinner if active, check
// if done) — the checklist lighting up step by step, not
// everything popping in at once. Total under one second,
// ease-out only, no spring. The Install button stays tappable
// the whole time: alpha does not block touches, and nothing here
// sets hidden or userInteractionEnabled, so it can be tapped the
// moment it appears. Runs once per appearance (viewWillAppear
// resets, viewDidAppear plays); the poll timer and state refresh
// never touch alpha or transform, so they cannot restart it or
// fight it.
- (void)prepareEntrance {
    self.actionButton.alpha = 0;
    for (UIView *row in self.rowViews) {
        row.alpha = 0;
        row.transform = CGAffineTransformMakeTranslation(0, 8);
    }
    self.continueButton.alpha = 0;
    self.logButton.alpha = 0;
}

- (void)runEntranceAnimation {
    // Install first, immediately tappable.
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.actionButton.alpha = 1;
    } completion:nil];
    // Rows one by one, ~110 ms apart, fading and sliding up.
    for (NSInteger i = 0; i < (NSInteger)self.rowViews.count; i++) {
        UIView *row = self.rowViews[(NSUInteger)i];
        [UIView animateWithDuration:0.20 delay:0.12 + (double)i * 0.11 options:UIViewAnimationOptionCurveEaseOut animations:^{
            row.alpha = 1;
            row.transform = CGAffineTransformIdentity;
        } completion:nil];
    }
    // Secondary buttons last, together. Ends at 0.84 s.
    [UIView animateWithDuration:0.16 delay:0.68 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.continueButton.alpha = 1;
        self.logButton.alpha = 1;
    } completion:nil];
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
    [self.rowViews addObject:row];
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
    [self refreshButtons];
    // Thin progress bar: the install fraction while downloading,
    // the serve progress once the engine is starting, 0 otherwise.
    OCEngine *engine = [OCEngine shared];
    double p = engine.state == OCEngineStateInstalling ? self.installFraction : engine.serveProgress;
    self.progressView.progress = (float)p;
}

// The one action button follows the engine state, and only the
// state (TermX's refreshButtons): Install when nothing is
// installed (or the last step failed), Start when the guest is
// installed but powered off, disabled with the live phase while
// something is in flight. The boot itself is automatic —
// maybeAutoStartEngine runs on install completion and on launch —
// so there is no Boot button to tap.
- (void)refreshButtons {
    OCEngine *engine = [OCEngine shared];
    switch (engine.state) {
        case OCEngineStateNotInstalled:
        case OCEngineStateError:
            [self.actionButton setTitle:@"Install" forState:UIControlStateNormal];
            self.actionButton.enabled = YES;
            break;
        case OCEngineStateInstalled:
        case OCEngineStateStopped:
        case OCEngineStateCorePending:
            [self.actionButton setTitle:@"Start" forState:UIControlStateNormal];
            self.actionButton.enabled = YES;
            break;
        case OCEngineStateInstalling:
            [self.actionButton setTitle:@"Downloading…" forState:UIControlStateNormal];
            self.actionButton.enabled = NO;
            break;
        case OCEngineStateStarting:
            [self.actionButton setTitle:@"Starting…" forState:UIControlStateNormal];
            self.actionButton.enabled = NO;
            break;
        case OCEngineStateRunning:
            [self.actionButton setTitle:@"Running" forState:UIControlStateNormal];
            self.actionButton.enabled = NO;
            break;
    }
}

- (void)actionTapped {
    OCEngine *engine = [OCEngine shared];
    if (engine.state == OCEngineStateInstalled || engine.state == OCEngineStateStopped ||
        engine.state == OCEngineStateCorePending) {
        // The guest is installed but powered off (or the runtime
        // failed to load): a manual start. This is a start the user
        // asked for, so it clears the stopped flag inside
        // startEngineWithCompletion.
        [[OCEngine shared] startEngineWithCompletion:^(BOOL started, NSError * _Nullable error) {
            (void)started; (void)error;
        }];
        return;
    }
    if (engine.state == OCEngineStateNotInstalled || engine.state == OCEngineStateError) {
        // One tap installs; the engine boots itself when the state
        // flips to Installed (the observer calls
        // maybeAutoStartEngine), and the tabs open on their own
        // once the server is listening.
        self.installFraction = 0;
        self.installMessage = nil;
        __weak typeof(self) weakSelf = self;
        [[OCEngine shared] runFirstLaunchSetupWithProgress:^(double fraction, NSString * _Nullable message) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                strongSelf.installFraction = fraction;
                strongSelf.installMessage = message;
                [strongSelf refresh];
            });
        } completion:^(BOOL done, NSError * _Nullable error) {
            (void)done; (void)error;
            // The state observer already refreshed and (on success)
            // auto-started; refresh once more so the button and the
            // reason line settle on the final state.
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf refresh];
            });
        }];
        return;
    }
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
    // Install and Start both live on this screen now — no reason
    // here ever points at the Engine tab.
    NSString *reason = nil;
    if (!engine.guestCoreLinked && !engine.guestCoreLoadable) {
        reason = @"The engine is not ready yet in this build. Setup downloads the guest image first, but the engine cannot start here.";
    } else if (engine.state == OCEngineStateNotInstalled) {
        reason = @"Guest image 1.16 GB · 12 parts";
    } else if (engine.state == OCEngineStateInstalling) {
        // The live install step (e.g. "Downloading guest image
        // part 3 of 12…"), or the static line until the first
        // progress callback arrives.
        reason = self.installMessage.length ? self.installMessage : @"First-launch setup is still running.";
    } else if (engine.state == OCEngineStateError) {
        reason = @"Setup or start failed. Check the log for the exact reason — Install below tries again.";
    } else if (engine.state == OCEngineStateStopped) {
        reason = @"The engine stopped. Tap Start below to start it again.";
    } else if (engine.state == OCEngineStateCorePending) {
        reason = @"The engine runtime did not load. Tap Start below to try again.";
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
        [self setRow:OCStartupRowCore state:OCStartupRowPending detail:@"Loads automatically at startup"];
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

// Present the tabs once the server is listening. A short beat at
// full green first, so the user sees every check done. If the log
// screen is open on top, wait until it closes instead of yanking
// it away. Only once per Running state (see viewDidAppear): coming
// back from the tabs with a swipe down must not re-trigger it.
- (void)maybePresentTabs {
    if ([OCEngine shared].state != OCEngineStateRunning) return;
    if (self.tabsPresented) return;
    if (self.presentScheduled) return;
    self.presentScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.presentScheduled = NO;
        if (strongSelf.presentedViewController) {
            strongSelf.presentTabsAfterLogCloses = YES;
            return;
        }
        [strongSelf presentTabs];
    });
}

// The tabs themselves, full-screen over this screen (TermX
// presents its terminal the same way). The exit drag (see
// onTabsExitPan:) is the way back here.
- (void)presentTabs {
    if (!self.tabsViewController) return;
    if (self.presentedViewController) {
        self.presentTabsAfterLogCloses = YES;
        return;
    }
    self.tabsPresented = YES;
    UITabBarController *tabs = self.tabsViewController;
    tabs.modalPresentationStyle = UIModalPresentationFullScreen;
    // The way back to the startup screen: a downward drag that
    // starts in the top strip of the tabs (TermX's exit drag on
    // its terminal). Attached once: presenting the tabs again
    // after a swipe back must not stack a second recognizer.
    // See onTabsExitPan:.
    if (!self.exitPanAttached) {
        self.exitPanAttached = YES;
        UIPanGestureRecognizer *exitPan = [[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(onTabsExitPan:)];
        exitPan.delegate = self;
        [tabs.view addGestureRecognizer:exitPan];
    }
    [self presentViewController:tabs animated:YES completion:nil];
}

// The exit drag: a downward pan that began in the top strip of the
// tabs returns to the startup screen, where Install, Start and Log
// live. It only fires for a drag that begins at the very top and
// moves decisively down, so ordinary scrolling never triggers it
// (TermX's onExitPan, same thresholds; the tabs have no single
// scroll view to check for "at top", so the top-strip start is
// the whole guard).
- (void)onTabsExitPan:(UIPanGestureRecognizer *)pan {
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            self.exitPanStart = [pan locationInView:pan.view];
            break;
        case UIGestureRecognizerStateEnded: {
            CGPoint translation = [pan translationInView:pan.view];
            if (self.exitPanStart.y < 44 && translation.y > 80 &&
                fabs(translation.y) > fabs(translation.x)) {
                // The presenting screen dismisses the tabs; the
                // flag stays set while Running (see viewDidAppear),
                // so the tabs do not instantly re-present.
                [self dismissViewControllerAnimated:YES completion:nil];
            }
            break;
        }
        default:
            break;
    }
}

// Let the exit pan watch touches alongside the tabs' own scrolling,
// so a drag can be both a scroll and a candidate exit.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    (void)gestureRecognizer; (void)otherGestureRecognizer;
    return YES;
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
        if (weakSelf.presentTabsAfterLogCloses) {
            weakSelf.presentTabsAfterLogCloses = NO;
            [weakSelf presentTabs];
        }
    }];
}

- (void)continueTapped {
    [self presentTabs];
}

@end
