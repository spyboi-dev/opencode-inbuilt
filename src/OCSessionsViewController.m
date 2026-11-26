// OCSessionsViewController - list of OpenCode sessions from the in-app engine.
#import "OCSessionsViewController.h"
#import "OCDesktopViewController.h"
#import "OCEngineViewController.h"
#import "OCServerClient.h"
#import "OCSettings.h"
#import "OCEngine.h"

@interface OCSessionsViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray *sessions;
@property (nonatomic, strong) UILabel *greetingLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIRefreshControl *refreshControl;
@property (nonatomic, strong, nullable) id engineStateToken;
@property (nonatomic, assign) BOOL listLoadFailed;
@end

@implementation OCSessionsViewController

// FreeMilk's greeting cover: a large greeting over the Threads
// list, the way FreeMilk greets you on its home tab. Time-based,
// in the rounded system font.
static NSString *OCGreetingForNow(void) {
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSInteger hour = [cal component:NSCalendarUnitHour fromDate:[NSDate date]];
    if (hour < 12) return @"Good morning";
    if (hour < 17) return @"Good afternoon";
    return @"Good evening";
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Threads";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(newChat)];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Engine" style:UIBarButtonItemStylePlain target:self action:@selector(showEngine)];

    self.greetingLabel = [[UILabel alloc] init];
    self.greetingLabel.text = OCGreetingForNow();
    UIFont *base = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    UIFontDescriptor *rounded = [[base fontDescriptor] fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
    self.greetingLabel.font = [UIFont fontWithDescriptor:rounded size:28] ?: base;
    self.greetingLabel.textColor = [UIColor labelColor];
    self.greetingLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.greetingLabel];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.font = [UIFont systemFontOfSize:13];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.textAlignment = NSTextAlignmentLeft;
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.statusLabel];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.tableView];
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(reloadSessions) forControlEvents:UIControlEventValueChanged];
    [self.tableView addSubview:self.refreshControl];

    [NSLayoutConstraint activateConstraints:@[
        [self.greetingLabel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [self.greetingLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.greetingLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.greetingLabel.bottomAnchor constant:4],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.tableView.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:8],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    // The status line used to freeze at whatever the engine state
    // was when the list last loaded: an auto-start (or a stop from
    // Integrations) while Threads was open left it wrong until the
    // next pull to refresh. Watch the engine like the other tabs.
    __weak typeof(self) weakSelf = self;
    self.engineStateToken = [[OCEngine shared] addStateChangeObserver:^(OCEngineState state) {
        (void)state;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf updateStatusLine]; });
    }];
}

- (void)dealloc {
    [[OCEngine shared] removeStateChangeObserver:self.engineStateToken];
}

// Status line for the current engine state, without clobbering a
// load failure (which explains itself) or the empty-list hint.
- (void)updateStatusLine {
    if (self.listLoadFailed) return;
    if (!self.sessions.count) {
        self.statusLabel.text = @"No sessions yet. Tap + to start one.";
        return;
    }
    self.statusLabel.text = [NSString stringWithFormat:@"Engine: %@", [OCEngine shared].stateDescription];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSessions];
}

- (void)showEngine {
    // The button says Engine, so it opens the Engine screen, not
    // just the Integrations tab (which used to leave the user one
    // more tap away from the screen the button names).
    UITabBarController *tabs = self.tabBarController;
    if (tabs.viewControllers.count > 1) tabs.selectedIndex = 1;
    UINavigationController *nav = tabs.viewControllers[1];
    if ([nav isKindOfClass:[UINavigationController class]]) {
        OCEngineViewController *vc = [[OCEngineViewController alloc] init];
        [nav pushViewController:vc animated:YES];
    }
}

- (OCServerClient *)client {
    OCSettings *s = [OCSettings shared];
    return [[OCServerClient alloc] initWithServerURL:s.serverURL password:[s serverPassword]];
}

- (void)reloadSessions {
    OCEngine *engine = [OCEngine shared];
    self.statusLabel.text = [NSString stringWithFormat:@"Engine: %@", engine.stateDescription];
    [[self client] listSessionsWithCompletion:^(NSArray *sessions, NSError *error) {
        [self.refreshControl endRefreshing];
        if (error) {
            // No modal for this normal state: the reason stays in
            // the status line, and pull to refresh retries. Clear
            // the list too, or it keeps showing chats from the last
            // run that can no longer be opened. Name the underlying
            // error: "Start the engine" lied on c360a14, when the
            // engine was running and the server simply was not
            // listening on 4096.
            self.listLoadFailed = YES;
            self.sessions = @[];
            [self.tableView reloadData];
            self.statusLabel.text = [NSString stringWithFormat:@"Engine: %@  ·  Could not load chats (%@). Pull to retry.", engine.stateDescription, error.localizedDescription ?: @"server not answering"];
            return;
        }
        self.listLoadFailed = NO;
        self.sessions = sessions ?: @[];
        [self.tableView reloadData];
        if (!self.sessions.count) self.statusLabel.text = @"No sessions yet. Tap + to start one.";
    }];
}

- (void)newChat {
    [[self client] createSessionWithTitle:nil agent:[OCSettings shared].agent completion:^(NSDictionary *session, NSError *error) {
        if (error || !session) {
            // No modal for this normal state: the engine is not
            // running. Say so in the status line instead.
            self.statusLabel.text = @"Could not start a chat. Start the engine first.";
            return;
        }
        [self openSession:session];
        [self reloadSessions];
    }];
}

- (void)openSession:(NSDictionary *)session {
    // User decision (2026-11-26): tapping a chat opens the CLI
    // terminal, not the custom native chat window. The TUI joins
    // the same server on 4096, so the session is there; there is
    // no deep-link to open one specific session inside the TUI,
    // so the user picks it inside the terminal itself. The native
    // OCChatViewController stays in the codebase as the fallback,
    // but the Threads tab no longer reaches it.
    (void)session;
    OCDesktopViewController *terminal = [[OCDesktopViewController alloc] init];
    [self.navigationController pushViewController:terminal animated:YES];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.sessions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"SessionCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
    NSDictionary *s = self.sessions[indexPath.row];
    NSString *title = s[@"title"];
    if (![title isKindOfClass:[NSString class]] || !title.length) title = @"New session";
    cell.textLabel.text = title;
    NSDictionary *model = s[@"model"];
    NSString *modelID = [model isKindOfClass:[NSDictionary class]] ? model[@"id"] : nil;
    NSNumber *cost = s[@"cost"];
    NSMutableString *detail = [NSMutableString string];
    if ([modelID isKindOfClass:[NSString class]]) [detail appendString:modelID];
    if ([cost isKindOfClass:[NSNumber class]] && cost.doubleValue > 0) [detail appendFormat:@"  ·  $%.4f", cost.doubleValue];
    cell.detailTextLabel.text = detail;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self openSession:self.sessions[indexPath.row]];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath { return YES; }

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    NSDictionary *s = self.sessions[indexPath.row];
    NSString *sessionID = s[@"id"];
    if (![sessionID isKindOfClass:[NSString class]]) return;
    __weak typeof(self) weakSelf = self;
    [[self client] deleteSession:sessionID completion:^(NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (error) {
            // A swipe delete that fails used to look like it worked
            // (the row vanished, then came back on the next load
            // with no explanation). Keep the row and say so in the
            // status line instead of reloading over the message.
            strongSelf.statusLabel.text = @"Could not delete that chat. Try again.";
            [strongSelf.tableView reloadData];
            return;
        }
        [strongSelf reloadSessions];
    }];
}

@end
