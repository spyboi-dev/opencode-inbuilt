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
    // Cells are reused across rows: reset the colour, or a provider
    // or Settings row can inherit the blue/red/grey of the Start /
    // Stop engine row it was recycled from.
    cell.textLabel.textColor = [UIColor labelColor];
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
            engine.userStoppedEngineThisSession = YES;
            [engine stopEngine];
        } else {
            engine.userStoppedEngineThisSession = NO;
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
