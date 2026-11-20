// OCIntegrationsViewController - FreeMilk's Integrations tab: the
// services the agent can use. Engine status with Start/Stop, the LLM
// providers the server reports, and a row into Settings. This is
// where the old Engine and Settings tabs now live.
#import "OCIntegrationsViewController.h"
#import "OCEngine.h"
#import "OCServerClient.h"
#import "OCSettings.h"
#import "OCEngineViewController.h"
#import "OCSettingsViewController.h"

@interface OCIntegrationsViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray *providers;
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
    [OCEngine shared].stateDidChange = ^(OCEngineState state) {
        (void)state;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf.tableView reloadData]; });
    };
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
    OCSettings *s = [OCSettings shared];
    OCServerClient *client = [[OCServerClient alloc] initWithServerURL:s.serverURL password:[s serverPassword]];
    [client listProvidersWithCompletion:^(NSArray *providers, NSError *error) {
        if (!error) {
            self.providers = providers ?: @[];
            [self.tableView reloadData];
        }
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
    if (section == 0) return 2;
    if (section == 1) return MAX(1, (NSInteger)self.providers.count);
    return 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"IntegrationCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.detailTextLabel.text = nil;
    if (indexPath.section == 0) {
        OCEngine *engine = [OCEngine shared];
        if (indexPath.row == 0) {
            cell.textLabel.text = @"OpenCode engine";
            cell.detailTextLabel.text = engine.stateDescription ?: @"";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            BOOL running = engine.state == OCEngineStateRunning || engine.state == OCEngineStateStarting;
            if (!engine.guestCoreLinked) {
                // The engine cannot start in this build: the row
                // looks unavailable and says why, instead of
                // looking tappable and doing nothing on tap.
                cell.textLabel.text = @"Start engine";
                cell.textLabel.textColor = [UIColor secondaryLabelColor];
                cell.detailTextLabel.text = @"Not ready yet";
            } else {
                cell.textLabel.text = running ? @"Stop engine" : @"Start engine";
                cell.textLabel.textColor = running ? [UIColor systemRedColor] : [UIColor systemBlueColor];
            }
        }
        return cell;
    }
    if (indexPath.section == 1) {
        if (!self.providers.count) {
            cell.textLabel.text = @"No providers reported";
            cell.detailTextLabel.text = @"Start the engine to list providers";
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
        if (indexPath.row == 0) {
            OCEngineViewController *vc = [[OCEngineViewController alloc] init];
            [self.navigationController pushViewController:vc animated:YES];
            return;
        }
        OCEngine *engine = [OCEngine shared];
        if (!engine.guestCoreLinked) {
            // Nothing to do: the row already says "Not ready yet".
            // No alert for this normal state.
            return;
        }
        if (engine.state == OCEngineStateRunning || engine.state == OCEngineStateStarting) {
            [engine stopEngine];
        } else {
            [engine startEngineWithCompletion:^(BOOL started, NSError * _Nullable error) {
                (void)started; (void)error;
                dispatch_async(dispatch_get_main_queue(), ^{ [self.tableView reloadData]; });
            }];
        }
        [self.tableView reloadData];
        return;
    }
    if (indexPath.section == 2) {
        OCSettingsViewController *vc = [[OCSettingsViewController alloc] init];
        [self.navigationController pushViewController:vc animated:YES];
    }
}

@end
