// OCWebUIViewController - the official OpenCode mobile web UI, in a native shell.
// The server (2.3.0, packages/app) serves its own UI at /: every path that is
// not /api/*, /auth/* or /openapi.json returns the app shell, so this WKWebView
// loading http://127.0.0.1:4096 shows the same mobile UI the official mobile
// app shows, at phone width. The server's HTTP Basic auth is answered from
// the Keychain password the native UI already uses, via the navigation
// delegate, so the UI never shows a sign-in screen. The CLI Terminal view
// stays alongside this: Engine tab -> Show terminal.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface OCWebUIViewController : UIViewController
- (instancetype)initWithSessionID:(nullable NSString *)sessionID;
@end

NS_ASSUME_NONNULL_END
