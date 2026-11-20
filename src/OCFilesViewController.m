// OCFilesViewController - browse the guest workspace through /api/fs.
#import "OCFilesViewController.h"
#import "OCServerClient.h"
#import "OCSettings.h"
#import "OCCodeViewController.h"

@interface OCFilesViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray *entries;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) UILabel *pathLabel;
@property (nonatomic, strong) UIView *emptyStateView;
@property (nonatomic, strong) UILabel *emptyTitleLabel;
@property (nonatomic, strong) UILabel *emptyDetailLabel;
@property (nonatomic, strong) UIButton *emptyRetryButton;
@end

@implementation OCFilesViewController

- (instancetype)init {
    if ((self = [super init])) _path = @"/";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // The title stays "Files" whatever folder is open. The current
    // folder shows as a small line at the top of the list instead,
    // so the tab never reads "/" the way it did on device.
    self.title = @"Files";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];

    // Inside the chat the Files screen has no nav bar, so its
    // Refresh button never appears. Pull to refresh is the only
    // way to reload the list there.
    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    [refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    self.tableView.refreshControl = refreshControl;

    UIView *pathHeader = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 30)];
    self.pathLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 6, pathHeader.bounds.size.width - 32, 18)];
    self.pathLabel.font = [UIFont systemFontOfSize:13];
    self.pathLabel.textColor = [UIColor secondaryLabelColor];
    self.pathLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [pathHeader addSubview:self.pathLabel];
    self.tableView.tableHeaderView = pathHeader;

    // Inline empty state: shown in the view itself when the server
    // is down or a folder is empty. Never a modal alert for this
    // normal state, and never a bare black list with no explanation.
    self.emptyStateView = [[UIView alloc] init];
    self.emptyStateView.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyStateView.hidden = YES;
    [self.view addSubview:self.emptyStateView];

    self.emptyTitleLabel = [[UILabel alloc] init];
    self.emptyTitleLabel.font = [UIFont boldSystemFontOfSize:17];
    self.emptyTitleLabel.textColor = [UIColor labelColor];
    self.emptyTitleLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyTitleLabel.numberOfLines = 0;
    self.emptyTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.emptyStateView addSubview:self.emptyTitleLabel];

    self.emptyDetailLabel = [[UILabel alloc] init];
    self.emptyDetailLabel.font = [UIFont systemFontOfSize:14];
    self.emptyDetailLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyDetailLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyDetailLabel.numberOfLines = 0;
    self.emptyDetailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.emptyStateView addSubview:self.emptyDetailLabel];

    self.emptyRetryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.emptyRetryButton setTitle:@"Retry" forState:UIControlStateNormal];
    self.emptyRetryButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    self.emptyRetryButton.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.emptyRetryButton.layer.cornerRadius = 10;
    self.emptyRetryButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.emptyRetryButton addTarget:self action:@selector(reload) forControlEvents:UIControlEventTouchUpInside];
    [self.emptyStateView addSubview:self.emptyRetryButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.emptyStateView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.emptyStateView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:32],
        [self.emptyStateView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-32],
        [self.emptyTitleLabel.topAnchor constraintEqualToAnchor:self.emptyStateView.topAnchor],
        [self.emptyTitleLabel.leadingAnchor constraintEqualToAnchor:self.emptyStateView.leadingAnchor],
        [self.emptyTitleLabel.trailingAnchor constraintEqualToAnchor:self.emptyStateView.trailingAnchor],
        [self.emptyDetailLabel.topAnchor constraintEqualToAnchor:self.emptyTitleLabel.bottomAnchor constant:8],
        [self.emptyDetailLabel.leadingAnchor constraintEqualToAnchor:self.emptyStateView.leadingAnchor],
        [self.emptyDetailLabel.trailingAnchor constraintEqualToAnchor:self.emptyStateView.trailingAnchor],
        [self.emptyRetryButton.topAnchor constraintEqualToAnchor:self.emptyDetailLabel.bottomAnchor constant:16],
        [self.emptyRetryButton.centerXAnchor constraintEqualToAnchor:self.emptyStateView.centerXAnchor],
        [self.emptyRetryButton.widthAnchor constraintEqualToConstant:120],
        [self.emptyRetryButton.heightAnchor constraintEqualToConstant:44],
        [self.emptyRetryButton.bottomAnchor constraintEqualToAnchor:self.emptyStateView.bottomAnchor],
    ]];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reload)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (OCServerClient *)client {
    OCSettings *s = [OCSettings shared];
    return [[OCServerClient alloc] initWithServerURL:s.serverURL password:[s serverPassword]];
}

- (void)showEmptyStateWithTitle:(NSString *)title detail:(NSString *)detail showRetry:(BOOL)showRetry {
    self.emptyTitleLabel.text = title;
    self.emptyDetailLabel.text = detail;
    self.emptyRetryButton.hidden = !showRetry;
    self.emptyStateView.hidden = NO;
}

- (void)reload {
    self.pathLabel.text = self.path;
    __weak typeof(self) weakSelf = self;
    [[self client] listFilesAtPath:self.path completion:^(NSArray *entries, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.tableView.refreshControl endRefreshing];
        if (error) {
            strongSelf.entries = @[];
            [strongSelf.tableView reloadData];
            [strongSelf showEmptyStateWithTitle:@"No files to show"
                                         detail:@"Could not reach the engine server at 127.0.0.1:4096. Start the engine, then try again."
                                      showRetry:YES];
            return;
        }
        strongSelf.entries = entries ?: @[];
        [strongSelf.tableView reloadData];
        if (!strongSelf.entries.count) {
            [strongSelf showEmptyStateWithTitle:@"This folder is empty"
                                         detail:@"There are no files here yet."
                                      showRetry:NO];
        } else {
            strongSelf.emptyStateView.hidden = YES;
        }
    }];
}

// The server returns a full path per entry ("/root/Projects/…").
// Show just the file name in the row, and navigate with the full
// path when it is one, so a folder never gets opened as
// "/root/Projects" + "/root/Projects/…" by appending a path that
// is already absolute.
+ (NSString *)displayNameForEntry:(NSDictionary *)entry {
    NSString *name = entry[@"name"];
    if ([name isKindOfClass:[NSString class]] && name.length) return name;
    NSString *path = entry[@"path"];
    if ([path isKindOfClass:[NSString class]] && path.length) return [path lastPathComponent];
    return @"?";
}

+ (NSString *)fullPathForEntry:(NSDictionary *)entry inFolder:(NSString *)folder {
    NSString *path = entry[@"path"];
    if ([path isKindOfClass:[NSString class]] && [path hasPrefix:@"/"]) return path;
    NSString *name = entry[@"name"];
    if (![name isKindOfClass:[NSString class]] || !name.length) name = [path lastPathComponent] ?: @"";
    if ([folder isEqualToString:@"/"]) return [@"/" stringByAppendingString:name];
    return [folder stringByAppendingPathComponent:name];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.entries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"FileCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellID];
    NSDictionary *entry = self.entries[indexPath.row];
    cell.textLabel.text = [OCFilesViewController displayNameForEntry:entry];
    NSString *type = entry[@"type"];
    cell.accessoryType = [type isEqualToString:@"directory"] ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *entry = self.entries[indexPath.row];
    NSString *child = [OCFilesViewController fullPathForEntry:entry inFolder:self.path];
    NSString *name = [OCFilesViewController displayNameForEntry:entry];
    if ([entry[@"type"] isEqualToString:@"directory"]) {
        OCFilesViewController *vc = [[OCFilesViewController alloc] init];
        vc.path = child;
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [[self client] readFileAtPath:child completion:^(NSString *content, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (error) {
            // A file that cannot be read is not a file to open: say
            // so in the list instead of pushing a view whose
            // "content" would just be the error text. Plain words,
            // not the raw system error.
            [strongSelf showEmptyStateWithTitle:[NSString stringWithFormat:@"Could not open %@", name]
                                         detail:@"The file could not be read. Try again."
                                      showRetry:YES];
            return;
        }
        OCCodeViewController *vc = [[OCCodeViewController alloc] initWithTitle:name content:content ?: @""];
        [strongSelf.navigationController pushViewController:vc animated:YES];
    }];
}

@end
