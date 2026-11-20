// OCDesktopViewController - see OCDesktopViewController.h.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "OCDesktopViewController.h"
#import "KernGlue.h"
#import "OCEngine.h"

// Linux input event codes (evdev) for the keys the iOS keyboard can
// send. Letters and digits follow the standard table; anything
// outside the table below is ignored for now.
static uint16_t KeyCodeForChar(unichar c, BOOL *shift) {
    *shift = NO;
    if (c >= 'a' && c <= 'z') {
        static const uint16_t letters[] = {
            30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50, 49,
            24, 25, 16, 19, 31, 20, 22, 47, 17, 45, 21, 44};
        return letters[c - 'a'];
    }
    if (c >= 'A' && c <= 'Z') {
        *shift = YES;
        BOOL ignored = NO;
        return KeyCodeForChar((unichar)(c - 'A' + 'a'), &ignored);
    }
    if (c >= '1' && c <= '9') {
        static const uint16_t digits[] = {2, 3, 4, 5, 6, 7, 8, 9, 10};
        return digits[c - '1'];
    }
    switch (c) {
        case '0': return 11;
        case ' ': return 57;
        case '\n': return 28;
        case '-': return 12;
        case '=': return 13;
        case ',': return 51;
        case '.': return 52;
        case '/': return 53;
        case ';': return 39;
        case '\'': return 40;
        case '[': return 26;
        case ']': return 27;
        case '\\': return 43;
        case '`': return 41;
        case '!': *shift = YES; return 2;
        case '@': *shift = YES; return 3;
        case '#': *shift = YES; return 4;
        case '$': *shift = YES; return 5;
        case '%': *shift = YES; return 6;
        case '^': *shift = YES; return 7;
        case '&': *shift = YES; return 8;
        case '*': *shift = YES; return 9;
        case '(': *shift = YES; return 10;
        case ')': *shift = YES; return 11;
        case '_': *shift = YES; return 12;
        case '+': *shift = YES; return 13;
        case '<': *shift = YES; return 51;
        case '>': *shift = YES; return 52;
        case '?': *shift = YES; return 53;
        case ':': *shift = YES; return 39;
        case '"': *shift = YES; return 40;
        case '{': *shift = YES; return 26;
        case '}': *shift = YES; return 27;
        case '|': *shift = YES; return 43;
        case '~': *shift = YES; return 41;
        default: return 0;
    }
}

@interface OCDesktopViewController () <UITextFieldDelegate>
@property (nonatomic, strong) UITextField *keyField;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, strong) NSMutableDictionary<NSValue *, NSNumber *> *touchSlots;
@property (nonatomic, assign) uint32_t nextSlot;
@end

@implementation OCDesktopViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Desktop";
    self.view.backgroundColor = [UIColor blackColor];
    self.touchSlots = [NSMutableDictionary dictionary];

    // Invisible field that summons the iOS keyboard. Typed text is
    // forwarded as key codes; nothing is ever inserted into it.
    self.keyField = [[UITextField alloc] initWithFrame:CGRectZero];
    self.keyField.delegate = self;
    self.keyField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.keyField.autocorrectionType = UITextAutocorrectionTypeNo;
    [self.view addSubview:self.keyField];

    self.hintLabel = [[UILabel alloc] init];
    self.hintLabel.text = @"Tap to click. Use Keyboard to type.";
    self.hintLabel.font = [UIFont systemFontOfSize:13];
    self.hintLabel.textColor = [UIColor whiteColor];
    self.hintLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.5];
    self.hintLabel.layer.cornerRadius = 8;
    self.hintLabel.layer.masksToBounds = YES;
    self.hintLabel.textAlignment = NSTextAlignmentCenter;
    self.hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.hintLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.hintLabel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.hintLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.hintLabel.widthAnchor constraintEqualToConstant:280],
        [self.hintLabel.heightAnchor constraintEqualToConstant:30],
    ]];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Keyboard" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(keyboardTapped)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Move the guest framebuffer view into this screen. run() keeps
    // the same view the whole time; only its parent changes.
    MTKView *guestView = [OCKernGlue shared].guestView;
    if (guestView) {
        guestView.frame = self.view.bounds;
        guestView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.view insertSubview:guestView atIndex:0];
    }
    if (![OCKernGlue shared].booted) {
        self.hintLabel.text = @"Desktop is not up yet. Start the engine from the Engine tab.";
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.hintLabel.hidden = YES;
    });
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.keyField resignFirstResponder];
    // Park the framebuffer view behind the app again, so run() keeps
    // its view while this screen is gone.
    [[OCKernGlue shared] parkGuestView];
}

- (void)keyboardTapped {
    if ([self.keyField isFirstResponder]) {
        [self.keyField resignFirstResponder];
    } else {
        [self.keyField becomeFirstResponder];
    }
}

#pragma mark - Touch input

- (void)sendTouch:(UITouch *)touch pressed:(BOOL)pressed {
    CGPoint p = [touch locationInView:self.view];
    CGFloat w = MAX(self.view.bounds.size.width, 1);
    CGFloat h = MAX(self.view.bounds.size.height, 1);
    uint32_t x = (uint32_t)MAX(0, MIN(32767, (int)(p.x / w * 32767)));
    uint32_t y = (uint32_t)MAX(0, MIN(32767, (int)(p.y / h * 32767)));
    NSValue *key = [NSValue valueWithNonretainedObject:touch];
    NSNumber *slot = self.touchSlots[key];
    if (!slot) {
        if (!pressed) return;
        if (self.nextSlot >= 10) return;
        slot = @(self.nextSlot++);
        self.touchSlots[key] = slot;
    }
    [[OCKernGlue shared] sendTouchSlot:slot.unsignedIntValue x:x y:y pressed:pressed];
    if (!pressed) [self.touchSlots removeObjectForKey:key];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    for (UITouch *t in touches) [self sendTouch:t pressed:YES];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    for (UITouch *t in touches) [self sendTouch:t pressed:YES];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    for (UITouch *t in touches) [self sendTouch:t pressed:NO];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    for (UITouch *t in touches) [self sendTouch:t pressed:NO];
}

#pragma mark - Keyboard input

- (void)sendChar:(unichar)c {
    if (c == '\n') {
        [[OCKernGlue shared] sendKeyCode:28 pressed:YES];
        [[OCKernGlue shared] sendKeyCode:28 pressed:NO];
        return;
    }
    BOOL shift = NO;
    uint16_t code = KeyCodeForChar(c, &shift);
    if (!code) return;
    if (shift) [[OCKernGlue shared] sendKeyCode:42 pressed:YES];
    [[OCKernGlue shared] sendKeyCode:code pressed:YES];
    [[OCKernGlue shared] sendKeyCode:code pressed:NO];
    if (shift) [[OCKernGlue shared] sendKeyCode:42 pressed:NO];
}

- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string {
    (void)textField;
    if (string.length == 0 && range.length == 1) {
        // Backspace.
        [[OCKernGlue shared] sendKeyCode:14 pressed:YES];
        [[OCKernGlue shared] sendKeyCode:14 pressed:NO];
        return NO;
    }
    for (NSUInteger i = 0; i < string.length; i++) {
        [self sendChar:[string characterAtIndex:i]];
    }
    return NO;
}

@end
