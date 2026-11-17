// OCSessionsViewController - list of OpenCode sessions from the in-app engine.
#import "OCSessionsViewController.h"
#import "OCChatViewController.h"
#import "OCServerClient.h"
#import "OCSettings.h"
#import "OCEngine.h"

@interface OCSessionsViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray *sessions;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIRefreshControl *refreshControl;
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

@interface OCSessionsViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray *sessions;
@property (nonatomic, strong) UILabel *greetingLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIRefreshControl *refreshControl;
@end

@implementation OCSessionsViewController

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
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSessions];
}

- (void)showEngine {
    // The engine lives in Integrations (tab 1) now.
    UITabBarController *tabs = self.tabBarController;
    if (tabs.viewControllers.count > 1) tabs.selectedIndex = 1;
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
            self.statusLabel.text = [NSString stringWithFormat:@"Engine: %@  ·  %@", engine.stateDescription, error.localizedDescription];
            return;
        }
        self.sessions = sessions ?: @[];
        [self.tableView reloadData];
        if (!self.sessions.count) self.statusLabel.text = @"No sessions yet. Tap + to start one.";
    }];
}

- (void)newChat {
    [[self client] createSessionWithTitle:nil agent:[OCSettings shared].agent completion:^(NSDictionary *session, NSError *error) {
        if (error || !session) {
            [self showError:error ?: [NSError errorWithDomain:@"OC" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Could not create a session. Is the engine running?"}]];
            return;
        }
        [self openSession:session];
        [self reloadSessions];
    }];
}

- (void)openSession:(NSDictionary *)session {
    OCChatViewController *chat = [[OCChatViewController alloc] initWithSession:session];
    [self.navigationController pushViewController:chat animated:YES];
}

- (void)showError:(NSError *)error {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Error" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
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
    [[self client] deleteSession:sessionID completion:^(NSError *error) { (void)error; [self reloadSessions]; }];
}

@end
