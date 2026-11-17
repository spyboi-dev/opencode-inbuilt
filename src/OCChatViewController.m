// OCChatViewController - chat thread for one OpenCode session.
#import "OCChatViewController.h"
#import "OCServerClient.h"
#import "OCSettings.h"
#import "OCUtil.h"

@interface OCChatViewController () <UITableViewDataSource, UITableViewDelegate, OCServerEventDelegate, UITextViewDelegate>
@property (nonatomic, strong) NSDictionary *session;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UITextView *composer;
@property (nonatomic, strong) UIButton *sendButton;
@property (nonatomic, strong) UIButton *stopButton;
@property (nonatomic, strong) NSLayoutConstraint *composerBottomConstraint;
@property (nonatomic, strong) NSArray *displayItems; // @{kind:@"text"|@"tool", role, text, detail, state}
@property (nonatomic, strong) OCServerClient *client;
@property (nonatomic, strong, nullable) NSTimer *pollTimer;
@property (nonatomic, assign) BOOL waitingForReply;
@property (nonatomic, strong) NSMutableSet *shownPermissionIDs;
@end

@implementation OCChatViewController

- (instancetype)initWithSession:(NSDictionary *)session {
    if ((self = [super init])) {
        _session = session;
        _displayItems = @[];
        _shownPermissionIDs = [NSMutableSet set];
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

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    NSString *title = self.session[@"title"];
    self.title = ([title isKindOfClass:[NSString class]] && title.length) ? title : @"Chat";
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"Model" style:UIBarButtonItemStylePlain target:self action:@selector(pickModel)],
        [[UIBarButtonItem alloc] initWithTitle:@"Diff" style:UIBarButtonItemStylePlain target:self action:@selector(showDiff)],
    ];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 60;
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.tableView];

    UIView *composerBar = [[UIView alloc] init];
    composerBar.backgroundColor = [UIColor secondarySystemBackgroundColor];
    composerBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:composerBar];

    self.composer = [[UITextView alloc] init];
    self.composer.font = [UIFont systemFontOfSize:16];
    self.composer.layer.cornerRadius = 8;
    self.composer.backgroundColor = [UIColor systemBackgroundColor];
    self.composer.delegate = self;
    self.composer.translatesAutoresizingMaskIntoConstraints = NO;
    [composerBar addSubview:self.composer];

    self.sendButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.sendButton setTitle:@"Send" forState:UIControlStateNormal];
    self.sendButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [self.sendButton addTarget:self action:@selector(sendTapped) forControlEvents:UIControlEventTouchUpInside];
    self.sendButton.translatesAutoresizingMaskIntoConstraints = NO;
    [composerBar addSubview:self.sendButton];

    self.stopButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.stopButton setTitle:@"Stop" forState:UIControlStateNormal];
    [self.stopButton addTarget:self action:@selector(stopTapped) forControlEvents:UIControlEventTouchUpInside];
    self.stopButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.stopButton.hidden = YES;
    [composerBar addSubview:self.stopButton];

    self.composerBottomConstraint = [composerBar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor];
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:composerBar.topAnchor],
        [composerBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [composerBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        self.composerBottomConstraint,
        [composerBar.heightAnchor constraintGreaterThanOrEqualToConstant:52],
        [self.composer.topAnchor constraintEqualToAnchor:composerBar.topAnchor constant:6],
        [self.composer.leadingAnchor constraintEqualToAnchor:composerBar.leadingAnchor constant:8],
        [self.composer.bottomAnchor constraintEqualToAnchor:composerBar.bottomAnchor constant:-6],
        [self.sendButton.leadingAnchor constraintEqualToAnchor:self.composer.trailingAnchor constant:8],
        [self.sendButton.centerYAnchor constraintEqualToAnchor:composerBar.centerYAnchor],
        [self.stopButton.leadingAnchor constraintEqualToAnchor:self.sendButton.trailingAnchor constant:4],
        [self.stopButton.trailingAnchor constraintEqualToAnchor:composerBar.trailingAnchor constant:-8],
        [self.stopButton.centerYAnchor constraintEqualToAnchor:composerBar.centerYAnchor],
        [self.sendButton.trailingAnchor constraintLessThanOrEqualToAnchor:composerBar.trailingAnchor constant:-8],
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
    self.composerBottomConstraint.constant = -height + self.view.safeAreaInsets.bottom;
    [self.view layoutIfNeeded];
    [self scrollToBottom];
}

- (void)keyboardWillHide:(NSNotification *)note {
    self.composerBottomConstraint.constant = 0;
    [self.view layoutIfNeeded];
}

#pragma mark - Messages

+ (NSArray *)displayItemsFromMessages:(NSArray *)messages {
    // Real server shape (verified live against opencode 2.2.6):
    // user:      {type:"user", text:"..."}
    // assistant: {type:"assistant", content:[{type:"text", text:"..."},
    //            {type:"tool", name:"shell", state:{status, input:{command}}}]}
    // idle:      {type:"idle", outcome:"succeeded"} (skipped, it is a status line)
    NSMutableArray *items = [NSMutableArray array];
    for (id raw in messages) {
        if (![raw isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *message = raw;
        NSString *role = message[@"type"];
        if (![role isKindOfClass:[NSString class]]) role = @"assistant";
        if ([role isEqualToString:@"idle"]) continue;
        NSArray *parts = message[@"content"];
        if (![parts isKindOfClass:[NSArray class]] || !parts.count) {
            NSString *text = message[@"text"];
            if ([text isKindOfClass:[NSString class]] && text.length)
                [items addObject:@{@"kind": @"text", @"role": role, @"text": text, @"detail": @""}];
            continue;
        }
        for (id partRaw in parts) {
            if (![partRaw isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *part = partRaw;
            NSString *type = part[@"type"];
            if ([type isEqualToString:@"text"] && [part[@"text"] isKindOfClass:[NSString class]] && ((NSString *)part[@"text"]).length) {
                [items addObject:@{@"kind": @"text", @"role": role, @"text": part[@"text"], @"detail": @""}];
            } else if ([type isEqualToString:@"tool"]) {
                NSString *tool = part[@"name"];
                if (![tool isKindOfClass:[NSString class]]) tool = @"tool";
                NSDictionary *state = part[@"state"];
                NSString *status = @"";
                NSString *detail = @"";
                if ([state isKindOfClass:[NSDictionary class]]) {
                    if ([state[@"status"] isKindOfClass:[NSString class]]) status = state[@"status"];
                    NSDictionary *input = state[@"input"];
                    if ([input isKindOfClass:[NSDictionary class]]) {
                        detail = input[@"command"] ?: input[@"filePath"] ?: input[@"path"] ?: input[@"pattern"] ?: @"";
                        if (![detail isKindOfClass:[NSString class]]) detail = @"";
                    }
                }
                [items addObject:@{@"kind": @"tool", @"role": role, @"text": tool, @"detail": detail, @"state": status}];
            } else if ([type isEqualToString:@"reasoning"] && [part[@"text"] isKindOfClass:[NSString class]]) {
                [items addObject:@{@"kind": @"text", @"role": @"reasoning", @"text": part[@"text"], @"detail": @""}];
            }
        }
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
                    else self.title = [NSString stringWithFormat:@"%@ · %@", self.session[@"title"] ?: @"Chat", modelID];
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

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"MessageCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.numberOfLines = 0;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    NSDictionary *item = self.displayItems[indexPath.row];
    NSString *kind = item[@"kind"];
    NSString *role = item[@"role"];
    if ([kind isEqualToString:@"tool"]) {
        cell.textLabel.text = [NSString stringWithFormat:@"Tool: %@ %@", item[@"text"], item[@"state"] ?: @""];
        cell.detailTextLabel.text = item[@"detail"];
        cell.textLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightSemibold];
        cell.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    } else {
        UIFont *font = [UIFont systemFontOfSize:16];
        cell.textLabel.attributedText = [OCUtil attributedFromMarkdown:item[@"text"] baseFont:font];
        cell.detailTextLabel.text = @"";
        cell.textLabel.font = font;
        cell.backgroundColor = [role isEqualToString:@"user"] ? [UIColor secondarySystemBackgroundColor] : [UIColor clearColor];
    }
    return cell;
}

@end
