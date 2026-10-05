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
//  颜色语义（v0.2.0，老板定调）：
//   红 = **我们强制让它充** —— 拦下了系统的停充写，正在阻止断流。
//        真机场景：温度高时系统会把充电电流砍到 0mA，我们顶住让它继续充到满，此时亮红。
//   绿 = **电池自己的颜色** —— 系统原生充电，我们没干预。
//   不充电 = 两个模式都一律不显示（拔线即消失）
//
//  模式（只有两个，见 kFFShowModeAlways / kFFShowModeForceOnly）：
//   常显   ：只要在充电就显示（绿打底，我们介入时转红）
//   仅强制 ：只有我们真的拦下停充时才显示红点；我们没干活就不显示
//

#import <UIKit/UIKit.h>
#import "FFPaths.h"

@interface FFIndicator : NSObject
+ (instancetype)shared;
// 窗口是否已成功创建（供设置页/状态文件判断「dylib 跑了但窗口建不出来」）
// 注意：只读指针，后台线程调用安全。
+ (BOOL)windowCreated;
// 窗口是否**真正可见**（已创建且未被 hidden）。
// 为什么单列：windowCreated=YES 只说明窗口对象存在；若它处于 hidden=YES，
// 则逻辑上"该显示"但屏幕上什么都看不到。这两种情况必须能区分，
// 否则排查「圆点不亮」时又得在"逻辑判定"与"窗口可见性"之间反复猜。
// 只读 BOOL，后台线程调用安全。
+ (BOOL)windowVisible;
// 当前 scene 的 activationState（1=ForegroundActive 2=ForegroundInactive
// 3=Background 4=Unattached；读不到场景返回 0）。
// 场景不在 ForegroundActive 时 ensureWindow 会拒绝建窗 → 圆点建不出来，
// 单列此值用于一眼确认「窗口建不出来」是不是场景状态造成的。
+ (NSInteger)sceneState;
// 依据当前状态更新圆点：显示/隐藏 + 颜色
//   charging: 是否正在充电（为 NO 时两个模式都不显示）
//   active  : 我们的强制充电这一轮有没有真的拦下系统停充（sessionBlocked > 0）
//   mode    : kFFShowModeAlways / kFFShowModeForceOnly（其余值按「仅强制」处理 —— 宁可不显示）
- (void)updateWithCharging:(BOOL)charging
                    active:(BOOL)active
                      mode:(NSInteger)mode;
@end

@implementation FFIndicator

static UIWindow *g_win = nil;
static UIView  *g_dot = nil;
static __weak UIWindowScene *g_scene = nil;

// 当前有效场景；若已有窗口的场景已失效则返回 nil（触发上层重建）
static UIWindowScene *ff_currentScene(void) {
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        if (ws.activationState == UISceneActivationStateForegroundActive) return ws;
    }
    return nil;
}

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
        // 只在主线程建窗；此处只做标记，实际创建推迟到首次 update（那时已在主线程）
    }
    return self;
}

+ (instancetype)shared {
    static FFIndicator *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[FFIndicator alloc] init]; });
    return inst;
}

+ (BOOL)windowCreated {
    return (g_win != nil);
}

+ (BOOL)windowVisible {
    return (g_win != nil && !g_win.hidden);
}

+ (NSInteger)sceneState {
    UIWindowScene *ws = ff_currentScene();
    return ws ? (NSInteger)ws.activationState : 0;
}

- (void)ensureWindow {
    // 已有窗口但场景已失效（SB 重启/scene 切换）→ 丢弃重建，防悬空窗口
    if (g_win && !g_scene) {
        g_win.hidden = YES;
        g_win = nil; g_dot = nil;
    }
    if (g_win) return;
    @try {
        // UIKit 必须在主线程操作（SpringBoard 崩溃黑屏的根因之一）
        if (![NSThread isMainThread]) {
            dispatch_sync(dispatch_get_main_queue(), ^{ [self ensureWindow]; });
            return;
        }
        UIWindowScene *scene = ff_currentScene();
        if (!scene) return;                       // 场景未就绪，等下次调用
        g_scene = scene;                          // weak 引用，失效可被发现
        CGFloat cx = ff_coord(kFFDotXKey, kFFDotXDefault);
        CGFloat cy = ff_coord(kFFDotYKey, kFFDotYDefault);
        g_win = [[UIWindow alloc] initWithWindowScene:scene];
        g_win.windowLevel = UIWindowLevelAlert + 1.0;   // 盖过灵动岛窗口
        g_win.backgroundColor = [UIColor clearColor];
        g_win.userInteractionEnabled = NO;             // 不吃触摸
        // 只覆盖圆点所在小区域，不占满屏（降低异常时的影响面）
        g_win.frame = CGRectMake(cx - 12, cy - 12, 24, 24);
        g_dot = [[UIView alloc] initWithFrame:CGRectMake(8, 8, 8, 8)];
        g_dot.backgroundColor = [UIColor colorWithRed:0.0 green:0.8 blue:0.4 alpha:1.0];
        g_dot.layer.cornerRadius = 4.0;
        g_dot.layer.masksToBounds = YES;
        [g_win addSubview:g_dot];
        g_win.hidden = YES;                          // 默认隐藏，由 update 决定
    } @catch (NSException *e) {
        // 场景/窗口创建异常 → 完全降级：丢弃半成品，后续重试
        g_win = nil; g_dot = nil; g_scene = nil;
    }
}

// 把圆点窗口移到指定坐标（小窗口 24x24，圆点居中 8x8）
- (void)moveToCoord:(CGFloat)cx cy:(CGFloat)cy {
    if (!g_win) return;
    g_win.frame = CGRectMake(cx - 12, cy - 12, 24, 24);
    g_dot.frame = CGRectMake(8, 8, 8, 8);
}

- (void)updateWithCharging:(BOOL)charging
                    active:(BOOL)active
                      mode:(NSInteger)mode {
    // ⚠️ 必须切主线程：调用方（SpringBoard 侧轮询）跑在后台队列，
    //    跨线程操作 UIKit 会让 SpringBoard 崩溃循环 → 黑屏。
    dispatch_async(dispatch_get_main_queue(), ^{
        [self ensureWindow];
        if (!g_win) return;

        if (mode == kFFShowModeOff) {                 // 模式3：关闭（代码级兜底）
            if (!g_win.hidden) g_win.hidden = YES;
            return;
        }

        // ⚠️ 不充电 → 两个模式都一律不显示（老板明确要求：拔线即消失）
        if (!charging) {
            if (!g_win.hidden) g_win.hidden = YES;
            return;
        }

        BOOL show;
        if (mode == kFFShowModeAlways) {
            show = YES;             // 常显：充电中就显示
        } else {
            // 仅强制（默认，含任何未识别的旧值）—— 只有一个判断点：
            // 我们真在干活才显示。宁可不显示，也不要亮一个"看起来在工作"的点。
            show = active;
        }
        if (!show) {
            if (!g_win.hidden) g_win.hidden = YES;
            return;
        }

        // 坐标每次刷新都重算（设置页可改）
        [self moveToCoord:ff_coord(kFFDotXKey, kFFDotXDefault)
                       cy:ff_coord(kFFDotYKey, kFFDotYDefault)];
        // 只有两个颜色：
        //   红 = 我们正在拦系统降流（强制快充确实在工作）
        //   绿 = 系统原生充电（我们没介入，系统自己就充得很好）
        g_dot.backgroundColor = active
            ? [UIColor colorWithRed:1.00 green:0.23 blue:0.19 alpha:1.0]   // 红
            : [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0];  // 绿
        if (g_win.hidden) g_win.hidden = NO;
    });
}

@end
