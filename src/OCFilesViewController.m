// OCFilesViewController - browse the guest workspace through /api/fs.
#import "OCFilesViewController.h"
#import "OCServerClient.h"
#import "OCSettings.h"

@interface OCFilesViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray *entries;
@property (nonatomic, copy) NSString *path;
@end

@implementation OCFilesViewController

- (instancetype)init {
    if ((self = [super init])) _path = @"/";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Files";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];
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

- (void)reload {
    self.title = self.path;
    [[self client] listFilesAtPath:self.path completion:^(NSArray *entries, NSError *error) {
        if (error) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Files unavailable" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
            return;
        }
        self.entries = entries ?: @[];
        [self.tableView reloadData];
    }];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.entries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"FileCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellID];
    NSDictionary *entry = self.entries[indexPath.row];
    cell.textLabel.text = entry[@"path"] ?: entry[@"name"] ?: @"?";
    NSString *type = entry[@"type"];
    cell.accessoryType = [type isEqualToString:@"directory"] ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *entry = self.entries[indexPath.row];
    NSString *name = entry[@"path"];
    if (![name isKindOfClass:[NSString class]]) return;
    NSString *child = [self.path isEqualToString:@"/"] ? [@"/" stringByAppendingString:name] : [self.path stringByAppendingPathComponent:name];
    if ([entry[@"type"] isEqualToString:@"directory"]) {
        OCFilesViewController *vc = [[OCFilesViewController alloc] init];
        vc.path = child;
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }
    [[self client] readFileAtPath:child completion:^(NSString *content, NSError *error) {
        UIViewController *vc = [[UIViewController alloc] init];
        vc.title = name;
        UITextView *tv = [[UITextView alloc] initWithFrame:vc.view.bounds];
        tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        tv.editable = NO;
        tv.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
        tv.text = content ?: (error ? error.localizedDescription : @"Empty file.");
        [vc.view addSubview:tv];
        [self.navigationController pushViewController:vc animated:YES];
    }];
}

@end
