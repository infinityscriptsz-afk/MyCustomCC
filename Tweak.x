// MyCustomCC — dark liquid-glass Control Center for iPhone 6s (375x667), iOS 15.x rootless
// Injected into SpringBoard only.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

#pragma mark - Tunables

static const CGFloat kMCCCornerRadius   = 20.0;   // continuous corner radius for module containers
static const CGFloat kMCCBorderWidth    = 0.6;    // glossy rim thickness
static const CGFloat kMCCTopInset       = 28.0;   // space kept free above the grid (status bar)
static const CGFloat kMCCBottomInset    = 20.0;   // space kept free below the grid
static const CGFloat kMCCMaxHeightRatio = 0.88;   // grid never taller than 88% of screen (~587pt on 6s)
static const CGFloat kMCCMinScale       = 0.78;   // never shrink more than this
static const NSInteger kMCCOverlayTag   = 0x4D43; // tag for our glass overlay view

static const void *kMCCHandlerKey = &kMCCHandlerKey;
static BOOL gMCCDismissing = NO;

#pragma mark - Forward declarations

@interface CCUIContentModuleContainerView : UIView
@end

@interface CCUIModularControlCenterOverlayViewController : UIViewController
@end

@interface CCUIModuleCollectionViewController : UIViewController
@end

#pragma mark - Glass styling

static UIView *MCCFindMaterialView(UIView *container) {
    static Class materialClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ materialClass = NSClassFromString(@"MTMaterialView"); });
    if (!materialClass) return nil;
    for (UIView *sub in container.subviews) {
        if ([sub isKindOfClass:materialClass]) return sub;
    }
    return nil;
}

static void MCCStyleContainer(UIView *container) {
    CGRect b = container.bounds;
    if (CGRectIsEmpty(b)) return;

    CGFloat radius = MIN(kMCCCornerRadius, MIN(b.size.width, b.size.height) / 2.0);

    // Native blur stays; we only round it and tint on top.
    UIView *material = MCCFindMaterialView(container);
    if (material) {
        material.layer.cornerRadius = radius;
        material.layer.cornerCurve = kCACornerCurveContinuous;
        material.layer.masksToBounds = YES;
    }

    container.layer.cornerRadius = radius;
    container.layer.cornerCurve = kCACornerCurveContinuous;

    UIView *glass = [container viewWithTag:kMCCOverlayTag];
    if (!glass) {
        glass = [[UIView alloc] initWithFrame:b];
        glass.tag = kMCCOverlayTag;
        glass.userInteractionEnabled = NO; // never steal touches / gestures
        glass.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.38]; // dark smoked tint
        glass.layer.borderWidth = kMCCBorderWidth;
        glass.layer.borderColor = [UIColor colorWithWhite:0.88 alpha:0.30].CGColor; // silver rim
        glass.layer.cornerCurve = kCACornerCurveContinuous;

        // One static gradient = specular sheen. Cheap: no shadows, no extra blur, no rasterization.
        CAGradientLayer *sheen = [CAGradientLayer layer];
        sheen.colors = @[
            (id)[UIColor colorWithWhite:1.0 alpha:0.16].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.02].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.06].CGColor
        ];
        sheen.locations = @[@0.0, @0.55, @1.0];
        sheen.startPoint = CGPointMake(0.0, 0.0);
        sheen.endPoint = CGPointMake(0.7, 1.0);
        sheen.cornerCurve = kCACornerCurveContinuous;
        [glass.layer addSublayer:sheen];

        if (material && material.superview == container) {
            [container insertSubview:glass aboveSubview:material];
        } else {
            [container insertSubview:glass atIndex:0];
        }
    }

    if (!CGRectEqualToRect(glass.frame, b) || glass.layer.cornerRadius != radius) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        glass.frame = b;
        glass.layer.cornerRadius = radius;
        CALayer *sheen = glass.layer.sublayers.firstObject;
        sheen.frame = glass.bounds;
        sheen.cornerRadius = radius;
        [CATransaction commit];
    }
}

#pragma mark - Fit grid on one screen

static UIView *MCCFindGridView(UIView *view, Class containerClass, int depth) {
    if (!view || depth > 8) return nil;
    NSUInteger count = 0;
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:containerClass]) count++;
    }
    if (count >= 2) return view;
    for (UIView *sub in view.subviews) {
        UIView *found = MCCFindGridView(sub, containerClass, depth + 1);
        if (found) return found;
    }
    return nil;
}

static void MCCFitGrid(UIView *root) {
    if (!root || !root.window) return;
    Class containerClass = NSClassFromString(@"CCUIContentModuleContainerView");
    if (!containerClass) return;

    UIView *grid = MCCFindGridView(root, containerClass, 0);
    if (!grid || !grid.superview) return;

    // Content extent in the grid's own coordinates (unaffected by the grid's transform).
    CGFloat minY = CGFLOAT_MAX, maxY = -CGFLOAT_MAX;
    for (UIView *sub in grid.subviews) {
        if (![sub isKindOfClass:containerClass] || sub.hidden) continue;
        minY = MIN(minY, CGRectGetMinY(sub.frame));
        maxY = MAX(maxY, CGRectGetMaxY(sub.frame));
    }
    if (minY == CGFLOAT_MAX) return;
    CGFloat contentH = maxY - minY;
    if (contentH <= 1.0) return;

    CGFloat screenH = UIScreen.mainScreen.bounds.size.height; // 667 on iPhone 6s
    CGFloat target = MIN(screenH - kMCCTopInset - kMCCBottomInset, screenH * kMCCMaxHeightRatio);

    CGAffineTransform t = CGAffineTransformIdentity;
    if (contentH > target) {
        CGFloat s = MAX(kMCCMinScale, target / contentH);

        // Place the scaled content's top edge at kMCCTopInset (window coords -> superview coords).
        CGPoint desiredTop = [grid.superview convertPoint:CGPointMake(0, kMCCTopInset) fromView:nil];
        CGFloat midY = grid.bounds.origin.y + grid.bounds.size.height / 2.0;
        CGFloat topAfterScale = grid.center.y + (minY - midY) * s;
        CGFloat ty = desiredTop.y - topAfterScale;
        t = CGAffineTransformTranslate(CGAffineTransformIdentity, 0, ty);
        t = CGAffineTransformScale(t, s, s);
        // translate-then-scale in CGAffineTransform order: scale applies about the anchor, then ty shifts it.
        t = CGAffineTransformMake(s, 0, 0, s, 0, ty);
    }

    CGAffineTransform cur = grid.transform;
    if (fabs(cur.a - t.a) > 0.001 || fabs(cur.ty - t.ty) > 0.5) {
        grid.transform = t;
    }
}

#pragma mark - Safe dismissal

static void MCCDismiss(UIViewController *vc) {
    if (gMCCDismissing) return;
    gMCCDismissing = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ gMCCDismissing = NO; });

    BOOL done = NO;

    Class sbcc = NSClassFromString(@"SBControlCenterController");
    SEL shared = NSSelectorFromString(@"sharedInstance");
    SEL dismissAnimated = NSSelectorFromString(@"dismissAnimated:");
    if (sbcc && [sbcc respondsToSelector:shared]) {
        id ctrl = ((id (*)(id, SEL))objc_msgSend)(sbcc, shared);
        if (ctrl && [ctrl respondsToSelector:dismissAnimated]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(ctrl, dismissAnimated, YES);
            done = YES;
        }
    }

    if (!done && [vc respondsToSelector:dismissAnimated]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(vc, dismissAnimated, YES);
        done = YES;
    }

    if (!done) {
        [vc dismissViewControllerAnimated:YES completion:nil];
    }
}

@interface MCCGestureHandler : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIViewController *controller;
- (void)handle:(UIGestureRecognizer *)gesture;
@end

@implementation MCCGestureHandler

- (void)handle:(UIGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    UIViewController *vc = self.controller;
    if (vc) MCCDismiss(vc);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr shouldReceiveTouch:(UITouch *)touch {
    UIView *v = touch.view;
    UIView *stop = self.controller.view;
    Class containerClass = NSClassFromString(@"CCUIContentModuleContainerView");
    while (v && v != stop) {
        if ((containerClass && [v isKindOfClass:containerClass]) ||
            [v isKindOfClass:[UIControl class]] ||
            [NSStringFromClass([v class]) containsString:@"Slider"]) {
            return NO; // touches on modules/sliders belong to the modules
        }
        v = v.superview;
    }
    return YES; // empty background
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES; // never block native CC gestures
}

@end

static void MCCInstallDismissGestures(UIViewController *vc) {
    if (objc_getAssociatedObject(vc, kMCCHandlerKey)) return;

    MCCGestureHandler *handler = [MCCGestureHandler new];
    handler.controller = vc;
    objc_setAssociatedObject(vc, kMCCHandlerKey, handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:handler action:@selector(handle:)];
    tap.cancelsTouchesInView = NO;
    tap.delaysTouchesBegan = NO;
    tap.delaysTouchesEnded = NO;
    tap.delegate = handler;
    [vc.view addGestureRecognizer:tap];

    UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:handler action:@selector(handle:)];
    swipe.direction = UISwipeGestureRecognizerDirectionUp;
    swipe.cancelsTouchesInView = NO;
    swipe.delaysTouchesBegan = NO;
    swipe.delegate = handler;
    [vc.view addGestureRecognizer:swipe];
}

#pragma mark - Hooks

%group Containers
%hook CCUIContentModuleContainerView
- (void)layoutSubviews {
    %orig;
    MCCStyleContainer(self);
}
%end
%end

%group Overlay
%hook CCUIModularControlCenterOverlayViewController
- (void)viewDidLoad {
    %orig;
    MCCInstallDismissGestures(self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    MCCFitGrid(self.view);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    gMCCDismissing = NO; // never leave the dismiss guard latched
}
%end
%end

%group Collection
%hook CCUIModuleCollectionViewController
- (void)viewDidLayoutSubviews {
    %orig;
    MCCFitGrid(self.view);
}
%end
%end

%ctor {
    @autoreleasepool {
        %init(Containers);
        %init(Overlay);
        %init(Collection);
    }
}
