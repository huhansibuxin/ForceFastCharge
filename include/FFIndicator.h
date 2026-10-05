//
//  FFIndicator.h — 状态栏小圆点指示器（SpringBoard 侧专用）
//
//  实现方式对齐本机 TGK（TrollGestureKiller v1.0.64）已验证方案：
//   · 独立 UIWindow，windowLevel = UIWindowLevelAlert + 100
//     （TGK 踩坑记录：StatusBar+5 会被 SBDynamicIslandWindow 盖住，attached 但看不见）
//   · userInteractionEnabled = NO，完全不吃触摸，不影响系统手势
//   · 坐标从偏好读取、可配置；空/0/非法一律回退默认，并 clamp 进屏幕
//   · 全程 @try/@catch 兜底，任何异常静默失败，绝不影响 SpringBoard
//
//  颜色语义（v0.4.0，老板定调 + 实机修正）：
//   红 = **我们强制让它充** —— 通过 SMC 把系统关掉的充电开关打开了，正在阻止断流。
//        真机场景：温度高时系统会把充电电流砍到 0mA，我们把它救回来，此时亮红。
//   橙 = **有线，但系统没在充电** —— 我们没干预（模式不对/温度超上限）或干预失败。
//        ⭐ v0.4.0 新增。为什么必须有它：本机实测"插着线却 0mA"是常态，
//        没有这一色就分不清"系统充得好好的"与"系统压根不给充"。
//   绿 = **电池自己的颜色** —— 系统原生充电，我们没干预。
//   不显示 = 没插线（两个模式都一致）；或「仅强制」模式下我们没在干活。
//
//  ⚠️ 是否显示的主判据（v0.4.0 起）是 **ExternalConnected（有没有插线）**，
//    不再是 IsCharging（系统有没有在充）。原因见 updateWithExt: 的声明处。
//
//  模式（只有两个，见 kFFShowModeAlways / kFFShowModeForceOnly）：
//   常显   ：只要插着线就显示（绿打底 → 系统停充转橙 → 我们介入转红）
//   仅强制 ：只有我们真的在干活时才显示红点；我们没干活就不显示
//
//  ⭐ v0.3.0 关键修复（老板实机：「开了常显，插上还是不显示」）
//   根因：刷新入口 refreshIndicator() 把「状态无变化就 return」放在了
//        updateWithCharging() 之前，而**建窗只发生在 updateWithCharging 里**。
//        SB 刚重启时 scene 尚未就绪 → 首次建窗失败 → 之后插着充电器状态恒稳
//        → 每 2s 的 tick 全部提前 return → 窗口永不重试创建。
//        实测证据：sb.log 里 charging=1 的 47 秒内只有 2 条 refresh（都 win=0），
//        随后 47 秒静默；直到拔线（charging 1→0，状态变化）才把窗口建出来。
//   修法：① 新增 ensureWindowAsync —— 刷新入口**无条件**先请求建窗（幂等），
//            把「建窗」与「状态变化」彻底解耦；
//         ② ff_currentScene() 放宽：ForegroundActive → 任意 UIWindowScene →
//            从已有 UIWindow 反查 windowScene（不再挑食）；
//         ③ +sceneState/+diagLine 改为读**主线程缓存**：后台线程直接读
//            [UIApplication sharedApplication] 有 main-thread-only 限制，
//            实测恒返回 0 场景 —— 这个假值曾把人往"场景不对"的沟里带；
//         ④ 窗口补一个空 rootViewController（scene 化 UIWindow 没有 rootVC 时
//            在部分 iOS 版本不参与合成，表现为 hidden=NO 却看不见）；
//         ⑤ 坐标 clamp 进屏幕，杜绝越界。
//

#import <UIKit/UIKit.h>
#import "FFPaths.h"

@interface FFIndicator : NSObject
+ (instancetype)shared;
// 窗口是否已成功创建（供设置页/状态文件判断「dylib 跑了但窗口建不出来」）
// 注意：只读缓存，后台线程调用安全。
+ (BOOL)windowCreated;
// 窗口是否**真正可见**（已创建且未被 hidden）。
// 为什么单列：windowCreated=YES 只说明窗口对象存在；若它处于 hidden=YES，
// 则逻辑上"该显示"但屏幕上什么都看不到。这两种情况必须能区分，
// 否则排查「圆点不亮」时又得在"逻辑判定"与"窗口可见性"之间反复猜。
// 只读缓存，后台线程调用安全。
+ (BOOL)windowVisible;
// 当前 scene 的 activationState（1=ForegroundActive 2=ForegroundInactive
// 3=Background 4=Unattached；读不到场景返回 0）。
// ⚠️ v0.3.0：这是一个**主线程缓存值**。后台线程直接读 UIApplication 拿不到
//    connectedScenes（main-thread-only），恒返回 0，会把排查带偏。
+ (NSInteger)sceneState;
// 一行窗口诊断串：lvl=层级 hid=隐藏 alpha=透明度 fr=窗口frame
// ws=是否挂到 windowScene rootVC=是否有 rootViewController dotSup=圆点是否在视图树里
// 用途：一眼区分「逻辑判定不该显示」与「建了却看不见」。
// 只读缓存，后台线程调用安全。
+ (NSString *)diagLine;
// ⭐ v0.3.0：幂等地请求建窗（内部自己切主线程，不阻塞调用方）。
// 由 2s tick 每轮调用：场景未就绪导致的首次建窗失败能自动重试，
// 而不必傻等下一次"状态变化"（v0.2.2 实机「插上不亮」的根因）。
- (void)ensureWindowAsync;
// 依据当前状态更新圆点：显示/隐藏 + 颜色
//   ext     : 是否有外部电源 —— ⭐ v0.4.0 起这是**是否显示的主判据**
//             为什么不再用 charging：本机实测系统经常「有线但拒绝充电」
//             （76% / 0mA / ncr=16），而那恰恰是老板最需要看见的状态；
//             用 charging 当判据会出现"最该显示的时候恰好不显示"。
//   charging: 系统是否正在充电（决定 绿 / 橙）
//   active  : 我们的强制充电这一轮有没有真的生效（决定 红）
//   mode    : kFFShowModeAlways / kFFShowModeForceOnly（其余值按「仅强制」处理）
- (void)updateWithExt:(BOOL)ext
             charging:(BOOL)charging
               active:(BOOL)active
                 mode:(NSInteger)mode;
@end

// 私有方法前置声明（两者都在 @implementation 内定义，但调用点在前）
@interface FFIndicator ()
- (void)ensureWindow;
- (void)moveToCoord:(CGFloat)cx cy:(CGFloat)cy;
@end

@implementation FFIndicator

static UIWindow *g_win = nil;
static UIView  *g_dot = nil;
static __weak UIWindowScene *g_scene = nil;
// 以下三个缓存**只由主线程写**，后台线程只读 —— 规避 UIKit 的非主线程访问限制。
static NSInteger g_sceneStateCache = 0;
// ⚠️ 刻意用一个独立的 volatile BOOL 给后台线程判「窗口在不在」：
//    直接读 static 对象指针（g_win）与之并发写是未定义行为（可能读到已释放地址）。
//    后台只读这个纯 BOOL，绝不解引用 UIKit 对象。
static volatile BOOL g_winExists     = NO;
static BOOL      g_winHiddenCache  = YES;
static NSString *g_diagCache       = @"win=nil";

// 场景获取（v0.3.0 放宽，不再挑食）：
//   ① ForegroundActive 的 UIWindowScene（首选，正常态）
//   ② 任意 UIWindowScene（ForegroundInactive / Background 也接受 —— 圆点是浮层，
//      iOS 13+ 没有 windowScene 的窗口根本不参与渲染，有 scene 就有机会）
//   ③ 从系统已有窗口反查 windowScene（connectedScenes 偶尔滞后/为空）
static UIWindowScene *ff_currentScene(void) {
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        UIWindowScene *fallback = nil;
        for (UIScene *s in app.connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)s;
            if (ws.activationState == UISceneActivationStateForegroundActive) return ws;
            if (!fallback) fallback = ws;
        }
        if (fallback) return fallback;
        for (UIWindow *w in app.windows) {
            if (w.windowScene) return w.windowScene;
        }
    } @catch (NSException *e) {}
    return nil;
}

// 主线程刷新场景状态缓存（供后台线程的 +sceneState 读）
static void ff_refreshSceneStateCache(void) {
    if (![NSThread isMainThread]) return;
    NSInteger best = 0;
    @try {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            NSInteger st = (NSInteger)((UIWindowScene *)s).activationState;
            if (st == UISceneActivationStateForegroundActive) { best = st; break; }
            if (best == 0) best = st;
        }
    } @catch (NSException *e) {}
    g_sceneStateCache = best;
}

// 主线程刷新窗口诊断缓存
static void ff_refreshDiagCache(void) {
    if (![NSThread isMainThread]) return;
    if (!g_win) { g_diagCache = @"win=nil"; return; }
    @try {
        CGRect f = g_win.frame;
        CGRect d = g_dot ? g_dot.frame : CGRectZero;
        g_diagCache = [NSString stringWithFormat:
            @"lvl=%.0f hid=%d alpha=%.2f win=(%.0f,%.0f,%.0f,%.0f) dot=(%.0f,%.0f,%.0f,%.0f) ws=%d rootVC=%d dotSup=%d",
            g_win.windowLevel, (int)g_win.hidden, g_win.alpha,
            f.origin.x, f.origin.y, f.size.width, f.size.height,
            d.origin.x, d.origin.y, d.size.width, d.size.height,
            (g_win.windowScene != nil), (g_win.rootViewController != nil),
            (g_dot.superview != nil)];
    } @catch (NSException *e) { g_diagCache = @"diag-fail"; }
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

// 把坐标夹进屏幕（主线程调用）—— 防老板填了越界值导致圆点"显示在屏幕外"
static CGFloat ff_clampX(CGFloat x) {
    CGRect b = [UIScreen mainScreen].bounds;
    if (b.size.width < 1) return x;
    if (x < 12) return 12;
    if (x > b.size.width - 12) return b.size.width - 12;
    return x;
}
static CGFloat ff_clampY(CGFloat y) {
    CGRect b = [UIScreen mainScreen].bounds;
    if (b.size.height < 1) return y;
    if (y < 12) return 12;
    if (y > b.size.height - 12) return b.size.height - 12;
    return y;
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
    return g_winExists;
}

+ (BOOL)windowVisible {
    return (g_winExists && !g_winHiddenCache);
}

+ (NSInteger)sceneState {
    return g_sceneStateCache;
}

+ (NSString *)diagLine {
    return g_diagCache ?: @"win=nil";
}

- (void)ensureWindowAsync {
    if (g_winExists) return;                    // 后台线程只读 volatile BOOL，不解引用对象
    // ⚠️ 必须 async（不能 sync）：调用方跑在全局队列的 tick 里，
    //    sync 到主线程一旦主线程正等这个队列就会死锁（SB 卡死 = 黑屏）。
    //    async 不阻塞，本 tick 没建好下个 tick（2s 后）继续重试。
    dispatch_async(dispatch_get_main_queue(), ^{
        @try { [self ensureWindow]; } @catch (NSException *e) {}
    });
}

- (void)ensureWindow {
    // ⚠️ 主线程检查放最前：下面每一行都要碰 UIKit（hidden/windowScene/frame），
    //    跨线程访问正是 SpringBoard 崩溃黑屏的经典成因。
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            @try { [self ensureWindow]; } @catch (NSException *e) {}
        });
        return;
    }
    // ------- 以下全程主线程 -------
    // 已有窗口但场景已失效（SB 重启/scene 切换）→ 丢弃重建，防悬空窗口
    if (g_win && !g_scene) {
        g_win.hidden = YES;
        g_win = nil; g_dot = nil;
        g_winExists = NO;
        g_winHiddenCache = YES;
        g_diagCache = @"win=nil";
    }
    if (g_win) { ff_refreshDiagCache(); return; }
    @try {
        ff_refreshSceneStateCache();
        UIWindowScene *scene = ff_currentScene();
        if (!scene) {
            // 场景确实还没就绪（SB 启动早期）—— 记下来，下次 tick 重试
            g_diagCache = @"no-scene";
            return;
        }
        g_scene = scene;                          // weak 引用，失效可被发现
        CGFloat cx = ff_clampX(ff_coord(kFFDotXKey, kFFDotXDefault));
        CGFloat cy = ff_clampY(ff_coord(kFFDotYKey, kFFDotYDefault));
        g_win = [[UIWindow alloc] initWithWindowScene:scene];
        g_winExists = YES;
        // ⚠️ Alert+100：必须稳稳盖过状态栏窗口（StatusBar=1000）与灵动岛窗口，
        //    同时低于系统级弹层，不干扰系统 UI。
        g_win.windowLevel = UIWindowLevelAlert + 100.0;
        g_win.backgroundColor = [UIColor clearColor];
        g_win.userInteractionEnabled = NO;             // 不吃触摸
        // ⚠️ 空的 rootViewController：scene 化的裸 UIWindow 在部分 iOS 版本下
        //    不参与渲染合成（hidden=NO 却看不见）；给个透明空 VC 稳妥。
        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = [UIColor clearColor];
        vc.view.userInteractionEnabled = NO;
        g_win.rootViewController = vc;
        // ⭐⭐ v0.3.0：窗口**铺满整个 scene**，圆点用绝对坐标定位。
        //   为什么不再用「24×24 小窗口 + 圆点居中」：scene 化的 UIWindow 其 frame
        //   由 scene 的 coordinateSpace 掌管，手动设的小 frame 可能被系统重置 ——
        //   一旦重置，圆点就会连同窗口飘到坐标系原点，日志仍报 hidden=NO/可见，
        //   屏幕上却什么都看不到（"日志说显示了、肉眼没显示"的经典成因）。
        //   铺满 scene 后，圆点 frame 就是屏幕绝对坐标，与 window.frame 脱钩。
        CGRect sb = scene.coordinateSpace.bounds;
        if (CGRectIsEmpty(sb)) sb = [UIScreen mainScreen].bounds;
        if (CGRectIsEmpty(sb)) sb = CGRectMake(0, 0, 430, 932);
        g_win.frame = sb;
        vc.view.frame = sb;
        g_dot = [[UIView alloc] initWithFrame:CGRectMake(cx - 4, cy - 4, 8, 8)];
        g_dot.backgroundColor = [UIColor colorWithRed:0.0 green:0.8 blue:0.4 alpha:1.0];
        g_dot.layer.cornerRadius = 4.0;
        g_dot.layer.masksToBounds = YES;
        [g_win addSubview:g_dot];
        g_win.hidden = YES;                            // 默认隐藏，由 update 决定
        g_winHiddenCache = YES;
    } @catch (NSException *e) {
        // 场景/窗口创建异常 → 完全降级：丢弃半成品，后续重试
        g_win = nil; g_dot = nil; g_scene = nil;
        g_winExists = NO;
        g_winHiddenCache = YES;
        g_diagCache = @"ensure-throw";
    }
    ff_refreshDiagCache();
}

// 把圆点移到指定坐标（窗口铺满屏幕，圆点用绝对坐标 —— 见 ensureWindow 说明）
- (void)moveToCoord:(CGFloat)cx cy:(CGFloat)cy {
    if (!g_win) return;
    g_dot.frame = CGRectMake(ff_clampX(cx) - 4, ff_clampY(cy) - 4, 8, 8);
}

- (void)updateWithExt:(BOOL)ext
             charging:(BOOL)charging
               active:(BOOL)active
                 mode:(NSInteger)mode {
    // ⚠️ 必须切主线程：调用方（SpringBoard 侧轮询）跑在后台队列，
    //    跨线程操作 UIKit 会让 SpringBoard 崩溃循环 → 黑屏。
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            [self ensureWindow];
            if (!g_win) return;

            // 先算出「这一轮该不该显示、什么颜色」，最后一次性落地，避免重复赋值抖动
            BOOL wantHidden = YES;   // 没插线 / 模式关闭 → 一律不显示
            BOOL wantRed    = NO;    // 红：我们正在阻止系统断流（强制充电生效中）
            BOOL wantOrange = NO;    // 橙：有线，但系统没在充电，我们也没能扭转

            if (ext && mode != kFFShowModeOff) {
                if (mode == kFFShowModeAlways) {
                    // 常显：只要**插着线**就显示（不再要求"系统正在充电"——
                    // 否则系统一停充圆点就消失，正好丢掉最有用的那个信号）
                    wantHidden = NO;
                    wantRed    = active;
                    wantOrange = (!active && !charging);
                } else {
                    // 仅强制（默认，含任何未识别的旧值）—— 只有一个判断点：
                    // 我们真在干活才显示。宁可不显示，也不要亮一个"看起来在工作"的点。
                    wantHidden = !active;
                    wantRed    = active;
                }
            }

            if (!wantHidden) {
                // 坐标每次刷新都重算（设置页可改）
                [self moveToCoord:ff_coord(kFFDotXKey, kFFDotXDefault)
                               cy:ff_coord(kFFDotYKey, kFFDotYDefault)];
                // 三种颜色：
                //   红 = 我们的强制充电正在生效（把系统关掉的充电打开了）
                //   橙 = 有线但系统没在充电（我们没干预 / 干预了没成）—— 诊断信号
                //   绿 = 系统原生充电（我们没介入，系统自己就充得很好）
                if (wantRed) {
                    g_dot.backgroundColor = [UIColor colorWithRed:1.00 green:0.23 blue:0.19 alpha:1.0];
                } else if (wantOrange) {
                    g_dot.backgroundColor = [UIColor colorWithRed:1.00 green:0.58 blue:0.00 alpha:1.0];
                } else {
                    g_dot.backgroundColor = [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0];
                }
                g_dot.hidden = NO;
            }
            if (g_win.hidden != wantHidden) {
                g_win.hidden = wantHidden;
                g_winHiddenCache = wantHidden;
            }
            ff_refreshDiagCache();
        } @catch (NSException *e) {}
    });
}

@end
