//
//  FFIndicatorTweak.xm — SpringBoard 侧指示点驱动
//
//  只注入 SpringBoard，负责：
//   1. 读偏好（开关/显示模式/坐标）+ 自读 IORegistry 充电状态 → 驱动圆点；
//   2. 监听 powerd 侧 Darwin 通知即时刷新；
//   3. 2s 兜底轮询；
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
static BOOL gLastThermal  = NO;
static BOOL gLastCharging = NO;
static NSInteger gLastMode = -1;
static CGFloat gLastX = -1, gLastY = -1;   // 坐标也要纳入变化检测，否则改坐标不生效
static BOOL gEnabled      = NO;   // 是否成功进入运行态

// ---------------------------------------------------------------- 诊断日志
// SpringBoard 侧此前完全没有日志，出问题只能盲猜，这里补全。
static void sbLog(NSString *fmt, ...) {
    mkdir("/var/mobile/ForceFastCharge", 0755);
    int fd = open("/var/mobile/ForceFastCharge/sb.log",
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
// 自己从 IOPMPowerSource 读，不依赖 powerd 侧的 status.plist——
// 这样即使 powerd 侧没跑，指示点也能正确区分「充电中 / 未充电」。
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

// ---------------------------------------------------------------- 状态回写
static void writeSbStatus(CGFloat cx, CGFloat cy) {
    mkdir("/var/mobile/ForceFastCharge", 0755);
    NSDictionary *st = @{
        @"loaded"        : @(gEnabled),
        @"windowCreated" : @([FFIndicator windowCreated]),
        @"force"         : @(gLastForce),
        @"thermal"       : @(gLastThermal),
        @"charging"      : @(gLastCharging),
        @"showMode"      : @(gLastMode),
        @"dotX"          : @(cx),
        @"dotY"          : @(cy),
        @"pid"           : @((int)getpid()),
        @"updatedAt"     : [[NSDate date] description]
    };
    [st writeToFile:[FFLogDir() stringByAppendingPathComponent:@"sb_status.plist"]
         atomically:YES];
}

// ---------------------------------------------------------------- 刷新驱动
static void refreshIndicator(BOOL forceNotify) {
    BOOL force    = readBool(kFFForceFastChargeKey, NO);
    BOOL thermal  = readBool(kFFThermalOverrideKey, NO);
    if (!force) thermal = NO;
    BOOL charging = readCharging();
    NSInteger mode = readInt(kFFIndicatorModeKey, kFFShowModeAuto);
    CGFloat cx = readDouble(kFFDotXKey, kFFDotXDefault);
    CGFloat cy = readDouble(kFFDotYKey, kFFDotYDefault);

    BOOL changed = (force != gLastForce) || (thermal != gLastThermal) ||
                   (charging != gLastCharging) || (mode != gLastMode) ||
                   (cx != gLastX) || (cy != gLastY);

    gLastForce = force; gLastThermal = thermal;
    gLastCharging = charging; gLastMode = mode;
    gLastX = cx; gLastY = cy;

    if (!forceNotify && !changed) return;   // 无变化不打扰

    sbLog(@"refresh force=%d thermal=%d charging=%d mode=%ld coord=(%.1f,%.1f) win=%d",
          force, thermal, charging, (long)mode, cx, cy, [FFIndicator windowCreated]);

    [[FFIndicator shared] updateWithForceOn:force thermalOn:thermal charging:charging];
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

        // ② kill-switch：存在 /var/mobile/ForceFastCharge/disable 则完全空跑
        if (access("/var/mobile/ForceFastCharge/disable", F_OK) == 0) {
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
        dispatch_source_t timer = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        if (timer) {
            dispatch_source_set_timer(timer,
                                      dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                                      2 * NSEC_PER_SEC,
                                      300 * NSEC_PER_SEC / 1000);   // 300ms leeway
            dispatch_source_set_event_handler(timer, ^{
                @try { refreshIndicator(NO); } @catch (NSException *e) {}
            });
            dispatch_resume(timer);
        }
    }
}
