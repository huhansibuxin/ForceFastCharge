//
//  ForceFastCharge Tweak.xm — 强制充电（阻止系统断流）
//
//  ⭐ v0.2.0 功能转向（重要，别再往回改）
//  ────────────────────────────────────────────────────────────────
//  原定位「强制快充」（吞掉系统的降流写让充电更快）已被实机证据否定：
//  2026-10-05 在 iPhone 14 Pro Max / iOS 16.6.1 上三重取证 ——
//   ① 插着充电器 dump 全表 IORegistry：ChargeCurrentLimit / MaxChargeCurrent /
//      AdapterPowerLimit / AdapterCurrentLimit / ChargingPowerLimit /
//      ChargingCurrentLimit / USBPD* / Thermal*Limit **命中 0 条**；
//   ② 把 powerd 本体拉下来解析：__cstring 里电池相关键只有
//      ChargingOverride / InflowOverride / ChargeInhibit / ChargeLimit /
//      DisableInflow / ChargingState / InflowState / VacVoltageLimit /
//      NotChargingReason / ChargerData —— **全是「限/停/只读」，没有一个能提高电流**；
//   ③ hook 确实挂着（setterCalls=7）但充电期间零命中，全是 boot 期系统键。
//  ⇒ 上游那套白名单是 macOS/Intel 时代产物，在 iOS 上永远空转。
//  ⇒ iOS 用户态**只能"限"（停充/限流/限百分比），不能"加"**；充电电流由内核
//     AppleSmartBatteryManager + SMC 固件决定。故「强制快充」物理上做不到。
//
//  现定位 = **强制充电**：系统想「断流」（停充）时，我们不让它停。
//  老板原话：「拦截降流这个功能我们就不要了，就只要强制充电，就是不要让它断流就行。」
//  ────────────────────────────────────────────────────────────────
//
//  拦什么（powerd 二进制实证存在、且用于停充的键）：
//    · ChargeInhibit  = 抑制充电   （true/非0 = 禁止充电）
//    · DisableInflow  = 禁止流入   （true/非0 = 不充电）
//    · ChargeBlocked  = 阻断充电   （上游提到过的同族键，一并覆盖）
//    判定粒度是**值**：只在「朝停充方向」写时吞掉；写 0/false（允许充）一律透传。
//
//  不碰什么（刻意护栏）：
//    · ChargeLimit —— 那是「充电上限百分比」，是用户意图（如设 80%），拦了就是破坏设置；
//    · FullyCharged / 电量相关 —— 充满了就该停，这是正常行为；
//    · 温度保护 —— 由内核 SMC 层直接执行，**根本不经过 powerd**，想拦也拦不到
//      （这反而是好事：我们的拦截不会破坏原厂热保护链）。
//
//  设计原则：
//   1. 只注入 powerd，不碰 thermalmonitord。生命周期 = powerd 生命周期，
//      powerd 由 launchd 常驻，故装上即一直生效，无需自拉 daemon。
//   2. 绝不伪造电池状态、绝不改写注册表读回值、**绝不主动写**任何电池属性。
//      拦截逻辑本身是**纯事件驱动**：只在系统自己发起停充写的那一刻动手，
//      零轮询写盘、不反复刷属性（老板明确反对 heartbeat 式功能实现）。
//
//      ⚠️ v0.2.1 例外（仅诊断，与功能无关）：加了一条 60s 心跳日志。
//      起因是老板问「日志怎么一直不更新，是不是关了」—— 根因正是上面的
//      "纯事件驱动"：不充电 / 没拦到东西时本来就不写日志，**静止是正确表现**，
//      但静止无法区分「插件活着没事干」与「插件死了」。
//      所以补一条 1 行/分钟的存活心跳 + 充电中的电池遥测，代价约 130KB/天
//      （并有 512KB 轮转上限），功能逻辑仍不受任何影响。
//   3. 覆盖三条写入通道：IORegistryEntrySetCFProperty（单数）、
//      IORegistryEntrySetCFProperties（复数）、IOServiceSetCFProperty（若存在）。
//      ⚠️ 复数版正是上游漏掉的那条 —— powerd 的 IOKit imports 里它是存在的。
//   4. 另 hook IOServiceOpen 做**纯诊断**（记录 powerd 打开了哪些 IO service），
//      用于判断它是否走 AppleSmartBatteryManagerUserClient（IOConnectCallMethod）通道。
//
//  与旧版（ChargeControl/Tweak.xm 激进派）的本质区别：
//      旧版：把限流值强行顶回「原生满量」，读不到就灌 5000mA(5A) 兜底，
//            并每 2s 清除 ChargingPaused/ForceDisableCharge/NotChargingReason
//            等停充标签 → 满流 + 禁停充 + **主动反复写** → 触发热保护强制关机（黑屏）。
//      本版：只在系统**自己发起**停充写入的那一刻拦下，不主动写、不伪造、不反复刷。
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
static BOOL gHookInstalled = NO;
static uint64_t gLastLogNS = 0;
static int gBlockedCount = 0;     // 累计拦下的停充写次数（历史总量）
static int gSessionBlocked = 0;   // **本次充电会话内**拦下的次数 —— 指示点红/绿的唯一判据
static int gSetterCalls = 0;      // hook 被调用的总次数（诊断：证明 hook 点到底有没有被 powerd 用到）
static BOOL gLastCharging = NO;   // 当前充电状态，供状态文件与指示器读取
static uint64_t gTickCount = 0;   // 2s 轮询 tick 计数（v0.2.1：每 30 tick = 60s 发一次心跳）

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

// ---------------------------------------------------------------- 电池遥测（纯只读）
// v0.2.1：回答「系统到底在不在给电流」「它为什么停充」。
// ⚠️ 全部只读 —— 绝不写任何属性，符合本插件「只拦不写」的铁律。
// 字段含义（ChargerData 子字典）：
//   ChargingCurrent             当前实际充电电流(mA)，0 = 真的没在充
//   NotChargingReason           不充电原因：0=正常；128=未接充电器；
//                               其余值=被系统/固件限制（温度、电量、策略…）
//   TimeChargingThermallyLimited 因温控被限流的累计秒数（>0 即温控介入过）
//   VacVoltageLimit / ChargingVoltage  充电器电压上限 / 实际充电电压(mV)
static NSDictionary *readBatteryTelemetry(void) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    @try {
        mach_port_t mp = MACH_PORT_NULL;
        if (IOMasterPort(MACH_PORT_NULL, &mp) != KERN_SUCCESS) return out;
        io_service_t s = IOServiceGetMatchingService(mp, IOServiceMatching("IOPMPowerSource"));
        if (!s) s = IOServiceGetMatchingService(mp, IOServiceMatching("AppleSmartBattery"));
        if (!s) return out;
        for (NSString *k in @[@"CurrentCapacity", @"Temperature",
                              @"ExternalConnected", @"IsCharging", @"FullyCharged"]) {
            CFTypeRef v = IORegistryEntryCreateCFProperty(s, (__bridge CFStringRef)k,
                                                          kCFAllocatorDefault, 0);
            if (v) out[k] = (__bridge_transfer id)v;   // transfer：交给 ARC 管理，不泄漏
        }
        CFTypeRef cd = IORegistryEntryCreateCFProperty(s, CFSTR("ChargerData"),
                                                       kCFAllocatorDefault, 0);
        if (cd) {
            if (CFGetTypeID(cd) == CFDictionaryGetTypeID()) {
                NSDictionary *d = (__bridge NSDictionary *)cd;
                for (NSString *k in @[@"ChargingCurrent", @"ChargingVoltage",
                                      @"VacVoltageLimit", @"NotChargingReason",
                                      @"TimeChargingThermallyLimited"]) {
                    if (d[k]) out[k] = d[k];
                }
            }
            CFRelease(cd);
        }
        IOObjectRelease(s);
    } @catch (NSException *e) {}
    return out;
}

// 把遥测压成一行（日志/状态文件共用）
static NSString *ffTelemetryLine(NSDictionary *t) {
    return [NSString stringWithFormat:
            @"cap=%@%% mA=%@ mV=%@ vac=%@ ncr=%@ thermal=%@ ext=%@ temp=%.1fC",
            t[@"CurrentCapacity"] ?: @"?",
            t[@"ChargingCurrent"] ?: @"?",
            t[@"ChargingVoltage"] ?: @"?",
            t[@"VacVoltageLimit"] ?: @"?",
            t[@"NotChargingReason"] ?: @"?",
            t[@"TimeChargingThermallyLimited"] ?: @"?",
            t[@"ExternalConnected"] ?: @"?",
            [t[@"Temperature"] doubleValue] / 100.0];   // IOKit 给的是 1/100 °C
}

// 日志体量上限：超 512KB 就删掉重来（心跳约 130KB/天 ⇒ 保留约 4 天）。
// ⚠️ 只在心跳里调用，绝不在 hook 热路径上做 syscall。
static void ffRotateLogIfTooBig(NSString *path) {
    @try {
        NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        if ([[a objectForKey:NSFileSize] unsignedLongLongValue] > 512ULL * 1024ULL) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        }
    } @catch (NSException *e) {}
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
static int  gStatSession  = -1;   // 会话计数也要参与节流，否则「刚拦到停充」不会立即落盘
static BOOL gStatCharging = NO;
static BOOL gStatForce    = NO;

static void writeStatusFile(void) {
    if (!gHookInstalled) return;
    // 节流：2s 定时器会频繁调用本函数，内容没变就不重复写盘（省 IO）
    if (gStatBlocked == gBlockedCount && gStatSession == gSessionBlocked &&
        gStatCharging == gLastCharging && gStatForce == gForceFastCharge) {
        return;
    }
    gStatBlocked  = gBlockedCount;
    gStatSession  = gSessionBlocked;
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
        // 「强制充电工作中」= 本次充电会话拦下过系统的停充写 —— 指示点红/绿的判据
        @"active"  : (gSessionBlocked > 0 ? @"工作中" : @"待命"),
    };
    FFWriteDomainPlist(@"ffstatus", domain);

    // ② 诊断文件（字段更全，人肉排查用）
    //    setterCalls 很关键：若它一直是 0，说明 powerd 压根没调用我们 hook 的那两个
    //    setter（hook 点不对）；若它 >0 而 blockedWriteCount==0，说明调了但键名没命中白名单。
    NSDictionary *st = @{
        @"hookInstalled"     : @(gHookInstalled),
        @"forceEnabled"      : @(gForceFastCharge),
        @"charging"          : @(gLastCharging),
        @"active"            : @(gSessionBlocked > 0),
        @"sessionBlocked"    : @(gSessionBlocked),
        @"blockedWriteCount" : @(gBlockedCount),
        @"setterCalls"       : @(gSetterCalls),
        @"pid"               : @((int)getpid()),
        @"updatedAt"         : [[NSDate date] description]
    };
    [st writeToFile:[dir stringByAppendingPathComponent:@"ff_status.plist"] atomically:YES];
}

static void updateChargeState(void) {
    BOOL enabled = readBoolPref(kFFForceFastChargeKey, NO);
    if (enabled == gForceFastCharge) {
        writeStatusFile();
        return;
    }
    gForceFastCharge = enabled;
    logDiag(@"forceCharge -> %@", enabled ? @"ON（拦停充）" : @"OFF");
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
    if (charging) {
        // 新一次充电会话开始 → 重置「我们有没有在工作」的判据。
        // 不重置的话，上一次充电拦到过降流会让圆点永远停在红色。
        gSessionBlocked = 0;
        logDiag(@"charging session start -> sessionBlocked reset");
    }
    logDiag(@"charging state -> %@", charging ? @"YES" : @"NO");
    if (!charging) {
        // ⭐ v0.2.1 关键取证：系统**为什么**停充。
        //   NotChargingReason: 0=正常、128=未接充电器、其余=被限（温度/电量/策略…）
        //   TimeChargingThermallyLimited: 因温控被限流的累计秒数
        //   分水岭判读：
        //     · ncr 非 0/128 且 sessionBlocked==0 → 停充**不经过 powerd**
        //       （内核 SMC 直控），我们拦不到 —— 这是"功能无效"，不是"没触发"。
        //     · sessionBlocked>0 → 系统本来要停充，被我们挡住了（圆点该是红的）。
        logDiag(@"charge stop reason: %@ sessionBlocked=%d",
                ffTelemetryLine(readBatteryTelemetry()), gSessionBlocked);
    }
    writeStatusFile();                       // 让指示器读到最新 charging
    notify_post(FFChargeStateNotifName.UTF8String);
}

// ---------------------------------------------------------------- 属性分类
// 「停充键」= 系统用来断流的属性名。
// 实证来源：powerd 二进制 __cstring 里 `ChargeInhibit` / `DisableInflow` 明确存在
//（两者在字符串表里紧邻，同属电源断言/充电控制那组键）；`ChargeBlocked` 是上游
// 注释里提到的同族键，一并覆盖以防不同机型用别的名字。
static BOOL isStopChargingKey(CFStringRef propertyName) {
    if (!propertyName) return NO;
    NSString *s = nil;
    @try { s = [(__bridge NSString *)propertyName lowercaseString]; }
    @catch (NSException *e) { return NO; }
    if (!s.length) return NO;
    static NSArray<NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = @[
            @"chargeinhibit",     // 抑制充电
            @"disableinflow",     // 禁止流入
            @"chargeblocked"      // 阻断充电（同族，保险位）
        ];
    });
    for (NSString *name in names) {
        // 精确匹配，不用包含匹配：这几个词太短，包含匹配会误伤 ChargeInhibitReasons
        // 之类的只读状态键。
        if ([s isEqualToString:name]) return YES;
    }
    return NO;
}

// 值判定：只有「朝停充方向」写才拦（true / 非 0）。
// ⚠️ 这一层不能省 —— 系统同样会写 ChargeInhibit=false 来**解除**停充（恢复充电），
//    那种写入对我们有利，拦了反而害事，必须原样放行。
static BOOL isStopValue(CFTypeRef v) {
    if (!v) return NO;
    @try {
        CFTypeID t = CFGetTypeID(v);
        if (t == CFBooleanGetTypeID()) return CFBooleanGetValue((CFBooleanRef)v);
        if (t == CFNumberGetTypeID()) {
            long long n = 0;
            if (CFNumberGetValue((CFNumberRef)v, kCFNumberLongLongType, &n)) return n != 0;
            return NO;
        }
        if (t == CFStringGetTypeID()) {
            NSString *s = [(__bridge NSString *)v lowercaseString];
            return [s isEqualToString:@"true"] || [s isEqualToString:@"yes"] ||
                   [s integerValue] != 0;
        }
    } @catch (NSException *e) {}
    return NO;
}

// 总判定：当前设置下，这个写操作是否应该被吞掉
static BOOL shouldBlockWrite(CFStringRef propertyName, CFTypeRef value) {
    if (!gForceFastCharge) return NO;
    return isStopChargingKey(propertyName) && isStopValue(value);
}

// ---------------------------------------------------------------- Hook
typedef kern_return_t (*IORegistryEntrySetCFPropertyFn)(io_registry_entry_t, CFStringRef, CFTypeRef);
typedef kern_return_t (*IORegistryEntrySetCFPropertiesFn)(io_registry_entry_t, CFTypeRef);
typedef kern_return_t (*IOServiceSetCFPropertyFn)(io_service_t, CFStringRef, CFTypeRef);
typedef kern_return_t (*IOServiceOpenFn)(io_service_t, task_port_t, uint32_t, io_connect_t *);

static IORegistryEntrySetCFPropertyFn   orig_SetCFProp   = NULL;
static IORegistryEntrySetCFPropertiesFn orig_SetCFProps  = NULL;
static IOServiceSetCFPropertyFn         orig_SvcSetCFProp = NULL;
static IOServiceOpenFn                  orig_SvcOpen     = NULL;

// 记账：证明 hook 到底有没有被 powerd 用到，以及它都写了哪些键。
// 为什么必须有它：只看 blockedWriteCount==0 无法区分两种情况 ——
//   ① powerd 压根没调用这些 setter（hook 点不对）
//   ② 调用了，但键名不在停充键表里（那就该扩表）
// 打出「总调用数 + 出现过的键名（去重，上限 48 个）」就能一眼分辨。
//
// ⭐ v0.2.1 修正：停充键**永不被去重上限吃掉**。
//   此前所有键共用 48 个名额，而 boot 期系统键就占了十几个；长期运行后名额
//   可能被占满 → 真正想看的 ChargeInhibit / DisableInflow 一条都记不到（
//   这恰好是"最关键的一条证据反而丢失"的坑）。现在停充键走独立分支，
//   每次命中都记（含值 + 判定结果），完全不消耗去重名额。
static void noteSetterCall(CFStringRef propertyName, CFTypeRef value) {
    gSetterCalls++;
    if (isStopChargingKey(propertyName)) {
        logDiag(@"stop-key seen: %@ = %@ (willBlock=%d)",
                (__bridge NSString *)propertyName,
                value ? (__bridge id)value : @"(nil)",
                shouldBlockWrite(propertyName, value));
        return;
    }
    static NSMutableSet<NSString *> *seen = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
    // 采够 48 个键名后就不再进锁：这是 powerd 的热路径，不能为纯诊断付互斥开销。
    // （这里无锁读 count 是刻意的：最坏情况只是多进一次锁，代价可忽略。）
    if (seen.count >= 48) return;
    NSString *n = propertyName ? (__bridge NSString *)propertyName : @"(null)";
    @synchronized (seen) {
        if (seen.count < 48 && ![seen containsObject:n]) {
            [seen addObject:n];
            logDiag(@"setter key seen: %@", n);
        }
    }
}

// 命中一次「停充写」→ 记账 + （本会话首次时）立即落盘并通知 SpringBoard 翻红。
// ⚠️ 本函数只负责「记账 + 通知」，不参与是否拦截的判定（那由 shouldBlockWrite 决定）。
static void recordStopWrite(NSString *where, CFStringRef propertyName) {
    gBlockedCount++;
    BOOL firstInSession = (gSessionBlocked == 0);
    gSessionBlocked++;
    logThrottled(@"BLOCK stop-charge(%@): %@ (total=%d, session=%d)",
                 where, (__bridge NSString *)propertyName, gBlockedCount, gSessionBlocked);
    if (firstInSession) {
        // 状态从「待命」翻成「工作中」→ 立即落盘并通知 SpringBoard 翻红
        writeStatusFile();
        notify_post(FFChargeStateNotifName.UTF8String);
    }
}

// 单数版：一次写一个属性。只在开关打开、且键与值都指向「停充」时才吞。
static kern_return_t hook_SetCFProperty(io_registry_entry_t entry,
                                        CFStringRef propertyName,
                                        CFTypeRef property) {
    noteSetterCall(propertyName, property);
    if (shouldBlockWrite(propertyName, property)) {
        recordStopWrite(@"set", propertyName);
        return KERN_SUCCESS;   // 告诉系统「已处理」，实际不写入 → 系统没能断流
    }
    return orig_SetCFProp ? orig_SetCFProp(entry, propertyName, property) : KERN_FAILURE;
}

// ⭐ 复数版：一次写一批属性（CFDictionary）。
// 上游 SBCPUPowerd.xm **只 hook 了单数版**，而 powerd 的 IOKit imports 里
// `_IORegistryEntrySetCFProperties` 是存在的 —— 这正是此前「hook 挂着却零命中」
// 的候选漏网通道。做法：把批次里的停充键剔除，剩下的原样透传；
// 若整批都是停充键 → 直接 return KERN_SUCCESS（整批吞掉）。
static kern_return_t hook_SetCFProperties(io_registry_entry_t entry, CFTypeRef properties) {
    if (!gForceFastCharge || !properties ||
        CFGetTypeID(properties) != CFDictionaryGetTypeID()) {
        return orig_SetCFProps ? orig_SetCFProps(entry, properties) : KERN_FAILURE;
    }
    NSDictionary *dict = (__bridge NSDictionary *)properties;
    NSMutableDictionary *kept = [NSMutableDictionary dictionary];
    BOOL blockedAny = NO;
    for (id k in dict) {
        @try {
            NSString *key = [k isKindOfClass:[NSString class]] ? (NSString *)k : [k description];
            if (!key.length) { kept[k] = dict[k]; continue; }
            CFStringRef kcf = (__bridge CFStringRef)key;
            noteSetterCall(kcf, (__bridge CFTypeRef)dict[k]);
            if (shouldBlockWrite(kcf, (__bridge CFTypeRef)dict[k])) {
                blockedAny = YES;
                recordStopWrite(@"setprops", kcf);
            } else {
                kept[k] = dict[k];      // 非停充键 → 原样保留
            }
        } @catch (NSException *e) {}
    }
    if (!blockedAny) {
        return orig_SetCFProps ? orig_SetCFProps(entry, properties) : KERN_FAILURE;
    }
    if (kept.count == 0) return KERN_SUCCESS;    // 整批都是停充键 → 整批吞掉
    return orig_SetCFProps ? orig_SetCFProps(entry, (__bridge CFTypeRef)kept) : KERN_FAILURE;
}

// service 版（本机 IOKit 里可能根本没有这个符号，取不到就跳过，不算失败）
static kern_return_t hook_SvcSetCFProperty(io_service_t service,
                                           CFStringRef propertyName,
                                           CFTypeRef property) {
    noteSetterCall(propertyName, property);
    if (shouldBlockWrite(propertyName, property)) {
        recordStopWrite(@"svc", propertyName);
        return KERN_SUCCESS;
    }
    return orig_SvcSetCFProp ? orig_SvcSetCFProp(service, propertyName, property) : KERN_FAILURE;
}

// 纯诊断：记录 powerd 打开了哪些 IO service（去重、上限 64）。
// 目的：判断它是否走 `AppleSmartBatteryManagerUserClient`（IOConnectCallMethod）那
// 条通道。那条通道我们**只观测不拦截** —— externalMethod 的参数结构未知，
// 盲拦有把电池通信搞坏的风险；等日志证明确实用它，再决定要不要动。
static kern_return_t hook_IOServiceOpen(io_service_t service, task_port_t owningTask,
                                        uint32_t type, io_connect_t *connect) {
    kern_return_t kr = orig_SvcOpen ? orig_SvcOpen(service, owningTask, type, connect)
                                    : KERN_FAILURE;
    if (kr == KERN_SUCCESS) {
        @try {
            io_name_t cls = {0};
            if (IOObjectGetClass(service, cls) == KERN_SUCCESS && cls[0]) {
                static NSMutableSet<NSString *> *seen = nil;
                static dispatch_once_t once;
                dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
                NSString *n = [NSString stringWithUTF8String:cls];
                if (n.length) {
                    @synchronized (seen) {
                        if (seen.count < 64 && ![seen containsObject:n]) {
                            [seen addObject:n];
                            logDiag(@"IO service opened: %@", n);
                        }
                    }
                }
            }
        } @catch (NSException *e) {}
    }
    return kr;
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
    // ⭐ 上游漏掉的复数版通道
    void *p1b = dlsym(handle, "IORegistryEntrySetCFProperties");
    if (p1b && !orig_SetCFProps) {
        MSHookFunction(p1b, (void *)hook_SetCFProperties, (void **)&orig_SetCFProps);
    }
    void *p2 = dlsym(handle, "IOServiceSetCFProperty");
    if (p2 && !orig_SvcSetCFProp) {
        MSHookFunction(p2, (void *)hook_SvcSetCFProperty, (void **)&orig_SvcSetCFProp);
    }
    // 诊断用：只记录，不改行为
    void *p3 = dlsym(handle, "IOServiceOpen");
    if (p3 && !orig_SvcOpen) {
        MSHookFunction(p3, (void *)hook_IOServiceOpen, (void **)&orig_SvcOpen);
    }
    gHookInstalled = (orig_SetCFProp != NULL || orig_SetCFProps != NULL ||
                      orig_SvcSetCFProp != NULL);
}

// ---------------------------------------------------------------- 存活心跳（v0.2.1）
// 老板问「日志怎么一直不更新，是不是关了」。根因是拦截逻辑纯事件驱动：
// 不充电 / 没拦到东西时本来就不写日志，**静止是正确表现**。但"静止"无法区分
// 「插件活着没事干」与「插件死了」，所以补一条 60s 心跳（每 30 个 2s tick 一次）：
//   · 待机：一行 alive —— 证明 dylib 还在、hook 还挂着
//   · 充电中：额外带电池遥测 —— 直接回答"系统到底有没有在给电流"
// 代价：1 行/分钟 ≈ 130KB/天，且做了 512KB 轮转上限，可忽略。
static void heartbeatTick(void) {
    if (gTickCount % 30 != 0) return;          // 30 × 2s = 60s
    ffRotateLogIfTooBig(diagLogPath());        // 顺带做日志体量治理（不在热路径）
    if (gLastCharging) {
        logDiag(@"heartbeat charging pid=%d hooks=%d force=%d %@ sessionBlocked=%d blocked=%d setterCalls=%d",
                (int)getpid(), gHookInstalled, gForceFastCharge,
                ffTelemetryLine(readBatteryTelemetry()),
                gSessionBlocked, gBlockedCount, gSetterCalls);
    } else {
        logDiag(@"heartbeat idle pid=%d hooks=%d force=%d charging=0 sessionBlocked=%d blocked=%d setterCalls=%d",
                (int)getpid(), gHookInstalled, gForceFastCharge,
                gSessionBlocked, gBlockedCount, gSetterCalls);
    }
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
        logDiag(@"hooks installed (set=%d, setProps=%d, svcSet=%d, svcOpen=%d)",
                orig_SetCFProp != NULL, orig_SetCFProps != NULL,
                orig_SvcSetCFProp != NULL, orig_SvcOpen != NULL);
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
                    gTickCount++;
                    updateChargeState();
                    pollChargeState();
                    heartbeatTick();     // v0.2.1：60s 一次存活心跳（含充电遥测）
                }
            });
            dispatch_resume(timer);
        }
    }
}
