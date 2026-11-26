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
#import "OCT3WebViewController.h"
#import "OCEngine.h"
#import "OCServerClient.h"
#import "OCSettings.h"
#import <WebKit/WebKit.h>

static NSString * const OCT3RootURLString = @"http://127.0.0.1:3773/";
static NSString * const OCT3PairingURLPath = @".t3-pairing-url";

@interface OCT3WebViewController () <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIView *errorView;
@property (nonatomic, strong) UILabel *errorLabel;
@property (nonatomic, strong) UIButton *retryButton;
@property (nonatomic, assign) BOOL loadingPairingURL;
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
    ]];

    [self loadT3UI];
}

// First open per engine run: the one-time pairing URL, read
// from the file the t3 bootstrap captured. Later opens: the t3
// root, authenticated by the t3_session cookie the pairing set.
// The flag lives on the engine and resets when the engine
// restarts, because a restart starts a new t3 server with a new
// token.
- (void)loadT3UI {
    self.errorView.hidden = YES;
    self.webView.hidden = NO;
    if ([[OCEngine shared] t3PairingURLLoaded]) {
        [self loadURLString:OCT3RootURLString pairing:NO];
        return;
    }
    OCSettings *settings = [OCSettings shared];
    OCServerClient *client = [[OCServerClient alloc] initWithServerURL:settings.serverURL password:[settings serverPassword]];
    __weak typeof(self) weakSelf = self;
    [client readFileAtPath:OCT3PairingURLPath completion:^(NSString * _Nullable content, NSError * _Nullable error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSString *urlString = [content stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (error || ![strongSelf isPairingURLString:urlString]) {
            // The t3 server is not up yet (or the bootstrap has
            // not captured the URL): say so instead of a blank
            // screen. The flag stays unset, so Retry reads the
            // file again.
            [strongSelf showLoadError];
            return;
        }
        [strongSelf loadURLString:urlString pairing:YES];
    }];
}

- (BOOL)isPairingURLString:(NSString *)urlString {
    return [urlString hasPrefix:@"http://127.0.0.1:3773/pair#token="];
}

- (void)loadURLString:(NSString *)urlString pairing:(BOOL)pairing {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) { [self showLoadError]; return; }
    self.loadingPairingURL = pairing;
    [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
}

- (void)showLoadError {
    self.webView.hidden = YES;
    self.errorView.hidden = NO;
}

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
    // redirect to /) is the app itself.
    BOOL isT3 = [[url.host lowercaseString] isEqualToString:@"127.0.0.1"] && url.port.integerValue == 3773;
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
