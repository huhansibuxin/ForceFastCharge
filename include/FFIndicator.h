//
//  FFIndicator.h — 状态栏小圆点指示器（SpringBoard 侧专用）
//
//  实现方式对齐本机 TGK（TrollGestureKiller v1.0.64）已验证方案：
//   · 独立 UIWindow，windowLevel = UIWindowLevelAlert + 1.0
//     （TGK 踩坑记录：StatusBar+5 会被 SBDynamicIslandWindow 盖住，attached 但看不见）
//   · userInteractionEnabled = NO，完全不吃触摸，不影响系统手势
//   · 坐标从偏好读取、可配置；空/0/非法一律回退默认，避免圆点飞出屏幕
//   · 全程 @try/@catch 兜底，任何异常静默失败，绝不影响 SpringBoard
//
//  颜色语义（四态一眼可辨）：
//   灰 = 未充电且未强制        （默认不显示，此处仅作兜底）
//   蓝 = 正在充电，但强制快充未开（正常充电）
//   绿 = 强制快充生效中        （已吞掉系统降流写）
//   红 = 强制快充 + 温控覆盖   （高风险档，吞掉了温控派生键）
//

#import <UIKit/UIKit.h>
#import "FFPaths.h"

@interface FFIndicator : NSObject
+ (instancetype)shared;
// 依据当前状态更新圆点：显示/隐藏 + 颜色
// charging: 当前是否正在充电；forceOn: 强制快充是否开启；thermalOn: 温控覆盖是否开启
- (void)updateWithForceOn:(BOOL)forceOn
                 thermalOn:(BOOL)thermalOn
                 charging:(BOOL)charging;
@end

@implementation FFIndicator

static UIWindow *g_win = nil;
static UIView  *g_dot = nil;

// 读偏好里的坐标；无效/0/空 → 回退默认（TGK 同款防护）
static CGFloat ff_coord(NSString *key, CGFloat def) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:FFPrefPath()];
        id v = d[key];
        if (v) {
            CGFloat val = [v floatValue];
            if (val > 0.0) return val;
        }
    } @catch (NSException *e) {}
    return def;
}

- (instancetype)init {
    if (self = [super init]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self ensureWindow]; });
    }
    return self;
}

+ (instancetype)shared {
    static FFIndicator *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[FFIndicator alloc] init]; });
    return inst;
}

- (UIWindowScene *)activeScene {
    UIWindow *kw = [UIApplication sharedApplication].keyWindow;
    if (kw && [kw.windowScene isKindOfClass:[UIWindowScene class]]) {
        return (UIWindowScene *)kw.windowScene;
    }
    UIWindowScene *fallback = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        if (ws.activationState == UISceneActivationStateForegroundActive) return ws;
        if (!fallback) fallback = ws;
    }
    return fallback;
}

- (void)ensureWindow {
    if (g_win) return;
    @try {
        UIWindowScene *scene = [self activeScene];
        if (!scene) return;                       // 场景未就绪，等下次调用
        CGFloat cx = ff_coord(kFFDotXKey, kFFDotXDefault);
        CGFloat cy = ff_coord(kFFDotYKey, kFFDotYDefault);
        g_win = [[UIWindow alloc] initWithWindowScene:scene];
        g_win.windowLevel = UIWindowLevelAlert + 1.0;   // 盖过灵动岛窗口
        g_win.backgroundColor = [UIColor clearColor];
        g_win.userInteractionEnabled = NO;             // 不吃触摸
        g_win.frame = [UIScreen mainScreen].bounds;
        g_dot = [[UIView alloc] initWithFrame:CGRectMake(cx - 4, cy - 4, 8, 8)];
        g_dot.backgroundColor = [UIColor colorWithRed:0.0 green:0.8 blue:0.4 alpha:1.0];
        g_dot.layer.cornerRadius = 4.0;
        g_dot.layer.masksToBounds = YES;
        [g_win addSubview:g_dot];
        g_win.hidden = YES;                          // 默认隐藏，由 update 决定
    } @catch (NSException *e) {
        g_win = nil; g_dot = nil;
    }
}

- (void)updateWithForceOn:(BOOL)forceOn
                 thermalOn:(BOOL)thermalOn
                 charging:(BOOL)charging {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self ensureWindow];
        if (!g_win) return;

        // 读显示模式
        NSInteger mode = kFFShowModeAuto;
        @try {
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:FFPrefPath()];
            id v = d[kFFIndicatorModeKey];
            if ([v isKindOfClass:[NSNumber class]]) mode = [v integerValue];
            else if ([v isKindOfClass:[NSString class]]) mode = [v integerValue];
        } @catch (NSException *e) {}

        if (mode == kFFShowModeOff) {                 // 模式3：完全关闭
            if (!g_win.hidden) g_win.hidden = YES;
            return;
        }

        BOOL show = NO;
        UIColor *c = nil;
        if (forceOn) {
            if (thermalOn) {
                // 红：强制 + 温控覆盖（最高优先级，任何模式下只要高风险档就显示）
                c = [UIColor colorWithRed:1.0 green:0.25 blue:0.2 alpha:1.0];
                show = YES;
            } else if (mode == kFFShowModeAuto) {
                // 自动：充电中蓝色、未充电绿色
                c = charging ? [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:1.0]
                             : [UIColor colorWithRed:0.0 green:0.8 blue:0.4 alpha:1.0];
                show = YES;
            } else if (mode == kFFShowModeAlways || mode == kFFShowModeForceOnly) {
                // 常显 / 仅强制：都是绿色
                c = [UIColor colorWithRed:0.0 green:0.8 blue:0.4 alpha:1.0];
                show = YES;
            }
        }
        // 未开启强制快充：自动模式不显示；常显模式也不显示（强制都没开）
        if (!show) {
            if (!g_win.hidden) g_win.hidden = YES;
            return;
        }
        g_dot.backgroundColor = c;
        if (g_win.hidden) g_win.hidden = NO;
    });
}

@end
