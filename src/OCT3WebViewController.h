// OCT3WebViewController - the chat UI: t3code's web UI in a
// WKWebView shell, served by the t3 server the engine starts in
// the guest (127.0.0.1:3773, via the localhost proxy). The t3
// server is wired to our OpenCode server on 4096 (see the t3
// bootstrap in OCEngine), so the UI drives the same sessions.
// First open per engine run waits for the one-time pairing URL
// the bootstrap captured (~/.t3-pairing-url), polling every 2 s
// for up to 5 minutes while the t3 server starts (first boot
// downloads t3, ~177 MB); later opens load the t3 root,
// authenticated by the t3_session cookie. If the engine reports
// the t3 bootstrap failed, the error names the failing step.
// Never a pairing/connect/QR/sign-in screen: the pairing URL
// is loaded programmatically. The t3 server uses cookie auth,
// not HTTP Basic, so there is no authentication-challenge
// handler here.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface OCT3WebViewController : UIViewController
@end

NS_ASSUME_NONNULL_END
