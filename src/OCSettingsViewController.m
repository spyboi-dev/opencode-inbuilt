// OCSettingsViewController - server URL, model, agent, providers, about.
#import "OCSettingsViewController.h"
#import "OCSettings.h"
#import "OCServerClient.h"
#import "OCEngine.h"
#import "OCLocalhostProxy.h"
#import "KernGlue.h"

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
    // Inset grouped: the Integrations page's exact style (same table
    // style, same subtitle cells, same section headers). The 1bf4c3a
    // card restyle (glyph tiles + header card) is not what the user
    // wants — Settings must match Integrations, plain.
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];
    // The server field is built once and reused. It used to be
    // recreated in every cellForRow, so a providers fetch landing
    // while the user was typing replaced the field mid-edit, lost
    // the typed text and dismissed the keyboard.
    self.serverField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 220, 30)];
    self.serverField.font = [UIFont systemFontOfSize:14];
    self.serverField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.serverField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.serverField.delegate = self;
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

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 5; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 3;
    if (section == 1) return 2;
    if (section == 2) return MAX(1, (NSInteger)self.providers.count);
    if (section == 3) return 2;
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"Engine server";
    if (section == 1) return @"Agent";
    if (section == 2) return @"Providers (from the engine)";
    if (section == 3) return @"About";
    return @"Guest data";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"SettingsCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.detailTextLabel.numberOfLines = 0;
    // Cells are reused across rows: clear the accessory, or the
    // Server URL field (or a disclosure chevron) can show up on a
    // row it does not belong to. The reset row is red, so the text
    // colour is reset here too.
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    cell.textLabel.textColor = [UIColor labelColor];
    cell.textLabel.text = nil;
    cell.detailTextLabel.text = nil;
    OCSettings *s = [OCSettings shared];
    if (indexPath.section == 0 && indexPath.row == 0) {
        cell.textLabel.text = @"Server URL";
        // Do not reset the field while the user is typing in it.
        if (!self.serverField.isFirstResponder) self.serverField.text = s.serverURL;
        cell.accessoryView = self.serverField;
    } else if (indexPath.section == 0 && indexPath.row == 1) {
        cell.textLabel.text = @"Server password";
        cell.detailTextLabel.text = s.hasServerPassword ? @"Stored in Keychain" : @"Not set yet (generated on first engine start)";
    } else if (indexPath.section == 0 && indexPath.row == 2) {
        // Localhost ports: guest services on these ports answer at
        // the phone's 127.0.0.1 (the localhost proxy). 4096 and
        // 8000 are already bridged and never listed here.
        cell.textLabel.text = @"Localhost ports";
        NSArray<NSNumber *> *ports = [OCLocalhostProxy configuredPorts];
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (NSNumber *port in ports) [parts addObject:[port stringValue]];
        cell.detailTextLabel.text = parts.count ? [parts componentsJoinedByString:@", "] : @"None";
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
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
            // Only join the parts that exist: a missing id or
            // activation used to leave a dangling " · ".
            NSMutableArray *parts = [NSMutableArray array];
            if ([p[@"id"] isKindOfClass:[NSString class]] && ((NSString *)p[@"id"]).length) [parts addObject:p[@"id"]];
            if ([p[@"activation"] isKindOfClass:[NSString class]] && ((NSString *)p[@"activation"]).length) [parts addObject:p[@"activation"]];
            cell.detailTextLabel.text = [parts componentsJoinedByString:@" · "];
        } else {
            cell.textLabel.text = @"No providers yet";
            cell.detailTextLabel.text = @"Start the engine, then sign in to a provider.";
        }
    } else if (indexPath.section == 3 && indexPath.row == 0) {
        cell.textLabel.text = @"OpenCode";
        cell.detailTextLabel.text = @"OpenCode 2.3.0";
    } else if (indexPath.section == 3 && indexPath.row == 1) {
        cell.textLabel.text = @"Files";
        cell.detailTextLabel.text = @"Agent files live in ~/Projects. Nothing leaves the phone except calls to your AI provider.";
    } else if (indexPath.section == 4 && indexPath.row == 0) {
        // Reset guest data: deletes the overlay file only (sessions,
        // logins, ~/Projects). The guest image and settings are kept.
        // A corrupt overlay breaks every boot, so this is the
        // recovery path. Red text, like a destructive action.
        cell.textLabel.text = @"Reset guest data";
        cell.textLabel.textColor = [UIColor systemRedColor];
        cell.detailTextLabel.text = @"Deletes sessions, logins and ~/Projects. The guest image and settings are kept.";
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    // Tapping a row while editing the server URL used to leave the
    // keyboard up over the sheet that opens.
    [self.serverField resignFirstResponder];
    if (indexPath.section == 0 && indexPath.row == 2) {
        // Edit the localhost ports as a comma-separated list. 4096
        // and 8000 are already bridged and are dropped on save.
        NSArray<NSNumber *> *current = [OCLocalhostProxy configuredPorts];
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (NSNumber *port in current) [parts addObject:[port stringValue]];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Localhost ports" message:@"Comma-separated ports. 4096 and 8000 are already bridged." preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull field) {
            field.text = [parts componentsJoinedByString:@", "];
            field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
            field.autocapitalizationType = UITextAutocapitalizationTypeNone;
            field.autocorrectionType = UITextAutocorrectionTypeNo;
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull a) {
            (void)a;
            NSString *text = alert.textFields.firstObject.text ?: @"";
            NSMutableArray<NSNumber *> *ports = [NSMutableArray array];
            for (NSString *piece in [text componentsSeparatedByString:@","]) {
                NSString *trimmed = [piece stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                long port = (long)[trimmed integerValue];
                if (trimmed.length && port >= 1 && port <= 65535) [ports addObject:@(port)];
            }
            // An empty list means no change: saving nothing would
            // make the next read fall back to the defaults.
            if (!ports.count) return;
            [OCLocalhostProxy setConfiguredPorts:ports];
            [[OCKernGlue shared] restartLocalhostProxy];
            [self.tableView reloadData];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    } else if (indexPath.section == 1 && indexPath.row == 0) {
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
    } else if (indexPath.section == 4 && indexPath.row == 0) {
        // Reset guest data: confirmation first, then stop the
        // engine (the overlay cannot be deleted while the guest
        // runs on it) and delete the overlay file only.
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset guest data" message:@"Deletes the guest's saved files — sessions, logins, and ~/Projects. The guest image and your settings are kept. The engine stops, and you will need to relaunch the app to start again." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull a) {
            (void)a;
            [self resetGuestData];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)resetGuestData {
    OCEngine *engine = [OCEngine shared];
    if (engine.state == OCEngineStateRunning || engine.state == OCEngineStateStarting) {
        [engine stopEngine];
    }
    NSString *error = nil;
    BOOL ok = [[OCKernGlue shared] resetGuestDataWithError:&error];
    UIAlertController *done = [UIAlertController alertControllerWithTitle:ok ? @"Guest data deleted" : @"Reset failed" message:ok ? @"The guest starts with a fresh disk next time. Relaunch the app to start it." : (error ?: @"Could not delete the guest data.") preferredStyle:UIAlertControllerStyleAlert];
    [done addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:done animated:YES completion:nil];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self saveServerURL];
    [textField resignFirstResponder];
    return YES;
}

@end
