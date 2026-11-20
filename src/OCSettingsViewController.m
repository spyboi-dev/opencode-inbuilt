// OCSettingsViewController - server URL, model, agent, providers, about.
#import "OCSettingsViewController.h"
#import "OCSettings.h"
#import "OCServerClient.h"
#import "OCEngine.h"

@interface OCSettingsViewController () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UITextField *serverField;
@property (nonatomic, strong) NSArray *providers;
@property (nonatomic, copy, nullable) NSString *modelNote; // shown in the Model row when the server cannot be reached
@end

@implementation OCSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Settings";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
    OCSettings *s = [OCSettings shared];
    OCServerClient *client = [[OCServerClient alloc] initWithServerURL:s.serverURL password:[s serverPassword]];
    [client listProvidersWithCompletion:^(NSArray *providers, NSError *error) {
        if (!error) { self.providers = providers ?: @[]; [self.tableView reloadData]; }
    }];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self saveServerURL];
}

- (void)saveServerURL {
    OCSettings *s = [OCSettings shared];
    NSString *url = [self.serverField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (url.length) { s.serverURL = url; [s save]; }
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 2;
    if (section == 1) return 2;
    if (section == 2) return MAX(1, (NSInteger)self.providers.count);
    return 3;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"Engine server";
    if (section == 1) return @"Agent";
    if (section == 2) return @"Providers (from the engine)";
    return @"About";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"SettingsCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.detailTextLabel.numberOfLines = 0;
    OCSettings *s = [OCSettings shared];
    if (indexPath.section == 0 && indexPath.row == 0) {
        cell.textLabel.text = @"Server URL";
        self.serverField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 220, 30)];
        self.serverField.text = s.serverURL;
        self.serverField.font = [UIFont systemFontOfSize:14];
        self.serverField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.serverField.autocorrectionType = UITextAutocorrectionTypeNo;
        self.serverField.delegate = self;
        cell.accessoryView = self.serverField;
    } else if (indexPath.section == 0 && indexPath.row == 1) {
        cell.textLabel.text = @"Server password";
        cell.detailTextLabel.text = s.hasServerPassword ? @"Stored in Keychain" : @"Not set yet (generated on first engine start)";
    } else if (indexPath.section == 1 && indexPath.row == 0) {
        cell.textLabel.text = @"Agent mode";
        cell.detailTextLabel.text = [s.agent isEqualToString:@"plan"] ? @"Plan" : @"Build";
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == 1 && indexPath.row == 1) {
        cell.textLabel.text = @"Model";
        // When the server is down the picker cannot open; the row
        // says so inline instead of doing nothing on tap.
        cell.detailTextLabel.text = self.modelNote ?: (s.model.length ? s.model : @"Server default");
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == 2) {
        if (self.providers.count) {
            NSDictionary *p = self.providers[indexPath.row];
            cell.textLabel.text = p[@"name"] ?: p[@"id"];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", p[@"id"] ?: @"", p[@"activation"] ?: @""];
        } else {
            cell.textLabel.text = @"No providers yet";
            cell.detailTextLabel.text = @"Start the engine, then sign in to a provider inside the guest.";
        }
    } else if (indexPath.section == 3 && indexPath.row == 0) {
        cell.textLabel.text = @"OpenCode engine";
        cell.detailTextLabel.text = @"Real OpenCode 2.3.0, inside this app (LinuxRunner interpreter, Debian 13, JITless).";
    } else if (indexPath.section == 3 && indexPath.row == 1) {
        cell.textLabel.text = @"Files";
        cell.detailTextLabel.text = @"Agent files live in the guest workspace (~/Projects). Nothing leaves the phone except calls to your AI provider.";
    } else {
        cell.textLabel.text = @"Limits";
        cell.detailTextLabel.text = @"If the app is closed, the engine stops. Your files stay saved, and the engine restarts next time.";
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1 && indexPath.row == 0) {
        OCSettings *s = [OCSettings shared];
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Agent mode" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Build" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull a) { (void)a; s.agent = @"build"; [s save]; [self.tableView reloadData]; }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Plan" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull a) { (void)a; s.agent = @"plan"; [s save]; [self.tableView reloadData]; }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:sheet animated:YES completion:nil];
    } else if (indexPath.section == 1 && indexPath.row == 1) {
        OCSettings *s = [OCSettings shared];
        OCServerClient *client = [[OCServerClient alloc] initWithServerURL:s.serverURL password:[s serverPassword]];
        [client listModelsWithCompletion:^(NSArray *models, NSError *error) {
            if (error || !models.count) {
                self.modelNote = @"Could not reach the server. Start the engine first.";
                [self.tableView reloadData];
                return;
            }
            self.modelNote = nil;
            UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Model" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
            for (NSDictionary *model in models) {
                NSString *modelID = model[@"modelID"] ?: model[@"id"];
                NSString *providerID = model[@"providerID"];
                NSString *name = model[@"name"] ?: modelID;
                if (![modelID isKindOfClass:[NSString class]]) continue;
                [sheet addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull a) {
                    (void)a;
                    s.model = modelID; s.modelProviderID = providerID ?: @""; [s save]; [self.tableView reloadData];
                }]];
            }
            [sheet addAction:[UIAlertAction actionWithTitle:@"Server default" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull a) {
                (void)a;
                s.model = @""; s.modelProviderID = @""; [s save]; [self.tableView reloadData];
            }]];
            [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:sheet animated:YES completion:nil];
        }];
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self saveServerURL];
    [textField resignFirstResponder];
    return YES;
}

@end
