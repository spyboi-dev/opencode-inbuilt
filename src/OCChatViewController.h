// OCChatViewController - chat thread for one OpenCode session.
// Messages come from GET /api/session/{id}/message, live updates arrive
// on the GET /api/event SSE stream (refetch on any event for this session),
// plus a poll while a reply is pending so the thread updates even if
// the stream drops. Tool calls render as tool cards, permission requests
// as an approve/deny sheet, diffs in a diff view with Revert.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface OCChatViewController : UIViewController
- (instancetype)initWithSession:(NSDictionary *)session;
@end

NS_ASSUME_NONNULL_END
