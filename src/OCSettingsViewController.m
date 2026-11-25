// OCSettingsViewController - server URL, model, agent, providers, about.
#import "OCSettingsViewController.h"
#import "OCSettings.h"
#import "OCServerClient.h"
#import "OCEngine.h"

// A row in a settings card: small rounded-square glyph tile on the
// left, title with a grey subtitle underneath, chevron on the right
// where the row opens something. A UIControl so tappable rows get
// the pressed highlight for free.
@interface OCSettingsRow : UIControl
@property (nonatomic, assign) NSInteger actionTag; // 0 agent mode, 1 model, -1 not tappable
@end

@implementation OCSettingsRow
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.backgroundColor = (highlighted && self.actionTag >= 0) ? [[UIColor whiteColor] colorWithAlphaComponent:0.06] : [UIColor clearColor];
}
@end

// Card fill #2e2e2e on the black base, text #f2f2f2, muted #aeaeae,
// glyph tiles grey, chevrons faint grey — the iOS Settings card
// family, same as the Integrations page.
static UIColor *OCSettingsCardColor(void) {
    return [UIColor colorWithRed:0x2e/255.0 green:0x2e/255.0 blue:0x2e/255.0 alpha:1.0];
}
static UIColor *OCSettingsTextColor(void) {
    return [UIColor colorWithRed:0xf2/255.0 green:0xf2/255.0 blue:0xf2/255.0 alpha:1.0];
}
static UIColor *OCSettingsMutedColor(void) {
    return [UIColor colorWithRed:0xae/255.0 green:0xae/255.0 blue:0xae/255.0 alpha:1.0];
}
static UIColor *OCSettingsTileColor(void) {
    return [UIColor colorWithRed:0x8e/255.0 green:0x8e/255.0 blue:0x93/255.0 alpha:1.0];
}

@interface OCSettingsViewController () <UITextFieldDelegate>
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *stackView;
@property (nonatomic, strong) UITextField *serverField;
@property (nonatomic, strong) NSArray *providers;
@property (nonatomic, copy, nullable) NSString *modelNote; // shown in the Model row when the server cannot be reached
@end

@implementation OCSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Settings";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.scrollView];
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    self.stackView = [[UIStackView alloc] init];
    self.stackView.axis = UILayoutConstraintAxisVertical;
    self.stackView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:self.stackView];
    [NSLayoutConstraint activateConstraints:@[
        [self.stackView.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor constant:16],
        [self.stackView.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor constant:-16],
        [self.stackView.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor constant:16],
        [self.stackView.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor],
        [self.stackView.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor constant:-32],
    ]];

    // The server field is built once and reused across rebuilds, so
    // a providers fetch landing while the user is typing does not
    // replace the field mid-edit. Its width and height are set here
    // so they survive being moved between rows; the row only pins
    // its position.
    self.serverField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 220, 30)];
    self.serverField.font = [UIFont systemFontOfSize:14];
    self.serverField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.serverField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.serverField.delegate = self;
    self.serverField.translatesAutoresizingMaskIntoConstraints = NO;
    [self.serverField.widthAnchor constraintEqualToConstant:220].active = YES;
    [self.serverField.heightAnchor constraintEqualToConstant:30].active = YES;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self rebuild];
    OCSettings *s = [OCSettings shared];
    OCServerClient *client = [[OCServerClient alloc] initWithServerURL:s.serverURL password:[s serverPassword]];
    [client listProvidersWithCompletion:^(NSArray *providers, NSError *error) {
        if (!error) { self.providers = providers ?: @[]; [self rebuild]; }
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

#pragma mark - Cards

- (void)rebuild {
    for (UIView *v in self.stackView.arrangedSubviews) {
        [self.stackView removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    OCSettings *s = [OCSettings shared];

    UIView *headerCard = [self headerCard];
    [self.stackView addArrangedSubview:headerCard];
    [self.stackView setCustomSpacing:24 afterView:headerCard];

    [self addSection:@"Engine server" rows:@[
        [self serverURLRow],
        [self rowWithIcon:@"key.fill" title:@"Server password" subtitle:(s.hasServerPassword ? @"Stored in Keychain" : @"Not set yet (generated on first engine start)") chevron:NO actionTag:-1 accessory:nil],
    ]];
    [self addSection:@"Agent" rows:@[
        [self rowWithIcon:@"cpu" title:@"Agent mode" subtitle:([s.agent isEqualToString:@"plan"] ? @"Plan" : @"Build") chevron:YES actionTag:0 accessory:nil],
        [self rowWithIcon:@"sparkles" title:@"Model" subtitle:(self.modelNote ?: (s.model.length ? s.model : @"Server default")) chevron:YES actionTag:1 accessory:nil],
    ]];

    NSMutableArray *providerRows = [NSMutableArray array];
    if (self.providers.count) {
        for (NSDictionary *p in self.providers) {
            // Only join the parts that exist: a missing id or
            // activation used to leave a dangling " · ".
            NSMutableArray *parts = [NSMutableArray array];
            if ([p[@"id"] isKindOfClass:[NSString class]] && ((NSString *)p[@"id"]).length) [parts addObject:p[@"id"]];
            if ([p[@"activation"] isKindOfClass:[NSString class]] && ((NSString *)p[@"activation"]).length) [parts addObject:p[@"activation"]];
            [providerRows addObject:[self rowWithIcon:@"plug" title:(p[@"name"] ?: p[@"id"]) subtitle:[parts componentsJoinedByString:@" · "] chevron:NO actionTag:-1 accessory:nil]];
        }
    } else {
        [providerRows addObject:[self rowWithIcon:@"plug" title:@"No providers yet" subtitle:@"Start the engine, then sign in to a provider." chevron:NO actionTag:-1 accessory:nil]];
    }
    [self addSection:@"Providers (from the engine)" rows:providerRows];

    [self addSection:@"About" rows:@[
        [self rowWithIcon:@"info.circle" title:@"OpenCode" subtitle:@"OpenCode 2.3.0" chevron:NO actionTag:-1 accessory:nil],
        [self rowWithIcon:@"folder" title:@"Files" subtitle:@"Agent files live in ~/Projects. Nothing leaves the phone except calls to your AI provider." chevron:NO actionTag:-1 accessory:nil],
    ]];

    // Bottom space so the last card clears the floating tab bar.
    UIView *spacer = [[UIView alloc] init];
    spacer.translatesAutoresizingMaskIntoConstraints = NO;
    [spacer.heightAnchor constraintEqualToConstant:100].active = YES;
    [self.stackView addArrangedSubview:spacer];
}

- (void)addSection:(NSString *)title rows:(NSArray<UIView *> *)rows {
    UILabel *header = [[UILabel alloc] init];
    header.text = title;
    header.font = [UIFont systemFontOfSize:13];
    header.textColor = OCSettingsMutedColor();
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [self.stackView addArrangedSubview:header];
    UIView *card = [self cardWithRows:rows];
    [self.stackView addArrangedSubview:card];
    [self.stackView setCustomSpacing:8 afterView:header];
    [self.stackView setCustomSpacing:24 afterView:card];
}

- (UIView *)cardWithRows:(NSArray<UIView *> *)rows {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = OCSettingsCardColor();
    card.layer.cornerRadius = 28;
    card.clipsToBounds = YES;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];
    for (NSUInteger i = 0; i < rows.count; i++) {
        UIView *rowView = rows[i];
        if (i > 0) {
            // Thin divider between rows in a card, starting after
            // the glyph tile, like iOS Settings.
            UIView *divider = [[UIView alloc] init];
            divider.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
            divider.translatesAutoresizingMaskIntoConstraints = NO;
            [rowView addSubview:divider];
            [NSLayoutConstraint activateConstraints:@[
                [divider.leadingAnchor constraintEqualToAnchor:rowView.leadingAnchor constant:58],
                [divider.trailingAnchor constraintEqualToAnchor:rowView.trailingAnchor constant:-16],
                [divider.topAnchor constraintEqualToAnchor:rowView.topAnchor],
                [divider.heightAnchor constraintEqualToConstant:(1.0 / [UIScreen mainScreen].scale)],
            ]];
        }
        [stack addArrangedSubview:rowView];
    }
    return card;
}

- (UIView *)headerCard {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = OCSettingsCardColor();
    card.layer.cornerRadius = 28;
    card.clipsToBounds = YES;
    card.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.backgroundColor = OCSettingsTileColor();
    iconView.layer.cornerRadius = 16;
    iconView.clipsToBounds = YES;
    iconView.contentMode = UIViewContentModeCenter;
    UIImage *gear = [[UIImage systemImageNamed:@"gear"] imageWithConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:30 weight:UIImageSymbolWeightRegular]];
    iconView.image = [gear imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    iconView.tintColor = [UIColor whiteColor];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:iconView];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"Settings";
    titleLabel.font = [UIFont boldSystemFontOfSize:32];
    titleLabel.textColor = OCSettingsTextColor();
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:titleLabel];

    UILabel *descLabel = [[UILabel alloc] init];
    descLabel.text = @"Server connection, agent, providers and app info.";
    descLabel.font = [UIFont systemFontOfSize:15];
    descLabel.textColor = OCSettingsMutedColor();
    descLabel.numberOfLines = 0;
    descLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:descLabel];

    [NSLayoutConstraint activateConstraints:@[
        [iconView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [iconView.topAnchor constraintEqualToAnchor:card.topAnchor constant:20],
        [iconView.widthAnchor constraintEqualToConstant:64],
        [iconView.heightAnchor constraintEqualToConstant:64],
        [titleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [titleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [titleLabel.topAnchor constraintEqualToAnchor:iconView.bottomAnchor constant:16],
        [descLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [descLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [descLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:6],
        [descLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-20],
    ]];
    return card;
}

- (OCSettingsRow *)serverURLRow {
    OCSettings *s = [OCSettings shared];
    // Do not reset the field while the user is typing in it.
    if (!self.serverField.isFirstResponder) self.serverField.text = s.serverURL;
    return [self rowWithIcon:@"server.rack" title:@"Server URL" subtitle:nil chevron:NO actionTag:-1 accessory:self.serverField];
}

- (OCSettingsRow *)rowWithIcon:(NSString *)symbol title:(NSString *)title subtitle:(NSString *)subtitle chevron:(BOOL)chevron actionTag:(NSInteger)actionTag accessory:(UIView *)accessory {
    OCSettingsRow *row = [[OCSettingsRow alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.actionTag = actionTag;
    if (actionTag >= 0) {
        [row addTarget:self action:@selector(rowTapped:) forControlEvents:UIControlEventTouchUpInside];
    }

    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.backgroundColor = OCSettingsTileColor();
    iconView.layer.cornerRadius = 8;
    iconView.clipsToBounds = YES;
    iconView.contentMode = UIViewContentModeCenter;
    UIImage *symbolImage = [[UIImage systemImageNamed:symbol] imageWithConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold]];
    iconView.image = [symbolImage imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    iconView.tintColor = [UIColor whiteColor];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:iconView];
    [NSLayoutConstraint activateConstraints:@[
        [iconView.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [iconView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:30],
        [iconView.heightAnchor constraintEqualToConstant:30],
    ]];

    UIStackView *textStack = [[UIStackView alloc] init];
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 2;
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:17];
    titleLabel.textColor = OCSettingsTextColor();
    [textStack addArrangedSubview:titleLabel];
    if (subtitle.length) {
        UILabel *subtitleLabel = [[UILabel alloc] init];
        subtitleLabel.text = subtitle;
        subtitleLabel.font = [UIFont systemFontOfSize:14];
        subtitleLabel.textColor = OCSettingsMutedColor();
        subtitleLabel.numberOfLines = 0;
        [textStack addArrangedSubview:subtitleLabel];
    }
    [row addSubview:textStack];

    UIView *rightView = nil;
    if (accessory) {
        rightView = accessory;
        [row addSubview:accessory];
    } else if (chevron) {
        UIImageView *chev = [[UIImageView alloc] init];
        UIImage *chevImage = [[UIImage systemImageNamed:@"chevron.right"] imageWithConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold]];
        chev.image = [chevImage imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        chev.tintColor = [UIColor colorWithRed:0x80/255.0 green:0x80/255.0 blue:0x80/255.0 alpha:1.0];
        chev.contentMode = UIViewContentModeCenter;
        chev.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:chev];
        rightView = chev;
    }
    if (rightView) {
        [NSLayoutConstraint activateConstraints:@[
            [rightView.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
            [rightView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        ]];
        [textStack.trailingAnchor constraintEqualToAnchor:rightView.leadingAnchor constant:-8].active = YES;
    } else {
        [textStack.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16].active = YES;
    }
    [NSLayoutConstraint activateConstraints:@[
        [textStack.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:12],
        [textStack.topAnchor constraintGreaterThanOrEqualToAnchor:row.topAnchor constant:10],
        [textStack.bottomAnchor constraintLessThanOrEqualToAnchor:row.bottomAnchor constant:-10],
        [textStack.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [row.heightAnchor constraintGreaterThanOrEqualToConstant:56],
    ]];
    return row;
}

#pragma mark - Row actions

- (void)rowTapped:(OCSettingsRow *)row {
    // Tapping a row while editing the server URL used to leave the
    // keyboard up over the sheet that opens.
    [self.serverField resignFirstResponder];
    if (row.actionTag == 0) {
        OCSettings *s = [OCSettings shared];
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Agent mode" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Build" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull a) { (void)a; s.agent = @"build"; [s save]; [self rebuild]; }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Plan" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull a) { (void)a; s.agent = @"plan"; [s save]; [self rebuild]; }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:sheet animated:YES completion:nil];
    } else if (row.actionTag == 1) {
        OCSettings *s = [OCSettings shared];
        OCServerClient *client = [[OCServerClient alloc] initWithServerURL:s.serverURL password:[s serverPassword]];
        [client listModelsWithCompletion:^(NSArray *models, NSError *error) {
            if (error || !models.count) {
                self.modelNote = @"Could not reach the server. Start the engine first.";
                [self rebuild];
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
                    s.model = modelID; s.modelProviderID = providerID ?: @""; [s save]; [self rebuild];
                }]];
            }
            [sheet addAction:[UIAlertAction actionWithTitle:@"Server default" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull a) {
                (void)a;
                s.model = @""; s.modelProviderID = @""; [s save]; [self rebuild];
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
