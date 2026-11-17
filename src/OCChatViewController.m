// OCChatViewController - chat thread for one OpenCode session.
// Follows OpenCode's own session-ui display model (packages/session-ui):
// user messages are right-aligned bubbles (layer-02, 10px radius, max
// 82% wide, folding past 12 lines); assistant text flows as plain
// markdown with a faint copy + meta footer; reasoning is a collapsible
// "Thinking"/"Thought" card; every tool is a 28px trigger row (icon,
// title, subtitle, chevron) whose detail opens below it, and Shell
// shows a command + result card. A new session is an empty timeline
// with the composer at the bottom; there is no greeting hero.
// Colours are OpenCode's dark tokens: base #161616, layer-01 #242424,
// layer-02 #2e2e2e, text #f2f2f2, muted #aeaeae, faint #808080,
// accent #3b5cf6.
#import "OCChatViewController.h"
#import "OCServerClient.h"
#import "OCSettings.h"
#import "OCUtil.h"

// OpenCode dark tokens, as dynamic colours so light mode still reads.
static UIColor *OCBackground(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0x16/255.0 green:0x16/255.0 blue:0x16/255.0 alpha:1.0] : [UIColor systemBackgroundColor];
    }];
}
static UIColor *OCLayer01(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0x24/255.0 green:0x24/255.0 blue:0x24/255.0 alpha:1.0] : [UIColor secondarySystemBackgroundColor];
    }];
}
static UIColor *OCLayer02(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0x2e/255.0 green:0x2e/255.0 blue:0x2e/255.0 alpha:1.0] : [UIColor systemGray5Color];
    }];
}
static UIColor *OCTextBase(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0xf2/255.0 green:0xf2/255.0 blue:0xf2/255.0 alpha:1.0] : [UIColor labelColor];
    }];
}
static UIColor *OCTextMuted(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0xae/255.0 green:0xae/255.0 blue:0xae/255.0 alpha:1.0] : [UIColor secondaryLabelColor];
    }];
}
static UIColor *OCTextFaint(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0x80/255.0 green:0x80/255.0 blue:0x80/255.0 alpha:1.0] : [UIColor tertiaryLabelColor];
    }];
}
static UIColor *OCAccent(void) {
    return [UIColor colorWithRed:0x3b/255.0 green:0x5c/255.0 blue:0xf6/255.0 alpha:1.0];
}

@interface OCChatViewController () <UITableViewDataSource, UITableViewDelegate, OCServerEventDelegate, UITextViewDelegate>
@property (nonatomic, strong) NSDictionary *session;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *composerCard;
@property (nonatomic, strong) UITextView *composer;
@property (nonatomic, strong) UILabel *composerPlaceholder;
@property (nonatomic, strong) NSLayoutConstraint *composerHeightConstraint;
@property (nonatomic, strong) UIButton *modelChipButton;
@property (nonatomic, strong) UIButton *sendButton;
@property (nonatomic, strong) UIButton *stopButton;
@property (nonatomic, strong) NSLayoutConstraint *composerBottomConstraint;
@property (nonatomic, strong) NSArray *displayItems; // @{kind, role, text, detail, output, state, model, duration, key}
@property (nonatomic, strong) OCServerClient *client;
@property (nonatomic, strong, nullable) NSTimer *pollTimer;
@property (nonatomic, assign) BOOL waitingForReply;
@property (nonatomic, strong) NSMutableSet *shownPermissionIDs;
@property (nonatomic, strong) NSMutableSet *expandedKeys; // keys of expanded tool/reasoning rows
@property (nonatomic, strong) NSMutableSet *expandedUserKeys; // keys of expanded (unfolded) user bubbles
@property (nonatomic, copy, nullable) NSString *currentModelID;
@property (nonatomic, copy, nullable) NSString *currentProviderID;
@end

@implementation OCChatViewController

- (instancetype)initWithSession:(NSDictionary *)session {
    if ((self = [super init])) {
        _session = session;
        _displayItems = @[];
        _shownPermissionIDs = [NSMutableSet set];
        _expandedKeys = [NSMutableSet set];
        _expandedUserKeys = [NSMutableSet set];
        id model = session[@"model"];
        if ([model isKindOfClass:[NSDictionary class]]) {
            if ([model[@"id"] isKindOfClass:[NSString class]]) _currentModelID = model[@"id"];
            if ([model[@"providerID"] isKindOfClass:[NSString class]]) _currentProviderID = model[@"providerID"];
        } else if ([model isKindOfClass:[NSString class]]) {
            _currentModelID = model;
        }
    }
    return self;
}

- (OCServerClient *)serverClient {
    if (!_client) {
        OCSettings *s = [OCSettings shared];
        _client = [[OCServerClient alloc] initWithServerURL:s.serverURL password:[s serverPassword]];
    }
    return _client;
}

- (NSString *)sessionID { return self.session[@"id"]; }

- (NSString *)modelChipTitle {
    if (self.currentModelID.length && self.currentProviderID.length)
        return [NSString stringWithFormat:@"%@ / %@", self.currentProviderID, self.currentModelID];
    if (self.currentModelID.length) return self.currentModelID;
    return @"Model";
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = OCBackground();
    NSString *title = self.session[@"title"];
    self.title = ([title isKindOfClass:[NSString class]] && title.length) ? title : @"New Session";
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"Model" style:UIBarButtonItemStylePlain target:self action:@selector(pickModel)],
        [[UIBarButtonItem alloc] initWithTitle:@"Diff" style:UIBarButtonItemStylePlain target:self action:@selector(showDiff)],
    ];

    // The timeline. No separators and no greeting hero: a new session
    // is an empty timeline with the composer at the bottom.
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 60;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.backgroundColor = OCBackground();
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.tableView];

    // Composer: one rounded card, 12px radius, at the bottom. The
    // text area sits on top; a 44px footer row holds the model chip
    // and the 28px send button.
    self.composerCard = [[UIView alloc] init];
    self.composerCard.backgroundColor = OCLayer01();
    self.composerCard.layer.cornerRadius = 12;
    self.composerCard.layer.shadowColor = [UIColor blackColor].CGColor;
    self.composerCard.layer.shadowOpacity = 0.25;
    self.composerCard.layer.shadowRadius = 8;
    self.composerCard.layer.shadowOffset = CGSizeMake(0, -2);
    self.composerCard.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.composerCard];

    self.composer = [[UITextView alloc] init];
    self.composer.font = [UIFont systemFontOfSize:16];
    self.composer.backgroundColor = [UIColor clearColor];
    self.composer.textColor = OCTextBase();
    self.composer.delegate = self;
    self.composer.translatesAutoresizingMaskIntoConstraints = NO;
    self.composerHeightConstraint = [self.composer.heightAnchor constraintEqualToConstant:36];
    self.composerHeightConstraint.active = YES;
    [self.composerCard addSubview:self.composer];

    self.composerPlaceholder = [[UILabel alloc] init];
    self.composerPlaceholder.text = @"Ask anything, / for commands, @ for context…";
    self.composerPlaceholder.font = [UIFont systemFontOfSize:16];
    self.composerPlaceholder.textColor = OCTextFaint();
    self.composerPlaceholder.translatesAutoresizingMaskIntoConstraints = NO;
    [self.composerCard addSubview:self.composerPlaceholder];

    self.modelChipButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.modelChipButton setTitle:[self modelChipTitle] forState:UIControlStateNormal];
    self.modelChipButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [self.modelChipButton setTitleColor:OCTextBase() forState:UIControlStateNormal];
    self.modelChipButton.backgroundColor = [UIColor clearColor];
    self.modelChipButton.contentEdgeInsets = UIEdgeInsetsMake(6, 8, 6, 8);
    self.modelChipButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.modelChipButton addTarget:self action:@selector(pickModel) forControlEvents:UIControlEventTouchUpInside];
    [self.composerCard addSubview:self.modelChipButton];

    self.sendButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.sendButton.backgroundColor = OCAccent();
    self.sendButton.layer.cornerRadius = 6;
    self.sendButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.sendButton setImage:[[UIImage systemImageNamed:@"arrow.up"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
    self.sendButton.tintColor = [UIColor whiteColor];
    self.sendButton.alpha = 0.35;
    [self.sendButton addTarget:self action:@selector(sendTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.composerCard addSubview:self.sendButton];

    self.stopButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.stopButton.backgroundColor = OCAccent();
    self.stopButton.layer.cornerRadius = 6;
    self.stopButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.stopButton setImage:[[UIImage systemImageNamed:@"stop.fill"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
    self.stopButton.tintColor = [UIColor whiteColor];
    [self.stopButton addTarget:self action:@selector(stopTapped) forControlEvents:UIControlEventTouchUpInside];
    self.stopButton.hidden = YES;
    [self.composerCard addSubview:self.stopButton];

    self.composerBottomConstraint = [self.composerCard.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8];
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.composerCard.topAnchor constant:-12],
        [self.composerCard.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.composerCard.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        self.composerBottomConstraint,
        [self.composer.topAnchor constraintEqualToAnchor:self.composerCard.topAnchor constant:12],
        [self.composer.leadingAnchor constraintEqualToAnchor:self.composerCard.leadingAnchor constant:16],
        [self.composer.trailingAnchor constraintEqualToAnchor:self.composerCard.trailingAnchor constant:-16],
        [self.composerPlaceholder.leadingAnchor constraintEqualToAnchor:self.composer.leadingAnchor constant:5],
        [self.composerPlaceholder.centerYAnchor constraintEqualToAnchor:self.composer.centerYAnchor],
        [self.modelChipButton.leadingAnchor constraintEqualToAnchor:self.composerCard.leadingAnchor constant:8],
        [self.modelChipButton.topAnchor constraintEqualToAnchor:self.composer.bottomAnchor constant:4],
        [self.modelChipButton.bottomAnchor constraintEqualToAnchor:self.composerCard.bottomAnchor constant:-8],
        [self.modelChipButton.heightAnchor constraintEqualToConstant:28],
        [self.sendButton.trailingAnchor constraintEqualToAnchor:self.composerCard.trailingAnchor constant:-8],
        [self.sendButton.centerYAnchor constraintEqualToAnchor:self.modelChipButton.centerYAnchor],
        [self.sendButton.widthAnchor constraintEqualToConstant:28],
        [self.sendButton.heightAnchor constraintEqualToConstant:28],
        [self.stopButton.trailingAnchor constraintEqualToAnchor:self.composerCard.trailingAnchor constant:-8],
        [self.stopButton.centerYAnchor constraintEqualToAnchor:self.modelChipButton.centerYAnchor],
        [self.stopButton.widthAnchor constraintEqualToConstant:28],
        [self.stopButton.heightAnchor constraintEqualToConstant:28],
    ]];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.serverClient.eventDelegate = self;
    [self.serverClient startEventStream];
    [self reloadMessages];
    [self checkPermissions];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.serverClient stopEventStream];
    [self.pollTimer invalidate];
    self.pollTimer = nil;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.pollTimer invalidate];
}

#pragma mark - Keyboard

- (void)keyboardWillShow:(NSNotification *)note {
    CGRect frame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat height = CGRectGetHeight([self.view convertRect:frame fromView:nil]);
    self.composerBottomConstraint.constant = -height + self.view.safeAreaInsets.bottom - 8;
    [self.view layoutIfNeeded];
    [self scrollToBottom];
}

- (void)keyboardWillHide:(NSNotification *)note {
    self.composerBottomConstraint.constant = -8;
    [self.view layoutIfNeeded];
}

#pragma mark - Composer

- (void)textViewDidChange:(UITextView *)textView {
    // The text area scrolls internally past 180px, so long prompts
    // stay usable without the card taking the screen.
    CGFloat width = textView.frame.size.width;
    if (width > 0) {
        CGSize fit = [textView sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)];
        CGFloat height = MIN(MAX(fit.height, 36), 180);
        if (fabs(self.composerHeightConstraint.constant - height) > 0.5) {
            self.composerHeightConstraint.constant = height;
            [self.view layoutIfNeeded];
        }
    }
    self.composerPlaceholder.hidden = textView.text.length > 0;
    self.sendButton.alpha = textView.text.length ? 1.0 : 0.35;
}

#pragma mark - Messages

+ (NSArray *)displayItemsFromMessages:(NSArray *)messages {
    // Real server shape (verified live against opencode 2.2.6):
    // user:      {type:"user", text:"...", time:{created}}
    // assistant: {type:"assistant", model:{id, providerID}, time:{created, completed},
    //            content:[{type:"text", text:"..."},
    //            {type:"reasoning", text:"..."},
    //            {type:"tool", name:"shell", state:{status, input:{command}, output:"..."}}]}
    // idle:      {type:"idle", outcome:"succeeded"} (skipped, it is a status line)
    NSMutableArray *items = [NSMutableArray array];
    NSInteger messageIndex = 0;
    for (id raw in messages) {
        if (![raw isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *message = raw;
        NSString *role = message[@"type"];
        if (![role isKindOfClass:[NSString class]]) role = @"assistant";
        if ([role isEqualToString:@"idle"]) continue;
        NSString *messageID = message[@"id"];
        if (![messageID isKindOfClass:[NSString class]]) messageID = [NSString stringWithFormat:@"m%ld", (long)messageIndex];
        NSString *modelID = @"";
        NSString *providerID = @"";
        id model = message[@"model"];
        if ([model isKindOfClass:[NSDictionary class]]) {
            if ([model[@"id"] isKindOfClass:[NSString class]]) modelID = model[@"id"];
            if ([model[@"providerID"] isKindOfClass:[NSString class]]) providerID = model[@"providerID"];
        }
        NSString *duration = @"";
        NSDictionary *time = message[@"time"];
        if ([time isKindOfClass:[NSDictionary class]]) {
            NSNumber *created = time[@"created"];
            NSNumber *completed = time[@"completed"];
            if ([created isKindOfClass:[NSNumber class]] && [completed isKindOfClass:[NSNumber class]] && completed.longLongValue > created.longLongValue) {
                long seconds = (completed.longLongValue - created.longLongValue) / 1000;
                duration = seconds < 60 ? [NSString stringWithFormat:@"%lds", seconds] : [NSString stringWithFormat:@"%ldm %lds", seconds / 60, seconds % 60];
            }
        }
        NSString *sentTime = @"";
        if ([time isKindOfClass:[NSDictionary class]] && [time[@"created"] isKindOfClass:[NSNumber class]]) {
            NSDate *date = [NSDate dateWithTimeIntervalSince1970:((NSNumber *)time[@"created"]).doubleValue / 1000.0];
            NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
            formatter.timeStyle = NSDateFormatterShortStyle;
            formatter.dateStyle = NSDateFormatterNoStyle;
            sentTime = [formatter stringFromDate:date];
        }
        NSArray *parts = message[@"content"];
        if (![parts isKindOfClass:[NSArray class]] || !parts.count) {
            NSString *text = message[@"text"];
            if ([text isKindOfClass:[NSString class]] && text.length)
                [items addObject:@{@"kind": @"text", @"role": role, @"text": text, @"detail": @"", @"output": @"", @"model": modelID, @"provider": providerID, @"duration": duration, @"sentTime": sentTime, @"key": [NSString stringWithFormat:@"%@:0", messageID]}];
            messageIndex++;
            continue;
        }
        NSInteger partIndex = 0;
        for (id partRaw in parts) {
            if (![partRaw isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *part = partRaw;
            NSString *type = part[@"type"];
            NSString *key = [NSString stringWithFormat:@"%@:%ld", messageID, (long)partIndex];
            if ([type isEqualToString:@"text"] && [part[@"text"] isKindOfClass:[NSString class]] && ((NSString *)part[@"text"]).length) {
                [items addObject:@{@"kind": @"text", @"role": role, @"text": part[@"text"], @"detail": @"", @"output": @"", @"model": modelID, @"provider": providerID, @"duration": duration, @"sentTime": sentTime, @"key": key}];
            } else if ([type isEqualToString:@"tool"]) {
                NSString *tool = part[@"name"];
                if (![tool isKindOfClass:[NSString class]]) tool = @"tool";
                NSDictionary *state = part[@"state"];
                NSString *status = @"";
                NSString *detail = @"";
                NSString *output = @"";
                if ([state isKindOfClass:[NSDictionary class]]) {
                    if ([state[@"status"] isKindOfClass:[NSString class]]) status = state[@"status"];
                    NSDictionary *input = state[@"input"];
                    if ([input isKindOfClass:[NSDictionary class]]) {
                        detail = input[@"command"] ?: input[@"filePath"] ?: input[@"path"] ?: input[@"pattern"] ?: input[@"query"] ?: input[@"url"] ?: @"";
                        if (![detail isKindOfClass:[NSString class]]) detail = @"";
                    }
                    id out = state[@"output"];
                    if ([out isKindOfClass:[NSString class]]) output = out;
                    else if ([out isKindOfClass:[NSDictionary class]] || [out isKindOfClass:[NSArray class]]) {
                        NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
                        if (json) output = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] ?: @"";
                    }
                }
                // OpenCode keeps only the last 64 KiB of shell output.
                if (output.length > 65536) output = [output substringFromIndex:output.length - 65536];
                [items addObject:@{@"kind": @"tool", @"role": role, @"text": tool, @"detail": detail, @"output": output, @"state": status, @"model": modelID, @"provider": providerID, @"duration": duration, @"sentTime": sentTime, @"key": key}];
            } else if ([type isEqualToString:@"reasoning"] && [part[@"text"] isKindOfClass:[NSString class]] && ((NSString *)part[@"text"]).length) {
                [items addObject:@{@"kind": @"reasoning", @"role": @"reasoning", @"text": part[@"text"], @"detail": @"", @"output": @"", @"model": modelID, @"provider": providerID, @"duration": duration, @"sentTime": sentTime, @"key": key}];
            }
            partIndex++;
        }
        messageIndex++;
    }
    return items;
}

- (void)reloadMessages {
    [[self serverClient] fetchMessagesForSession:self.sessionID completion:^(NSArray *messages, NSError *error) {
        if (error || !messages) return;
        // The server returns messages newest first; the thread reads oldest first.
        NSArray *chronological = [[messages reverseObjectEnumerator] allObjects];
        self.displayItems = [OCChatViewController displayItemsFromMessages:chronological];
        [self.tableView reloadData];
        [self scrollToBottom];
    }];
    [self checkPermissions];
}

- (void)scrollToBottom {
    NSInteger rows = [self.tableView numberOfRowsInSection:0];
    if (!rows) return;
    NSIndexPath *last = [NSIndexPath indexPathForRow:rows - 1 inSection:0];
    [self.tableView scrollToRowAtIndexPath:last atScrollPosition:UITableViewScrollPositionBottom animated:YES];
}

- (void)startPolling {
    [self.pollTimer invalidate];
    self.waitingForReply = YES;
    self.stopButton.hidden = NO;
    self.sendButton.hidden = YES;
    __weak typeof(self) weakSelf = self;
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
        (void)timer;
        [weakSelf reloadMessages];
        [weakSelf checkSessionIdle];
    }];
}

- (void)stopPolling {
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    self.waitingForReply = NO;
    self.stopButton.hidden = YES;
    self.sendButton.hidden = NO;
}

// The server marks a session idle when the agent finishes (time.idle >=
// time.busy). Stop polling then, so the thread does not refetch forever.
- (void)checkSessionIdle {
    if (!self.waitingForReply) return;
    [[self serverClient] fetchSession:self.sessionID completion:^(NSDictionary *session, NSError *error) {
        if (error || !session) return;
        NSDictionary *time = session[@"time"];
        if (![time isKindOfClass:[NSDictionary class]]) return;
        NSNumber *busy = time[@"busy"];
        NSNumber *idle = time[@"idle"];
        if ([busy isKindOfClass:[NSNumber class]] && [idle isKindOfClass:[NSNumber class]] &&
            idle.longLongValue > 0 && idle.longLongValue >= busy.longLongValue) {
            [self stopPolling];
            [self reloadMessages];
        }
    }];
}

#pragma mark - Send / stop

- (void)sendTapped {
    NSString *text = [self.composer.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length) return;
    self.composer.text = @"";
    [self textViewDidChange:self.composer];
    [self.composer resignFirstResponder];
    [self startPolling];
    [[self serverClient] sendPrompt:text toSession:self.sessionID completion:^(NSDictionary *message, NSError *error) {
        (void)message;
        if (error) {
            [self stopPolling];
            [self showError:error];
            return;
        }
        [self reloadMessages];
    }];
}

- (void)stopTapped {
    [[self serverClient] interruptSession:self.sessionID completion:^(NSError *error) {
        (void)error;
        [self stopPolling];
        [self reloadMessages];
    }];
}

- (void)showError:(NSError *)error {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Error" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Model picker / diff

- (void)pickModel {
    [[self serverClient] listModelsWithCompletion:^(NSArray *models, NSError *error) {
        if (error || !models.count) { [self showError:error ?: [NSError errorWithDomain:@"OC" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No models returned by the server"}]]; return; }
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Model" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSDictionary *model in models) {
            NSString *modelID = model[@"modelID"] ?: model[@"id"];
            NSString *providerID = model[@"providerID"];
            NSString *name = model[@"name"] ?: modelID;
            if (![modelID isKindOfClass:[NSString class]]) continue;
            [sheet addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                (void)action;
                [[self serverClient] setModel:modelID providerID:providerID forSession:self.sessionID completion:^(NSError *error) {
                    if (error) [self showError:error];
                    else {
                        self.currentModelID = modelID;
                        self.currentProviderID = providerID;
                        [self.modelChipButton setTitle:[self modelChipTitle] forState:UIControlStateNormal];
                        self.title = [NSString stringWithFormat:@"%@ · %@", self.session[@"title"] ?: @"Chat", modelID];
                    }
                }];
            }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:sheet animated:YES completion:nil];
    }];
}

- (void)showDiff {
    [[self serverClient] fetchDiffForSession:self.sessionID completion:^(NSArray *diff, NSError *error) {
        if (error) { [self showError:error]; return; }
        NSMutableString *text = [NSMutableString string];
        for (NSDictionary *entry in diff) {
            NSString *path = entry[@"path"] ?: entry[@"file"] ?: @"";
            [text appendFormat:@"%@\n", path];
            NSString *patch = entry[@"patch"] ?: entry[@"diff"];
            if ([patch isKindOfClass:[NSString class]]) [text appendFormat:@"%@\n\n", patch];
        }
        if (!text.length) text = [NSMutableString stringWithString:@"No pending changes."];
        UIViewController *vc = [[UIViewController alloc] init];
        vc.title = @"Diff";
        UITextView *tv = [[UITextView alloc] initWithFrame:vc.view.bounds];
        tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        tv.editable = NO;
        tv.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
        tv.text = text;
        [vc.view addSubview:tv];
        vc.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Revert" style:UIBarButtonItemStylePlain target:self action:@selector(revertTapped)];
        [self.navigationController pushViewController:vc animated:YES];
    }];
}

- (void)revertTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Revert changes" message:@"Undo all uncommitted changes in this session?" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Revert" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        (void)action;
        [[self serverClient] revertSession:self.sessionID completion:^(NSError *error) {
            if (error) [self showError:error];
            [self.navigationController popViewControllerAnimated:YES];
            [self reloadMessages];
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Permissions

- (void)checkPermissions {
    [[self serverClient] fetchPermissionsForSession:self.sessionID completion:^(NSArray *requests, NSError *error) {
        if (error || !requests.count) return;
        for (NSDictionary *req in requests) {
            NSString *requestID = req[@"id"];
            if (![requestID isKindOfClass:[NSString class]]) continue;
            if ([self.shownPermissionIDs containsObject:requestID]) continue;
            [self.shownPermissionIDs addObject:requestID];
            [self presentPermission:req];
        }
    }];
}

- (void)presentPermission:(NSDictionary *)req {
    NSString *requestID = req[@"id"];
    NSString *action = req[@"action"];
    if (![action isKindOfClass:[NSString class]]) action = @"run this";
    NSArray *resources = req[@"resources"];
    NSString *resource = ([resources isKindOfClass:[NSArray class]] && resources.count && [resources[0] isKindOfClass:[NSString class]]) ? resources[0] : @"";
    NSString *title = [NSString stringWithFormat:@"Allow %@?", action];
    NSString *message = req[@"message"];
    if (![message isKindOfClass:[NSString class]] || !message.length) message = resource.length ? resource : @"The agent wants to do this.";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Allow once" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        (void)action;
        [self replyPermission:requestID decision:@"once"];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Always allow" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        (void)action;
        [self replyPermission:requestID decision:@"always"];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Deny" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        (void)action;
        [self replyPermission:requestID decision:@"reject"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)replyPermission:(NSString *)requestID decision:(NSString *)decision {
    [[self serverClient] replyPermission:requestID sessionID:self.sessionID decision:decision completion:^(NSError *error) {
        if (error) [self showError:error];
        [self reloadMessages];
    }];
}

#pragma mark - SSE events

- (void)serverClientDidReceiveEvent:(NSDictionary *)event {
    NSString *type = event[@"type"];
    if (![type isKindOfClass:[NSString class]]) return;
    if ([type isEqualToString:@"server.connected"]) return;
    // Any session/message/permission/tool event refreshes this thread.
    if ([type containsString:@"message"] || [type containsString:@"session"] ||
        [type containsString:@"permission"] || [type containsString:@"tool"]) {
        [self reloadMessages];
    }
}

- (void)serverClientEventStreamDidFail:(NSError *)error {
    // The client auto-reconnects. Polling keeps the thread live meanwhile.
    if (self.waitingForReply && !self.pollTimer) [self startPolling];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.displayItems.count;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    NSDictionary *item = self.displayItems[indexPath.row];
    NSString *kind = item[@"kind"];
    NSString *key = item[@"key"];
    if (![key isKindOfClass:[NSString class]]) return;
    if ([kind isEqualToString:@"tool"] || [kind isEqualToString:@"reasoning"]) {
        if ([self.expandedKeys containsObject:key]) [self.expandedKeys removeObject:key];
        else [self.expandedKeys addObject:key];
        [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    } else if ([kind isEqualToString:@"text"] && [item[@"role"] isEqualToString:@"user"]) {
        if ([self.expandedUserKeys containsObject:key]) [self.expandedUserKeys removeObject:key];
        else [self.expandedUserKeys addObject:key];
        [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"MessageCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellID];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = [UIColor clearColor];
    }
    // Cells are reused; clear the previous message's views first.
    for (UIView *v in cell.contentView.subviews) [v removeFromSuperview];

    NSDictionary *item = self.displayItems[indexPath.row];
    NSString *kind = item[@"kind"];
    NSString *role = item[@"role"];

    if ([kind isEqualToString:@"tool"]) {
        [self configureToolCell:cell item:item];
    } else if ([kind isEqualToString:@"reasoning"]) {
        [self configureReasoningCell:cell item:item];
    } else if ([role isEqualToString:@"user"]) {
        [self configureUserCell:cell item:item];
    } else {
        [self configureAssistantCell:cell item:item];
    }
    return cell;
}

// User message, OpenCode's way: a right-aligned bubble, layer-02,
// 10px radius, at most 82% wide, 8px/12px padding, plain text. A
// faint sent-time sits under the bubble. Past 12 lines it folds to
// the first 8 with a Read more toggle.
- (void)configureUserCell:(UITableViewCell *)cell item:(NSDictionary *)item {
    NSString *text = item[@"text"];
    NSString *key = item[@"key"];
    BOOL folded = NO;
    NSString *shownText = text;
    NSArray *lines = [text componentsSeparatedByString:@"\n"];
    if (lines.count > 12 && ![self.expandedUserKeys containsObject:key]) {
        folded = YES;
        shownText = [[lines subarrayWithRange:NSMakeRange(0, 8)] componentsJoinedByString:@"\n"];
    }
    UIView *bubble = [[UIView alloc] init];
    bubble.backgroundColor = OCLayer02();
    bubble.layer.cornerRadius = 10;
    bubble.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *label = [[UILabel alloc] init];
    label.text = shownText;
    label.font = [UIFont systemFontOfSize:16];
    label.textColor = OCTextBase();
    label.numberOfLines = 0;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [bubble addSubview:label];
    [cell.contentView addSubview:bubble];

    NSMutableArray *constraints = [NSMutableArray arrayWithArray:@[
        [label.topAnchor constraintEqualToAnchor:bubble.topAnchor constant:8],
        [label.leadingAnchor constraintEqualToAnchor:bubble.leadingAnchor constant:12],
        [label.trailingAnchor constraintEqualToAnchor:bubble.trailingAnchor constant:-12],
        [label.bottomAnchor constraintEqualToAnchor:bubble.bottomAnchor constant:-8],
        [bubble.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:4],
        [bubble.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [bubble.widthAnchor constraintLessThanOrEqualToAnchor:cell.contentView.widthAnchor multiplier:0.82],
    ]];
    // Vertical chain: bubble, then the fold toggle if the message
    // folds, then the sent-time meta. Only the last view pins the
    // cell bottom, so the chain never fights itself.
    UIView *lastView = bubble;
    BOOL needsFoldToggle = folded || [self.expandedUserKeys containsObject:key];
    if (needsFoldToggle) {
        UIButton *foldButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [foldButton setTitle:(folded ? @"Read more" : @"Show less") forState:UIControlStateNormal];
        foldButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        [foldButton setTitleColor:OCAccent() forState:UIControlStateNormal];
        foldButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
        foldButton.translatesAutoresizingMaskIntoConstraints = NO;
        [foldButton addTarget:self action:@selector(foldButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        foldButton.tag = [self.displayItems indexOfObject:item];
        [cell.contentView addSubview:foldButton];
        [constraints addObjectsFromArray:@[
            [foldButton.topAnchor constraintEqualToAnchor:lastView.bottomAnchor constant:2],
            [foldButton.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        ]];
        lastView = foldButton;
    }
    NSString *sentTime = item[@"sentTime"];
    if ([sentTime isKindOfClass:[NSString class]] && sentTime.length) {
        UILabel *meta = [[UILabel alloc] init];
        meta.text = sentTime;
        meta.font = [UIFont systemFontOfSize:12];
        meta.textColor = OCTextFaint();
        meta.textAlignment = NSTextAlignmentRight;
        meta.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:meta];
        [constraints addObjectsFromArray:@[
            [meta.topAnchor constraintEqualToAnchor:lastView.bottomAnchor constant:2],
            [meta.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        ]];
        lastView = meta;
    }
    [constraints addObject:[lastView.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-4]];
    [NSLayoutConstraint activateConstraints:constraints];
}

- (void)foldButtonTapped:(UIButton *)sender {
    NSInteger row = sender.tag;
    if (row < 0 || row >= self.displayItems.count) return;
    NSDictionary *item = self.displayItems[row];
    NSString *key = item[@"key"];
    if (![key isKindOfClass:[NSString class]]) return;
    if ([self.expandedUserKeys containsObject:key]) [self.expandedUserKeys removeObject:key];
    else [self.expandedUserKeys addObject:key];
    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:row inSection:0]] withRowAnimation:UITableViewRowAnimationAutomatic];
}

// Assistant text, OpenCode's way: no bubble, no avatar, plain
// flowing markdown. A faint footer carries a copy button plus the
// model, duration and tokens line.
- (void)configureAssistantCell:(UITableViewCell *)cell item:(NSDictionary *)item {
    UILabel *label = [[UILabel alloc] init];
    label.attributedText = [OCUtil attributedFromMarkdown:item[@"text"] baseFont:[UIFont systemFontOfSize:16]];
    label.numberOfLines = 0;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:label];

    NSMutableArray *metaParts = [NSMutableArray array];
    NSString *provider = item[@"provider"];
    NSString *model = item[@"model"];
    if ([provider isKindOfClass:[NSString class]] && provider.length && [model isKindOfClass:[NSString class]] && model.length)
        [metaParts addObject:[NSString stringWithFormat:@"%@ / %@", provider, model]];
    else if ([model isKindOfClass:[NSString class]] && model.length)
        [metaParts addObject:model];
    NSString *duration = item[@"duration"];
    if ([duration isKindOfClass:[NSString class]] && duration.length) [metaParts addObject:duration];
    NSString *metaText = [metaParts componentsJoinedByString:@" · "];

    UIButton *copyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [copyButton setTitle:@"Copy" forState:UIControlStateNormal];
    copyButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [copyButton setTitleColor:OCTextFaint() forState:UIControlStateNormal];
    copyButton.translatesAutoresizingMaskIntoConstraints = NO;
    [copyButton addTarget:self action:@selector(copyButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    copyButton.tag = [self.displayItems indexOfObject:item];
    [cell.contentView addSubview:copyButton];

    UILabel *metaLabel = [[UILabel alloc] init];
    metaLabel.text = metaText;
    metaLabel.font = [UIFont systemFontOfSize:12];
    metaLabel.textColor = OCTextFaint();
    metaLabel.numberOfLines = 0;
    metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:metaLabel];

    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:12],
        [label.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [label.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [copyButton.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:6],
        [copyButton.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [copyButton.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
        [metaLabel.centerYAnchor constraintEqualToAnchor:copyButton.centerYAnchor],
        [metaLabel.leadingAnchor constraintEqualToAnchor:copyButton.trailingAnchor constant:12],
        [metaLabel.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [metaLabel.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
    ]];
}

- (void)copyButtonTapped:(UIButton *)sender {
    NSInteger row = sender.tag;
    if (row < 0 || row >= self.displayItems.count) return;
    NSString *text = self.displayItems[row][@"text"];
    if ([text isKindOfClass:[NSString class]] && text.length) {
        [UIPasteboard generalPasteboard].string = text;
        [sender setTitle:@"Copied" forState:UIControlStateNormal];
    }
}

// Reasoning, OpenCode's way: a collapsible BasicTool card titled
// "Thinking" while streaming and "Thought" once done, with the
// duration as the subtitle and the reasoning text inside in 13px
// muted markdown.
- (void)configureReasoningCell:(UITableViewCell *)cell item:(NSDictionary *)item {
    NSString *key = item[@"key"];
    BOOL expanded = [self.expandedKeys containsObject:key];
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = OCLayer01();
    card.layer.cornerRadius = 12;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:card];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = expanded ? @"Thought" : @"Thinking";
    titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    titleLabel.textColor = OCTextBase();
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:titleLabel];

    UILabel *subtitleLabel = [[UILabel alloc] init];
    NSString *duration = item[@"duration"];
    subtitleLabel.text = ([duration isKindOfClass:[NSString class]] && duration.length) ? duration : @"";
    subtitleLabel.font = [UIFont systemFontOfSize:13];
    subtitleLabel.textColor = OCTextMuted();
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:subtitleLabel];

    UILabel *chevron = [[UILabel alloc] init];
    chevron.text = expanded ? @"▾" : @"▸";
    chevron.font = [UIFont systemFontOfSize:13];
    chevron.textColor = OCTextFaint();
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:chevron];

    NSMutableArray *constraints = [NSMutableArray arrayWithArray:@[
        [titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:8],
        [titleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [subtitleLabel.centerYAnchor constraintEqualToAnchor:titleLabel.centerYAnchor],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:titleLabel.trailingAnchor constant:8],
        [chevron.centerYAnchor constraintEqualToAnchor:titleLabel.centerYAnchor],
        [chevron.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [card.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:4],
        [card.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
    ]];
    if (expanded) {
        UILabel *body = [[UILabel alloc] init];
        body.attributedText = [OCUtil attributedFromMarkdown:item[@"text"] baseFont:[UIFont systemFontOfSize:13]];
        body.textColor = OCTextMuted();
        body.numberOfLines = 0;
        body.translatesAutoresizingMaskIntoConstraints = NO;
        [card addSubview:body];
        [constraints addObjectsFromArray:@[
            [body.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:8],
            [body.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
            [body.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
            [body.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-10],
            [titleLabel.bottomAnchor constraintEqualToAnchor:body.topAnchor constant:-8],
        ]];
    } else {
        [constraints addObject:[titleLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8]];
    }
    [constraints addObject:[card.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-4]];
    [NSLayoutConstraint activateConstraints:constraints];
}

// Tool call, OpenCode's way: a BasicTool trigger row, 28px tall, with
// a per-tool icon, a 13px medium title and a 13px muted subtitle
// (truncated), and a chevron. No card background on the trigger; the
// detail opens below it. Shell shows a command + result card.
- (void)configureToolCell:(UITableViewCell *)cell item:(NSDictionary *)item {
    NSString *key = item[@"key"];
    BOOL expanded = [self.expandedKeys containsObject:key];
    NSString *tool = item[@"text"];
    NSString *status = item[@"state"];
    BOOL running = [status isEqualToString:@"pending"] || [status isEqualToString:@"running"];

    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:row];

    UILabel *iconLabel = [[UILabel alloc] init];
    iconLabel.text = [self iconForTool:tool];
    iconLabel.font = [UIFont systemFontOfSize:13];
    iconLabel.textColor = OCTextMuted();
    iconLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:iconLabel];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = [self displayTitleForTool:tool];
    titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    titleLabel.textColor = OCTextBase();
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:titleLabel];

    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.text = item[@"detail"];
    subtitleLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    subtitleLabel.textColor = OCTextMuted();
    subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:subtitleLabel];

    UILabel *chevron = [[UILabel alloc] init];
    chevron.text = expanded ? @"▾" : @"▸";
    chevron.font = [UIFont systemFontOfSize:13];
    chevron.textColor = OCTextFaint();
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:chevron];

    // A running tool shimmers its title in OpenCode; here the title
    // reads in the accent colour while it runs.
    if (running) titleLabel.textColor = OCAccent();

    NSMutableArray *constraints = [NSMutableArray arrayWithArray:@[
        [row.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:4],
        [row.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [row.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [row.heightAnchor constraintEqualToConstant:28],
        [iconLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [iconLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [titleLabel.leadingAnchor constraintEqualToAnchor:iconLabel.trailingAnchor constant:8],
        [titleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:titleLabel.trailingAnchor constant:8],
        [subtitleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:chevron.leadingAnchor constant:-8],
        [chevron.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [chevron.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];

    if (expanded) {
        UIView *detail = [self detailViewForTool:item];
        detail.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:detail];
        [constraints addObjectsFromArray:@[
            [detail.topAnchor constraintEqualToAnchor:row.bottomAnchor constant:4],
            [detail.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
            [detail.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
            [detail.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-4],
        ]];
    } else {
        [constraints addObject:[row.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-4]];
    }
    [NSLayoutConstraint activateConstraints:constraints];
}

- (NSString *)iconForTool:(NSString *)tool {
    static NSDictionary *icons;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        icons = @{
            @"shell": @"⌘", @"bash": @"⌘", @"read": @"📄", @"edit": @"✎",
            @"write": @"✎", @"patch": @"✎", @"list": @"☰", @"glob": @"☰",
            @"grep": @"⌕", @"webfetch": @"🌐", @"websearch": @"⌕",
            @"browser": @"🌐", @"agent": @"🤖", @"skill": @"✦",
            @"todowrite": @"☑", @"question": @"?",
        };
    });
    NSString *icon = icons[[tool lowercaseString]];
    return icon ?: @"⚙";
}

- (NSString *)displayTitleForTool:(NSString *)tool {
    static NSDictionary *titles;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        titles = @{
            @"shell": @"Shell", @"bash": @"Shell", @"read": @"Read",
            @"list": @"List", @"glob": @"Glob", @"grep": @"Grep",
            @"webfetch": @"Webfetch", @"websearch": @"Web Search",
            @"browser": @"Browser", @"edit": @"Edit", @"write": @"Write",
            @"patch": @"Patch", @"question": @"Questions", @"agent": @"Agent",
            @"skill": @"Skill", @"todowrite": @"Todo",
        };
    });
    NSString *title = titles[[tool lowercaseString]];
    if (title) return title;
    NSString *capitalised = [tool capitalizedString];
    return [NSString stringWithFormat:@"Called %@", capitalised];
}

// The detail that opens under a tool trigger. Shell gets OpenCode's
// command + result card (0.5px border, 6px radius, mono 13px, result
// in layer-01); other tools show their output as muted mono text.
- (UIView *)detailViewForTool:(NSDictionary *)item {
    NSString *tool = item[@"text"];
    NSString *output = item[@"output"];
    NSString *detail = item[@"detail"];
    BOOL isShell = [[tool lowercaseString] isEqualToString:@"shell"] || [[tool lowercaseString] isEqualToString:@"bash"];
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = OCLayer01();
    card.layer.cornerRadius = 6;
    card.layer.borderColor = [UIColor separatorColor].CGColor;
    card.layer.borderWidth = 0.5;

    UILabel *commandLabel = [[UILabel alloc] init];
    commandLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    commandLabel.textColor = OCTextBase();
    commandLabel.numberOfLines = 0;
    commandLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:commandLabel];

    UILabel *outputLabel = [[UILabel alloc] init];
    outputLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    outputLabel.textColor = OCTextMuted();
    outputLabel.numberOfLines = 0;
    outputLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:outputLabel];

    if (isShell) {
        commandLabel.text = detail.length ? detail : @"(no command)";
        outputLabel.text = output.length ? output : @"";
    } else {
        commandLabel.text = detail.length ? detail : @"";
        outputLabel.text = output.length ? output : @"";
    }
    NSMutableArray *constraints = [NSMutableArray arrayWithArray:@[
        [commandLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:8],
        [commandLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [commandLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
    ]];
    if (outputLabel.text.length) {
        [constraints addObjectsFromArray:@[
            [outputLabel.topAnchor constraintEqualToAnchor:commandLabel.bottomAnchor constant:8],
            [outputLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
            [outputLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
            [outputLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8],
        ]];
    } else {
        [constraints addObject:[commandLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8]];
    }
    [NSLayoutConstraint activateConstraints:constraints];
    return card;
}

@end
