// OCIntegrationsViewController - FreeMilk's Integrations tab: the
// services the agent can use. Engine status, the LLM providers
// the server reports, and a row into Settings. This is where the
// old Engine and Settings tabs now live. No start/stop here any
// more (2026-11-22): the engine is fully automatic, and the
// Engine row only opens the Engine screen (state + logs).
#import "OCIntegrationsViewController.h"
#import "OCEngine.h"
#import "OCServerClient.h"
#import "OCSettings.h"
#import "OCEngineViewController.h"
#import "OCSettingsViewController.h"

@interface OCIntegrationsViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray *providers;
@property (nonatomic, strong, nullable) id engineStateToken;
@end

@implementation OCIntegrationsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Integrations";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];
    __weak typeof(self) weakSelf = self;
    // Multicast observer: the Engine screen observes the same
    // engine. Assigning the single stateDidChange callback here
    // used to steal it from the Engine screen (or the other way
    // round), so this row could go stale while Engine was open.
    self.engineStateToken = [[OCEngine shared] addStateChangeObserver:^(OCEngineState state) {
        (void)state;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf.tableView reloadData]; });
    }];
}

- (void)dealloc {
    [[OCEngine shared] removeStateChangeObserver:self.engineStateToken];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
    OCSettings *s = [OCSettings shared];
    OCServerClient *client = [[OCServerClient alloc] initWithServerURL:s.serverURL password:[s serverPassword]];
    [client listProvidersWithCompletion:^(NSArray *providers, NSError *error) {
        if (error) {
            // The engine is down: clear the list instead of showing
            // providers from the last run that no longer exist.
            self.providers = @[];
            [self.tableView reloadData];
            return;
        }
        self.providers = providers ?: @[];
        [self.tableView reloadData];
    }];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"Engine";
    if (section == 1) return @"Providers";
    return @"App";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    if (section == 1) return MAX(1, (NSInteger)self.providers.count);
    return 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"IntegrationCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.detailTextLabel.text = nil;
    // Cells are reused across rows: reset the colour, or a provider
    // or Settings row can inherit the colour of another row it was
    // recycled from.
    cell.textLabel.textColor = [UIColor labelColor];
    if (indexPath.section == 0) {
        OCEngine *engine = [OCEngine shared];
        cell.textLabel.text = @"OpenCode engine";
        cell.detailTextLabel.text = engine.stateDescription ?: @"";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    if (indexPath.section == 1) {
        if (!self.providers.count) {
            cell.textLabel.text = @"No providers reported";
            cell.detailTextLabel.text = @"Providers appear once the engine is running";
            return cell;
        }
        NSDictionary *p = self.providers[indexPath.row];
        cell.textLabel.text = p[@"name"] ?: p[@"id"] ?: @"Provider";
        NSString *pid = p[@"id"];
        cell.detailTextLabel.text = [pid isKindOfClass:[NSString class]] ? pid : nil;
        return cell;
    }
    cell.textLabel.text = @"Settings";
    cell.detailTextLabel.text = @"Server, model, providers";
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        OCEngineViewController *vc = [[OCEngineViewController alloc] init];
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }
    if (indexPath.section == 2) {
        OCSettingsViewController *vc = [[OCSettingsViewController alloc] init];
        [self.navigationController pushViewController:vc animated:YES];
    }
}

@end
