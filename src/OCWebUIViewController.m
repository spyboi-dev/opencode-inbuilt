// OCWebUIViewController - the official OpenCode mobile web UI, in a native shell.
#import "OCWebUIViewController.h"
#import "OCSettings.h"
#import <WebKit/WebKit.h>

@interface OCWebUIViewController () <WKNavigationDelegate>
@property (nonatomic, copy, nullable) NSString *sessionID;
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIView *errorView;
@property (nonatomic, strong) UILabel *errorLabel;
@end

@implementation OCWebUIViewController

- (instancetype)initWithSessionID:(nullable NSString *)sessionID {
    if ((self = [super init])) {
        _sessionID = [sessionID copy];
        self.hidesBottomBarWhenPushed = YES;
    }
    return self;
}

// The session route is /server/<key>/session/<id>, where <key> is the
// base64url (no padding) of the server URL: packages/app
// src/shell/routes/session.ts sessionHref, and the key for an http
// connection is its URL (runtime/server/registry.tsx ServerConnection.key).
+ (NSString *)base64URLEncodedString:(NSString *)string {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    NSString *encoded = [data base64EncodedStringWithOptions:0];
    encoded = [[encoded stringByReplacingOccurrencesOfString:@"+" withString:@"-"]
        stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [encoded stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"="]];
}

- (NSURL *)startURL {
    NSString *serverURL = [OCSettings shared].serverURL;
    if (!self.sessionID.length) return [NSURL URLWithString:serverURL];
    NSString *key = [OCWebUIViewController base64URLEncodedString:serverURL];
    NSString *encodedID = [self.sessionID stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSString *path = [NSString stringWithFormat:@"%@/server/%@/session/%@", serverURL, key, encodedID ?: @""];
    return [NSURL URLWithString:path];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Chat";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reloadTapped)];

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config];
    self.webView.navigationDelegate = self;
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.webView];

    // A failed load never leaves a blank screen: the reason and a
    // retry sit over the web view until a load succeeds.
    self.errorView = [[UIView alloc] init];
    self.errorView.backgroundColor = [UIColor systemBackgroundColor];
    self.errorView.hidden = YES;
    self.errorView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.errorView];
    self.errorLabel = [[UILabel alloc] init];
    self.errorLabel.font = [UIFont systemFontOfSize:15];
    self.errorLabel.textColor = [UIColor secondaryLabelColor];
    self.errorLabel.textAlignment = NSTextAlignmentCenter;
    self.errorLabel.numberOfLines = 0;
    self.errorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.errorView addSubview:self.errorLabel];
    UIButton *retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [retryButton setTitle:@"Retry" forState:UIControlStateNormal];
    retryButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    retryButton.translatesAutoresizingMaskIntoConstraints = NO;
    [retryButton addTarget:self action:@selector(reloadTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.errorView addSubview:retryButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.webView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.errorView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.errorView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.errorView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.errorView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.errorLabel.centerXAnchor constraintEqualToAnchor:self.errorView.centerXAnchor],
        [self.errorLabel.centerYAnchor constraintEqualToAnchor:self.errorView.centerYAnchor constant:-20],
        [self.errorLabel.leadingAnchor constraintEqualToAnchor:self.errorView.leadingAnchor constant:24],
        [self.errorLabel.trailingAnchor constraintEqualToAnchor:self.errorView.trailingAnchor constant:-24],
        [retryButton.topAnchor constraintEqualToAnchor:self.errorLabel.bottomAnchor constant:16],
        [retryButton.centerXAnchor constraintEqualToAnchor:self.errorView.centerXAnchor],
    ]];

    [self loadStartURL];
}

- (void)loadStartURL {
    NSURL *url = [self startURL];
    if (!url) { [self showLoadError:@"Could not load the mobile UI."]; return; }
    [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
}

- (void)reloadTapped {
    self.errorView.hidden = YES;
    if (self.webView.URL) [self.webView reload];
    else [self loadStartURL];
}

- (void)showLoadError:(NSString *)reason {
    self.errorLabel.text = reason;
    self.errorView.hidden = NO;
}

#pragma mark - WKNavigationDelegate

// The server challenges HTTP Basic (realm "Secure Area", 401 with
// www-authenticate) on /api/*; the web shell itself is served before
// auth. WKWebView hands every challenge, main frame and fetch/XHR
// subresources alike, to this delegate, so answering here signs the
// UI in with the same Keychain password the native UI uses, and the
// web app never shows its own sign-in screen. One attempt only:
// a rejected credential cancels instead of looping the challenge.
- (void)webView:(WKWebView *)webView didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completionHandler {
    (void)webView;
    NSString *password = [[OCSettings shared] serverPassword];
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodHTTPBasic] &&
        challenge.previousFailureCount == 0 && password.length) {
        NSURLCredential *credential = [NSURLCredential credentialWithUser:@"opencode"
                                                                 password:password
                                                              persistence:NSURLCredentialPersistenceForSession];
        completionHandler(NSURLSessionAuthChallengeUseCredential, credential);
        return;
    }
    completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
}

// Links out of the UI (docs, external pages) stay out: the shell has
// no address bar, so leaving for another host would strand the user
// away from the chat with no way back except the back button.
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    (void)webView;
    NSURL *url = navigationAction.request.URL;
    NSString *serverHost = [self startURL].host;
    if (navigationAction.navigationType == WKNavigationTypeLinkActivated &&
        url.host.length && serverHost.length &&
        ![url.host isEqualToString:serverHost]) {
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    (void)webView; (void)navigation;
    self.errorView.hidden = YES;
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    (void)webView; (void)navigation;
    if (error.code == NSURLErrorCancelled) return;
    [self showLoadError:@"Could not load the mobile UI. Start the engine and try again."];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    (void)webView; (void)navigation;
    if (error.code == NSURLErrorCancelled) return;
    [self showLoadError:@"Could not load the mobile UI. Start the engine and try again."];
}

@end
