//
//  FFIndicatorTweak.xm — SpringBoard 侧指示点驱动
//
//  只注入 SpringBoard，负责：
//   1. 读偏好（开关/显示模式/坐标）+ 自读 IORegistry 充电状态 → 驱动圆点；
//   2. 监听 powerd 侧 Darwin 通知即时刷新；
//   3. 2s 兜底轮询（v0.2.1 起顺带每 60s 发一次存活心跳，避免日志静止被误判为"插件死了"）；
//   4. 把运行状态写 sb_status.plist，供设置页确认「指示器到底跑没跑」。
//
//  ⚠️ v0.1.2 关键修复（实机踩坑）：
//    v0.1.0/v0.1.1 的 %ctor 用
//        if (![[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"]) return;
//    做进程判定。实测 dylib 明明已在进程里（CocoaTop 可见），却零日志零圆点——
//    根因就是 processName 在系统进程里不保证等于短名，判 false → %ctor 直接 return，
//    后面一行都不执行。现改用 FFIsProcess（getprogname + 包含匹配），
//    并用 FFBootLog 无条件落盘，杜绝再出现「注入了却什么都没发生」的黑洞。
//
//  ⚠️⚠️ v0.2.2 关键修复：定时器必须由**文件级静态变量**持有强引用（见 gTimer）。
//
//  ⚠️⚠️ v0.3.0 关键修复（老板实机：「开了常显，插上还是不显示」）：
//    根因不是注入、不是开关、不是场景 —— 是**刷新入口的短路顺序**。
//    refreshIndicator() 里 `if (!forceNotify && !changed) return;` 挡在了
//    updateWithCharging() 之前，而建窗只发生在 updateWithCharging 里。
//    SB 刚重启时 scene 未就绪 → 首次建窗失败 → 插着充电器时状态恒稳 →
//    每 2s 的 tick 全部提前 return → **窗口再没有任何重试机会**，圆点永不出现；
//    直到某次状态翻转（拔线）才把窗口建出来。
//    实机证据：charging=1 的 47 秒内仅 2 条 refresh（均 win=0），随后 47 秒静默。
//    修法：每轮无条件先 ensureWindowAsync()（幂等、非阻塞），再做变化检测。
//
//  ⭐ v0.4.0 关键修正（判据换了）：「是否显示」改看 **ExternalConnected（有没有插线）**，
//    不再看 IsCharging（系统有没有正在充）。
//    起因：老板报「开了常显，插上还是不显示」。翻日志后确认**圆点逻辑本身没错** ——
//    是**系统在插上线后 2 秒内就把充电停掉了**（IsCharging 1→0），圆点按"充电中"
//    判据自然隐藏；重插也一样（系统直接拒绝充电，charging 恒为 0）→ 一直不显示。
//    而「有线但系统拒绝充电」恰恰是最需要被看见的状态 —— 用 charging 当判据
//    等于"在最该显示的时候不显示"。故改为：
//      ext（ExternalConnected） → 决定是否显示
//      charging                 → 决定绿（系统在充）/ 橙（系统没在充）
//      active（SMC 纠正生效）   → 决定红
//    另：refresh 日志新增 want= 字段，与 vis 区分 —— vis 读的是**上一拍**的窗口缓存
//    （刷新是 async 落主线程的，天然滞后一拍），此前这个滞后把排查带偏过。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <IOKit/IOKitLib.h>
#import <mach/mach.h>
#import <notify.h>
#include <stdarg.h>
#include <sys/time.h>
#import "FFIndicator.h"
#import "FFPaths.h"

static BOOL gLastForce    = NO;
static BOOL gLastExt      = NO;   // v0.4.0：是否显示的主判据（有没有插线）
static BOOL gLastCharging = NO;
static BOOL gLastActive   = NO;   // 上一轮「我们有没有真干活」，纳入变化检测
static NSInteger gLastMode = -1;
static CGFloat gLastX = -1, gLastY = -1;   // 坐标也要纳入变化检测，否则改坐标不生效
static BOOL gEnabled      = NO;   // 是否成功进入运行态
static uint64_t gTick      = 0;   // 2s tick 计数（v0.2.1：每 30 tick = 60s 一次心跳）

// ⚠️⚠️ v0.2.2 关键修复：定时器必须由**文件级静态变量**持有强引用。
//   ARC 下 dispatch_source_t 是托管对象；写成 %ctor 的局部变量，离开作用域即被
//   release → libdispatch 对「已 resume 的 source」自动 cancel → 定时器永久失效
//   （完全静默：不 crash、不报错、无任何日志）。
//   实机铁证（v0.2.1）：sb.log 跨越约 2 小时、heartbeat 0 次；唯一还能刷新圆点的
//   通路退化成「用户在设置页操作所发的 Darwin 通知」—— 这就是老板观察到的
//   「插上充电器不亮、拔掉不灭，点一下设置页（应用位置）才更新」的根因。
static dispatch_source_t gTimer = nil;

// ---------------------------------------------------------------- 诊断日志
// SpringBoard 侧此前完全没有日志，出问题只能盲猜，这里补全。
static void sbLog(NSString *fmt, ...) {
    // ⚠️ 必须写 mobile 可写的位置：SpringBoard 以 mobile 身份运行，
    //    powerd 建的 /var/mobile/ForceFastCharge(root:mobile 755) 它写不进去，
    //    之前"SB 侧零日志"就是这么来的。Documents 归 mobile 所有且不被 RootHide 重定向。
    mkdir("/var/mobile/Documents/ForceFastCharge", 0777);
    chmod("/var/mobile/Documents/ForceFastCharge", 0777);
    int fd = open("/var/mobile/Documents/ForceFastCharge/sb.log",
                  O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    struct timeval tv; gettimeofday(&tv, NULL);
    NSString *line = [NSString stringWithFormat:@"[%lld.%03d] %@\n",
                      (long long)tv.tv_sec, (int)(tv.tv_usec / 1000), body];
    const char *cs = line.UTF8String;
    if (cs) (void)write(fd, cs, strlen(cs));
    close(fd);
}

// 日志体量上限（同 powerd 侧）：只在心跳里检查，热路径零开销
static void sbRotateIfTooBig(void) {
    @try {
        NSString *p = @"/var/mobile/Documents/ForceFastCharge/sb.log";
        NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
        if ([[a objectForKey:NSFileSize] unsignedLongLongValue] > 512ULL * 1024ULL) {
            [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
        }
    } @catch (NSException *e) {}
}

// ---------------------------------------------------------------- 偏好读取
static BOOL readBool(NSString *key, BOOL def) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:FFPrefPath()];
        id v = d[key];
        if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
        if ([v isKindOfClass:[NSString class]]) return [v boolValue];
    } @catch (NSException *e) {}
    return def;
}

static NSInteger readInt(NSString *key, NSInteger def) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:FFPrefPath()];
        id v = d[key];
        if ([v isKindOfClass:[NSNumber class]]) return [v integerValue];
        if ([v isKindOfClass:[NSString class]]) return [v integerValue];
    } @catch (NSException *e) {}
    return def;
}

// 文本框输入（PSEditTextCell）存的是字符串，滑块存的是数字，这里都兼容
static CGFloat readDouble(NSString *key, CGFloat def) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:FFPrefPath()];
        id v = d[key];
        CGFloat n = 0;
        if ([v isKindOfClass:[NSNumber class]])      n = [v doubleValue];
        else if ([v isKindOfClass:[NSString class]]) n = [(NSString *)v doubleValue];
        if (n > 0) return n;          // 0/空/非法 → 回退默认，防圆点飞出屏幕
    } @catch (NSException *e) {}
    return def;
}

// ---------------------------------------------------------------- 充电状态
// 两个独立判据，刻意分开读（v0.4.0）：
//   ext      = ExternalConnected  → **是否显示的主判据**（插着线就该有圆点）
//   charging = ExternalConnected && IsCharging → 决定颜色是绿还是橙
// 为什么必须分开：本机实测"插着线但系统拒绝充电"（76% / 0mA / ncr=16）是常态，
// 只用一个 charging 当判据 → 最该显示的情形（系统不给充）恰好不显示。
static BOOL readSelfExternal(void) {
    BOOL ext = NO;
    @try {
        mach_port_t mp = MACH_PORT_NULL;
        if (IOMasterPort(MACH_PORT_NULL, &mp) != KERN_SUCCESS) return NO;
        io_service_t s = IOServiceGetMatchingService(mp, IOServiceMatching("IOPMPowerSource"));
        if (!s) return NO;
        CFTypeRef ec = IORegistryEntryCreateCFProperty(s, CFSTR("ExternalConnected"),
                                                       kCFAllocatorDefault, 0);
        if (ec && CFGetTypeID(ec) == CFBooleanGetTypeID())
            ext = CFBooleanGetValue((CFBooleanRef)ec);
        if (ec) CFRelease(ec);
        IOObjectRelease(s);
    } @catch (NSException *e) {}
    return ext;
}

static BOOL readSelfCharging(void) {
    BOOL charging = NO;
    @try {
        mach_port_t mp = MACH_PORT_NULL;
        if (IOMasterPort(MACH_PORT_NULL, &mp) != KERN_SUCCESS) return NO;
        io_service_t s = IOServiceGetMatchingService(mp, IOServiceMatching("IOPMPowerSource"));
        if (!s) return NO;
        CFTypeRef ec = IORegistryEntryCreateCFProperty(s, CFSTR("ExternalConnected"),
                                                       kCFAllocatorDefault, 0);
        CFTypeRef ic = IORegistryEntryCreateCFProperty(s, CFSTR("IsCharging"),
                                                       kCFAllocatorDefault, 0);
        if (ec && CFGetTypeID(ec) == CFBooleanGetTypeID())
            charging = CFBooleanGetValue((CFBooleanRef)ec);
        if (ic && CFGetTypeID(ic) == CFBooleanGetTypeID())
            charging = charging && CFBooleanGetValue((CFBooleanRef)ic);
        if (ec) CFRelease(ec);
        if (ic) CFRelease(ic);
        IOObjectRelease(s);
    } @catch (NSException *e) {}
    return charging;
}

// 充电状态：优先自读 IORegistry（不依赖 powerd），失败回退 powerd 的状态文件
static BOOL readCharging(void) {
    if (readSelfCharging()) return YES;
    @try {
        NSDictionary *st = [NSDictionary dictionaryWithContentsOfFile:FFStatusPath()];
        id v = st[@"charging"];
        if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    } @catch (NSException *e) {}
    return NO;
}

// 「我们的强制充电这一轮有没有真的在干活」= powerd 侧 sessionBlocked > 0。
// ⚠️ 判据不是「开关开没开」（老板的开关是常开的），而是「有没有真拦下系统的停充写」。
//    powerd 把结果写进 ff_status.plist 的 active 字段（root:wheel 0644，SB 可读）。
static BOOL readForceActive(void) {
    @try {
        NSDictionary *st = [NSDictionary dictionaryWithContentsOfFile:FFStatusPath()];
        id v = st[@"active"];
        if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
        if ([v isKindOfClass:[NSString class]]) return [(NSString *)v boolValue];
    } @catch (NSException *e) {}
    return NO;
}

// ---------------------------------------------------------------- 状态回写
static void writeSbStatus(CGFloat cx, CGFloat cy) {
    NSString *dir = FFLogDir();
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];

    // 把「此刻圆点该是什么样」也算出来给设置页看 —— 老板不必盯着状态栏就能核对逻辑
    NSString *dotState;
    BOOL visible;
    if (gLastMode == kFFShowModeOff || !gLastExt) {
        visible = NO;                       // 模式关闭 / 没插线 → 一律不显示
    } else if (gLastMode != kFFShowModeAlways && !gLastActive) {
        visible = NO;                       // 「仅强制」且我们没干活 → 不显示
    } else {
        visible = YES;
    }
    if (!visible)              dotState = @"不显示";
    else if (gLastActive)      dotState = @"红 · 正在强制充电（已纠正停充）";
    else if (!gLastCharging)   dotState = @"橙 · 有线但系统未充电";
    else                       dotState = @"绿 · 系统原生充电";

    // ① 设置页读的域文件（键名必须与 Root.plist 的 key 逐字一致：
    //    defaults=com.chargecontrol.sbstatus，键 dotLoaded / dotWindow / dotState）
    NSDictionary *domain = @{
        @"dotLoaded" : (gEnabled ? @"是" : @"否"),
        @"dotWindow" : ([FFIndicator windowCreated] ? @"已创建" : @"未创建"),
        @"dotState"  : dotState,
        // ⭐ v0.3.0：窗口细节（层级/隐藏/alpha/frame/是否挂到 scene）——
        // 直接在手机上就能区分「逻辑判定不显示」与「建了却看不见」，不必先 SSH。
        @"dotDiag"   : [FFIndicator diagLine],
    };
    FFWriteDomainPlist(@"sbstatus", domain);

    // ② 诊断文件（字段更全）
    NSDictionary *st = @{
        @"loaded"        : @(gEnabled),
        @"windowCreated" : @([FFIndicator windowCreated]),
        @"force"         : @(gLastForce),
        @"ext"           : @(gLastExt),
        @"charging"      : @(gLastCharging),
        @"active"        : @(gLastActive),
        @"dotState"      : dotState,
        @"showMode"      : @(gLastMode),
        @"dotX"          : @(cx),
        @"dotY"          : @(cy),
        @"pid"           : @((int)getpid()),
        @"updatedAt"     : [[NSDate date] description]
    };
    [st writeToFile:[dir stringByAppendingPathComponent:@"sb_status.plist"]
         atomically:YES];
}

// ---------------------------------------------------------------- 刷新驱动
static void refreshIndicator(BOOL forceNotify) {
    // ⭐⭐ v0.3.0 关键修复（老板实机：「开了常显，插上还是不显示」）
    //   必须在**状态变化检测之前**无条件请求建窗。
    //   根因链：建窗只发生在 updateWithCharging 里 → 而这里"无变化就 return" →
    //   SB 刚重启时场景未就绪导致首次建窗失败后，插着充电器状态恒稳，
    //   每 2s 的 tick 全部提前 return，**窗口再没有任何重试机会**
    //   → 插上充电器几十分钟都不出圆点，直到某次状态翻转（拔线）才把窗口建出来。
    //   实机证据：sb.log 中 charging=1 的 47 秒里仅 2 条 refresh（均 win=0），
    //   之后 47 秒静默；1791186123（拔线，charging 1→0）那一帧才出现 win=1。
    //   ensureWindowAsync 内部幂等 + 自带主线程切换 + 不阻塞，代价可忽略。
    [[FFIndicator shared] ensureWindowAsync];

    BOOL force    = readBool(kFFForceFastChargeKey, NO);
    BOOL ext      = readSelfExternal();    // v0.4.0：**是否显示的主判据**（插着线就该有圆点）
    BOOL charging = readCharging();        // 决定颜色绿/橙
    BOOL active   = readForceActive();     // 我们这一轮有没有真干活 → 决定是否红
    NSInteger mode = readInt(kFFIndicatorModeKey, kFFShowModeForceOnly);
    CGFloat cx = readDouble(kFFDotXKey, kFFDotXDefault);
    CGFloat cy = readDouble(kFFDotYKey, kFFDotYDefault);

    BOOL changed = (force != gLastForce) || (ext != gLastExt) ||
                   (charging != gLastCharging) || (active != gLastActive) ||
                   (mode != gLastMode) || (cx != gLastX) || (cy != gLastY);

    gLastForce = force;
    gLastExt = ext; gLastCharging = charging; gLastActive = active;
    gLastMode = mode; gLastX = cx; gLastY = cy;

    if (!forceNotify && !changed) return;   // 无变化不打扰（窗口仍在每轮 ensureWindowAsync 里保活）

    // ⚠️ 本轮「逻辑上该不该显示」必须**单独算一份**记进日志，不能靠 vis 判断。
    //   原因：updateWithExt 是 async 落到主线程的，vis/diagLine 读的是**上一拍**的
    //   窗口缓存，天然滞后一拍 —— 曾经这个滞后把排查带偏（看起来"该显示却 vis=0"，
    //   实际那只是上一轮的值）。现在 want 是"此刻的期望值"，vis 是"上一拍的实际值"，
    //   两者对照就能立刻定位是"逻辑没到"还是"窗口没建/被隐藏"。
    BOOL wantShow = ext && mode != kFFShowModeOff &&
                    (mode == kFFShowModeAlways || active);

    sbLog(@"refresh force=%d ext=%d charging=%d active=%d mode=%ld want=%d coord=(%.1f,%.1f) win=%d vis=%d scene=%ld [%@]",
          force, ext, charging, active, (long)mode, wantShow, cx, cy,
          [FFIndicator windowCreated], [FFIndicator windowVisible],
          (long)[FFIndicator sceneState], [FFIndicator diagLine]);

    [[FFIndicator shared] updateWithExt:ext charging:charging active:active mode:mode];
    writeSbStatus(cx, cy);
}

// ---------------------------------------------------------------- 通知回调
static void stateChanged(CFNotificationCenterRef center, void *observer,
                          CFNotificationName name, const void *object,
                          CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    @try { refreshIndicator(YES); } @catch (NSException *e) {}
}

#pragma mark - ctor
%ctor {
    @autoreleasepool {
        // ① 先落盘（纯 POSIX），保证只要 dylib 被加载就有痕迹
        FFBootLog("FF-indicator-ctor");

        // ② kill-switch：存在 .../Documents/ForceFastCharge/disable 则完全空跑
        //    （旧路径也一并认，兼容老习惯）
        if (access("/var/mobile/Documents/ForceFastCharge/disable", F_OK) == 0 ||
            access("/var/mobile/ForceFastCharge/disable", F_OK) == 0) {
            sbLog(@"kill-switch 命中 → 不启动");
            return;
        }

        // ③ 进程判定（宽松匹配，见文件头说明）
        NSString *prog  = FFProcName();
        NSString *pname = [NSProcessInfo processInfo].processName;
        if (!FFIsProcess(@"springboard")) {
            sbLog(@"非 SpringBoard（progname=%@ processName=%@）→ 不启动", prog, pname);
            return;
        }
        gEnabled = YES;
        sbLog(@"=== indicator ctor ok pid=%d progname=%@ processName=%@ ===",
              (int)getpid(), prog, pname);

        // ④ 首次刷新延后到主线程下一轮 runloop：SB 启动瞬间 scene 尚未就绪，
        //    此时建窗容易拿到无效 scene。
        dispatch_async(dispatch_get_main_queue(), ^{
            @try { refreshIndicator(YES); } @catch (NSException *e) {}
        });

        // ⑤ 监听 powerd 的充电状态 / 设置变更通知
        CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
        if (center) {
            CFNotificationCenterAddObserver(center, NULL, stateChanged,
                                             (__bridge CFStringRef)FFChargeStateNotifName,
                                             NULL,
                                             CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(center, NULL, stateChanged,
                                             (__bridge CFStringRef)FFSettingsChangedNotifName,
                                             NULL,
                                             CFNotificationSuspensionBehaviorDeliverImmediately);
        }

        // ⑥ 2s 兜底轮询：覆盖通知丢失 / 设置页改坐标不触发通知等情况
        // ⚠️ 必须存进文件级静态 gTimer（见其声明处说明）——
        //    写成局部变量会被 ARC 提前释放，定时器静默失效，圆点只剩
        //    「用户操作设置页」这一条刷新通路（v0.2.1 实机踩坑的根因）。
        gTimer = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        if (gTimer) {
            dispatch_source_set_timer(gTimer,
                                      dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                                      2 * NSEC_PER_SEC,
                                      300 * NSEC_PER_SEC / 1000);   // 300ms leeway
            dispatch_source_set_event_handler(gTimer, ^{
                @try {
                    // v0.2.1：60s 存活心跳。refreshIndicator 在"无变化"时是不写日志的
                    // （纯事件驱动），日志静止会让人以为插件死了 —— 心跳解决这个歧义。
                    // v0.2.2：心跳额外记录 vis / scene，用于区分
                    //   「逻辑判定不该显示」与「逻辑要显示但窗口被隐藏 / 建不出来」。
                    gTick++;
                    if (gTick % 30 == 0) {
                        sbRotateIfTooBig();
                        sbLog(@"heartbeat pid=%d win=%d vis=%d scene=%ld [%@] force=%d ext=%d charging=%d active=%d mode=%ld",
                              (int)getpid(), [FFIndicator windowCreated],
                              [FFIndicator windowVisible], (long)[FFIndicator sceneState],
                              [FFIndicator diagLine],
                              gLastForce, gLastExt, gLastCharging, gLastActive, (long)gLastMode);
                    }
                    refreshIndicator(NO);
                } @catch (NSException *e) {}
            });
            dispatch_resume(gTimer);
        }
    }
}
