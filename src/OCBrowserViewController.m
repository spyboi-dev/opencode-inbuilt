// OCBrowserViewController - FreeMilk's globe: a minimal in-app
// browser the agent and the user share to preview a built project.
#import "OCBrowserViewController.h"
#import <WebKit/WebKit.h>

@interface OCBrowserViewController () <WKNavigationDelegate, UITextFieldDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UITextField *addressField;
@end

@implementation OCBrowserViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(doneTapped)];

    self.addressField = [[UITextField alloc] init];
    self.addressField.placeholder = @"Enter a URL";
    self.addressField.borderStyle = UITextBorderStyleRoundedRect;
    self.addressField.keyboardType = UIKeyboardTypeURL;
    self.addressField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.addressField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.addressField.returnKeyType = UIReturnKeyGo;
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
    self.toolbarItems = @[back, forward, reload];
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
    if (!url) return;
    self.addressField.text = urlString;
    [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
    [self.addressField resignFirstResponder];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self loadAddress:textField.text];
    return YES;
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    (void)navigation;
    self.addressField.text = webView.URL.absoluteString;
}

@end
