//
//  ForceFastCharge Tweak.xm — 强制快充（单功能版）
//
//  移植自 mowang7426/sbcpu 的 SBCPUPowerd.xm（V3.1.14+ 独立 powerd 目标）。
//  仅保留「强制快充」一个功能，不含限充 / 温度停充 / 任何 SMC 逻辑。
//
//  设计原则（与上游一致，刻意为之）：
//   1. 只注入 powerd，不碰 thermalmonitord。生命周期 = powerd 生命周期，
//      powerd 由 launchd 常驻，故装上即一直生效，无需自拉 daemon。
//   2. 绝不伪造电池状态、绝不改写注册表读回值。
//   3. 只「吞掉」系统降低充电功率的写指令（返回 KERN_SUCCESS 表示已处理），
//      不主动把电流顶到某个值。
//   4. 绝不拦截 ChargeInhibit / ChargeBlocked / ChargeLimit / FullyCharged
//      以及任何温度安全键——这些是原厂保护链，碰了就是黑屏/烧机。
//
//  与旧版（ChargeControl/Tweak.xm 激进派）的本质区别：
//      旧版：把限流值强行顶回「原生满量」，读不到就灌 5000mA(5A) 兜底，
//            并每 2s 清除 ChargingPaused/ForceDisableCharge/NotChargingReason
//            等停充标签 → 满流 + 禁停充 → 无视温度 → 触发热保护强制关机（黑屏）。
//      新版：只阻止系统「往下压」，压到什么值由充电器协商与 BMS 决定。
//

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <IOKit/IOKitLib.h>
#import <notify.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <substrate.h>
#include <stdio.h>
#include <stdarg.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <sys/time.h>
#include "FFPaths.h"

static BOOL gForceFastCharge = NO;
static BOOL gThermalOverride = NO;
static BOOL gHookInstalled = NO;
static uint64_t gLastLogNS = 0;
static int gBlockedCount = 0;
static BOOL gLastCharging = NO;   // 当前充电状态，供状态文件与指示器读取

// ---------------------------------------------------------------- 诊断日志
static NSString *diagLogPath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = FFLogDir();          // /var/mobile/Documents/ForceFastCharge
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return [dir stringByAppendingPathComponent:@"ffcharge.log"];
}

static void logDiag(NSString *fmt, ...) {
    NSString *path = diagLogPath();
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    struct timeval tv; gettimeofday(&tv, NULL);
    NSString *line = [NSString stringWithFormat:@"[%lld.%03d][%@] %@\n",
                      (long long)tv.tv_sec, (int)(tv.tv_usec / 1000),
                      [[NSProcessInfo processInfo] processName], body];
    const char *cs = line.UTF8String;
    if (cs) (void)write(fd, cs, strlen(cs));
    close(fd);
}

// 状态变化时立即记；拦截计数按 10s 节流，避免刷屏
static void logThrottled(NSString *fmt, ...) {
    uint64_t now = dispatch_time(DISPATCH_TIME_NOW, 0);
    if (now - gLastLogNS < (uint64_t)(10.0 * NSEC_PER_SEC)) return;
    gLastLogNS = now;
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    logDiag(@"%@", body);
}

// ---------------------------------------------------------------- 开关读取
// 注意：powerd 以 root 运行，用 CFPreferences 走 mobile 域会串域，
//      必须像上游 SBCPUChargeEngine 那样直读 plist 文件。
static BOOL readBoolPref(NSString *key, BOOL fallback) {
    // 逐候选路径读（jbroot 版 / 真实版 / var/jb 版）：
    // roothide 下设置页把开关写进 jbroot，而 powerd 是系统进程读的是真实 rootfs，
    // 只认单一路径就会「开关打开了这里却是 false」。
    NSDictionary *d = FFReadPrefsDict();
    if (!d) return fallback;
    id v = d[key];
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    if ([v isKindOfClass:[NSString class]]) {
        return [[(NSString *)v lowercaseString] isEqualToString:@"true"] || [v integerValue] != 0;
    }
    return fallback;
}

// 状态标志：设置页「运行状态」两行读的是 defaults=com.chargecontrol.ffstatus 域
// 的 loaded / blocked 键（见 Settings/Root.plist）。
// ⚠️ v0.1.3 修复：此前这里只写自定义文件 status.plist，与设置页的读取通道
//    完全对不上 → 设置页永远显示「未加载」。现在写官方域文件（roothide 下位于
//    jbroot 的 Preferences 目录，正好是设置页读的那份），另存诊断文件供人排查。
static int  gStatBlocked  = -1;
static BOOL gStatCharging = NO;
static BOOL gStatForce    = NO;

static void writeStatusFile(void) {
    if (!gHookInstalled) return;
    // 节流：2s 定时器会频繁调用本函数，内容没变就不重复写盘（省 IO）
    if (gStatBlocked == gBlockedCount && gStatCharging == gLastCharging &&
        gStatForce == gForceFastCharge) {
        return;
    }
    gStatBlocked  = gBlockedCount;
    gStatCharging = gLastCharging;
    gStatForce    = gForceFastCharge;

    NSString *dir = FFLogDir();
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];

    // ① 设置页读的域文件（键名必须与 Root.plist 的 key 逐字一致）
    NSDictionary *domain = @{
        @"loaded"  : (gHookInstalled ? @"是" : @"否"),
        @"blocked" : [NSString stringWithFormat:@"%d", gBlockedCount],
    };
    FFWriteDomainPlist(@"ffstatus", domain);

    // ② 诊断文件（字段更全，人肉排查用）
    NSDictionary *st = @{
        @"hookInstalled"     : @(gHookInstalled),
        @"forceEnabled"      : @(gForceFastCharge),
        @"thermalOverride"   : @(gThermalOverride),
        @"charging"          : @(gLastCharging),
        @"pid"               : @((int)getpid()),
        @"blockedWriteCount" : @(gBlockedCount),
        @"updatedAt"         : [[NSDate date] description]
    };
    [st writeToFile:[dir stringByAppendingPathComponent:@"ff_status.plist"] atomically:YES];
}

static void updateChargeState(void) {
    BOOL enabled = readBoolPref(kFFForceFastChargeKey, NO);
    BOOL thermal = readBoolPref(kFFThermalOverrideKey, NO);
    // 温控强制只在主开关打开时才有意义
    if (!enabled) thermal = NO;
    if (enabled == gForceFastCharge && thermal == gThermalOverride) {
        writeStatusFile();
        return;
    }
    gForceFastCharge = enabled;
    gThermalOverride = thermal;
    if (gThermalOverride) {
        logDiag(@"forceFastCharge -> ON (含温控派生键覆盖，风险自负)");
    } else {
        logDiag(@"forceFastCharge -> %@", enabled ? @"ON" : @"OFF");
    }
    writeStatusFile();
    // 开关变化 → 通知 SpringBoard 侧立即刷新指示点
    notify_post(FFChargeStateNotifName.UTF8String);
}

// ---------------------------------------------------------------- 充电状态
// 读 IOPMPowerSource 的 ExternalConnected/IsCharging；状态变化时 post
// FFChargeStateNotif，驱动 SpringBoard 侧指示点显示/隐藏。
static BOOL readIsCharging(void) {
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

static void pollChargeState(void) {
    BOOL charging = readIsCharging();
    if (charging == gLastCharging) return;   // 无变化不打扰
    gLastCharging = charging;
    logDiag(@"charging state -> %@", charging ? @"YES" : @"NO");
    writeStatusFile();                       // 让指示器读到最新 charging
    notify_post(FFChargeStateNotifName.UTF8String);
}

// ---------------------------------------------------------------- 属性分类
// A 类：系统软件层降流键 —— 主开关打开即吞掉（安全，不碰温度保护链）
static BOOL isFastChargeProperty(CFStringRef propertyName) {
    if (!propertyName) return NO;
    NSString *s = (__bridge NSString *)propertyName;
    static NSArray<NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = @[
            @"ChargeCurrentLimit",
            @"MaxChargeCurrent",
            @"AdapterPowerLimit",
            @"AdapterCurrentLimit",
            @"ChargingPowerLimit",
            @"ChargingCurrentLimit",
            @"USBPDCurrentLimit",
            @"USBPDPowerLimit"
        ];
    });
    for (NSString *name in names) {
        if ([s caseInsensitiveCompare:name] == NSOrderedSame ||
            [s rangeOfString:name options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

// B 类：温控派生的降流键 —— 这正是「高温时系统原生拒绝充电」的那一层。
//      默认【放行】，只有用户显式打开「高温强制」才吞。
//      ⚠️ 吞掉这层等于无视原厂热保护，设备将不再自行停止充电，
//         有过热强制关机（黑屏）与电池老化风险。
static BOOL isThermalLimitProperty(CFStringRef propertyName) {
    if (!propertyName) return NO;
    NSString *s = (__bridge NSString *)propertyName;
    static NSArray<NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = @[
            @"ThermalMaxChargeCurrent",
            @"ThermalChargingLimit",
            @"ThermalChargeCurrentLimit",
            @"ThermalAdapterCurrentLimit"
        ];
    });
    for (NSString *name in names) {
        if ([s caseInsensitiveCompare:name] == NSOrderedSame ||
            [s rangeOfString:name options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

// 总判定：当前设置下，这个写操作是否应该被吞掉
static BOOL shouldBlockWrite(CFStringRef propertyName) {
    if (!gForceFastCharge) return NO;
    if (isThermalLimitProperty(propertyName)) return gThermalOverride;  // 需二次开关
    return isFastChargeProperty(propertyName);
}

// ---------------------------------------------------------------- Hook
typedef kern_return_t (*IORegistryEntrySetCFPropertyFn)(io_registry_entry_t, CFStringRef, CFTypeRef);
typedef kern_return_t (*IOServiceSetCFPropertyFn)(io_service_t, CFStringRef, CFTypeRef);

static IORegistryEntrySetCFPropertyFn orig_SetCFProp = NULL;
static IOServiceSetCFPropertyFn orig_SvcSetCFProp = NULL;

// 只在开关打开时吃掉降流写；其余一律原样透传给系统
static kern_return_t hook_SetCFProperty(io_registry_entry_t entry,
                                        CFStringRef propertyName,
                                        CFTypeRef property) {
    if (shouldBlockWrite(propertyName)) {
        gBlockedCount++;
        logThrottled(@"blocked down-limit write: %@ (total=%d)",
                     (__bridge NSString *)propertyName, gBlockedCount);
        return KERN_SUCCESS;   // 告诉系统「已处理」，实际不写入 → 系统无法把上限压低
    }
    return orig_SetCFProp ? orig_SetCFProp(entry, propertyName, property) : KERN_FAILURE;
}

static kern_return_t hook_SvcSetCFProperty(io_service_t service,
                                           CFStringRef propertyName,
                                           CFTypeRef property) {
    if (shouldBlockWrite(propertyName)) {
        gBlockedCount++;
        logThrottled(@"blocked down-limit write(svc): %@ (total=%d)",
                     (__bridge NSString *)propertyName, gBlockedCount);
        return KERN_SUCCESS;
    }
    return orig_SvcSetCFProp ? orig_SvcSetCFProp(service, propertyName, property) : KERN_FAILURE;
}

static void installIOKitHooks(void) {
    void *handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",
                          RTLD_NOW | RTLD_GLOBAL);
    if (!handle) {
        logDiag(@"IOKit dlopen failed");
        return;
    }
    void *p1 = dlsym(handle, "IORegistryEntrySetCFProperty");
    if (p1 && !orig_SetCFProp) {
        MSHookFunction(p1, (void *)hook_SetCFProperty, (void **)&orig_SetCFProp);
    }
    void *p2 = dlsym(handle, "IOServiceSetCFProperty");
    if (p2 && !orig_SvcSetCFProp) {
        MSHookFunction(p2, (void *)hook_SvcSetCFProperty, (void **)&orig_SvcSetCFProp);
    }
    gHookInstalled = (orig_SetCFProp != NULL || orig_SvcSetCFProp != NULL);
}

// Darwin 通知回调（CFNotificationCenter 形态，对齐上游 SBCPUPowerd.xm 签名）
static void pollChargeState(void);   // 前置声明
static void settingsChanged(CFNotificationCenterRef center, void *observer,
                            CFNotificationName name, const void *object,
                            CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    if (gHookInstalled) {
        updateChargeState();
        pollChargeState();
    }
}

#pragma mark - ctor
%ctor {
    @autoreleasepool {
        // ① 先落盘：纯 POSIX，不依赖 ObjC 运行时。
        //    只要 dylib 被加载就一定留下痕迹（含真实进程名），
        //    避免再出现「CocoaTop 看得到 dylib、却零日志零功能」的黑洞。
        FFBootLog("FF-powerd-ctor");

        // ①' kill-switch：SSH 下 touch /var/mobile/Documents/ForceFastCharge/disable
        //      即可让本 dylib 完全空跑（不挂任何 hook），用于异常时的快速止血。
        //      旧路径 /var/mobile/ForceFastCharge/disable 也一并认，兼容老习惯。
        if (access("/var/mobile/Documents/ForceFastCharge/disable", F_OK) == 0 ||
            access("/var/mobile/ForceFastCharge/disable", F_OK) == 0) {
            logDiag(@"kill-switch 命中 → 不挂 hook");
            return;
        }

        // ② 进程判定：FFIsProcess 用 getprogname + 包含匹配。
        //    ⚠️ 不能用 isEqualToString（v0.1.x 全盘失效根因：
        //    守护进程的 processName 未必等于短名，判 false 直接 return）。
        NSString *prog  = FFProcName();
        NSString *pname = [NSProcessInfo processInfo].processName;
        if (!FFIsProcess(@"powerd")) {
            logDiag(@"ctor: 非 powerd（progname=%@ processName=%@）→ 不挂 hook",
                    prog, pname);
            return;
        }

        logDiag(@"=== boot pid=%d progname=%@ processName=%@ ===",
                (int)getpid(), prog, pname);
        installIOKitHooks();
        if (!gHookInstalled) {
            logDiag(@"no IOKit setter hooks installed");
            return;
        }
        logDiag(@"hooks installed (SetCFProperty=%d, SvcSetCFProperty=%d)",
                orig_SetCFProp != NULL, orig_SvcSetCFProp != NULL);
        writeStatusFile();

        // 监听设置变更与充电状态变化（Darwin 通知中心，与上游一致）
        CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
        if (center) {
            CFNotificationCenterAddObserver(center, NULL, settingsChanged,
                                             (__bridge CFStringRef)FFSettingsChangedNotifName,
                                             NULL,
                                             CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(center, NULL, settingsChanged,
                                             (__bridge CFStringRef)FFChargeStateNotifName,
                                             NULL,
                                             CFNotificationSuspensionBehaviorDeliverImmediately);
        }
        updateChargeState();

        // 兜底轮询：偏好改动通知可能丢失，2s 复查一次开关
        dispatch_source_t timer = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        if (timer) {
            dispatch_source_set_timer(timer,
                                      dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                                      2 * NSEC_PER_SEC,
                                      300 * NSEC_PER_SEC / 1000);   // 300ms leeway
            dispatch_source_set_event_handler(timer, ^{
                if (gHookInstalled) {
                    updateChargeState();
                    pollChargeState();
                }
            });
            dispatch_resume(timer);
        }
    }
}
