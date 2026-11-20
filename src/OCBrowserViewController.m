// OCBrowserViewController - FreeMilk's globe: a minimal in-app
// browser the agent and the user share to preview a built project.
#import "OCBrowserViewController.h"
#import <WebKit/WebKit.h>

@interface OCBrowserViewController () <WKNavigationDelegate, UITextFieldDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UITextField *addressField;
@property (nonatomic, strong) UIBarButtonItem *backButton;
@property (nonatomic, strong) UIBarButtonItem *forwardButton;
@end

@implementation OCBrowserViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Browser";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(doneTapped)];

    self.addressField = [[UITextField alloc] init];
    self.addressField.placeholder = @"Enter a URL";
    self.addressField.borderStyle = UITextBorderStyleRoundedRect;
    self.addressField.keyboardType = UIKeyboardTypeURL;
    self.addressField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.addressField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.addressField.returnKeyType = UIReturnKeyGo;
    self.addressField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.addressField.delegate = self;
    self.addressField.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.addressField];

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config];
    self.webView.navigationDelegate = self;
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.webView];

    UIBarButtonItem *back = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.left"] style:UIBarButtonItemStylePlain target:self action:@selector(goBack)];
    UIBarButtonItem *forward = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"] style:UIBarButtonItemStylePlain target:self action:@selector(goForward)];
    UIBarButtonItem *reload = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reloadPage)];
    self.backButton = back;
    self.forwardButton = forward;
    self.toolbarItems = @[back, forward, reload];
    [self updateNavButtons];
    [self.navigationController setToolbarHidden:NO animated:NO];

    [NSLayoutConstraint activateConstraints:@[
        [self.addressField.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.addressField.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.addressField.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.addressField.heightAnchor constraintEqualToConstant:36],
        [self.webView.topAnchor constraintEqualToAnchor:self.addressField.bottomAnchor constant:8],
        [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
    ]];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.navigationController setToolbarHidden:YES animated:animated];
}

- (void)doneTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)goBack { [self.webView goBack]; }
- (void)goForward { [self.webView goForward]; }
- (void)reloadPage { [self.webView reload]; }

- (void)loadAddress:(NSString *)text {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!trimmed.length) return;
    NSString *urlString = trimmed;
    if (![urlString containsString:@"://"]) urlString = [@"https://" stringByAppendingString:urlString];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        // A bad address used to do nothing at all. Say so in the
        // view, the same way a failed load does.
        [self showLoadError:[NSError errorWithDomain:@"OCBrowser" code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: @"That address does not look like a web address."}]];
        return;
    }
    self.addressField.text = urlString;
    [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
    [self.addressField resignFirstResponder];
}

// Back and Forward used to stay tappable with nowhere to go.
// Grey them out when the web view cannot move that way.
- (void)updateNavButtons {
    self.backButton.enabled = self.webView.canGoBack;
    self.forwardButton.enabled = self.webView.canGoForward;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self loadAddress:textField.text];
    return YES;
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    (void)navigation;
    self.addressField.text = webView.URL.absoluteString;
    [self updateNavButtons];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    (void)navigation;
    [self showLoadError:error];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    (void)navigation;
    [self showLoadError:error];
}

// A page that fails to load never leaves a blank screen: the view
// itself says what happened and what to try next.
- (void)showLoadError:(NSError *)error {
    NSString *reason = error.localizedDescription ?: @"The page could not be opened.";
    NSString *html = [NSString stringWithFormat:
        @"<html><body style=\"background:#242424;color:#f2f2f2;font-family:-apple-system;font-size:16px;padding:40px 24px;text-align:center;\">"
        @"<p><b>Could not open this page.</b></p><p style=\"color:#aeaeae;\">%@</p>"
        @"<p style=\"color:#aeaeae;\">Check the address and try again.</p></body></html>", reason];
    [self.webView loadHTMLString:html baseURL:nil];
}

@end
