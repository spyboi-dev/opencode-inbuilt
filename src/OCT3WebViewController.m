// OCT3WebViewController - the chat UI: t3code's web UI in a
// WKWebView shell (see the header). t3code is the UI the user
// picked (2026-11-26: "our ui is basoc remove it use this ui
// https://github.com/pingdotgg/t3code"); the basic native chat
// (OCChatViewController) is deleted. This is t3code's own UI,
// not OpenCode's: the t3 server serves it and drives our
// OpenCode server as a provider, so threads are t3-managed —
// there is no deep link from an OpenCode session ID into t3,
// and opening this view always lands on the t3 UI root (its
// own thread list), where the user picks or starts a thread.
//
// First open per engine run WAITS for the one-time pairing URL
// the t3 bootstrap captures (~/.t3-pairing-url): the first boot
// downloads t3 (~177 MB), so the file may not exist yet when
// the user taps a thread. dc3caf2 did one fs read and failed
// at once with a dead-end error (device test 2026-11-26 23:58
// IST: the Chat view showed only "Could not load the t3 UI").
// This view now polls the file every 2 s for up to 5 minutes
// (the bootstrap's own watchdog budget) and shows a waiting
// state meanwhile. If the engine reports the t3 bootstrap
// failed, polling stops early and the error names the failing
// step. Later opens load the t3 root, authenticated by the
// t3_session cookie the pairing set. The pairing token is never
// logged.
#import "OCT3WebViewController.h"
#import "OCEngine.h"
#import "OCServerClient.h"
#import "OCSettings.h"
#import <WebKit/WebKit.h>

static NSString * const OCT3RootURLString = @"http://127.0.0.1:3773/";
static NSString * const OCT3PairingURLPath = @".t3-pairing-url";
// Poll the pairing-URL file every 2 s for up to 5 minutes: the
// t3 bootstrap's own watchdog budget (see deliverT3Bootstrap
// in OCEngine). The first boot downloads t3 (~177 MB), so the
// file can take minutes to appear after the engine starts.
static const NSTimeInterval OCT3PollInterval = 2.0;
static const NSTimeInterval OCT3PollBudget = 300.0;

@interface OCT3WebViewController () <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIView *errorView;
@property (nonatomic, strong) UILabel *errorLabel;
@property (nonatomic, strong) UIButton *retryButton;
@property (nonatomic, strong) UIView *waitingView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *waitingLabel;
@property (nonatomic, assign) BOOL loadingPairingURL;
@property (nonatomic, strong, nullable) NSTimer *pollTimer;
@property (nonatomic, strong, nullable) NSDate *pollDeadline;
@property (nonatomic, assign) BOOL pollReadInFlight;
@end

@implementation OCT3WebViewController

- (instancetype)init {
    self = [super init];
    if (self) {
        self.title = @"Chat";
        self.hidesBottomBarWhenPushed = YES;
    }
    return self;
}

- (void)dealloc {
    [self.pollTimer invalidate];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reloadTapped)];

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config];
    self.webView.navigationDelegate = self;
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.webView];

    self.errorView = [[UIView alloc] init];
    self.errorView.translatesAutoresizingMaskIntoConstraints = NO;
    self.errorView.hidden = YES;
    [self.view addSubview:self.errorView];

    self.errorLabel = [[UILabel alloc] init];
    self.errorLabel.text = @"Could not load the t3 UI.\nStart the engine and try again.";
    self.errorLabel.numberOfLines = 0;
    self.errorLabel.textAlignment = NSTextAlignmentCenter;
    self.errorLabel.textColor = [UIColor secondaryLabelColor];
    self.errorLabel.font = [UIFont systemFontOfSize:16];
    self.errorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.errorView addSubview:self.errorLabel];

    self.retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.retryButton setTitle:@"Retry" forState:UIControlStateNormal];
    self.retryButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [self.retryButton addTarget:self action:@selector(retryTapped) forControlEvents:UIControlEventTouchUpInside];
    self.retryButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.errorView addSubview:self.retryButton];

    self.waitingView = [[UIView alloc] init];
    self.waitingView.translatesAutoresizingMaskIntoConstraints = NO;
    self.waitingView.hidden = YES;
    [self.view addSubview:self.waitingView];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.waitingView addSubview:self.spinner];

    self.waitingLabel = [[UILabel alloc] init];
    self.waitingLabel.text = @"Starting the t3 server…";
    self.waitingLabel.numberOfLines = 0;
    self.waitingLabel.textAlignment = NSTextAlignmentCenter;
    self.waitingLabel.textColor = [UIColor secondaryLabelColor];
    self.waitingLabel.font = [UIFont systemFontOfSize:16];
    self.waitingLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.waitingView addSubview:self.waitingLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.webView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.errorView.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerYAnchor],
        [self.errorView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:32],
        [self.errorView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-32],
        [self.errorLabel.topAnchor constraintEqualToAnchor:self.errorView.topAnchor],
        [self.errorLabel.leadingAnchor constraintEqualToAnchor:self.errorView.leadingAnchor],
        [self.errorLabel.trailingAnchor constraintEqualToAnchor:self.errorView.trailingAnchor],
        [self.retryButton.topAnchor constraintEqualToAnchor:self.errorLabel.bottomAnchor constant:16],
        [self.retryButton.centerXAnchor constraintEqualToAnchor:self.errorView.centerXAnchor],
        [self.retryButton.bottomAnchor constraintEqualToAnchor:self.errorView.bottomAnchor],
        [self.waitingView.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerYAnchor],
        [self.waitingView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:32],
        [self.waitingView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-32],
        [self.spinner.topAnchor constraintEqualToAnchor:self.waitingView.topAnchor],
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.waitingView.centerXAnchor],
        [self.waitingLabel.topAnchor constraintEqualToAnchor:self.spinner.bottomAnchor constant:16],
        [self.waitingLabel.leadingAnchor constraintEqualToAnchor:self.waitingView.leadingAnchor],
        [self.waitingLabel.trailingAnchor constraintEqualToAnchor:self.waitingView.trailingAnchor],
        [self.waitingLabel.bottomAnchor constraintEqualToAnchor:self.waitingView.bottomAnchor],
    ]];

    [self loadT3UI];
}

// First open per engine run: the one-time pairing URL, read
// from the file the t3 bootstrap captured. Later opens: the t3
// root, authenticated by the t3_session cookie the pairing set.
// The flag lives on the engine and resets when the engine
// restarts, because a restart starts a new t3 server with a new
// token. If the pairing URL is not there yet, this starts the
// wait/poll cycle instead of failing at once (see startPolling).
- (void)loadT3UI {
    [self stopPolling];
    self.loadingPairingURL = NO;
    self.errorView.hidden = YES;
    self.waitingView.hidden = YES;
    self.webView.hidden = NO;
    if ([[OCEngine shared] t3PairingURLLoaded]) {
        [self loadURLString:OCT3RootURLString pairing:NO];
        return;
    }
    [self startPolling];
}

// The pairing URL is not available yet: show the waiting state
// and poll the fs API for it every 2 s until the budget runs
// out. The t3 bootstrap can take minutes on a first boot (the
// ~177 MB download), so a single read at tap time is not
// enough. On success the pairing URL loads; on budget expiry
// the error view appears with Retry, which restarts the whole
// cycle with a fresh budget. The token is never logged.
- (void)startPolling {
    self.webView.hidden = YES;
    self.errorView.hidden = YES;
    self.waitingView.hidden = NO;
    [self.spinner startAnimating];
    self.pollDeadline = [NSDate dateWithTimeIntervalSinceNow:OCT3PollBudget];
    [[OCEngine shared] appendEngineLog:@"t3 UI: waiting for pairing URL"];
    __weak typeof(self) weakSelf = self;
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:OCT3PollInterval repeats:YES block:^(NSTimer * _Nonnull timer) {
        (void)timer;
        [weakSelf pollTick];
    }];
    [self pollTick];
}

- (void)stopPolling {
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    self.pollDeadline = nil;
    self.pollReadInFlight = NO;
    [self.spinner stopAnimating];
    self.waitingView.hidden = YES;
}

// One poll tick: the engine's t3 failure state ends the wait
// early with the specific step that failed; the budget ending
// ends it with the generic error; otherwise read the file.
- (void)pollTick {
    if (self.pollReadInFlight) return;
    OCEngine *engine = [OCEngine shared];
    if (engine.t3Failed) {
        NSString *reason = engine.t3FailureMessage ?: @"t3 failed";
        [self stopPolling];
        [[OCEngine shared] appendEngineLog:[NSString stringWithFormat:@"t3 UI: t3 failed: %@", reason]];
        [self showLoadErrorWithMessage:reason];
        return;
    }
    if (self.pollDeadline && [[NSDate date] compare:self.pollDeadline] == NSOrderedDescending) {
        [self stopPolling];
        [[OCEngine shared] appendEngineLog:@"t3 UI: timed out waiting for pairing URL"];
        [self showLoadError];
        return;
    }
    [self attemptPairingURLRead];
}

- (void)attemptPairingURLRead {
    self.pollReadInFlight = YES;
    OCSettings *settings = [OCSettings shared];
    OCServerClient *client = [[OCServerClient alloc] initWithServerURL:settings.serverURL password:[settings serverPassword]];
    __weak typeof(self) weakSelf = self;
    [client readFileAtPath:OCT3PairingURLPath completion:^(NSString * _Nullable content, NSError * _Nullable error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.pollReadInFlight = NO;
        // The poll ended while this read was in flight (Retry,
        // timeout, or the view went away): the result is stale.
        if (!strongSelf.pollTimer) return;
        NSString *urlString = [content stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!error && [strongSelf isPairingURLString:urlString]) {
            [strongSelf stopPolling];
            [[OCEngine shared] appendEngineLog:@"t3 UI: pairing URL loaded"];
            [strongSelf loadURLString:urlString pairing:YES];
            return;
        }
        // Still not there (or not a pairing URL yet): the next
        // tick retries, unless the engine failed meanwhile or
        // the budget ran out while this read was in flight.
        [strongSelf pollTick];
    }];
}

// The pairing URL format was assumed from t3 0.1.12, never
// verified against real t3 output, so the check is loose: http,
// host 127.0.0.1 or localhost, port 3773, a path containing
// "pair", and a token in the fragment (#token=...) or the query
// (?token=...). A strict prefix match would fail the whole UI
// on any of those varying.
- (BOOL)isPairingURLString:(NSString *)urlString {
    if (!urlString.length) return NO;
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return NO;
    if (![[url.scheme lowercaseString] isEqualToString:@"http"]) return NO;
    NSString *host = [url.host lowercaseString];
    if (![host isEqualToString:@"127.0.0.1"] && ![host isEqualToString:@"localhost"]) return NO;
    if (url.port.integerValue != 3773) return NO;
    if (![url.path containsString:@"pair"]) return NO;
    NSString *tokenSource = url.fragment.length ? url.fragment : url.query;
    return [tokenSource containsString:@"token="];
}

- (void)loadURLString:(NSString *)urlString pairing:(BOOL)pairing {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) { [self showLoadError]; return; }
    self.loadingPairingURL = pairing;
    [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
}

- (void)showLoadError {
    [self showLoadErrorWithMessage:nil];
}

- (void)showLoadErrorWithMessage:(nullable NSString *)message {
    [self stopPolling];
    self.webView.hidden = YES;
    self.waitingView.hidden = YES;
    if (message.length) {
        self.errorLabel.text = [NSString stringWithFormat:@"Could not load the t3 UI.\n%@", message];
    } else {
        self.errorLabel.text = @"Could not load the t3 UI.\nStart the engine and try again.";
    }
    self.errorView.hidden = NO;
}

// Retry re-reads the pairing URL and restarts the poll with a
// fresh budget — it does not just reload the same failed URL.
// That matters after a WebView-level failure too: the token may
// have changed if the server restarted since the last read.
- (void)retryTapped { [self loadT3UI]; }

- (void)reloadTapped {
    if (!self.errorView.hidden) { [self loadT3UI]; return; }
    [self.webView reload];
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;
    // The shell has no address bar: anything off the t3 server
    // would strand the user away from the chat, so cancel it.
    // Same-host navigation (threads, settings, the pairing
    // redirect to /) is the app itself. localhost is the same
    // server as 127.0.0.1: the pairing URL may use either host
    // (see isPairingURLString), and its redirect follows it.
    NSString *host = [url.host lowercaseString];
    BOOL isT3 = ([host isEqualToString:@"127.0.0.1"] || [host isEqualToString:@"localhost"]) && url.port.integerValue == 3773;
    decisionHandler(isT3 ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    (void)navigation;
    // The pairing exchange happened: the t3_session cookie is
    // set, so later opens can load the root directly.
    if (self.loadingPairingURL) {
        self.loadingPairingURL = NO;
        [OCEngine shared].t3PairingURLLoaded = YES;
    }
    self.errorView.hidden = YES;
    self.waitingView.hidden = YES;
    self.webView.hidden = NO;
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    (void)navigation;
    // A cancelled load is just a superseded one (Retry tapped
    // while a load was in flight), not a failure.
    if (error.code == NSURLErrorCancelled) return;
    self.loadingPairingURL = NO;
    [self showLoadError];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    (void)navigation;
    if (error.code == NSURLErrorCancelled) return;
    self.loadingPairingURL = NO;
    [self showLoadError];
}

@end
