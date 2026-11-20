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

// OpenCode's exact dark tokens (ui/src/styles/tokens/theme.css):
// base #242424, layer-01 #2e2e2e, layer-02 #3a3a3a, text #f2f2f2,
// muted #aeaeae, faint #808080, accent blue-400 #a2bcff (dark) and
// blue-600 #3b5cf6 (light). Inter for UI, IBM Plex Mono for code;
// on iOS the system font reads as Inter and the monospaced system
// font as Plex Mono.
static UIColor *OCLayer01(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0x2e/255.0 green:0x2e/255.0 blue:0x2e/255.0 alpha:1.0] : [UIColor secondarySystemBackgroundColor];
    }];
}
static UIColor *OCLayer02(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0x3a/255.0 green:0x3a/255.0 blue:0x3a/255.0 alpha:1.0] : [UIColor systemGray5Color];
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
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0xa2/255.0 green:0xbc/255.0 blue:0xff/255.0 alpha:1.0] : [UIColor colorWithRed:0x3b/255.0 green:0x5c/255.0 blue:0xf6/255.0 alpha:1.0];
    }];
}
// OpenCode's base background.
static UIColor *OCClaudeBackground(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0x24/255.0 green:0x24/255.0 blue:0x24/255.0 alpha:1.0] : [UIColor systemBackgroundColor];
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
@property (nonatomic, strong) UIButton *sparkleButton;
// FreeMilk toolbar: Chat/Files switch, Run, globe. Files mode is an
// embedded file browser; the uncommitted bar sits above the composer.
// The roadmap sits at the bottom of the chat, fed by the session's
// todos (the todowrite tool calls), one ticket per milestone.
@property (nonatomic, strong) UISegmentedControl *modeSegment;
@property (nonatomic, strong) UIButton *projectFolderButton;
@property (nonatomic, strong) UIButton *runButton;
@property (nonatomic, strong) UIButton *globeButton;
@property (nonatomic, strong) OCFilesViewController *filesChild;
@property (nonatomic, strong) UIButton *uncommittedBar;
@property (nonatomic, strong) NSLayoutConstraint *uncommittedHeightConstraint;
@property (nonatomic, assign) NSInteger diffCount;
@property (nonatomic, strong) UIView *roadmapContainer;
@property (nonatomic, strong) UIScrollView *roadmapScroll;
@property (nonatomic, strong) NSLayoutConstraint *roadmapHeightConstraint;
@property (nonatomic, strong) NSArray *roadmapItems;
@property (nonatomic, strong) NSArray *displayItems; // @{kind, role, text, detail, output, state, model, duration, key}
@property (nonatomic, strong) OCServerClient *client;
@property (nonatomic, strong, nullable) NSTimer *pollTimer;
@property (nonatomic, assign) BOOL waitingForReply;
@property (nonatomic, strong) NSMutableSet *shownPermissionIDs;
@property (nonatomic, strong) NSMutableSet *expandedKeys; // keys of expanded tool/reasoning rows
@property (nonatomic, strong) NSMutableSet *expandedUserKeys; // keys of expanded (unfolded) user bubbles
@property (nonatomic, copy, nullable) NSString *currentModelID;
@property (nonatomic, copy, nullable) NSString *currentProviderID;
// Inline error banner: a short reason shown at the top of the
// thread when a send, model pick or diff fails. It replaces the
// old modal "Error" alert, which blocked the whole screen for a
// normal state (the engine not running). It hides itself after
// a few seconds; errorBannerToken keeps a stale hide from
// dismissing a newer message.
@property (nonatomic, strong) UIView *errorBanner;
@property (nonatomic, strong) UILabel *errorBannerLabel;
@property (nonatomic, assign) NSInteger errorBannerToken;
// YES when the last message fetch failed: the empty thread then
// explains the server is down instead of saying "no messages".
@property (nonatomic, assign) BOOL loadError;
@end

@implementation OCChatViewController

- (instancetype)initWithSession:(NSDictionary *)session {
    if ((self = [super init])) {
        _session = session;
        _displayItems = @[];
        _shownPermissionIDs = [NSMutableSet set];
        _expandedKeys = [NSMutableSet set];
        _expandedUserKeys = [NSMutableSet set];
        // FreeMilk is a full-screen chat: no tab bar on this screen.
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

// The model pill in the composer, FreeMilk's way: the model name
// with a chevron, like "GPT 6 Luna" with a down chevron.
- (NSString *)modelPillTitle {
    NSString *name = self.currentModelID.length ? self.currentModelID : @"Choose a model";
    return [name stringByAppendingString:@"  ⌄"];
}

// FreeMilk's send button: a dark gray circle with an up arrow. While
// a reply is in flight it shows a stop square instead. The keyboard
// offers dictation, so there is no waveform/voice state.
- (void)updateSendButton {
    UIImage *icon = nil;
    if (self.waitingForReply) {
        icon = [UIImage systemImageNamed:@"stop.fill"];
    } else {
        icon = [UIImage systemImageNamed:@"arrow.up"];
    }
    [self.sendButton setImage:[icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
    self.sendButton.tintColor = [UIColor whiteColor];
    // With an empty composer the arrow used to look exactly as
    // ready as with text in it, although tapping it only focuses
    // the composer. Dim it while there is nothing to send.
    self.sendButton.alpha = (self.waitingForReply || self.composer.text.length > 0) ? 1.0 : 0.5;
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

    // FreeMilk's chat toolbar, from the screenshot: a single glass
    // pill bar floating over the thread, not a full-width bar. Left
    // to right: a back chevron in a dark circle, a folder button,
    // the Chat/Files switch as a centered pill with two icon
    // segments (a chat bubble and a folder), then a globe and a play
    // button in dark circles. The nav bar itself is hidden in
    // viewWillAppear and restored in viewWillDisappear.
    UIVisualEffectView *toolbarGlass = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    toolbarGlass.layer.cornerRadius = 28;
    toolbarGlass.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
    toolbarGlass.layer.borderWidth = 0.5;
    toolbarGlass.clipsToBounds = YES;
    toolbarGlass.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:toolbarGlass];
    self.toolbarGlass = toolbarGlass;
    self.topBar = toolbarGlass.contentView;

    self.menuButton = [self glassCircleButtonWithImage:@"chevron.left" diameter:44];
    [self.menuButton addTarget:self action:@selector(menuTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.topBar addSubview:self.menuButton];

    self.projectFolderButton = [self glassCircleButtonWithImage:@"folder" diameter:44];
    [self.projectFolderButton addTarget:self action:@selector(projectFolderTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.topBar addSubview:self.projectFolderButton];

    self.modeSegment = [[UISegmentedControl alloc] initWithItems:@[[UIImage systemImageNamed:@"bubble.left.and.bubble.right"], [UIImage systemImageNamed:@"folder"]]];
    self.modeSegment.selectedSegmentIndex = 0;
    self.modeSegment.translatesAutoresizingMaskIntoConstraints = NO;
    [self.modeSegment addTarget:self action:@selector(modeChanged) forControlEvents:UIControlEventValueChanged];
    [self.topBar addSubview:self.modeSegment];

    self.globeButton = [self glassCircleButtonWithImage:@"globe" diameter:44];
    [self.globeButton addTarget:self action:@selector(globeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.topBar addSubview:self.globeButton];

    self.runButton = [self glassCircleButtonWithImage:@"play.fill" diameter:44];
    [self.runButton addTarget:self action:@selector(runTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.topBar addSubview:self.runButton];

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

    // Roadmap: FreeMilk's list of milestone tickets at the bottom of
    // the chat. A horizontal row of glass ticket cards, one per todo
    // from the session. Hidden while the session has no todos.
    self.roadmapContainer = [[UIView alloc] init];
    self.roadmapContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.roadmapContainer.hidden = YES;
    [self.view addSubview:self.roadmapContainer];

    UILabel *roadmapLabel = [[UILabel alloc] init];
    roadmapLabel.text = @"Roadmap";
    roadmapLabel.font = OCRoundedFont(13, UIFontWeightSemibold);
    roadmapLabel.textColor = OCTextFaint();
    roadmapLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.roadmapContainer addSubview:roadmapLabel];

    self.roadmapScroll = [[UIScrollView alloc] init];
    self.roadmapScroll.showsHorizontalScrollIndicator = NO;
    self.roadmapScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.roadmapContainer addSubview:self.roadmapScroll];

    [NSLayoutConstraint activateConstraints:@[
        [roadmapLabel.topAnchor constraintEqualToAnchor:self.roadmapContainer.topAnchor],
        [roadmapLabel.leadingAnchor constraintEqualToAnchor:self.roadmapContainer.leadingAnchor constant:16],
        [roadmapLabel.trailingAnchor constraintEqualToAnchor:self.roadmapContainer.trailingAnchor constant:-16],
        [roadmapLabel.heightAnchor constraintEqualToConstant:18],
        [self.roadmapScroll.topAnchor constraintEqualToAnchor:roadmapLabel.bottomAnchor constant:6],
        [self.roadmapScroll.leadingAnchor constraintEqualToAnchor:self.roadmapContainer.leadingAnchor],
        [self.roadmapScroll.trailingAnchor constraintEqualToAnchor:self.roadmapContainer.trailingAnchor],
        [self.roadmapScroll.bottomAnchor constraintEqualToAnchor:self.roadmapContainer.bottomAnchor],
    ]];

    // Composer: FreeMilk's big rounded card over a Liquid Glass
    // blur, two rows. Top row: the text area (placeholder
    // "Follow up...") with a dark send arrow at its right. Bottom
    // row: a plus circle, the model pill (model name with a chevron),
    // and a sparkle for the theme picker at the right.
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
    self.composer.font = OCRoundedFont(17, UIFontWeightRegular);
    self.composer.backgroundColor = [UIColor clearColor];
    self.composer.textColor = OCTextBase();
    self.composer.delegate = self;
    self.composer.translatesAutoresizingMaskIntoConstraints = NO;
    self.composerHeightConstraint = [self.composer.heightAnchor constraintEqualToConstant:36];
    self.composerHeightConstraint.active = YES;
    [self.composerCard addSubview:self.composer];

    self.composerPlaceholder = [[UILabel alloc] init];
    self.composerPlaceholder.text = @"Follow up...";
    self.composerPlaceholder.font = OCRoundedFont(17, UIFontWeightRegular);
    self.composerPlaceholder.textColor = OCTextFaint();
    self.composerPlaceholder.translatesAutoresizingMaskIntoConstraints = NO;
    [self.composerCard addSubview:self.composerPlaceholder];

    self.plusButton = [self glassCircleButtonWithImage:@"plus" diameter:36];
    [self.plusButton addTarget:self action:@selector(plusTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.composerCard addSubview:self.plusButton];

    self.modelChipButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.modelChipButton setTitle:[self modelPillTitle] forState:UIControlStateNormal];
    self.modelChipButton.titleLabel.font = OCRoundedFont(17, UIFontWeightSemibold);
    [self.modelChipButton setTitleColor:OCTextBase() forState:UIControlStateNormal];
    self.modelChipButton.backgroundColor = [UIColor clearColor];
    self.modelChipButton.contentEdgeInsets = UIEdgeInsetsMake(6, 4, 6, 4);
    self.modelChipButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.modelChipButton addTarget:self action:@selector(pickModel) forControlEvents:UIControlEventTouchUpInside];
    [self.composerCard addSubview:self.modelChipButton];

    self.sparkleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.sparkleButton setImage:[[UIImage systemImageNamed:@"sparkles"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
    self.sparkleButton.tintColor = OCTextMuted();
    self.sparkleButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.sparkleButton addTarget:self action:@selector(sparkleTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.composerCard addSubview:self.sparkleButton];

    self.sendButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.sendButton.backgroundColor = [UIColor systemGrayColor];
    self.sendButton.layer.cornerRadius = 18;
    self.sendButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.sendButton addTarget:self action:@selector(sendTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.composerCard addSubview:self.sendButton];
    [self updateSendButton];

    self.composerBottomConstraint = [self.composerCard.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8];
    // The content ends at the roadmap, the roadmap ends at the
    // uncommitted bar, and the bar ends at the composer. Both the
    // roadmap and the bar collapse to zero height when hidden, so
    // the content reaches the composer with a fixed gap.
    NSLayoutConstraint *tableBottom = [self.tableView.bottomAnchor constraintEqualToAnchor:self.roadmapContainer.topAnchor constant:-8];
    NSLayoutConstraint *filesBottom = [self.filesChild.view.bottomAnchor constraintEqualToAnchor:self.roadmapContainer.topAnchor constant:-8];
    NSLayoutConstraint *roadmapBottom = [self.roadmapContainer.bottomAnchor constraintEqualToAnchor:self.uncommittedBar.topAnchor constant:-8];
    NSLayoutConstraint *roadmapHeight = [self.roadmapContainer.heightAnchor constraintEqualToConstant:0];
    self.roadmapHeightConstraint = roadmapHeight;
    NSLayoutConstraint *composerTop = [self.uncommittedBar.bottomAnchor constraintEqualToAnchor:self.composerCard.topAnchor constant:-8];
    // When the bar is hidden it still occupies its height, so the
    // content ends at the composer with a fixed 12pt gap instead.
    // The bar's height constraint collapses it when hidden.
    NSLayoutConstraint *uncommittedHeight = [self.uncommittedBar.heightAnchor constraintEqualToConstant:40];
    self.uncommittedHeightConstraint = uncommittedHeight;
    [NSLayoutConstraint activateConstraints:@[
        [self.toolbarGlass.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.toolbarGlass.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.toolbarGlass.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.toolbarGlass.heightAnchor constraintEqualToConstant:56],
        [self.menuButton.leadingAnchor constraintEqualToAnchor:self.topBar.leadingAnchor constant:6],
        [self.menuButton.centerYAnchor constraintEqualToAnchor:self.topBar.centerYAnchor],
        [self.menuButton.widthAnchor constraintEqualToConstant:44],
        [self.menuButton.heightAnchor constraintEqualToConstant:44],
        [self.projectFolderButton.leadingAnchor constraintEqualToAnchor:self.menuButton.trailingAnchor constant:6],
        [self.projectFolderButton.centerYAnchor constraintEqualToAnchor:self.topBar.centerYAnchor],
        [self.projectFolderButton.widthAnchor constraintEqualToConstant:44],
        [self.projectFolderButton.heightAnchor constraintEqualToConstant:44],
        [self.modeSegment.centerXAnchor constraintEqualToAnchor:self.topBar.centerXAnchor],
        [self.modeSegment.centerYAnchor constraintEqualToAnchor:self.topBar.centerYAnchor],
        [self.modeSegment.widthAnchor constraintEqualToConstant:120],
        [self.modeSegment.heightAnchor constraintEqualToConstant:40],
        [self.globeButton.trailingAnchor constraintEqualToAnchor:self.runButton.leadingAnchor constant:-6],
        [self.globeButton.centerYAnchor constraintEqualToAnchor:self.topBar.centerYAnchor],
        [self.globeButton.widthAnchor constraintEqualToConstant:44],
        [self.globeButton.heightAnchor constraintEqualToConstant:44],
        [self.runButton.trailingAnchor constraintEqualToAnchor:self.topBar.trailingAnchor constant:-6],
        [self.runButton.centerYAnchor constraintEqualToAnchor:self.topBar.centerYAnchor],
        [self.runButton.widthAnchor constraintEqualToConstant:44],
        [self.runButton.heightAnchor constraintEqualToConstant:44],
        [self.tableView.topAnchor constraintEqualToAnchor:self.toolbarGlass.bottomAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        tableBottom,
        [self.filesChild.view.topAnchor constraintEqualToAnchor:self.toolbarGlass.bottomAnchor],
        [self.filesChild.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.filesChild.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        filesBottom,
        [self.roadmapContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.roadmapContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        roadmapBottom,
        roadmapHeight,
        [self.uncommittedBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.uncommittedBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        composerTop,
        uncommittedHeight,
        [self.composerCard.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.composerCard.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        self.composerBottomConstraint,
        [self.composer.topAnchor constraintEqualToAnchor:self.composerCard.topAnchor constant:14],
        [self.composer.leadingAnchor constraintEqualToAnchor:self.composerCard.leadingAnchor constant:18],
        [self.composer.trailingAnchor constraintEqualToAnchor:self.sendButton.leadingAnchor constant:-8],
        [self.composerPlaceholder.leadingAnchor constraintEqualToAnchor:self.composer.leadingAnchor constant:5],
        [self.composerPlaceholder.centerYAnchor constraintEqualToAnchor:self.composer.centerYAnchor],
        [self.sendButton.trailingAnchor constraintEqualToAnchor:self.composerCard.trailingAnchor constant:-12],
        [self.sendButton.topAnchor constraintEqualToAnchor:self.composerCard.topAnchor constant:12],
        [self.sendButton.widthAnchor constraintEqualToConstant:36],
        [self.sendButton.heightAnchor constraintEqualToConstant:36],
        [self.plusButton.leadingAnchor constraintEqualToAnchor:self.composerCard.leadingAnchor constant:12],
        [self.plusButton.topAnchor constraintEqualToAnchor:self.composer.bottomAnchor constant:8],
        [self.plusButton.bottomAnchor constraintEqualToAnchor:self.composerCard.bottomAnchor constant:-12],
        [self.plusButton.widthAnchor constraintEqualToConstant:36],
        [self.plusButton.heightAnchor constraintEqualToConstant:36],
        [self.modelChipButton.leadingAnchor constraintEqualToAnchor:self.plusButton.trailingAnchor constant:8],
        [self.modelChipButton.centerYAnchor constraintEqualToAnchor:self.plusButton.centerYAnchor],
        [self.modelChipButton.heightAnchor constraintEqualToConstant:36],
        [self.sparkleButton.trailingAnchor constraintEqualToAnchor:self.composerCard.trailingAnchor constant:-16],
        [self.sparkleButton.centerYAnchor constraintEqualToAnchor:self.plusButton.centerYAnchor],
        [self.sparkleButton.widthAnchor constraintEqualToConstant:28],
        [self.sparkleButton.heightAnchor constraintEqualToConstant:28],
    ]];
    // The model pill takes the space between the plus and the sparkle.
    [self.modelChipButton.trailingAnchor constraintLessThanOrEqualToAnchor:self.sparkleButton.leadingAnchor constant:-8].active = YES;

    // Inline error banner, over the top of the thread. Hidden until
    // a send, model pick or diff fails; see showError:. The text
    // sits in a padded label inside the container: as a bare label
    // it ran edge to edge with no breathing room.
    self.errorBanner = [[UIView alloc] init];
    self.errorBanner.backgroundColor = OCLayer01();
    self.errorBanner.layer.cornerRadius = 10;
    self.errorBanner.layer.masksToBounds = YES;
    self.errorBanner.hidden = YES;
    self.errorBanner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.errorBanner];
    self.errorBannerLabel = [[UILabel alloc] init];
    self.errorBannerLabel.font = OCRoundedFont(13, UIFontWeightMedium);
    self.errorBannerLabel.textColor = OCTextBase();
    self.errorBannerLabel.textAlignment = NSTextAlignmentCenter;
    self.errorBannerLabel.numberOfLines = 2;
    self.errorBannerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.errorBanner addSubview:self.errorBannerLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.errorBanner.topAnchor constraintEqualToAnchor:self.toolbarGlass.bottomAnchor constant:8],
        [self.errorBanner.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.errorBanner.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.errorBanner.heightAnchor constraintGreaterThanOrEqualToConstant:36],
        [self.errorBannerLabel.topAnchor constraintEqualToAnchor:self.errorBanner.topAnchor constant:8],
        [self.errorBannerLabel.leadingAnchor constraintEqualToAnchor:self.errorBanner.leadingAnchor constant:12],
        [self.errorBannerLabel.trailingAnchor constraintEqualToAnchor:self.errorBanner.trailingAnchor constant:-12],
        [self.errorBannerLabel.bottomAnchor constraintEqualToAnchor:self.errorBanner.bottomAnchor constant:-8],
    ]];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
    [self updateEmptyState];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // FreeMilk is a full-screen chat: the nav bar stays hidden here and
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
    // Ride the keyboard's own animation instead of jumping: the
    // composer used to snap to its new spot while the keyboard
    // slid in.
    NSTimeInterval duration = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationOptions curve = (UIViewAnimationOptions)([note.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue] << 16);
    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:duration delay:0 options:curve animations:^{
        [self.view layoutIfNeeded];
    } completion:^(BOOL finished) {
        (void)finished;
        [weakSelf scrollToBottom];
    }];
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

// The sparkle at the right of the composer's bottom row: FreeMilk
// keeps its milk bottle there (the theme/flavour picker). The bottle
// is FreeMilk's own mascot, so this app shows a sparkle instead and
// opens the model picker, the closest matching action here.
- (void)sparkleTapped {
    [self pickModel];
}

- (void)plusTapped {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"View diff" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        (void)action;
        [self showDiff];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Open Files" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        (void)action;
        self.modeSegment.selectedSegmentIndex = 1;
        [self modeChanged];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

// FreeMilk's project folder button: opens the project's files.
- (void)projectFolderTapped {
    self.modeSegment.selectedSegmentIndex = 1;
    [self modeChanged];
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

// FreeMilk's roadmap: rebuild the ticket cards from the session's
// todos. One glass card per todo, with a status mark and the title;
// tapping a card asks the agent to work on that milestone. The
// whole strip hides while the session has no todos.
- (void)updateRoadmap {
    NSArray *todos = self.roadmapItems ?: @[];
    for (UIView *v in self.roadmapScroll.subviews) [v removeFromSuperview];
    if (!todos.count) {
        self.roadmapContainer.hidden = YES;
        self.roadmapHeightConstraint.constant = 0;
        [self.view layoutIfNeeded];
        return;
    }
    self.roadmapContainer.hidden = NO;
    self.roadmapHeightConstraint.constant = 110;
    CGFloat x = 16;
    for (NSDictionary *todo in todos) {
        if (![todo isKindOfClass:[NSDictionary class]]) continue;
        NSString *content = todo[@"content"];
        if (![content isKindOfClass:[NSString class]] || !content.length) continue;
        NSString *status = todo[@"status"];
        if (![status isKindOfClass:[NSString class]]) status = @"pending";
        NSString *mark = @"○";
        UIColor *markColor = OCTextFaint();
        if ([status isEqualToString:@"completed"]) { mark = @"✓"; markColor = [UIColor systemGreenColor]; }
        else if ([status isEqualToString:@"in_progress"]) { mark = @"◐"; markColor = [UIColor systemBlueColor]; }

        UIButton *card = [UIButton buttonWithType:UIButtonTypeSystem];
        card.backgroundColor = OCLayer01();
        card.layer.cornerRadius = 14;
        card.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.10].CGColor;
        card.layer.borderWidth = 0.5;
        card.translatesAutoresizingMaskIntoConstraints = NO;
        card.tag = (NSInteger)[todos indexOfObject:todo];
        [card addTarget:self action:@selector(roadmapCardTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.roadmapScroll addSubview:card];

        UILabel *markLabel = [[UILabel alloc] init];
        markLabel.text = mark;
        markLabel.font = OCRoundedFont(16, UIFontWeightSemibold);
        markLabel.textColor = markColor;
        markLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [card addSubview:markLabel];

        UILabel *titleLabel = [[UILabel alloc] init];
        titleLabel.text = content;
        titleLabel.font = OCRoundedFont(14, UIFontWeightMedium);
        titleLabel.textColor = OCTextBase();
        titleLabel.numberOfLines = 3;
        titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [card addSubview:titleLabel];

        [NSLayoutConstraint activateConstraints:@[
            [card.leadingAnchor constraintEqualToAnchor:self.roadmapScroll.leadingAnchor constant:x],
            [card.topAnchor constraintEqualToAnchor:self.roadmapScroll.topAnchor],
            [card.widthAnchor constraintEqualToConstant:180],
            [card.heightAnchor constraintEqualToConstant:76],
            [markLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
            [markLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:10],
            [markLabel.widthAnchor constraintEqualToConstant:20],
            [markLabel.heightAnchor constraintEqualToConstant:20],
            [titleLabel.leadingAnchor constraintEqualToAnchor:markLabel.trailingAnchor constant:6],
            [titleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
            [titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:10],
            [titleLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-10],
        ]];
        x += 180 + 10;
    }
    self.roadmapScroll.contentSize = CGSizeMake(x + 6, 76);
    [self.view layoutIfNeeded];
}

- (void)roadmapCardTapped:(UIButton *)sender {
    NSArray *todos = self.roadmapItems ?: @[];
    if (sender.tag < 0 || sender.tag >= (NSInteger)todos.count) return;
    NSDictionary *todo = todos[sender.tag];
    NSString *content = todo[@"content"];
    if (![content isKindOfClass:[NSString class]] || !content.length) return;
    [self sendPromptText:[NSString stringWithFormat:@"Work on this milestone: %@", content]];
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

// FreeMilk's roadmap: the session's todos, from the latest
// todowrite tool call. Each todo is a milestone ticket with a
// content (title), a status (pending, in_progress, completed) and a
// priority. The latest call wins; an empty list means no roadmap.
+ (NSArray *)roadmapFromMessages:(NSArray *)messages {
    NSArray *latest = nil;
    for (id raw in messages) {
        if (![raw isKindOfClass:[NSDictionary class]]) continue;
        NSArray *parts = raw[@"content"];
        if (![parts isKindOfClass:[NSArray class]]) continue;
        for (id partRaw in parts) {
            if (![partRaw isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *part = partRaw;
            if (![part[@"type"] isEqualToString:@"tool"]) continue;
            if (![part[@"name"] isEqualToString:@"todowrite"]) continue;
            NSDictionary *state = part[@"state"];
            if (![state isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *input = state[@"input"];
            if (![input isKindOfClass:[NSDictionary class]]) continue;
            NSArray *todos = input[@"todos"];
            if ([todos isKindOfClass:[NSArray class]] && todos.count) latest = todos;
        }
    }
    return latest ?: @[];
}

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
    __weak typeof(self) weakSelf = self;
    // Only stick to the bottom if the user is already there: the
    // 2-second poll used to yank the thread back down on every
    // refresh while the user was reading an earlier message.
    BOOL wasNearBottom = [self isNearBottom];
    [[self serverClient] fetchMessagesForSession:self.sessionID completion:^(NSArray *messages, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (error || !messages) {
            // A failed refresh is a normal state (engine down).
            // Keep the messages already on screen; the empty
            // thread explains itself instead of going blank.
            strongSelf.loadError = YES;
            [strongSelf updateEmptyState];
            return;
        }
        strongSelf.loadError = NO;
        // The server returns messages newest first; the thread reads oldest first.
        NSArray *chronological = [[messages reverseObjectEnumerator] allObjects];
        strongSelf.displayItems = [OCChatViewController displayItemsFromMessages:chronological];
        strongSelf.roadmapItems = [OCChatViewController roadmapFromMessages:chronological];
        [strongSelf updateUncommittedBar];
        [strongSelf updateRoadmap];
        [strongSelf.tableView reloadData];
        [strongSelf updateEmptyState];
        if (wasNearBottom) [strongSelf scrollToBottom];
    }];
    [self checkPermissions];
}

- (BOOL)isNearBottom {
    if (!self.tableView.contentSize.height) return YES;
    CGFloat bottom = self.tableView.contentOffset.y + self.tableView.bounds.size.height;
    return (self.tableView.contentSize.height - bottom) < 120;
}

// Empty thread: never a bare black screen. With messages the
// background is plain; without them it says why, and a failed
// fetch says the engine is down instead of "no messages yet".
- (void)updateEmptyState {
    if (self.displayItems.count) {
        self.tableView.backgroundView = nil;
        return;
    }
    UILabel *label = [[UILabel alloc] initWithFrame:self.tableView.bounds];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    label.text = self.loadError
        ? @"Could not load this chat.\nStart the engine and try again."
        : @"No messages yet.\nType below to start.";
    label.font = OCRoundedFont(15, UIFontWeightRegular);
    label.textColor = OCTextFaint();
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    self.tableView.backgroundView = label;
}

- (void)scrollToBottom {
    NSInteger rows = [self.tableView numberOfRowsInSection:0];
    if (!rows) return;
    NSIndexPath *last = [NSIndexPath indexPathForRow:rows - 1 inSection:0];
    [self.tableView scrollToRowAtIndexPath:last atScrollPosition:UITableViewScrollPositionBottom animated:YES];
}

// FreeMilk's agent loading view: while the agent is working, a
// footer row at the bottom of the thread shows a spinner and the
// agent's state. It is the thread's table footer, so it sits under
// the last message and scrolls with the thread.
- (void)updateActivityFooter {
    if (!self.waitingForReply) {
        self.tableView.tableFooterView = nil;
        return;
    }
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [spinner startAnimating];
    [footer addSubview:spinner];
    UILabel *label = [[UILabel alloc] init];
    label.text = @"Agent is working";
    label.font = OCRoundedFont(14, UIFontWeightMedium);
    label.textColor = OCTextFaint();
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [footer addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [spinner.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:16],
        [spinner.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
        [label.leadingAnchor constraintEqualToAnchor:spinner.trailingAnchor constant:8],
        [label.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
    ]];
    self.tableView.tableFooterView = footer;
}

- (void)startPolling {
    [self.pollTimer invalidate];
    self.waitingForReply = YES;
    [self updateSendButton];
    [self updateActivityFooter];
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
    [self updateActivityFooter];
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
    // The dark send arrow: while a reply is in flight it stops,
    // with text it sends, and when empty it just focuses the
    // composer.
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
    // Inline, not modal: a short reason at the top of the thread
    // that fades away on its own. A failed send or model pick is a
    // normal state (the engine is not running), not something to
    // block the whole screen with an OK button for.
    NSString *message = error.localizedDescription ?: @"Something went wrong.";
    dispatch_async(dispatch_get_main_queue(), ^{
        self.errorBannerLabel.text = message;
        self.errorBanner.hidden = NO;
        // The banner floats over the thread, so push the thread down
        // by its height while it is up; otherwise it covers the
        // first message for the four seconds it is visible.
        [self.errorBanner layoutIfNeeded];
        CGFloat bannerHeight = self.errorBanner.frame.size.height;
        if (bannerHeight <= 0) bannerHeight = 44;
        UIEdgeInsets inset = UIEdgeInsetsMake(bannerHeight + 8, 0, 0, 0);
        self.tableView.contentInset = inset;
        self.tableView.scrollIndicatorInsets = inset;
        self.errorBannerToken++;
        NSInteger token = self.errorBannerToken;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (token == self.errorBannerToken) {
                self.errorBanner.hidden = YES;
                self.tableView.contentInset = UIEdgeInsetsZero;
                self.tableView.scrollIndicatorInsets = UIEdgeInsetsZero;
            }
        });
    });
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

// User message, OpenCode's way: a right-aligned bubble, layer-02
// (#3a3a3a), 10px radius, at most 82% wide, 8px/12px padding, plain
// text. A faint sent-time sits under the bubble. Past 12 lines it
// folds to the first 8 with a Read more toggle.
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
    if (row < 0 || row >= (NSInteger)self.displayItems.count) return;
    NSDictionary *item = self.displayItems[row];
    NSString *key = item[@"key"];
    if (![key isKindOfClass:[NSString class]]) return;
    if ([self.expandedUserKeys containsObject:key]) [self.expandedUserKeys removeObject:key];
    else [self.expandedUserKeys addObject:key];
    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:row inSection:0]] withRowAnimation:UITableViewRowAnimationAutomatic];
}

// Assistant text, OpenCode's way: no bubble, no avatar, plain
// flowing markdown at 14px with 160% line-height. A faint footer
// carries a copy button plus the model, duration and tokens line.
- (void)configureAssistantCell:(UITableViewCell *)cell item:(NSDictionary *)item {
    UILabel *label = [[UILabel alloc] init];
    NSMutableAttributedString *body = [[OCUtil attributedFromMarkdown:item[@"text"] baseFont:[UIFont systemFontOfSize:14]] mutableCopy];
    NSMutableParagraphStyle *para = [[NSMutableParagraphStyle alloc] init];
    para.lineHeightMultiple = 1.6;
    [body addAttribute:NSParagraphStyleAttributeName value:para range:NSMakeRange(0, body.length)];
    label.attributedText = body;
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
    if (row < 0 || row >= (NSInteger)self.displayItems.count) return;
    NSString *text = self.displayItems[row][@"text"];
    if ([text isKindOfClass:[NSString class]] && text.length) {
        [UIPasteboard generalPasteboard].string = text;
        [sender setTitle:@"Copied" forState:UIControlStateNormal];
        // "Copied" used to stick forever until the cell was reused.
        // Put it back, on the same button.
        __weak UIButton *weakButton = sender;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakButton setTitle:@"Copy" forState:UIControlStateNormal];
        });
    }
}

// Reasoning, OpenCode's way: a collapsible BasicTool card titled
// "Thinking" while streaming and "Thought" once done, with the
// duration as the subtitle and the reasoning text inside in 13px
// muted markdown.
// Thinking, OpenCode's way: a compact bare row, no card. "Thinking"
// while streaming (the title reads in the accent colour) or
// "Thought" + the elapsed time once done. Opening shows the
// reasoning markdown.
- (void)configureReasoningCell:(UITableViewCell *)cell item:(NSDictionary *)item {
    NSString *key = item[@"key"];
    BOOL expanded = [self.expandedKeys containsObject:key];
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:row];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = expanded ? @"Thought" : @"Thinking";
    titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    titleLabel.textColor = OCTextBase();
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:titleLabel];

    UILabel *subtitleLabel = [[UILabel alloc] init];
    NSString *duration = item[@"duration"];
    subtitleLabel.text = ([duration isKindOfClass:[NSString class]] && duration.length) ? duration : @"";
    subtitleLabel.font = [UIFont systemFontOfSize:13];
    subtitleLabel.textColor = OCTextMuted();
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:subtitleLabel];

    UILabel *chevron = [[UILabel alloc] init];
    chevron.text = expanded ? @"\u25be" : @"\u25b8";
    chevron.font = [UIFont systemFontOfSize:13];
    chevron.textColor = OCTextFaint();
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:chevron];

    NSMutableArray *constraints = [NSMutableArray arrayWithArray:@[
        [row.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:4],
        [row.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [row.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [row.heightAnchor constraintEqualToConstant:28],
        [titleLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [titleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [subtitleLabel.centerYAnchor constraintEqualToAnchor:titleLabel.centerYAnchor],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:titleLabel.trailingAnchor constant:8],
        [chevron.centerYAnchor constraintEqualToAnchor:titleLabel.centerYAnchor],
        [chevron.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
    ]];
    if (expanded) {
        UILabel *body = [[UILabel alloc] init];
        body.attributedText = [OCUtil attributedFromMarkdown:item[@"text"] baseFont:[UIFont systemFontOfSize:13]];
        body.textColor = OCTextMuted();
        body.numberOfLines = 0;
        body.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:body];
        [constraints addObjectsFromArray:@[
            [body.topAnchor constraintEqualToAnchor:row.bottomAnchor constant:4],
            [body.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:30],
            [body.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
            [body.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-4],
        ]];
    } else {
        [constraints addObject:[row.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-4]];
    }
    [NSLayoutConstraint activateConstraints:constraints];
}

// Tool call, OpenCode's way: a bare row, no card background. 13px,
 // 28px tall, title in base colour, subtitle/args in muted truncated
 // with an ellipsis, chevron at the end when expandable. A 16px
 // spinner while running; the running title reads in the accent
 // colour. Nested content hangs from a 1px vertical rail 2px in from
 // the row's leading edge, content 14px in. Shell shows a command +
 // result card.
- (void)configureToolCell:(UITableViewCell *)cell item:(NSDictionary *)item {
    NSString *key = item[@"key"];
    BOOL expanded = [self.expandedKeys containsObject:key];
    NSString *tool = item[@"text"];
    NSString *status = item[@"state"];
    BOOL running = [status isEqualToString:@"pending"] || [status isEqualToString:@"running"];

    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:row];

    if (running) {
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        spinner.translatesAutoresizingMaskIntoConstraints = NO;
        [spinner startAnimating];
        [row addSubview:spinner];
        [NSLayoutConstraint activateConstraints:@[
            [spinner.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
            [spinner.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [spinner.widthAnchor constraintEqualToConstant:16],
            [spinner.heightAnchor constraintEqualToConstant:16],
        ]];
    } else {
        UILabel *iconLabel = [[UILabel alloc] init];
        iconLabel.text = [self iconForTool:tool];
        iconLabel.font = [UIFont systemFontOfSize:13];
        iconLabel.textColor = OCTextMuted();
        iconLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:iconLabel];
        [NSLayoutConstraint activateConstraints:@[
            [iconLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
            [iconLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        ]];
    }

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = [self displayTitleForTool:tool];
    titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
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
        [titleLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:24],
        [titleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:titleLabel.trailingAnchor constant:8],
        [subtitleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:chevron.leadingAnchor constant:-8],
        [chevron.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [chevron.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];

    if (expanded) {
        // The 1px nested rail, 2px in from the row's leading edge.
        UIView *rail = [[UIView alloc] init];
        rail.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
        rail.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:rail];
        UIView *detail = [self detailViewForTool:item];
        detail.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:detail];
        [constraints addObjectsFromArray:@[
            [rail.topAnchor constraintEqualToAnchor:row.bottomAnchor constant:2],
            [rail.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:18],
            [rail.widthAnchor constraintEqualToConstant:1],
            [rail.bottomAnchor constraintEqualToAnchor:detail.bottomAnchor],
            [detail.topAnchor constraintEqualToAnchor:row.bottomAnchor constant:4],
            [detail.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:30],
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
    // OpenCode's shell card: 0.5px border, 6px radius. The command
    // sits on the base bg, the output on layer-01 bg, separated by a
    // divider. The output is cut to 4 lines with a fade at the top.
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = OCClaudeBackground();
    card.layer.cornerRadius = 6;
    card.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.10].CGColor;
    card.layer.borderWidth = 0.5;
    card.clipsToBounds = YES;

    UILabel *commandLabel = [[UILabel alloc] init];
    commandLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    commandLabel.textColor = OCTextBase();
    commandLabel.numberOfLines = 0;
    commandLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:commandLabel];

    UIView *outputBox = [[UIView alloc] init];
    outputBox.backgroundColor = OCLayer01();
    outputBox.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:outputBox];

    UILabel *outputLabel = [[UILabel alloc] init];
    outputLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    outputLabel.textColor = OCTextMuted();
    outputLabel.numberOfLines = 4;
    outputLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [outputBox addSubview:outputLabel];

    if (isShell) {
        commandLabel.text = detail.length ? detail : @"(no command)";
        outputLabel.text = output.length ? output : @"";
    } else {
        commandLabel.text = detail.length ? detail : @"";
        outputLabel.text = output.length ? output : @"";
    }
    NSMutableArray *constraints = [NSMutableArray arrayWithArray:@[
        [commandLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [commandLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [commandLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [outputBox.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [outputBox.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [outputLabel.topAnchor constraintEqualToAnchor:outputBox.topAnchor constant:12],
        [outputLabel.leadingAnchor constraintEqualToAnchor:outputBox.leadingAnchor constant:12],
        [outputLabel.trailingAnchor constraintEqualToAnchor:outputBox.trailingAnchor constant:-12],
        [outputLabel.bottomAnchor constraintEqualToAnchor:outputBox.bottomAnchor constant:-12],
    ]];
    if (outputLabel.text.length) {
        [constraints addObjectsFromArray:@[
            [outputBox.topAnchor constraintEqualToAnchor:commandLabel.bottomAnchor constant:12],
            [outputBox.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        ]];
    } else {
        [constraints addObjectsFromArray:@[
            [commandLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],
            [outputBox.heightAnchor constraintEqualToConstant:0],
            [outputBox.topAnchor constraintEqualToAnchor:commandLabel.bottomAnchor],
        ]];
    }
    [NSLayoutConstraint activateConstraints:constraints];
    return card;
}

@end
