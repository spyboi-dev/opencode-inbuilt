// OCChatViewController - chat thread for one OpenCode session.
// Follows FreeMilk's chat layout: a glass toolbar with a back
// chevron, the Chat/Files switch, a Run button and a globe for the
// in-app browser; Files lives inside the chat as an embedded file
// browser; a bar above the composer counts uncommitted changes and
// opens the diff; the composer is a big rounded card over a Liquid
// Glass blur, with rounded system type throughout. Messages
// themselves follow OpenCode's own session-ui model (user bubbles,
// plain assistant markdown, collapsible Thinking cards, 28px tool
// rows, Shell command + result cards). FreeMilk's roadmap, milk
// bottle mascot, flavours and sips are not copied: the roadmap has
// no OpenCode equivalent, and the mascot/flavours/sips are
// FreeMilk's own branding and currency.
#import "OCChatViewController.h"
#import "OCServerClient.h"
#import "OCSettings.h"
#import "OCUtil.h"
#import "OCFilesViewController.h"
#import "OCBrowserViewController.h"

// FreeMilk's rounded system font for the chrome (toolbar, bar,
// composer). Takes the system font at the given size and weight and
// swaps its design to rounded, so the UI reads like FreeMilk's
// rounded system type.
static UIFont *OCRoundedFont(CGFloat size, UIFontWeight weight) {
    UIFont *base = [UIFont systemFontOfSize:size weight:weight];
    UIFontDescriptor *desc = [[base fontDescriptor] fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
    UIFont *font = [UIFont fontWithDescriptor:desc size:size];
    return font ?: base;
}

static UIColor *OCLayer01(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0x24/255.0 green:0x24/255.0 blue:0x24/255.0 alpha:1.0] : [UIColor secondarySystemBackgroundColor];
    }];
}
static UIColor *OCLayer02(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0x2e/255.0 green:0x2e/255.0 blue:0x2e/255.0 alpha:1.0] : [UIColor systemGray5Color];
    }];
}
static UIColor *OCTextBase(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0xf2/255.0 green:0xf2/255.0 blue:0xf2/255.0 alpha:1.0] : [UIColor labelColor];
    }];
}
static UIColor *OCTextMuted(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0xae/255.0 green:0xae/255.0 blue:0xae/255.0 alpha:1.0] : [UIColor secondaryLabelColor];
    }];
}
static UIColor *OCTextFaint(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0x80/255.0 green:0x80/255.0 blue:0x80/255.0 alpha:1.0] : [UIColor tertiaryLabelColor];
    }];
}
static UIColor *OCAccent(void) {
    return [UIColor colorWithRed:0x3b/255.0 green:0x5c/255.0 blue:0xf6/255.0 alpha:1.0];
}
// Claude chrome colours.
static UIColor *OCClaudeBackground(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0x1a/255.0 green:0x1a/255.0 blue:0x1a/255.0 alpha:1.0] : [UIColor systemBackgroundColor];
    }];
}
static UIColor *OCClaudeGlass(void) {
    return [UIColor colorWithWhite:1.0 alpha:0.08];
}

@interface OCChatViewController () <UITableViewDataSource, UITableViewDelegate, OCServerEventDelegate, UITextViewDelegate>
@property (nonatomic, strong) NSDictionary *session;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *composerCard;
@property (nonatomic, strong) UITextView *composer;
@property (nonatomic, strong) UILabel *composerPlaceholder;
@property (nonatomic, strong) NSLayoutConstraint *composerHeightConstraint;
@property (nonatomic, strong) UIButton *modelChipButton;
@property (nonatomic, strong) UIButton *sendButton;
@property (nonatomic, strong) NSLayoutConstraint *composerBottomConstraint;
// Claude chrome: glass top bar, composer extras.
@property (nonatomic, strong) UIVisualEffectView *toolbarGlass;
@property (nonatomic, strong) UIView *topBar;
@property (nonatomic, strong) UIButton *menuButton;
@property (nonatomic, strong) UIButton *plusButton;
@property (nonatomic, strong) UIButton *micButton;
// FreeMilk toolbar: Chat/Files switch, Run, globe. Files mode is an
// embedded file browser; the uncommitted bar sits above the composer.
@property (nonatomic, strong) UISegmentedControl *modeSegment;
@property (nonatomic, strong) UIButton *runButton;
@property (nonatomic, strong) UIButton *globeButton;
@property (nonatomic, strong) OCFilesViewController *filesChild;
@property (nonatomic, strong) UIButton *uncommittedBar;
@property (nonatomic, strong) NSLayoutConstraint *uncommittedHeightConstraint;
@property (nonatomic, assign) NSInteger diffCount;
@property (nonatomic, strong) NSArray *displayItems; // @{kind, role, text, detail, output, state, model, duration, key}
@property (nonatomic, strong) OCServerClient *client;
@property (nonatomic, strong, nullable) NSTimer *pollTimer;
@property (nonatomic, assign) BOOL waitingForReply;
@property (nonatomic, strong) NSMutableSet *shownPermissionIDs;
@property (nonatomic, strong) NSMutableSet *expandedKeys; // keys of expanded tool/reasoning rows
@property (nonatomic, strong) NSMutableSet *expandedUserKeys; // keys of expanded (unfolded) user bubbles
@property (nonatomic, copy, nullable) NSString *currentModelID;
@property (nonatomic, copy, nullable) NSString *currentProviderID;
@end

@implementation OCChatViewController

- (instancetype)initWithSession:(NSDictionary *)session {
    if ((self = [super init])) {
        _session = session;
        _displayItems = @[];
        _shownPermissionIDs = [NSMutableSet set];
        _expandedKeys = [NSMutableSet set];
        _expandedUserKeys = [NSMutableSet set];
        // Claude is a full-screen chat: no tab bar on this screen.
        self.hidesBottomBarWhenPushed = YES;
        id model = session[@"model"];
        if ([model isKindOfClass:[NSDictionary class]]) {
            if ([model[@"id"] isKindOfClass:[NSString class]]) _currentModelID = model[@"id"];
            if ([model[@"providerID"] isKindOfClass:[NSString class]]) _currentProviderID = model[@"providerID"];
        } else if ([model isKindOfClass:[NSString class]]) {
            _currentModelID = model;
        }
    }
    return self;
}

- (OCServerClient *)serverClient {
    if (!_client) {
        OCSettings *s = [OCSettings shared];
        _client = [[OCServerClient alloc] initWithServerURL:s.serverURL password:[s serverPassword]];
    }
    return _client;
}

- (NSString *)sessionID { return self.session[@"id"]; }

// The short model label for the Claude-style pills (hero + composer):
// just the model id, so it fits like "Sonnet 5.5 Medium" does.
- (NSString *)modelPillTitle {
    if (self.currentModelID.length) return self.currentModelID;
    return @"Choose a model";
}

// The white circle at the right of the composer is the send button in
// all three states: a waveform when the input is empty (tap focuses
// the composer), an arrow-up when there is text (tap sends), and a
// stop square while a reply is in flight (tap stops).
- (void)updateSendButton {
    UIImage *icon = nil;
    if (self.waitingForReply) {
        icon = [UIImage systemImageNamed:@"stop.fill"];
    } else if (self.composer.text.length) {
        icon = [UIImage systemImageNamed:@"arrow.up"];
    } else {
        icon = [UIImage systemImageNamed:@"waveform"];
    }
    [self.sendButton setImage:[icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
    self.sendButton.tintColor = [UIColor blackColor];
}

- (UIButton *)glassCircleButtonWithImage:(NSString *)imageName diameter:(CGFloat)diameter {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.backgroundColor = OCClaudeGlass();
    b.layer.cornerRadius = diameter / 2.0;
    b.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
    b.layer.borderWidth = 0.5;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setImage:[[UIImage systemImageNamed:imageName] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
    b.tintColor = [UIColor whiteColor];
    return b;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = OCClaudeBackground();

    // FreeMilk's chat toolbar: a glass bar with a back chevron, the
    // Chat/Files switch, a Run button and a globe for the in-app
    // browser. The nav bar itself is hidden in viewWillAppear and
    // restored in viewWillDisappear.
    UIVisualEffectView *toolbarGlass = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    toolbarGlass.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:toolbarGlass];
    self.toolbarGlass = toolbarGlass;
    self.topBar = toolbarGlass.contentView;

    self.menuButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.menuButton setImage:[[UIImage systemImageNamed:@"chevron.left"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
    self.menuButton.tintColor = OCTextBase();
    self.menuButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.menuButton addTarget:self action:@selector(menuTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.topBar addSubview:self.menuButton];

    self.modeSegment = [[UISegmentedControl alloc] initWithItems:@[@"Chat", @"Files"]];
    self.modeSegment.selectedSegmentIndex = 0;
    [self.modeSegment setTitleTextAttributes:@{NSFontAttributeName: OCRoundedFont(14, UIFontWeightSemibold)} forState:UIControlStateNormal];
    self.modeSegment.translatesAutoresizingMaskIntoConstraints = NO;
    [self.modeSegment addTarget:self action:@selector(modeChanged) forControlEvents:UIControlEventValueChanged];
    [self.topBar addSubview:self.modeSegment];

    self.runButton = [self glassCircleButtonWithImage:@"play.fill" diameter:36];
    [self.runButton addTarget:self action:@selector(runTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.topBar addSubview:self.runButton];

    self.globeButton = [self glassCircleButtonWithImage:@"globe" diameter:36];
    [self.globeButton addTarget:self action:@selector(globeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.topBar addSubview:self.globeButton];

    // The timeline.
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 60;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.backgroundColor = OCClaudeBackground();
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.tableView];

    // Files mode: the guest file browser, embedded as a child view
    // controller and swapped with the timeline by the Chat/Files
    // switch. FreeMilk keeps Files inside the chat, not as a tab.
    self.filesChild = [[OCFilesViewController alloc] init];
    [self addChildViewController:self.filesChild];
    self.filesChild.view.translatesAutoresizingMaskIntoConstraints = NO;
    self.filesChild.view.hidden = YES;
    [self.view addSubview:self.filesChild.view];
    [self.filesChild didMoveToParentViewController:self];

    // Uncommitted-changes bar, FreeMilk style: a bar above the
    // composer counting the session's uncommitted changes; tapping it
    // opens the diff. Hidden while the session is clean.
    self.uncommittedBar = [UIButton buttonWithType:UIButtonTypeSystem];
    self.uncommittedBar.backgroundColor = OCLayer01();
    self.uncommittedBar.layer.cornerRadius = 12;
    self.uncommittedBar.contentEdgeInsets = UIEdgeInsetsMake(10, 14, 10, 14);
    self.uncommittedBar.titleLabel.font = OCRoundedFont(14, UIFontWeightMedium);
    [self.uncommittedBar setTitleColor:OCTextBase() forState:UIControlStateNormal];
    self.uncommittedBar.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    self.uncommittedBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.uncommittedBar addTarget:self action:@selector(showDiff) forControlEvents:UIControlEventTouchUpInside];
    self.uncommittedBar.hidden = YES;
    [self.view addSubview:self.uncommittedBar];

    // Composer: FreeMilk's big rounded card (28px radius) over a
    // Liquid Glass blur. The text area sits on top; the bottom row
    // holds a plus circle, the model pill, a mic circle and the white
    // voice/send circle.
    self.composerCard = [[UIView alloc] init];
    self.composerCard.backgroundColor = [UIColor clearColor];
    self.composerCard.layer.cornerRadius = 28;
    self.composerCard.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
    self.composerCard.layer.borderWidth = 0.5;
    self.composerCard.clipsToBounds = YES;
    self.composerCard.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.composerCard];
    UIVisualEffectView *composerGlass = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    composerGlass.translatesAutoresizingMaskIntoConstraints = NO;
    [self.composerCard addSubview:composerGlass];
    [NSLayoutConstraint activateConstraints:@[
        [composerGlass.topAnchor constraintEqualToAnchor:self.composerCard.topAnchor],
        [composerGlass.leadingAnchor constraintEqualToAnchor:self.composerCard.leadingAnchor],
        [composerGlass.trailingAnchor constraintEqualToAnchor:self.composerCard.trailingAnchor],
        [composerGlass.bottomAnchor constraintEqualToAnchor:self.composerCard.bottomAnchor],
    ]];

    self.composer = [[UITextView alloc] init];
    self.composer.font = OCRoundedFont(16, UIFontWeightRegular);
    self.composer.backgroundColor = [UIColor clearColor];
    self.composer.textColor = OCTextBase();
    self.composer.delegate = self;
    self.composer.translatesAutoresizingMaskIntoConstraints = NO;
    self.composerHeightConstraint = [self.composer.heightAnchor constraintEqualToConstant:36];
    self.composerHeightConstraint.active = YES;
    [self.composerCard addSubview:self.composer];

    self.composerPlaceholder = [[UILabel alloc] init];
    self.composerPlaceholder.text = @"Chat with OpenCode";
    self.composerPlaceholder.font = OCRoundedFont(16, UIFontWeightRegular);
    self.composerPlaceholder.textColor = OCTextFaint();
    self.composerPlaceholder.translatesAutoresizingMaskIntoConstraints = NO;
    [self.composerCard addSubview:self.composerPlaceholder];

    self.plusButton = [self glassCircleButtonWithImage:@"plus" diameter:36];
    [self.plusButton addTarget:self action:@selector(plusTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.composerCard addSubview:self.plusButton];

    self.modelChipButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.modelChipButton setTitle:[self modelPillTitle] forState:UIControlStateNormal];
    self.modelChipButton.titleLabel.font = OCRoundedFont(14, UIFontWeightMedium);
    [self.modelChipButton setTitleColor:OCTextBase() forState:UIControlStateNormal];
    self.modelChipButton.backgroundColor = OCClaudeGlass();
    self.modelChipButton.layer.cornerRadius = 18;
    self.modelChipButton.contentEdgeInsets = UIEdgeInsetsMake(6, 12, 6, 12);
    self.modelChipButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.modelChipButton addTarget:self action:@selector(pickModel) forControlEvents:UIControlEventTouchUpInside];
    [self.composerCard addSubview:self.modelChipButton];

    self.micButton = [self glassCircleButtonWithImage:@"mic.fill" diameter:36];
    [self.micButton addTarget:self action:@selector(micTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.composerCard addSubview:self.micButton];

    self.sendButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.sendButton.backgroundColor = [UIColor whiteColor];
    self.sendButton.layer.cornerRadius = 18;
    self.sendButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.sendButton addTarget:self action:@selector(sendTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.composerCard addSubview:self.sendButton];
    [self updateSendButton];

    self.composerBottomConstraint = [self.composerCard.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8];
    // The uncommitted bar sits between the content and the composer;
    // the table and files views end at whichever is visible above it.
    NSLayoutConstraint *tableBottom = [self.tableView.bottomAnchor constraintEqualToAnchor:self.uncommittedBar.topAnchor constant:-8];
    NSLayoutConstraint *filesBottom = [self.filesChild.view.bottomAnchor constraintEqualToAnchor:self.uncommittedBar.topAnchor constant:-8];
    NSLayoutConstraint *composerTop = [self.uncommittedBar.bottomAnchor constraintEqualToAnchor:self.composerCard.topAnchor constant:-8];
    // When the bar is hidden it still occupies its height, so the
    // content ends at the composer with a fixed 12pt gap instead.
    // The bar's height constraint collapses it when hidden.
    NSLayoutConstraint *uncommittedHeight = [self.uncommittedBar.heightAnchor constraintEqualToConstant:40];
    self.uncommittedHeightConstraint = uncommittedHeight;
    [NSLayoutConstraint activateConstraints:@[
        [self.toolbarGlass.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.toolbarGlass.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.toolbarGlass.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.toolbarGlass.heightAnchor constraintEqualToConstant:56],
        [self.menuButton.leadingAnchor constraintEqualToAnchor:self.topBar.leadingAnchor constant:8],
        [self.menuButton.centerYAnchor constraintEqualToAnchor:self.topBar.centerYAnchor],
        [self.menuButton.widthAnchor constraintEqualToConstant:36],
        [self.menuButton.heightAnchor constraintEqualToConstant:36],
        [self.modeSegment.leadingAnchor constraintEqualToAnchor:self.menuButton.trailingAnchor constant:8],
        [self.modeSegment.centerYAnchor constraintEqualToAnchor:self.topBar.centerYAnchor],
        [self.modeSegment.heightAnchor constraintEqualToConstant:32],
        [self.modeSegment.trailingAnchor constraintEqualToAnchor:self.runButton.leadingAnchor constant:-8],
        [self.runButton.trailingAnchor constraintEqualToAnchor:self.globeButton.leadingAnchor constant:-8],
        [self.runButton.centerYAnchor constraintEqualToAnchor:self.topBar.centerYAnchor],
        [self.runButton.widthAnchor constraintEqualToConstant:36],
        [self.runButton.heightAnchor constraintEqualToConstant:36],
        [self.globeButton.trailingAnchor constraintEqualToAnchor:self.topBar.trailingAnchor constant:-12],
        [self.globeButton.centerYAnchor constraintEqualToAnchor:self.topBar.centerYAnchor],
        [self.globeButton.widthAnchor constraintEqualToConstant:36],
        [self.globeButton.heightAnchor constraintEqualToConstant:36],
        [self.tableView.topAnchor constraintEqualToAnchor:self.toolbarGlass.bottomAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        tableBottom,
        [self.filesChild.view.topAnchor constraintEqualToAnchor:self.toolbarGlass.bottomAnchor],
        [self.filesChild.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.filesChild.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        filesBottom,
        [self.uncommittedBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.uncommittedBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        composerTop,
        uncommittedHeight,
        [self.composerCard.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.composerCard.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        self.composerBottomConstraint,
        [self.composer.topAnchor constraintEqualToAnchor:self.composerCard.topAnchor constant:14],
        [self.composer.leadingAnchor constraintEqualToAnchor:self.composerCard.leadingAnchor constant:18],
        [self.composer.trailingAnchor constraintEqualToAnchor:self.composerCard.trailingAnchor constant:-18],
        [self.composerPlaceholder.leadingAnchor constraintEqualToAnchor:self.composer.leadingAnchor constant:5],
        [self.composerPlaceholder.centerYAnchor constraintEqualToAnchor:self.composer.centerYAnchor],
        [self.plusButton.leadingAnchor constraintEqualToAnchor:self.composerCard.leadingAnchor constant:12],
        [self.plusButton.topAnchor constraintEqualToAnchor:self.composer.bottomAnchor constant:8],
        [self.plusButton.bottomAnchor constraintEqualToAnchor:self.composerCard.bottomAnchor constant:-12],
        [self.plusButton.widthAnchor constraintEqualToConstant:36],
        [self.plusButton.heightAnchor constraintEqualToConstant:36],
        [self.modelChipButton.leadingAnchor constraintEqualToAnchor:self.plusButton.trailingAnchor constant:8],
        [self.modelChipButton.centerYAnchor constraintEqualToAnchor:self.plusButton.centerYAnchor],
        [self.modelChipButton.heightAnchor constraintEqualToConstant:36],
        [self.micButton.centerYAnchor constraintEqualToAnchor:self.plusButton.centerYAnchor],
        [self.micButton.widthAnchor constraintEqualToConstant:36],
        [self.micButton.heightAnchor constraintEqualToConstant:36],
        [self.sendButton.trailingAnchor constraintEqualToAnchor:self.composerCard.trailingAnchor constant:-12],
        [self.sendButton.centerYAnchor constraintEqualToAnchor:self.plusButton.centerYAnchor],
        [self.sendButton.widthAnchor constraintEqualToConstant:36],
        [self.sendButton.heightAnchor constraintEqualToConstant:36],
    ]];
    // The model pill takes the space between the plus and mic
    // buttons; the mic sits just left of the send circle.
    [self.modelChipButton.trailingAnchor constraintLessThanOrEqualToAnchor:self.micButton.leadingAnchor constant:-8].active = YES;
    [self.micButton.trailingAnchor constraintEqualToAnchor:self.sendButton.leadingAnchor constant:-8].active = YES;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Claude is a full-screen chat: the nav bar stays hidden here and
    // is restored when leaving, so the sessions list keeps its bar.
    [self.navigationController setNavigationBarHidden:YES animated:animated];
    self.serverClient.eventDelegate = self;
    [self.serverClient startEventStream];
    [self updateUncommittedBar];
    [self reloadMessages];
    [self checkPermissions];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.navigationController setNavigationBarHidden:NO animated:animated];
    [self.serverClient stopEventStream];
    [self.pollTimer invalidate];
    self.pollTimer = nil;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.pollTimer invalidate];
}

#pragma mark - Keyboard

- (void)keyboardWillShow:(NSNotification *)note {
    CGRect frame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat height = CGRectGetHeight([self.view convertRect:frame fromView:nil]);
    self.composerBottomConstraint.constant = -height + self.view.safeAreaInsets.bottom - 8;
    [self.view layoutIfNeeded];
    [self scrollToBottom];
}

- (void)keyboardWillHide:(NSNotification *)note {
    self.composerBottomConstraint.constant = -8;
    [self.view layoutIfNeeded];
}

#pragma mark - Composer

- (void)textViewDidChange:(UITextView *)textView {
    // The text area scrolls internally past 180px, so long prompts
    // stay usable without the card taking the screen.
    CGFloat width = textView.frame.size.width;
    if (width > 0) {
        CGSize fit = [textView sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)];
        CGFloat height = MIN(MAX(fit.height, 36), 180);
        if (fabs(self.composerHeightConstraint.constant - height) > 0.5) {
            self.composerHeightConstraint.constant = height;
            [self.view layoutIfNeeded];
        }
    }
    self.composerPlaceholder.hidden = textView.text.length > 0;
    [self updateSendButton];
}

#pragma mark - Claude chrome actions

- (void)menuTapped {
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)micTapped {
    // The keyboard already offers dictation; bring it up.
    [self.composer becomeFirstResponder];
}

- (void)plusTapped {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"View diff" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self showDiff];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Open Files" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        self.modeSegment.selectedSegmentIndex = 1;
        [self modeChanged];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

// FreeMilk's Chat/Files switch: the timeline and the embedded file
// browser swap; the composer stays put.
- (void)modeChanged {
    BOOL filesMode = self.modeSegment.selectedSegmentIndex == 1;
    self.tableView.hidden = filesMode;
    self.filesChild.view.hidden = !filesMode;
    if (filesMode) [self.filesChild reload];
}

// FreeMilk's Run button: ask the agent to build and run the project.
- (void)runTapped {
    [self sendPromptText:@"Build and run the project"];
}

// FreeMilk's globe: the in-app browser for previewing a build.
- (void)globeTapped {
    OCBrowserViewController *browser = [[OCBrowserViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:browser];
    [self presentViewController:nav animated:YES completion:nil];
}

// FreeMilk's uncommitted-changes bar: counts the session's diff and
// shows while there is anything uncommitted; tapping it opens the
// diff. Hidden while the session is clean.
- (void)updateUncommittedBar {
    [[self serverClient] fetchDiffForSession:self.sessionID completion:^(NSArray *diff, NSError *error) {
        if (error) return;
        self.diffCount = (NSInteger)(diff ?: @[]).count;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.diffCount > 0) {
                [self.uncommittedBar setTitle:[NSString stringWithFormat:@"%ld uncommitted change%@  ›", (long)self.diffCount, self.diffCount == 1 ? @"" : @"s"] forState:UIControlStateNormal];
                self.uncommittedBar.hidden = NO;
                self.uncommittedHeightConstraint.constant = 40;
            } else {
                self.uncommittedBar.hidden = YES;
                self.uncommittedHeightConstraint.constant = 0;
            }
            [self.view layoutIfNeeded];
        });
    }];
}

#pragma mark - Messages

+ (NSArray *)displayItemsFromMessages:(NSArray *)messages {
    // Real server shape (verified live against opencode 2.2.6):
    // user:      {type:"user", text:"...", time:{created}}
    // assistant: {type:"assistant", model:{id, providerID}, time:{created, completed},
    //            content:[{type:"text", text:"..."},
    //            {type:"reasoning", text:"..."},
    //            {type:"tool", name:"shell", state:{status, input:{command}, output:"..."}}]}
    // idle:      {type:"idle", outcome:"succeeded"} (skipped, it is a status line)
    NSMutableArray *items = [NSMutableArray array];
    NSInteger messageIndex = 0;
    for (id raw in messages) {
        if (![raw isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *message = raw;
        NSString *role = message[@"type"];
        if (![role isKindOfClass:[NSString class]]) role = @"assistant";
        if ([role isEqualToString:@"idle"]) continue;
        NSString *messageID = message[@"id"];
        if (![messageID isKindOfClass:[NSString class]]) messageID = [NSString stringWithFormat:@"m%ld", (long)messageIndex];
        NSString *modelID = @"";
        NSString *providerID = @"";
        id model = message[@"model"];
        if ([model isKindOfClass:[NSDictionary class]]) {
            if ([model[@"id"] isKindOfClass:[NSString class]]) modelID = model[@"id"];
            if ([model[@"providerID"] isKindOfClass:[NSString class]]) providerID = model[@"providerID"];
        }
        NSString *duration = @"";
        NSDictionary *time = message[@"time"];
        if ([time isKindOfClass:[NSDictionary class]]) {
            NSNumber *created = time[@"created"];
            NSNumber *completed = time[@"completed"];
            if ([created isKindOfClass:[NSNumber class]] && [completed isKindOfClass:[NSNumber class]] && completed.longLongValue > created.longLongValue) {
                long seconds = (completed.longLongValue - created.longLongValue) / 1000;
                duration = seconds < 60 ? [NSString stringWithFormat:@"%lds", seconds] : [NSString stringWithFormat:@"%ldm %lds", seconds / 60, seconds % 60];
            }
        }
        NSString *sentTime = @"";
        if ([time isKindOfClass:[NSDictionary class]] && [time[@"created"] isKindOfClass:[NSNumber class]]) {
            NSDate *date = [NSDate dateWithTimeIntervalSince1970:((NSNumber *)time[@"created"]).doubleValue / 1000.0];
            NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
            formatter.timeStyle = NSDateFormatterShortStyle;
            formatter.dateStyle = NSDateFormatterNoStyle;
            sentTime = [formatter stringFromDate:date];
        }
        NSArray *parts = message[@"content"];
        if (![parts isKindOfClass:[NSArray class]] || !parts.count) {
            NSString *text = message[@"text"];
            if ([text isKindOfClass:[NSString class]] && text.length)
                [items addObject:@{@"kind": @"text", @"role": role, @"text": text, @"detail": @"", @"output": @"", @"model": modelID, @"provider": providerID, @"duration": duration, @"sentTime": sentTime, @"key": [NSString stringWithFormat:@"%@:0", messageID]}];
            messageIndex++;
            continue;
        }
        NSInteger partIndex = 0;
        for (id partRaw in parts) {
            if (![partRaw isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *part = partRaw;
            NSString *type = part[@"type"];
            NSString *key = [NSString stringWithFormat:@"%@:%ld", messageID, (long)partIndex];
            if ([type isEqualToString:@"text"] && [part[@"text"] isKindOfClass:[NSString class]] && ((NSString *)part[@"text"]).length) {
                [items addObject:@{@"kind": @"text", @"role": role, @"text": part[@"text"], @"detail": @"", @"output": @"", @"model": modelID, @"provider": providerID, @"duration": duration, @"sentTime": sentTime, @"key": key}];
            } else if ([type isEqualToString:@"tool"]) {
                NSString *tool = part[@"name"];
                if (![tool isKindOfClass:[NSString class]]) tool = @"tool";
                NSDictionary *state = part[@"state"];
                NSString *status = @"";
                NSString *detail = @"";
                NSString *output = @"";
                if ([state isKindOfClass:[NSDictionary class]]) {
                    if ([state[@"status"] isKindOfClass:[NSString class]]) status = state[@"status"];
                    NSDictionary *input = state[@"input"];
                    if ([input isKindOfClass:[NSDictionary class]]) {
                        detail = input[@"command"] ?: input[@"filePath"] ?: input[@"path"] ?: input[@"pattern"] ?: input[@"query"] ?: input[@"url"] ?: @"";
                        if (![detail isKindOfClass:[NSString class]]) detail = @"";
                    }
                    id out = state[@"output"];
                    if ([out isKindOfClass:[NSString class]]) output = out;
                    else if ([out isKindOfClass:[NSDictionary class]] || [out isKindOfClass:[NSArray class]]) {
                        NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
                        if (json) output = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] ?: @"";
                    }
                }
                // OpenCode keeps only the last 64 KiB of shell output.
                if (output.length > 65536) output = [output substringFromIndex:output.length - 65536];
                [items addObject:@{@"kind": @"tool", @"role": role, @"text": tool, @"detail": detail, @"output": output, @"state": status, @"model": modelID, @"provider": providerID, @"duration": duration, @"sentTime": sentTime, @"key": key}];
            } else if ([type isEqualToString:@"reasoning"] && [part[@"text"] isKindOfClass:[NSString class]] && ((NSString *)part[@"text"]).length) {
                [items addObject:@{@"kind": @"reasoning", @"role": @"reasoning", @"text": part[@"text"], @"detail": @"", @"output": @"", @"model": modelID, @"provider": providerID, @"duration": duration, @"sentTime": sentTime, @"key": key}];
            }
            partIndex++;
        }
        messageIndex++;
    }
    return items;
}

- (void)reloadMessages {
    [[self serverClient] fetchMessagesForSession:self.sessionID completion:^(NSArray *messages, NSError *error) {
        if (error || !messages) return;
        // The server returns messages newest first; the thread reads oldest first.
        NSArray *chronological = [[messages reverseObjectEnumerator] allObjects];
        self.displayItems = [OCChatViewController displayItemsFromMessages:chronological];
        [self updateUncommittedBar];
        [self.tableView reloadData];
        [self scrollToBottom];
    }];
    [self checkPermissions];
}

- (void)scrollToBottom {
    NSInteger rows = [self.tableView numberOfRowsInSection:0];
    if (!rows) return;
    NSIndexPath *last = [NSIndexPath indexPathForRow:rows - 1 inSection:0];
    [self.tableView scrollToRowAtIndexPath:last atScrollPosition:UITableViewScrollPositionBottom animated:YES];
}

- (void)startPolling {
    [self.pollTimer invalidate];
    self.waitingForReply = YES;
    [self updateSendButton];
    __weak typeof(self) weakSelf = self;
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
        (void)timer;
        [weakSelf reloadMessages];
        [weakSelf checkSessionIdle];
    }];
}

- (void)stopPolling {
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    self.waitingForReply = NO;
    [self updateSendButton];
}

// The server marks a session idle when the agent finishes (time.idle >=
// time.busy). Stop polling then, so the thread does not refetch forever.
- (void)checkSessionIdle {
    if (!self.waitingForReply) return;
    [[self serverClient] fetchSession:self.sessionID completion:^(NSDictionary *session, NSError *error) {
        if (error || !session) return;
        NSDictionary *time = session[@"time"];
        if (![time isKindOfClass:[NSDictionary class]]) return;
        NSNumber *busy = time[@"busy"];
        NSNumber *idle = time[@"idle"];
        if ([busy isKindOfClass:[NSNumber class]] && [idle isKindOfClass:[NSNumber class]] &&
            idle.longLongValue > 0 && idle.longLongValue >= busy.longLongValue) {
            [self stopPolling];
            [self reloadMessages];
        }
    }];
}

#pragma mark - Send / stop

// Send a prompt without going through the composer text view. Used
// by the Run button and any other quick action.
- (void)sendPromptText:(NSString *)text {
    if (!text.length || self.waitingForReply) return;
    [self startPolling];
    [[self serverClient] sendPrompt:text toSession:self.sessionID completion:^(NSDictionary *message, NSError *error) {
        (void)message;
        if (error) {
            [self stopPolling];
            [self showError:error];
            return;
        }
        [self reloadMessages];
    }];
}

- (void)sendTapped {
    // The white circle is one button in three states: while a reply
    // is in flight it stops, with text it sends, and when empty it
    // just focuses the composer (the keyboard offers dictation).
    if (self.waitingForReply) { [self stopTapped]; return; }
    NSString *text = [self.composer.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length) { [self.composer becomeFirstResponder]; return; }
    self.composer.text = @"";
    [self textViewDidChange:self.composer];
    [self.composer resignFirstResponder];
    [self sendPromptText:text];
}

- (void)stopTapped {
    [[self serverClient] interruptSession:self.sessionID completion:^(NSError *error) {
        (void)error;
        [self stopPolling];
        [self reloadMessages];
    }];
}

- (void)showError:(NSError *)error {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Error" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Model picker / diff

- (void)pickModel {
    [[self serverClient] listModelsWithCompletion:^(NSArray *models, NSError *error) {
        if (error || !models.count) { [self showError:error ?: [NSError errorWithDomain:@"OC" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No models returned by the server"}]]; return; }
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Model" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSDictionary *model in models) {
            NSString *modelID = model[@"modelID"] ?: model[@"id"];
            NSString *providerID = model[@"providerID"];
            NSString *name = model[@"name"] ?: modelID;
            if (![modelID isKindOfClass:[NSString class]]) continue;
            [sheet addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                (void)action;
                [[self serverClient] setModel:modelID providerID:providerID forSession:self.sessionID completion:^(NSError *error) {
                    if (error) [self showError:error];
                    else {
                        self.currentModelID = modelID;
                        self.currentProviderID = providerID;
                        [self.modelChipButton setTitle:[self modelPillTitle] forState:UIControlStateNormal];
                    }
                }];
            }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:sheet animated:YES completion:nil];
    }];
}

- (void)showDiff {
    [[self serverClient] fetchDiffForSession:self.sessionID completion:^(NSArray *diff, NSError *error) {
        if (error) { [self showError:error]; return; }
        NSMutableString *text = [NSMutableString string];
        for (NSDictionary *entry in diff) {
            NSString *path = entry[@"path"] ?: entry[@"file"] ?: @"";
            [text appendFormat:@"%@\n", path];
            NSString *patch = entry[@"patch"] ?: entry[@"diff"];
            if ([patch isKindOfClass:[NSString class]]) [text appendFormat:@"%@\n\n", patch];
        }
        if (!text.length) text = [NSMutableString stringWithString:@"No pending changes."];
        UIViewController *vc = [[UIViewController alloc] init];
        vc.title = @"Diff";
        UITextView *tv = [[UITextView alloc] initWithFrame:vc.view.bounds];
        tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        tv.editable = NO;
        tv.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
        tv.text = text;
        [vc.view addSubview:tv];
        vc.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Revert" style:UIBarButtonItemStylePlain target:self action:@selector(revertTapped)];
        [self.navigationController pushViewController:vc animated:YES];
    }];
}

- (void)revertTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Revert changes" message:@"Undo all uncommitted changes in this session?" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Revert" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        (void)action;
        [[self serverClient] revertSession:self.sessionID completion:^(NSError *error) {
            if (error) [self showError:error];
            [self.navigationController popViewControllerAnimated:YES];
            [self reloadMessages];
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Permissions

- (void)checkPermissions {
    [[self serverClient] fetchPermissionsForSession:self.sessionID completion:^(NSArray *requests, NSError *error) {
        if (error || !requests.count) return;
        for (NSDictionary *req in requests) {
            NSString *requestID = req[@"id"];
            if (![requestID isKindOfClass:[NSString class]]) continue;
            if ([self.shownPermissionIDs containsObject:requestID]) continue;
            [self.shownPermissionIDs addObject:requestID];
            [self presentPermission:req];
        }
    }];
}

- (void)presentPermission:(NSDictionary *)req {
    NSString *requestID = req[@"id"];
    NSString *action = req[@"action"];
    if (![action isKindOfClass:[NSString class]]) action = @"run this";
    NSArray *resources = req[@"resources"];
    NSString *resource = ([resources isKindOfClass:[NSArray class]] && resources.count && [resources[0] isKindOfClass:[NSString class]]) ? resources[0] : @"";
    NSString *title = [NSString stringWithFormat:@"Allow %@?", action];
    NSString *message = req[@"message"];
    if (![message isKindOfClass:[NSString class]] || !message.length) message = resource.length ? resource : @"The agent wants to do this.";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Allow once" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        (void)action;
        [self replyPermission:requestID decision:@"once"];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Always allow" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        (void)action;
        [self replyPermission:requestID decision:@"always"];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Deny" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        (void)action;
        [self replyPermission:requestID decision:@"reject"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)replyPermission:(NSString *)requestID decision:(NSString *)decision {
    [[self serverClient] replyPermission:requestID sessionID:self.sessionID decision:decision completion:^(NSError *error) {
        if (error) [self showError:error];
        [self reloadMessages];
    }];
}

#pragma mark - SSE events

- (void)serverClientDidReceiveEvent:(NSDictionary *)event {
    NSString *type = event[@"type"];
    if (![type isKindOfClass:[NSString class]]) return;
    if ([type isEqualToString:@"server.connected"]) return;
    // Any session/message/permission/tool event refreshes this thread.
    if ([type containsString:@"message"] || [type containsString:@"session"] ||
        [type containsString:@"permission"] || [type containsString:@"tool"]) {
        [self reloadMessages];
    }
}

- (void)serverClientEventStreamDidFail:(NSError *)error {
    // The client auto-reconnects. Polling keeps the thread live meanwhile.
    if (self.waitingForReply && !self.pollTimer) [self startPolling];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.displayItems.count;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    NSDictionary *item = self.displayItems[indexPath.row];
    NSString *kind = item[@"kind"];
    NSString *key = item[@"key"];
    if (![key isKindOfClass:[NSString class]]) return;
    if ([kind isEqualToString:@"tool"] || [kind isEqualToString:@"reasoning"]) {
        if ([self.expandedKeys containsObject:key]) [self.expandedKeys removeObject:key];
        else [self.expandedKeys addObject:key];
        [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    } else if ([kind isEqualToString:@"text"] && [item[@"role"] isEqualToString:@"user"]) {
        if ([self.expandedUserKeys containsObject:key]) [self.expandedUserKeys removeObject:key];
        else [self.expandedUserKeys addObject:key];
        [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"MessageCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellID];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = [UIColor clearColor];
    }
    // Cells are reused; clear the previous message's views first.
    for (UIView *v in cell.contentView.subviews) [v removeFromSuperview];

    NSDictionary *item = self.displayItems[indexPath.row];
    NSString *kind = item[@"kind"];
    NSString *role = item[@"role"];

    if ([kind isEqualToString:@"tool"]) {
        [self configureToolCell:cell item:item];
    } else if ([kind isEqualToString:@"reasoning"]) {
        [self configureReasoningCell:cell item:item];
    } else if ([role isEqualToString:@"user"]) {
        [self configureUserCell:cell item:item];
    } else {
        [self configureAssistantCell:cell item:item];
    }
    return cell;
}

// User message, OpenCode's way: a right-aligned bubble, layer-02,
// 10px radius, at most 82% wide, 8px/12px padding, plain text. A
// faint sent-time sits under the bubble. Past 12 lines it folds to
// the first 8 with a Read more toggle.
- (void)configureUserCell:(UITableViewCell *)cell item:(NSDictionary *)item {
    NSString *text = item[@"text"];
    NSString *key = item[@"key"];
    BOOL folded = NO;
    NSString *shownText = text;
    NSArray *lines = [text componentsSeparatedByString:@"\n"];
    if (lines.count > 12 && ![self.expandedUserKeys containsObject:key]) {
        folded = YES;
        shownText = [[lines subarrayWithRange:NSMakeRange(0, 8)] componentsJoinedByString:@"\n"];
    }
    UIView *bubble = [[UIView alloc] init];
    bubble.backgroundColor = OCLayer02();
    bubble.layer.cornerRadius = 10;
    bubble.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *label = [[UILabel alloc] init];
    label.text = shownText;
    label.font = [UIFont systemFontOfSize:16];
    label.textColor = OCTextBase();
    label.numberOfLines = 0;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [bubble addSubview:label];
    [cell.contentView addSubview:bubble];

    NSMutableArray *constraints = [NSMutableArray arrayWithArray:@[
        [label.topAnchor constraintEqualToAnchor:bubble.topAnchor constant:8],
        [label.leadingAnchor constraintEqualToAnchor:bubble.leadingAnchor constant:12],
        [label.trailingAnchor constraintEqualToAnchor:bubble.trailingAnchor constant:-12],
        [label.bottomAnchor constraintEqualToAnchor:bubble.bottomAnchor constant:-8],
        [bubble.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:4],
        [bubble.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [bubble.widthAnchor constraintLessThanOrEqualToAnchor:cell.contentView.widthAnchor multiplier:0.82],
    ]];
    // Vertical chain: bubble, then the fold toggle if the message
    // folds, then the sent-time meta. Only the last view pins the
    // cell bottom, so the chain never fights itself.
    UIView *lastView = bubble;
    BOOL needsFoldToggle = folded || [self.expandedUserKeys containsObject:key];
    if (needsFoldToggle) {
        UIButton *foldButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [foldButton setTitle:(folded ? @"Read more" : @"Show less") forState:UIControlStateNormal];
        foldButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        [foldButton setTitleColor:OCAccent() forState:UIControlStateNormal];
        foldButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
        foldButton.translatesAutoresizingMaskIntoConstraints = NO;
        [foldButton addTarget:self action:@selector(foldButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        foldButton.tag = [self.displayItems indexOfObject:item];
        [cell.contentView addSubview:foldButton];
        [constraints addObjectsFromArray:@[
            [foldButton.topAnchor constraintEqualToAnchor:lastView.bottomAnchor constant:2],
            [foldButton.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        ]];
        lastView = foldButton;
    }
    NSString *sentTime = item[@"sentTime"];
    if ([sentTime isKindOfClass:[NSString class]] && sentTime.length) {
        UILabel *meta = [[UILabel alloc] init];
        meta.text = sentTime;
        meta.font = [UIFont systemFontOfSize:12];
        meta.textColor = OCTextFaint();
        meta.textAlignment = NSTextAlignmentRight;
        meta.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:meta];
        [constraints addObjectsFromArray:@[
            [meta.topAnchor constraintEqualToAnchor:lastView.bottomAnchor constant:2],
            [meta.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        ]];
        lastView = meta;
    }
    [constraints addObject:[lastView.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-4]];
    [NSLayoutConstraint activateConstraints:constraints];
}

- (void)foldButtonTapped:(UIButton *)sender {
    NSInteger row = sender.tag;
    if (row < 0 || row >= self.displayItems.count) return;
    NSDictionary *item = self.displayItems[row];
    NSString *key = item[@"key"];
    if (![key isKindOfClass:[NSString class]]) return;
    if ([self.expandedUserKeys containsObject:key]) [self.expandedUserKeys removeObject:key];
    else [self.expandedUserKeys addObject:key];
    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:row inSection:0]] withRowAnimation:UITableViewRowAnimationAutomatic];
}

// Assistant text, OpenCode's way: no bubble, no avatar, plain
// flowing markdown. A faint footer carries a copy button plus the
// model, duration and tokens line.
- (void)configureAssistantCell:(UITableViewCell *)cell item:(NSDictionary *)item {
    UILabel *label = [[UILabel alloc] init];
    label.attributedText = [OCUtil attributedFromMarkdown:item[@"text"] baseFont:[UIFont systemFontOfSize:16]];
    label.numberOfLines = 0;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:label];

    NSMutableArray *metaParts = [NSMutableArray array];
    NSString *provider = item[@"provider"];
    NSString *model = item[@"model"];
    if ([provider isKindOfClass:[NSString class]] && provider.length && [model isKindOfClass:[NSString class]] && model.length)
        [metaParts addObject:[NSString stringWithFormat:@"%@ / %@", provider, model]];
    else if ([model isKindOfClass:[NSString class]] && model.length)
        [metaParts addObject:model];
    NSString *duration = item[@"duration"];
    if ([duration isKindOfClass:[NSString class]] && duration.length) [metaParts addObject:duration];
    NSString *metaText = [metaParts componentsJoinedByString:@" · "];

    UIButton *copyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [copyButton setTitle:@"Copy" forState:UIControlStateNormal];
    copyButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [copyButton setTitleColor:OCTextFaint() forState:UIControlStateNormal];
    copyButton.translatesAutoresizingMaskIntoConstraints = NO;
    [copyButton addTarget:self action:@selector(copyButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    copyButton.tag = [self.displayItems indexOfObject:item];
    [cell.contentView addSubview:copyButton];

    UILabel *metaLabel = [[UILabel alloc] init];
    metaLabel.text = metaText;
    metaLabel.font = [UIFont systemFontOfSize:12];
    metaLabel.textColor = OCTextFaint();
    metaLabel.numberOfLines = 0;
    metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:metaLabel];

    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:12],
        [label.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [label.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [copyButton.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:6],
        [copyButton.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [copyButton.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
        [metaLabel.centerYAnchor constraintEqualToAnchor:copyButton.centerYAnchor],
        [metaLabel.leadingAnchor constraintEqualToAnchor:copyButton.trailingAnchor constant:12],
        [metaLabel.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [metaLabel.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
    ]];
}

- (void)copyButtonTapped:(UIButton *)sender {
    NSInteger row = sender.tag;
    if (row < 0 || row >= self.displayItems.count) return;
    NSString *text = self.displayItems[row][@"text"];
    if ([text isKindOfClass:[NSString class]] && text.length) {
        [UIPasteboard generalPasteboard].string = text;
        [sender setTitle:@"Copied" forState:UIControlStateNormal];
    }
}

// Reasoning, OpenCode's way: a collapsible BasicTool card titled
// "Thinking" while streaming and "Thought" once done, with the
// duration as the subtitle and the reasoning text inside in 13px
// muted markdown.
- (void)configureReasoningCell:(UITableViewCell *)cell item:(NSDictionary *)item {
    NSString *key = item[@"key"];
    BOOL expanded = [self.expandedKeys containsObject:key];
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = OCLayer01();
    card.layer.cornerRadius = 12;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:card];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = expanded ? @"Thought" : @"Thinking";
    titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    titleLabel.textColor = OCTextBase();
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:titleLabel];

    UILabel *subtitleLabel = [[UILabel alloc] init];
    NSString *duration = item[@"duration"];
    subtitleLabel.text = ([duration isKindOfClass:[NSString class]] && duration.length) ? duration : @"";
    subtitleLabel.font = [UIFont systemFontOfSize:13];
    subtitleLabel.textColor = OCTextMuted();
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:subtitleLabel];

    UILabel *chevron = [[UILabel alloc] init];
    chevron.text = expanded ? @"▾" : @"▸";
    chevron.font = [UIFont systemFontOfSize:13];
    chevron.textColor = OCTextFaint();
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:chevron];

    NSMutableArray *constraints = [NSMutableArray arrayWithArray:@[
        [titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:8],
        [titleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [subtitleLabel.centerYAnchor constraintEqualToAnchor:titleLabel.centerYAnchor],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:titleLabel.trailingAnchor constant:8],
        [chevron.centerYAnchor constraintEqualToAnchor:titleLabel.centerYAnchor],
        [chevron.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [card.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:4],
        [card.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
    ]];
    if (expanded) {
        UILabel *body = [[UILabel alloc] init];
        body.attributedText = [OCUtil attributedFromMarkdown:item[@"text"] baseFont:[UIFont systemFontOfSize:13]];
        body.textColor = OCTextMuted();
        body.numberOfLines = 0;
        body.translatesAutoresizingMaskIntoConstraints = NO;
        [card addSubview:body];
        [constraints addObjectsFromArray:@[
            [body.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:8],
            [body.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
            [body.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
            [body.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-10],
            [titleLabel.bottomAnchor constraintEqualToAnchor:body.topAnchor constant:-8],
        ]];
    } else {
        [constraints addObject:[titleLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8]];
    }
    [constraints addObject:[card.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-4]];
    [NSLayoutConstraint activateConstraints:constraints];
}

// Tool call, OpenCode's way: a BasicTool trigger row, 28px tall, with
// a per-tool icon, a 13px medium title and a 13px muted subtitle
// (truncated), and a chevron. No card background on the trigger; the
// detail opens below it. Shell shows a command + result card.
- (void)configureToolCell:(UITableViewCell *)cell item:(NSDictionary *)item {
    NSString *key = item[@"key"];
    BOOL expanded = [self.expandedKeys containsObject:key];
    NSString *tool = item[@"text"];
    NSString *status = item[@"state"];
    BOOL running = [status isEqualToString:@"pending"] || [status isEqualToString:@"running"];

    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:row];

    UILabel *iconLabel = [[UILabel alloc] init];
    iconLabel.text = [self iconForTool:tool];
    iconLabel.font = [UIFont systemFontOfSize:13];
    iconLabel.textColor = OCTextMuted();
    iconLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:iconLabel];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = [self displayTitleForTool:tool];
    titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    titleLabel.textColor = OCTextBase();
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:titleLabel];

    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.text = item[@"detail"];
    subtitleLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    subtitleLabel.textColor = OCTextMuted();
    subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:subtitleLabel];

    UILabel *chevron = [[UILabel alloc] init];
    chevron.text = expanded ? @"▾" : @"▸";
    chevron.font = [UIFont systemFontOfSize:13];
    chevron.textColor = OCTextFaint();
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:chevron];

    // A running tool shimmers its title in OpenCode; here the title
    // reads in the accent colour while it runs.
    if (running) titleLabel.textColor = OCAccent();

    NSMutableArray *constraints = [NSMutableArray arrayWithArray:@[
        [row.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:4],
        [row.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [row.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [row.heightAnchor constraintEqualToConstant:28],
        [iconLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [iconLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [titleLabel.leadingAnchor constraintEqualToAnchor:iconLabel.trailingAnchor constant:8],
        [titleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:titleLabel.trailingAnchor constant:8],
        [subtitleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:chevron.leadingAnchor constant:-8],
        [chevron.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [chevron.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];

    if (expanded) {
        UIView *detail = [self detailViewForTool:item];
        detail.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:detail];
        [constraints addObjectsFromArray:@[
            [detail.topAnchor constraintEqualToAnchor:row.bottomAnchor constant:4],
            [detail.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
            [detail.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
            [detail.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-4],
        ]];
    } else {
        [constraints addObject:[row.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-4]];
    }
    [NSLayoutConstraint activateConstraints:constraints];
}

- (NSString *)iconForTool:(NSString *)tool {
    static NSDictionary *icons;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        icons = @{
            @"shell": @"⌘", @"bash": @"⌘", @"read": @"📄", @"edit": @"✎",
            @"write": @"✎", @"patch": @"✎", @"list": @"☰", @"glob": @"☰",
            @"grep": @"⌕", @"webfetch": @"🌐", @"websearch": @"⌕",
            @"browser": @"🌐", @"agent": @"🤖", @"skill": @"✦",
            @"todowrite": @"☑", @"question": @"?",
        };
    });
    NSString *icon = icons[[tool lowercaseString]];
    return icon ?: @"⚙";
}

- (NSString *)displayTitleForTool:(NSString *)tool {
    static NSDictionary *titles;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        titles = @{
            @"shell": @"Shell", @"bash": @"Shell", @"read": @"Read",
            @"list": @"List", @"glob": @"Glob", @"grep": @"Grep",
            @"webfetch": @"Webfetch", @"websearch": @"Web Search",
            @"browser": @"Browser", @"edit": @"Edit", @"write": @"Write",
            @"patch": @"Patch", @"question": @"Questions", @"agent": @"Agent",
            @"skill": @"Skill", @"todowrite": @"Todo",
        };
    });
    NSString *title = titles[[tool lowercaseString]];
    if (title) return title;
    NSString *capitalised = [tool capitalizedString];
    return [NSString stringWithFormat:@"Called %@", capitalised];
}

// The detail that opens under a tool trigger. Shell gets OpenCode's
// command + result card (0.5px border, 6px radius, mono 13px, result
// in layer-01); other tools show their output as muted mono text.
- (UIView *)detailViewForTool:(NSDictionary *)item {
    NSString *tool = item[@"text"];
    NSString *output = item[@"output"];
    NSString *detail = item[@"detail"];
    BOOL isShell = [[tool lowercaseString] isEqualToString:@"shell"] || [[tool lowercaseString] isEqualToString:@"bash"];
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = OCLayer01();
    card.layer.cornerRadius = 6;
    card.layer.borderColor = [UIColor separatorColor].CGColor;
    card.layer.borderWidth = 0.5;

    UILabel *commandLabel = [[UILabel alloc] init];
    commandLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    commandLabel.textColor = OCTextBase();
    commandLabel.numberOfLines = 0;
    commandLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:commandLabel];

    UILabel *outputLabel = [[UILabel alloc] init];
    outputLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    outputLabel.textColor = OCTextMuted();
    outputLabel.numberOfLines = 0;
    outputLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:outputLabel];

    if (isShell) {
        commandLabel.text = detail.length ? detail : @"(no command)";
        outputLabel.text = output.length ? output : @"";
    } else {
        commandLabel.text = detail.length ? detail : @"";
        outputLabel.text = output.length ? output : @"";
    }
    NSMutableArray *constraints = [NSMutableArray arrayWithArray:@[
        [commandLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:8],
        [commandLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [commandLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
    ]];
    if (outputLabel.text.length) {
        [constraints addObjectsFromArray:@[
            [outputLabel.topAnchor constraintEqualToAnchor:commandLabel.bottomAnchor constant:8],
            [outputLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
            [outputLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
            [outputLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8],
        ]];
    } else {
        [constraints addObject:[commandLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8]];
    }
    [NSLayoutConstraint activateConstraints:constraints];
    return card;
}

@end
