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
//  ⭐⭐ v0.4.0 关键升级：从「拦截」改为「纠正」（用户态唯一真正能强制充电的路径）
//  ────────────────────────────────────────────────────────────────
//  v0.2.x / v0.3.0 的实机取证反复证明「拦 IOKit 写」是空转：
//    · setterCalls 从 boot 后恒定（22 → 32），整个充电会话内 0 次充电相关写；
//    · IOConnectCall* 探针显示 powerd 只在**启动期**碰过 AppleSMC(sel 0/1/2) 与
//      AppleSmartBatteryManager(sel 4)，之后整个充电过程再无任何调用；
//    · 2026-10-05 复验：上游 SBCPUPowerd 的 8 个电流/功率键、以及停充键，
//      在全表 24349 行的 IORegistry 里**命中 0 条**（powerd 二进制里也没有这些串）。
//  ⇒ powerd 是充电状态的**读取者**、不是决策者；这里没有可拦的动作。
//
//  真正的充电开关在 **SMC 固件**，用户态唯一通道是 AppleSMC user client：
//      CH0C bit0 = 1 → 电池充电被禁止   → 写 0 恢复
//      CH0I bit0 = 1 → 外部供电被切断   → 写 0 恢复
//  本版**照搬上游 SBCPUChargeSMC 的恢复路径**（与 Battman restore command 同语义）：
//  系统把充电关掉之后，我们把这两个禁止位写回 0，让充电继续。
//
//  ⚠️ 这是全插件**风险最高**的一段（主动写电池管理固件键）。
//     护栏与上游踩坑记录见 smcEnforceIfNeeded() 上方的注释。
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

// ⚠️⚠️ v0.2.2 关键修复：定时器必须由**文件级静态变量**持有强引用。
//   ARC 下 dispatch_source_t 是托管对象；若只存在于 %ctor 的局部变量中，
//   离开作用域即被 release → libdispatch 对「已 resume 的 source」会自动 cancel
//   → 定时器**永久失效**，且完全静默（不 crash、不报错）。
//
//   实机铁证（v0.2.1，2026-10-05）：
//     · ffcharge.log / sb.log 跨数小时、heartbeat 均为 0 次 —— handler 从未执行；
//     · 但日志里确实出现过 charging state -> YES/NO —— 那是**通知回调**打的，
//       即唯一还能工作的通路退化成「用户在设置页操作 → 发通知 → 两侧被唤起」。
//     · 于是表现为老板观察到的：「插拔充电器圆点不刷新，点一下设置才更新」。
//   修法：静态强引用持有（block 里不捕获它，故无循环引用）。
static dispatch_source_t gTimer = nil;

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


// ================================================================ AppleSMC 读写层（v0.4.0）
//
// ⭐⭐ 为什么必须有它 —— 这是「强制充电」唯一能落地的地方
//  ────────────────────────────────────────────────────────────────
//  v0.2.x / v0.3.0 的实机取证已把「拦 IOKit 写」这条路彻底否掉：
//    · setterCalls 从 boot 后恒为 22（后 32），整个充电会话内 0 次充电相关写；
//    · v0.3.0 新增的 IOConnectCall* 探针显示 powerd 只在**启动期**碰过
//      AppleSmartBatteryManager(selector=4) 与 AppleSMC(selector=0/1/2)，
//      此后整个充电过程再无任何调用。
//  ⇒ powerd 对「停充」没有控制权，它只是**读取者**。拦它 = 拦一个不存在的动作。
//
//  真正的充电开关在 **SMC 固件**，用户态唯一通道是 AppleSMC user client：
//    CH0C bit0 : 电池充电开关   （1 = 禁止电池充电 / 停充）
//    CH0I bit0 : 外部供电流入开关（1 = 切断外部供电）
//    CH0B      : OBC managed charging（系统"优化电池充电"托管位）
//    CH0R bit1 : No VBUS（无外部供电时禁止写）
//    CHCE      : ExternalConnected
//  语义与「恢复路径」完全对齐上游 SBCPUChargeSMC.m / Battman：
//    **恢复充电 = 直接写 CH0C = 0**（Battman restore command 同款）。
//
//  ⇒ 本插件由此从「拦截」升级为「纠正」：系统把充电关掉之后，我们把它打开。
//
//  ⚠️ 这是全插件**风险最高的一段**（主动写电池管理固件键），故设四道护栏：
//    ① 只在「开关打开 && 有线 && 未在充电 && 温度 < 上限」时才动；
//    ② 写的值恒为 0（= 恢复出厂默认的"允许"），**绝不写 1**（那才是停充）；
//    ③ 每次写前后都回读并把结果落盘 —— 出问题能一眼看出是谁写的；
//    ④ 电池温度超过上限立刻停手（**不绕过原厂热保护**）。
// ================================================================

#define FF_KEY4(a,b,c,d) ((uint32_t)(a) << 24 | (uint32_t)(b) << 16 | \
                          (uint32_t)(c) << 8  | (uint32_t)(d))

typedef struct { uint8_t major, minor, build; uint16_t release; } FF_SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } FF_SMCPLimitData;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } FF_SMCKeyInfo;

typedef struct FF_SMCParamStruct {
    uint32_t key;
    struct FF_SMCParam {
        FF_SMCVersion    vers;
        FF_SMCPLimitData pLimitData;
        FF_SMCKeyInfo    keyInfo;
        uint8_t          result;
        uint8_t          status;
        uint8_t          data8;
        uint32_t         data32;
        unsigned char    bytes[120];
    } param;
} FF_SMCParamStruct;

// ⚠️ AppleSMC 的 user-client 结构体是 **ABI 敏感**的：arm64 上必须是 168 字节。
//    上游踩过这个坑 —— 把 vers 写成单字节 → 结构体变 164 字节 → 之后所有字段
//    偏移全错 → AppleSMC 一律回 kIOReturnBadArgument(0xe00002c2)。
//    这里用编译期断言把它钉死，杜绝"改了字段忘了对齐"的静默失效。
_Static_assert(sizeof(FF_SMCParamStruct) == 168, "AppleSMC ABI must be 168 bytes");

enum {
    kFFSMCHandleYPCEvent = 2,   // 所有 SMC 操作都走这个 selector
    kFFSMCReadKey        = 5,
    kFFSMCWriteKey       = 6,
    kFFSMCGetKeyInfo     = 9,
};

static io_connect_t gSMCConn   = 0;
static int32_t      gSMCErr    = 0;   // 最近一次 SMC 调用的 IOReturn（0=成功），诊断/上报用
// ⭐ v0.5.1：SMC **固件层**返回码（out.param.result），与 io 层 IOReturn 分开上报。
//   分水岭判读（这是「我们写不进去」和「写进去了被 SMC 拒」的区分依据）：
//     io 返回 0xe00002bc(=kIOReturnError) 且 smcResult!=0 ⇒ **io 通道通、SMC 固件拒绝**
//        —— 说明我们的 ABI/权限都没问题，问题在这条命令本身
//     io 返回 0xe00002c1 之类                                      ⇒ io 层就拒了（权限/ABI）
//   result 常见值：0x00=接受；0x83=key not found；0x84/0x85=参数/命令被拒。
static int          gSMCLastResult = 0;
static volatile BOOL gSMCSelfOpen = NO;  // 标记「这次 IOServiceOpen 是我们自己发的」

// ⚠️ 本层只由 2s tick 单线程调用（见 smcEnforceIfNeeded 的调用点），
//    刻意不做加锁：SMC 在 powerd 热路径之外，加锁反而引入无谓开销与优先级反转风险。
static IOReturn ff_smc_call(int index, FF_SMCParamStruct *in, FF_SMCParamStruct *out) {
    if (gSMCConn == 0) {
        mach_port_t master = MACH_PORT_NULL;
        if (IOMasterPort(MACH_PORT_NULL, &master) != KERN_SUCCESS) {
            gSMCErr = kIOReturnError;
            return (IOReturn)gSMCErr;
        }
        io_service_t svc = IOServiceGetMatchingService(master, IOServiceMatching("AppleSMC"));
        if (!svc) { gSMCErr = kIOReturnNotFound; return (IOReturn)gSMCErr; }
        gSMCSelfOpen = YES;          // 让 IOServiceOpen 探针别把我们自己记成"powerd 打开了"
        IOReturn r = IOServiceOpen(svc, mach_task_self(), 0, &gSMCConn);
        gSMCSelfOpen = NO;
        IOObjectRelease(svc);
        if (r != kIOReturnSuccess) {
            gSMCConn = 0;
            gSMCErr  = r;            // 权限不足时这里通常是 kIOReturnNotPermitted
            return r;
        }
    }
    size_t inSize = sizeof(FF_SMCParamStruct), outSize = sizeof(FF_SMCParamStruct);
    IOReturn r = IOConnectCallStructMethod(gSMCConn, (uint32_t)index, in, inSize, out, &outSize);
    if (r != kIOReturnSuccess) gSMCErr = r;
    return r;
}

// ⭐⭐ v0.5.1 根因修复（实机踩坑）：ReadKey / WriteKey 的 input 里**必须回填 keyInfo**。
//
//   v0.4.0/v0.5.0 的写法是「用独立的空结构体发 ReadKey/WriteKey」——
//   结构体里 keyInfo 全零。实机后果（日志铁证）：
//     · 4 字节键（CHCE / CHBI / CHKS）**读出来恒为 0**（真值分别是 1 / 882mA / 95）
//     · 所有**写**都被 SMC 固件拒绝（out.param.result != 0）⇒ 写自检「不可写」
//     · 1 字节键（CH0C / CH0B）看起来"对"，纯属真值本来就是 0 的巧合
//   上游 SBCPUChargeSMC / Battman libsmc 的正确做法是：
//       smc_get_keyinfo(key, &in.param.keyInfo);   // ← 结果直接写回 input
//       in.param.data8 = kSMCReadKey;
//       smc_call(kSMCHandleYPCEvent, &in, &out);
//   即 **同一个结构体**先做 GetKeyInfo、再改成 ReadKey/WriteKey 发出去，keyInfo 全程带着。
//   本版逐字对齐上游。不回填不是"能跑但慢"，是**通道根本没工作**。
//
// 读一个 SMC 键。buf 由调用方提供，size 传入容量、返回实际长度。
static IOReturn ff_smc_read(uint32_t key, void *buf, int32_t *size) {
    if (!size || *size <= 0 || !buf) return kIOReturnBadArgument;

    FF_SMCParamStruct in = {0}, out = {0};
    in.key = key;
    in.param.data8 = kFFSMCGetKeyInfo;
    IOReturn r = ff_smc_call(kFFSMCHandleYPCEvent, &in, &out);
    if (r != kIOReturnSuccess) return r;
    if (out.param.result != 0) {           // SMC 固件层拒绝了 GetKeyInfo
        gSMCLastResult = out.param.result;
        gSMCErr = kIOReturnError;
        return kIOReturnError;
    }

    uint32_t dataSize = out.param.keyInfo.dataSize;
    if (dataSize == 0 || dataSize > sizeof(out.param.bytes)) {
        gSMCLastResult = 0xFF;             // keyInfo 为空 = 这个键不存在/不可读
        gSMCErr = kIOReturnError;
        return kIOReturnError;
    }
    if ((uint32_t)*size < dataSize) { *size = (int32_t)dataSize; return kIOReturnNoSpace; }

    // ⭐ 回填 keyInfo，再发 ReadKey（与上游一致 —— 这一步漏了整条通道就是死的）
    in.param.keyInfo = out.param.keyInfo;
    in.param.data8   = kFFSMCReadKey;
    memset(&out, 0, sizeof(out));
    r = ff_smc_call(kFFSMCHandleYPCEvent, &in, &out);
    if (r != kIOReturnSuccess) return r;
    if (out.param.result != 0) {
        gSMCLastResult = out.param.result;
        gSMCErr = kIOReturnError;
        return kIOReturnError;
    }

    memcpy(buf, out.param.bytes, dataSize);
    *size = (int32_t)dataSize;
    gSMCLastResult = 0;
    return kIOReturnSuccess;
}

// 写一个 SMC 键（长度以该键自己的 dataSize 为准）。
// ⚠️ 关键判据：IOConnectCallStructMethod 返回成功 ≠ 写入成功 ——
//    SMC 固件还可能拒绝，只有 out.param.result == 0 才是 SMC 级成功。
static IOReturn ff_smc_write(uint32_t key, const void *buf, uint32_t size) {
    if (!buf || size == 0 || size > 120) return kIOReturnBadArgument;

    FF_SMCParamStruct in = {0}, out = {0};
    in.key = key;
    in.param.data8 = kFFSMCGetKeyInfo;
    IOReturn r = ff_smc_call(kFFSMCHandleYPCEvent, &in, &out);
    if (r != kIOReturnSuccess) return r;
    if (out.param.result != 0) {
        gSMCLastResult = out.param.result;
        gSMCErr = kIOReturnError;
        return kIOReturnError;
    }

    uint32_t dataSize = out.param.keyInfo.dataSize;
    if (dataSize == 0 || dataSize > sizeof(in.param.bytes) || dataSize > size) {
        gSMCLastResult = 0xFF;
        gSMCErr = kIOReturnError;
        return kIOReturnError;
    }

    // ⭐ v0.5.1：与 ff_smc_read 同理 —— keyInfo 必须回填进 input，
    //   否则 SMC 固件直接拒绝写入（这正是 v0.4/v0.5 「写通道自检=不可写」的根因）。
    //   注意赋值顺序：keyInfo 在 bytes 之前，先回填再 memcpy 数据互不覆盖。
    in.param.keyInfo = out.param.keyInfo;
    in.param.data8   = kFFSMCWriteKey;
    memcpy(in.param.bytes, buf, dataSize);

    memset(&out, 0, sizeof(out));
    r = ff_smc_call(kFFSMCHandleYPCEvent, &in, &out);
    if (r != kIOReturnSuccess) return r;
    // io 返回成功 ≠ 写入成功：SMC 固件还可能拒绝，result==0 才是 SMC 级成功
    if (out.param.result != 0) {
        gSMCLastResult = out.param.result;
        gSMCErr = kIOReturnError;
        return kIOReturnError;
    }
    gSMCLastResult = 0;
    return kIOReturnSuccess;
}

// ⭐⭐ v0.5.0 关键修复：SMC 键的**数据宽度不是统一的**。
//   `smcDiagnose` 在实机上给出的真实类型：
//     CH0C = 0x00            → 1 字节（ui8/flag）
//     CH0B = 0x00            → 1 字节
//     CH0R = 0x00 00 00 00   → 4 字节
//     CH0I = 0.000000        → 4 字节（数值型，不是 1 字节位图！）
//     CHCE = 1.000000        → 4 字节
//   v0.4.0 照抄上游用的是 `uint8_t v; size=1`，而 ff_smc_read 在
//   `*size < dataSize` 时返回 kIOReturnNoSpace —— 于是 **CH0I / CHCE 每次都读失败**，
//   `needI` 恒为 false，CH0I 的恢复分支成了死代码。上游注释写的是 "CH0I bit0"，
//   那是想当然；真机 ABI 说了算。
//   修法：一律用 4 字节缓冲 + size=sizeof(uint32)，让 GetKeyInfo 拿到的 dataSize
//   自己去决定拷几个字节（1/2/4 字节键全部覆盖），调用方只取低 32 位。
static IOReturn ff_smc_read_u32(uint32_t key, uint32_t *out) {
    uint32_t v  = 0;
    int32_t  sz = (int32_t)sizeof(v);
    IOReturn r  = ff_smc_read(key, &v, &sz);
    if (r == kIOReturnSuccess && out) *out = v;
    return r;
}

// 把任意宽度的键写成 0。ff_smc_write 内部按该键自己的 dataSize 截取，
// 所以传 4 字节零缓冲对 1/2/4 字节键都正确（1 字节键只取低字节 0x00）。
// ⚠️ 只用于「清禁止位」——语义上永远是"允许"，绝不写 1。
static IOReturn ff_smc_write_zero(uint32_t key) {
    uint32_t z = 0;
    return ff_smc_write(key, &z, sizeof(z));
}

// ---------------------------------------------------------------- 强制充电状态（v0.4.0）
// 这些全局量既驱动圆点红/绿，也写进状态文件供设置页与日志核对。
static int  gSMCLastCH0C = -1;   // 最近读到的 CH0C（1=停充位被置起）
static int  gSMCLastCH0I = -1;   // 最近读到的 CH0I
static int  gSMCLastCHCE = -1;   // CHCE：外部电源连接
static int  gSMCLastCH0R = -1;   // CH0R：bit1 = No VBUS
static int  gSMCLastCH0B = -1;   // CH0B：OBC 托管
// v0.5.0 温控三兄弟（只观测）：无温控限制时全为 0；
// 系统因温度限制充电时它们应出现非 0 —— 这是"限流发生在 SMC 哪一层"的关键旁证。
static int  gSMCLastCHTE = -1;   // CHTE：温控相关
static int  gSMCLastCHTC = -1;   // CHTC：温控相关
static int  gSMCLastCHTM = -1;   // CHTM：温控相关
static BOOL gSMCSelfTested = NO; // 写通道自检是否已做过（只做一次，避免反复写 SMC）
static int  gSMCSessFix  = 0;    // **本充电会话**成功把充电救回来的次数
static int  gSMCTotalFix = 0;    // 历史累计
static BOOL gSMCRecovered = NO;  // 本会话是否靠 SMC 真的把充电救回来过（圆点红/绿判据）
static int  gSMCFailStreak = 0;  // 连续失败次数（>=3 时降频重试，别刷 SMC）
static uint64_t gLastSMCWriteNS = 0;
// v0.5.1：SMC **读** 节流。smcEnforceIfNeeded 现在挂在 2s tick 上，而 SMC 读是
//   系统调用（IOConnectCallStructMethod × 2/键），没必要每 2s 做一次。
//   10s 足够及时察觉状态变化，同时把开销压在可忽略的量级。
static uint64_t gLastSMCReadNS  = 0;

// 电池温度上限（℃）：超过它就不再纠正 —— 宁可充不动，也不绕过原厂热保护。
// 本机实测「系统停充」发生在 42.5~43.5℃，留 ~2℃ 余量。
#define FF_SMC_TEMP_LIMIT_C 45.0

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
static int  gStatSMC      = -1;   // v0.4.0：SMC 纠正计数也参与节流
static int  gStatCH0C     = -2;   // v0.5.0：SMC 开关值也参与节流（设置页要看到实时值变化）

static void writeStatusFile(void) {
    if (!gHookInstalled) return;
    // 节流：2s 定时器会频繁调用本函数，内容没变就不重复写盘（省 IO）
    if (gStatBlocked == gBlockedCount && gStatSession == gSessionBlocked &&
        gStatCharging == gLastCharging && gStatForce == gForceFastCharge &&
        gStatSMC == gSMCTotalFix && gStatCH0C == gSMCLastCH0C) {
        return;
    }
    gStatBlocked  = gBlockedCount;
    gStatSession  = gSessionBlocked;
    gStatCharging = gLastCharging;
    gStatForce    = gForceFastCharge;
    gStatSMC      = gSMCTotalFix;
    gStatCH0C     = gSMCLastCH0C;

    NSString *dir = FFLogDir();
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];

    // ① 设置页读的域文件（键名必须与 Root.plist 的 key 逐字一致）
    NSDictionary *domain = @{
        @"loaded"  : (gHookInstalled ? @"是" : @"否"),
        @"blocked" : [NSString stringWithFormat:@"%d", gBlockedCount],
        @"smcfix"  : [NSString stringWithFormat:@"%d", gSMCTotalFix],
        // v0.5.0：SMC 实时开关 + 温控值（设置页一行看全，不必 SSH）
        //   开关 CH0C/CH0I 都是 0 = 系统没在"关充电"；任一是 1 = 系统用禁止位停充（我们能解除）
        // v0.5.1：追加 SMC 固件返回码 —— 非 00 表示上面这对读数本身无效（通道没通）
        @"smcnow"  : [NSString stringWithFormat:@"开关 %d/%d · 温控 %d/%d/%d · 返回码 %02X",
                      gSMCLastCH0C, gSMCLastCH0I,
                      gSMCLastCHTE, gSMCLastCHTC, gSMCLastCHTM,
                      (unsigned)(gSMCLastResult & 0xFF)],
        // 「强制充电工作中」的判据（v0.4.0 起为两者之一）：
        //   · gSMCRecovered —— 我们通过 SMC 把被系统关掉的充电真的打开了（主要路径）
        //   · gSessionBlocked > 0 —— 拦下了系统的停充写（历史路径，本机实测为空转）
        @"active"  : ((gSMCRecovered || gSessionBlocked > 0) ? @"工作中" : @"待命"),
    };
    FFWriteDomainPlist(@"ffstatus", domain);

    // ② 诊断文件（字段更全，人肉排查用）
    //    setterCalls 很关键：若它一直是 0，说明 powerd 压根没调用我们 hook 的那两个
    //    setter（hook 点不对）；若它 >0 而 blockedWriteCount==0，说明调了但键名没命中白名单。
    //    ⭐ v0.4.0 的 smc* 一组是「强制充电到底能不能做」的直接答案：
    //      smcCH0C  = 1 而 smcSessionFix = 0 → 系统在停充，但我们写不进去（权限/被覆盖）
    //      smcCH0C  = 0 而未充电           → 停充发生在更底层，用户态无解
    //      smcSessionFix > 0               → 功能真的在工作（圆点该是红的）
    NSDictionary *st = @{
        @"hookInstalled"     : @(gHookInstalled),
        @"forceEnabled"      : @(gForceFastCharge),
        @"charging"          : @(gLastCharging),
        @"active"            : @(gSMCRecovered || gSessionBlocked > 0),
        @"sessionBlocked"    : @(gSessionBlocked),
        @"blockedWriteCount" : @(gBlockedCount),
        @"setterCalls"       : @(gSetterCalls),
        @"smcRecovered"      : @(gSMCRecovered),
        @"smcSessionFix"     : @(gSMCSessFix),
        @"smcTotalFix"       : @(gSMCTotalFix),
        @"smcCH0C"           : @(gSMCLastCH0C),
        @"smcCH0I"           : @(gSMCLastCH0I),
        @"smcCH0B"           : @(gSMCLastCH0B),
        @"smcCHCE"           : @(gSMCLastCHCE),
        @"smcCH0R"           : @(gSMCLastCH0R),
        // v0.5.0：温控三兄弟 + 写通道自检结果（决定「能否解除系统限充」的直接证据）
        @"smcCHTE"           : @(gSMCLastCHTE),
        @"smcCHTC"           : @(gSMCLastCHTC),
        @"smcCHTM"           : @(gSMCLastCHTM),
        @"smcSelfTested"     : @(gSMCSelfTested),
        @"smcErr"            : @(gSMCErr),
        // v0.5.1：SMC 固件层返回码（0=接受）。与 smcErr 的区别：
        //   smcErr=0xe00002bc 且这里非 0 → io 通道通、SMC 固件拒绝（命令本身有问题）
        //   smcErr 是别的值               → io 层就拒了（权限/ABI）
        @"smcResult"         : @(gSMCLastResult),
        @"smcFailStreak"     : @(gSMCFailStreak),
        @"smcTempLimitC"     : @(FF_SMC_TEMP_LIMIT_C),
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
// v0.4.0：原来这里有个 readIsCharging()，现已被 readBatteryTelemetry() 取代
//（pollChargeState 需要同时拿到 ExternalConnected 与 IsCharging，一次读取更省）。
// 删掉而不是留着，避免 -Wunused-function 在 CI 上变成噪声甚至失败。

static BOOL gLastExt = NO;   // 上一轮的外部电源状态（v0.4.0：用它的上升沿划"充电会话"边界）

static void pollChargeState(void) {
    NSDictionary *t = readBatteryTelemetry();     // 一次读取，ext / charging 都用它
    BOOL ext      = [t[@"ExternalConnected"] boolValue];
    BOOL charging = [t[@"IsCharging"] boolValue];

    // ⭐ v0.4.0：会话边界改用 **ExternalConnected 的上升沿**（插线），
    //   而不是"charging 变 YES"。原因：本机实测系统经常**直接拒绝充电**
    //   （插上就是 IsCharging=NO），charging 永远不出现 YES 沿 —— 那样旧会话的
    //   "已恢复"计数会一直残留 → 圆点永远停在红/绿的错误状态。
    if (ext && !gLastExt) {
        gSessionBlocked = 0;
        gSMCSessFix     = 0;
        gSMCRecovered   = NO;
        gSMCFailStreak  = 0;
        logDiag(@"charging session start (plugged) -> counters reset");
    }
    BOOL extChanged = (ext != gLastExt);
    gLastExt = ext;

    if (charging != gLastCharging) {
        gLastCharging = charging;
        logDiag(@"charging state -> %@", charging ? @"YES" : @"NO");
        if (!charging) {
            // ⭐ 关键取证：系统**为什么**停充，以及我们有没有动手、动得成不成。
            //   ncr=0 正常 / 128 未接充电器 / 其余 = 被限（温度、电量、策略…）。
            //   smcCH0C = 1 且 smcFix = 0 → 系统的确关掉了充电开关，但我们没能写回去；
            //   smcCH0C = 0 且未充电     → 停充在 SMC 更底层，用户态无解。
            logDiag(@"charge stop reason: %@ sessionBlocked=%d smcFix=%d smcCH0C=%d smcCH0I=%d "
                    @"smcErr=0x%08x smcResult=0x%02x",
                    ffTelemetryLine(t), gSessionBlocked, gSMCSessFix, gSMCLastCH0C,
                    gSMCLastCH0I, (unsigned)gSMCErr, (unsigned)gSMCLastResult);
        }
        writeStatusFile();
        notify_post(FFChargeStateNotifName.UTF8String);
        return;
    }
    if (extChanged) {
        // ext 翻转（插/拔线）立刻落盘并通知 —— 圆点必须跟着插拔立即变，
        // 不能等下一次状态轮询（老板 v0.3.0 反馈的核心体验问题）。
        writeStatusFile();
        notify_post(FFChargeStateNotifName.UTF8String);
    }
}

// ---------------------------------------------------------------- 强制充电主逻辑（v0.4.0）
// ⭐ 实现**照搬上游 SBCPUChargeSMC 的恢复路径**（与 Battman restore command 同语义）：
//    系统把充电关掉之后，我们把 SMC 里的「禁止位」写回 0。
//
//      CH0C bit0 = 1 → 电池充电被禁止   → 写 0 恢复
//      CH0I bit0 = 1 → 外部供电被切断   → 写 0 恢复
//
//  ⚠️ 上游踩过的两个坑，这里刻意照抄其结论（不是自创）：
//    ① **恢复路径不做 CHCE / CH0R / OBC 安全检查**。
//       上游 V4.28 的教训：一旦禁止位生效，SMC 可能把 CH0R bit1 报成 No VBUS
//       （哪怕线物理上还插着）；若用这个状态去拒绝"恢复"，设备会**卡死在阻断态**。
//       所以这里 CH0R 只记录、不参与判断。
//    ② **写后必须回读确认**（上游 V4.29 的教训）：
//       IOConnectCallStructMethod 返回成功 ≠ SMC 接受；而且系统可能立刻覆盖回去。
//       只有回读 bit0 == 0 才算真的成功。
static void smcEnforceIfNeeded(void) {
    if (!gForceFastCharge) return;

    NSDictionary *t = readBatteryTelemetry();
    BOOL   ext      = [t[@"ExternalConnected"] boolValue];
    BOOL   charging = [t[@"IsCharging"] boolValue];
    double tempC    = [t[@"Temperature"] doubleValue] / 100.0;   // IOKit 给的是 1/100 ℃
    int    ncr      = [t[@"NotChargingReason"] intValue];

    // ⭐ v0.5.1：入口条件从「有线 **且** 未充电」放宽为「有线」。
    //   起因（功能盲区）：系统因温度限流时**往往只把电流压到 0，而 IsCharging 仍报 YES**。
    //   旧条件会让本函数直接 return ⇒ 永远不去读 SMC ⇒ 「系统关掉了充电开关」这件事
    //   既发现不了、也纠正不了。现在改为"读一次现场，由**禁止位**决定要不要动手"：
    //     CH0C/CH0I bit0 有 1  → 纠正（无论 IsCharging 报什么、无论充没充电）
    //     两位都是 0 且在充电 → 早退，不打扰
    if (!ext) return;

    // 读节流 10s（本函数挂在 2s tick 上，SMC 读没必要这么频繁）
    uint64_t nowRead = (uint64_t)dispatch_time(DISPATCH_TIME_NOW, 0);
    if (nowRead - gLastSMCReadNS < (uint64_t)(10.0 * NSEC_PER_SEC)) return;
    gLastSMCReadNS = nowRead;

    // 读 SMC 现场（CHCE / CH0R / CH0B 只作诊断，不参与判断 —— 见上文①）
    // ⚠️ v0.5.0：统一 4 字节读取。v0.4.0 写死 1 字节导致 CH0I/CHCE 恒读失败
    //   （真机 dataSize 是 4），详见 ff_smc_read_u32 上方注释。
    uint32_t ch0c = 0, ch0i = 0, chce = 0, ch0b = 0, ch0r = 0;
    uint32_t chte = 0, chtc = 0, chtm = 0;
    IOReturn rC = ff_smc_read_u32(FF_KEY4('C','H','0','C'), &ch0c);
    IOReturn rI = ff_smc_read_u32(FF_KEY4('C','H','0','I'), &ch0i);
    IOReturn rE = ff_smc_read_u32(FF_KEY4('C','H','C','E'), &chce);
    IOReturn rR = ff_smc_read_u32(FF_KEY4('C','H','0','R'), &ch0r);
    IOReturn rB = ff_smc_read_u32(FF_KEY4('C','H','0','B'), &ch0b);
    ff_smc_read_u32(FF_KEY4('C','H','T','E'), &chte);   // 温控：只观测
    ff_smc_read_u32(FF_KEY4('C','H','T','C'), &chtc);
    ff_smc_read_u32(FF_KEY4('C','H','T','M'), &chtm);

    if (rC != kIOReturnSuccess) {
        gSMCFailStreak++;
        logThrottled(@"smc: read CH0C failed io=0x%08x smcResult=0x%02x smcErr=0x%08x "
                     @"（io 通但 SMC 拒 → 命令/权限；io 就拒 → 无 SMC 权限）streak=%d",
                     (unsigned)rC, (unsigned)gSMCLastResult, (unsigned)gSMCErr, gSMCFailStreak);
        return;
    }
    gSMCLastCH0C = (int)ch0c;
    gSMCLastCH0I = (rI == kIOReturnSuccess) ? (int)ch0i : -1;
    gSMCLastCHCE = (rE == kIOReturnSuccess) ? (int)chce : -1;
    gSMCLastCH0B = (rB == kIOReturnSuccess) ? (int)ch0b : -1;
    gSMCLastCH0R = (rR == kIOReturnSuccess) ? (int)ch0r : -1;
    gSMCLastCHTE = (int)chte;
    gSMCLastCHTC = (int)chtc;
    gSMCLastCHTM = (int)chtm;

    BOOL needC = ((ch0c & 1) != 0);                       // 电池充电被禁止
    BOOL needI = (rI == kIOReturnSuccess && (ch0i & 1));  // 外部供电被切断

    // ⭐ 决定性判据：两个禁止位**都是 0** 却仍未充电 ⇒ 停充发生在 SMC 更底层
    //   （温度/VBUS/电量策略，或电池自身不请求充电）⇒ 用户态无解，别再空转。
    //   这条分支的存在，正是为了把「我们没工作」与「我们做了但没用」分开。
    if (!needC && !needI) {
        gSMCFailStreak = 0;
        // 正在正常充电且禁止位都是 0 ⇒ 系统自己干得好好的，绝不插手（也不刷日志）
        if (charging) return;
        logThrottled(@"smc: CH0C=0x%02x CH0I=0x%02x 均为允许，但未充电 → 停充不在这一层 "
                     @"ncr=%d temp=%.1fC CHCE=%u CH0R=0x%08x CH0B=0x%02x",
                     ch0c, ch0i, ncr, tempC, chce, ch0r, ch0b);
        return;
    }

    // 温度护栏（本插件自加，上游没有）：确认**需要纠正**之后才检查 ——
    //   超上限就不写，宁可充不动，也不在这一层绕过原厂热保护。理由见 README「风险」。
    //   v0.5.1 把它从函数入口挪到这里：入口放宽后，正常充电也会走到这片代码，
    //   若仍放在入口，正常充电 + 天热时会每 60s 刷一条无意义的 SKIP 日志。
    if (tempC >= FF_SMC_TEMP_LIMIT_C) {
        static uint64_t lastWarn = 0;
        uint64_t nw = (uint64_t)dispatch_time(DISPATCH_TIME_NOW, 0);
        if (nw - lastWarn > (uint64_t)(60.0 * NSEC_PER_SEC)) {
            lastWarn = nw;
            logDiag(@"smc: SKIP 温度 %.1fC >= %.0fC 上限 —— 不绕过原厂热保护 "
                    @"CH0C=%u CH0I=%u ncr=%d",
                    tempC, FF_SMC_TEMP_LIMIT_C, ch0c, ch0i, ncr);
        }
        return;
    }

    // 写节流：正常 10s 一次；连续失败 ≥3 次降为 60s 一次，避免对着 SMC 空转刷屏。
    uint64_t now = (uint64_t)dispatch_time(DISPATCH_TIME_NOW, 0);
    uint64_t gap = (gSMCFailStreak >= 3) ? (uint64_t)(60.0 * NSEC_PER_SEC)
                                         : (uint64_t)(10.0 * NSEC_PER_SEC);
    if (now - gLastSMCWriteNS < gap) return;
    gLastSMCWriteNS = now;

    BOOL okC = NO, okI = NO;

    if (needC) {
        // v0.5.0：改用 ff_smc_write_zero（4 字节零缓冲，内部按真实 dataSize 截取），
        // 不再写死 1 字节 —— 否则 CH0I 这类 4 字节键永远写不进去。
        gSMCLastResult = 0;
        IOReturn w = ff_smc_write_zero(FF_KEY4('C','H','0','C'));
        int wRes = gSMCLastResult;
        if (w != kIOReturnSuccess) {
            logDiag(@"smc: 写 CH0C=0 失败 io=0x%08x smcResult=0x%02x smcErr=0x%08x",
                    (unsigned)w, (unsigned)wRes, (unsigned)gSMCErr);
        } else {
            uint32_t back = 0xFFFFFFFFu;
            IOReturn rb = ff_smc_read_u32(FF_KEY4('C','H','0','C'), &back);
            okC = (rb == kIOReturnSuccess && (back & 1) == 0);
            gSMCLastCH0C = (int)back;
            if (!okC) logDiag(@"smc: CH0C 写 0 后回读仍 0x%08x（io=0x%08x）—— 被系统立刻覆盖",
                              (unsigned)back, (unsigned)rb);
        }
    } else {
        okC = YES;   // 本来就没被禁
    }

    if (needI) {
        gSMCLastResult = 0;
        IOReturn w = ff_smc_write_zero(FF_KEY4('C','H','0','I'));
        int wRes = gSMCLastResult;
        if (w != kIOReturnSuccess) {
            logDiag(@"smc: 写 CH0I=0 失败 io=0x%08x smcResult=0x%02x smcErr=0x%08x",
                    (unsigned)w, (unsigned)wRes, (unsigned)gSMCErr);
        } else {
            uint32_t back = 0xFFFFFFFFu;
            IOReturn rb = ff_smc_read_u32(FF_KEY4('C','H','0','I'), &back);
            okI = (rb == kIOReturnSuccess && (back & 1) == 0);
            gSMCLastCH0I = (int)back;
            if (!okI) logDiag(@"smc: CH0I 写 0 后回读仍 0x%08x（io=0x%08x）—— 被系统立刻覆盖",
                              (unsigned)back, (unsigned)rb);
        }
    } else {
        okI = YES;
    }

    if (okC && okI) {
        gSMCSessFix++;
        gSMCTotalFix++;
        gSMCFailStreak = 0;
        gSMCRecovered  = YES;             // 圆点转红：我们真的在阻止系统断流
        logDiag(@"smc: FIX 停充已纠正 CH0C %d→0 CH0I %d→0（本会话第 %d 次 / 累计 %d）ncr=%d %@",
                (needC ? 1 : 0), (needI ? 1 : 0), gSMCSessFix, gSMCTotalFix, ncr,
                ffTelemetryLine(t));
        writeStatusFile();                // 立即落盘 + 通知 SpringBoard 翻红
        notify_post(FFChargeStateNotifName.UTF8String);
    } else {
        gSMCFailStreak++;
    }
}

// ---------------------------------------------------------------- SMC 常驻探测（v0.5.0）
// ⭐ 为什么需要它（老板问「温度高了系统限充，插件能解除吗」时的取证手段）：
//   smcEnforceIfNeeded() 只在「有线 && 未充电」时才读 SMC。若系统限充时
//   IsCharging 仍报 YES（只是把电流压到 0），我们就**永远不去读** ——
//   那这个问题就没有数据可答。所以这里把"观测"与"纠正"**彻底分成两条路**：
//   只要有线，就周期性读一次 SMC 并落盘；任何形态的限流都会在日志里留下一行现场。
//
//   ★ 第一次探测另带**写通道自检**：在 CH0C 当前已是 0（允许）时写一次 0 再回读。
//     写的值就是当前值 ⇒ 对系统零副作用，却能立刻回答
//     「我们到底有没有 SMC 写权限」—— 这是"能不能解除限制"的前提。
static void smcProbeTick(void) {
    if (!gForceFastCharge) return;

    NSDictionary *t = readBatteryTelemetry();
    if (![t[@"ExternalConnected"] boolValue]) return;   // 没插线不探测

    uint32_t ch0c = 0, ch0i = 0, ch0b = 0, chce = 0, ch0r = 0;
    uint32_t chte = 0, chtc = 0, chtm = 0, chbi = 0, chks = 0;
    IOReturn rC = ff_smc_read_u32(FF_KEY4('C','H','0','C'), &ch0c);
    IOReturn rI = ff_smc_read_u32(FF_KEY4('C','H','0','I'), &ch0i);
    IOReturn rB = ff_smc_read_u32(FF_KEY4('C','H','0','B'), &ch0b);
    IOReturn rE = ff_smc_read_u32(FF_KEY4('C','H','C','E'), &chce);
    IOReturn rR = ff_smc_read_u32(FF_KEY4('C','H','0','R'), &ch0r);
    ff_smc_read_u32(FF_KEY4('C','H','T','E'), &chte);
    ff_smc_read_u32(FF_KEY4('C','H','T','C'), &chtc);
    ff_smc_read_u32(FF_KEY4('C','H','T','M'), &chtm);
    ff_smc_read_u32(FF_KEY4('C','H','B','I'), &chbi);
    ff_smc_read_u32(FF_KEY4('C','H','K','S'), &chks);

    if (rC != kIOReturnSuccess) {
        logDiag(@"smc probe: **读失败** CH0C io=0x%08x smcResult=0x%02x smcErr=0x%08x "
                @"—— AppleSMC 通道不可用（权限/ABI/SMC 拒绝）",
                (unsigned)rC, (unsigned)gSMCLastResult, (unsigned)gSMCErr);
        return;
    }
    gSMCLastCH0C = (int)ch0c;
    gSMCLastCH0I = (rI == kIOReturnSuccess) ? (int)ch0i : -1;
    gSMCLastCH0B = (rB == kIOReturnSuccess) ? (int)ch0b : -1;
    gSMCLastCHCE = (rE == kIOReturnSuccess) ? (int)chce : -1;
    gSMCLastCH0R = (rR == kIOReturnSuccess) ? (int)ch0r : -1;
    gSMCLastCHTE = (int)chte;  gSMCLastCHTC = (int)chtc;  gSMCLastCHTM = (int)chtm;

    // 写通道自检：只做一次；严格限制在"禁止位本来就是 0"（写 0 == 写当前值）。
    // v0.5.1：额外抓写那一刻的 SMC 固件返回码 —— 它是区分
    //   「io 层拒绝」与「io 通但 SMC 固件拒绝」的唯一依据。
    if (!gSMCSelfTested) {
        gSMCSelfTested = YES;
        if ((ch0c & 1) == 0) {
            gSMCLastResult = 0;
            IOReturn w = ff_smc_write_zero(FF_KEY4('C','H','0','C'));
            int wRes = gSMCLastResult;                 // 写自己的 result（别被后面的回读刷掉）
            uint32_t back = 0xFFFFFFFFu;
            IOReturn rb = ff_smc_read_u32(FF_KEY4('C','H','0','C'), &back);
            BOOL writable = (w == kIOReturnSuccess && rb == kIOReturnSuccess && (back & 1) == 0);
            logDiag(@"smc probe: 写通道自检 CH0C(写0) io=0x%08x smcResult=0x%02x → 回读 0x%08x (io=0x%08x) = %@",
                    (unsigned)w, (unsigned)wRes, (unsigned)back, (unsigned)rb,
                    writable ? @"**可写**" : @"不可写");
        }
    }

    // 现场一行。判读：
    //   CH0C=0 CH0I=0 且 CHBI=0 ⇒ 开关都开着却没电流 = 限流在 SMC 更底层（温度/VBUS 策略）
    //   CH0C=1 或 CH0I=1        ⇒ 系统用「禁止位」停充 —— 这是我们能写回去解除的
    //   smcResult=0x00          ⇒ 上面这行读数是可信的；非 0 说明读数本身无效
    logDiag(@"smc probe: CH0C=%u CH0I=%u CH0B=%u CHCE=%u CH0R=0x%08x | 温控 CHTE=%u CHTC=%u CHTM=%u "
            @"| CHBI=%umA CHKS=%u | smcResult=0x%02x | charging=%d %@",
            ch0c, ch0i, ch0b, chce, (unsigned)ch0r, chte, chtc, chtm,
            chbi, chks, (unsigned)gSMCLastResult,
            [t[@"IsCharging"] boolValue], ffTelemetryLine(t));

    // v0.5.1：逐个键上报 io 返回码 —— 上面那行若出现"疑似全零"的读数
    //   （如 CHCE=0 但明明插着线、CHBI=0 但明明在充电），看这行就知道是哪个键读失败。
    //   ⭐ 全部 0x00000000 且读数合理 ⇒ SMC 通道完全正常。
    if (rC != kIOReturnSuccess || rI != kIOReturnSuccess || rE != kIOReturnSuccess ||
        rR != kIOReturnSuccess || rB != kIOReturnSuccess) {
        logDiag(@"smc probe: 部分键读失败 — per-key io CH0C=0x%08x CH0I=0x%08x CHCE=0x%08x "
                @"CH0R=0x%08x CH0B=0x%08x smcResult=0x%02x（0x00=全部正常）",
                (unsigned)rC, (unsigned)rI, (unsigned)rE, (unsigned)rR, (unsigned)rB,
                (unsigned)gSMCLastResult);
    }
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

// ---------------------------------------------------------------- 连接→服务映射（v0.3.0）
// 为下面 IOConnectCall* 探针服务：把 user client 句柄映射回它所属的 IO service 类名，
// 这样日志里才能说出「是 AppleSMC 还是 AppleSmartBatteryManager 在发命令」。
// 刻意用**定长数组 + 线性扫描**（零锁、零分配）：这些探针挂在 powerd 的热路径上，
// 不能为纯诊断引入互斥或 ObjC 分配。
#define FF_CONN_MAX 32
static mach_port_t gConnPort[FF_CONN_MAX];
static char        gConnCls [FF_CONN_MAX][64];
static int         gConnCnt = 0;

static void ff_connRemember(mach_port_t port, const char *cls) {
    if (!cls || !cls[0]) return;
    for (int i = 0; i < gConnCnt && i < FF_CONN_MAX; i++) {
        if (gConnPort[i] == port) {                       // 句柄复用 → 覆盖类名
            strncpy(gConnCls[i], cls, sizeof(gConnCls[i]) - 1);
            gConnCls[i][sizeof(gConnCls[i]) - 1] = '\0';
            return;
        }
    }
    if (gConnCnt < FF_CONN_MAX) {
        gConnPort[gConnCnt] = port;
        strncpy(gConnCls[gConnCnt], cls, sizeof(gConnCls[gConnCnt]) - 1);
        gConnCls[gConnCnt][sizeof(gConnCls[gConnCnt]) - 1] = '\0';
        gConnCnt++;
    }
}

static const char *ff_connClassOf(mach_port_t port) {
    for (int i = 0; i < gConnCnt && i < FF_CONN_MAX; i++) {
        if (gConnPort[i] == port) return gConnCls[i];
    }
    return "(unknown)";
}

// ---------------------------------------------------------------- IOConnectCall* 探针（v0.3.0，只观测不拦截）
// ⭐ 为什么必须有它（回答"强制充电到底能不能做"）：
//   v0.2.x 的实机证据已经证明 powerd **不通过** IORegistryEntrySetCFProperty 控制充电
//   —— setterCalls 从 boot 后恒为 22 再不增长，且全是 TimeZoneOffsetSeconds /
//   SleepWakeUUID 这类系统键，整个充电会话里 0 次充电相关写。也就是说
//   「拦 IOKit setter」这条路在 iOS 16.6.1 上根本没有承载逻辑，是空转。
//   剩下的唯一可能通道就是 user client 的 external method：
//     powerd 打开 AppleSmartBatteryManager / AppleSMC 后，
//     若通过 IOConnectCallMethod/StructMethod 下发充电控制，那我们 hook 这两个
//     函数就能看到 (service, selector)。
//   ⚠️ 本探针**只记录，绝不改动**任何参数或返回值 —— externalMethod 的参数结构
//      未知，盲拦有把电池通信搞坏的风险。等日志证明确实用它，再决定要不要动。
//   只盯电源/电池链路的 service，其它（KeyStore 等）噪声太大直接忽略。
static BOOL ff_shouldWatchConn(const char *cls) {
    if (!cls || !cls[0]) return NO;
    static const char *watch[] = {
        "AppleSmartBattery", "AppleSMC", "IOPMrootDomain", "AppleSmartBatteryManager"
    };
    for (size_t i = 0; i < sizeof(watch) / sizeof(watch[0]); i++) {
        if (strstr(cls, watch[i])) return YES;
    }
    return NO;
}

// 去重表：只记「出现过哪些 selector」，不记次数（避免热路径计数开销）
#define FF_SEL_MAX 128
static uint32_t gSelSeen[FF_SEL_MAX];
static int      gSelCnt = 0;

static void ff_noteConnCall(mach_port_t conn, uint32_t selector, const char *api) {
    const char *cls = ff_connClassOf(conn);
    if (!ff_shouldWatchConn(cls)) return;
    for (int i = 0; i < gSelCnt && i < FF_SEL_MAX; i++) {
        if (gSelSeen[i] == selector) return;             // 已记过
    }
    if (gSelCnt >= FF_SEL_MAX) return;
    gSelSeen[gSelCnt++] = selector;
    logDiag(@"io-conn %s: %s selector=%u", api, cls, selector);
}

typedef kern_return_t (*IOConnectCallMethodFn)(mach_port_t, uint32_t,
                                               const uint64_t *, uint32_t,
                                               const void *, size_t,
                                               uint64_t *, uint32_t *,
                                               void *, size_t *);
typedef kern_return_t (*IOConnectCallStructMethodFn)(mach_port_t, uint32_t,
                                                     const void *, size_t,
                                                     void *, size_t *);
typedef kern_return_t (*IOConnectCallScalarMethodFn)(mach_port_t, uint32_t,
                                                     const uint64_t *, uint32_t,
                                                     uint64_t *, uint32_t *);

static IOConnectCallMethodFn       orig_IOConnectMethod     = NULL;
static IOConnectCallStructMethodFn orig_IOConnectStructMeth = NULL;
static IOConnectCallScalarMethodFn orig_IOConnectScalarMeth = NULL;

static kern_return_t hook_IOConnectCallMethod(mach_port_t conn, uint32_t selector,
                                              const uint64_t *input, uint32_t inputCnt,
                                              const void *inputStruct, size_t inputStructCnt,
                                              uint64_t *output, uint32_t *outputCnt,
                                              void *outputStruct, size_t *outputStructCnt) {
    @try { ff_noteConnCall(conn, selector, "method"); } @catch (NSException *e) {}
    return orig_IOConnectMethod
        ? orig_IOConnectMethod(conn, selector, input, inputCnt, inputStruct, inputStructCnt,
                               output, outputCnt, outputStruct, outputStructCnt)
        : KERN_FAILURE;
}

static kern_return_t hook_IOConnectCallStructMethod(mach_port_t conn, uint32_t selector,
                                                    const void *inputStruct, size_t inputStructCnt,
                                                    void *outputStruct, size_t *outputStructCnt) {
    @try { ff_noteConnCall(conn, selector, "struct"); } @catch (NSException *e) {}
    return orig_IOConnectStructMeth
        ? orig_IOConnectStructMeth(conn, selector, inputStruct, inputStructCnt,
                                   outputStruct, outputStructCnt)
        : KERN_FAILURE;
}

static kern_return_t hook_IOConnectCallScalarMethod(mach_port_t conn, uint32_t selector,
                                                    const uint64_t *input, uint32_t inputCnt,
                                                    uint64_t *output, uint32_t *outputCnt) {
    @try { ff_noteConnCall(conn, selector, "scalar"); } @catch (NSException *e) {}
    return orig_IOConnectScalarMeth
        ? orig_IOConnectScalarMeth(conn, selector, input, inputCnt, output, outputCnt)
        : KERN_FAILURE;
}

// 纯诊断：记录 powerd 打开了哪些 IO service（去重、上限 64）。
// 目的：判断它是否走 `AppleSmartBatteryManagerUserClient`（IOConnectCallMethod）那
// 条通道。那条通道我们**只观测不拦截** —— externalMethod 的参数结构未知，
// 盲拦有把电池通信搞坏的风险；等日志证明确实用它，再决定要不要动。
static kern_return_t hook_IOServiceOpen(io_service_t service, task_port_t owningTask,
                                        uint32_t type, io_connect_t *connect) {
    kern_return_t kr = orig_SvcOpen ? orig_SvcOpen(service, owningTask, type, connect)
                                    : KERN_FAILURE;
    // ⚠️ v0.4.0：跳过「我们自己开 AppleSMC」的那一次 —— 否则日志里会出现
    //    重复的 "IO service opened: AppleSMC"，让人误判 powerd 又去开了一次 SMC。
    if (kr == KERN_SUCCESS && !gSMCSelfOpen) {
        @try {
            io_name_t cls = {0};
            if (IOObjectGetClass(service, cls) == KERN_SUCCESS && cls[0]) {
                // ⭐ v0.3.0：先登记句柄→类名映射，供 IOConnectCall* 探针反查
                ff_connRemember(*connect, cls);
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
    // ⭐ v0.3.0：user client external method 探针（只观测不拦截）。
    //   用途：判定 powerd 是否通过 AppleSmartBatteryManager / AppleSMC 的
    //   external method 下发充电控制 —— 这是「拦 IOKit setter」失效后
    //   唯一还没被排除的用户态通道。符号不存在则跳过（不同机型/系统可能没有）。
    void *p4 = dlsym(handle, "IOConnectCallMethod");
    if (p4 && !orig_IOConnectMethod) {
        MSHookFunction(p4, (void *)hook_IOConnectCallMethod, (void **)&orig_IOConnectMethod);
    }
    void *p5 = dlsym(handle, "IOConnectCallStructMethod");
    if (p5 && !orig_IOConnectStructMeth) {
        MSHookFunction(p5, (void *)hook_IOConnectCallStructMethod, (void **)&orig_IOConnectStructMeth);
    }
    void *p6 = dlsym(handle, "IOConnectCallScalarMethod");
    if (p6 && !orig_IOConnectScalarMeth) {
        MSHookFunction(p6, (void *)hook_IOConnectCallScalarMethod, (void **)&orig_IOConnectScalarMeth);
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
    // v0.5.0：先探测后回报 —— 这样 heartbeat 行里的 smc[...] 是**这一拍的真实值**，
    //         而不是上一次纠正尝试留下的陈旧快照。有线才探测（内部自判）。
    smcProbeTick();
    // ⭐ v0.3.0：idle 分支也带遥测。
    //   起因：老板报「76% 就停了不充了」，而当时日志只有一行 charge stop reason，
    //   无法分辨「他拔线了(ext=0)」还是「线插着系统停充(ext=1)」。放电静置时
    //   每 60s 带一次 ext/ncr/temp，任何时刻取日志都能一眼判定线在不在、
    //   系统是不是在限流（vac 被压低 / ncr 非 0）。
    //   （两个分支内容已一致，合并成一条；输出的仍是 "heartbeat idle pid=" /
    //    "heartbeat charging pid="，老的 grep 习惯不受影响。）
    // ⭐ v0.4.0 加 smc 一组：任何时刻取**一行**心跳，就能同时判断
    //   「系统的充电开关现在开还是关」「我们救回来过几次」「SMC 通道通不通」。
    logDiag(@"heartbeat %@ pid=%d hooks=%d force=%d %@ sessionBlocked=%d blocked=%d setterCalls=%d "
            @"smc[CH0C=%d CH0I=%d CH0B=%d CHCE=%d CH0R=%d 温控 tE=%d tC=%d tM=%d "
            @"fix=%d/%d err=0x%08x res=0x%02x streak=%d rec=%d selftest=%d]",
            gLastCharging ? @"charging" : @"idle",
            (int)getpid(), gHookInstalled, gForceFastCharge,
            ffTelemetryLine(readBatteryTelemetry()),
            gSessionBlocked, gBlockedCount, gSetterCalls,
            gSMCLastCH0C, gSMCLastCH0I, gSMCLastCH0B, gSMCLastCHCE, gSMCLastCH0R,
            gSMCLastCHTE, gSMCLastCHTC, gSMCLastCHTM,
            gSMCSessFix, gSMCTotalFix, (unsigned)gSMCErr, (unsigned)gSMCLastResult, gSMCFailStreak,
            (int)gSMCRecovered, (int)gSMCSelfTested);
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
        logDiag(@"hooks installed (set=%d, setProps=%d, svcSet=%d, svcOpen=%d, connMethod=%d, connStruct=%d, connScalar=%d)",
                orig_SetCFProp != NULL, orig_SetCFProps != NULL,
                orig_SvcSetCFProp != NULL, orig_SvcOpen != NULL,
                orig_IOConnectMethod != NULL, orig_IOConnectStructMeth != NULL,
                orig_IOConnectScalarMeth != NULL);
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
        // ⚠️ 必须存进文件级静态 gTimer（见其声明处的说明）——
        //    写成局部变量会被 ARC 提前释放，定时器静默失效（v0.2.1 实机踩坑）。
        gTimer = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        if (gTimer) {
            dispatch_source_set_timer(gTimer,
                                      dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                                      2 * NSEC_PER_SEC,
                                      300 * NSEC_PER_SEC / 1000);   // 300ms leeway
            dispatch_source_set_event_handler(gTimer, ^{
                if (gHookInstalled) {
                    gTickCount++;
                    updateChargeState();
                    pollChargeState();
                    // ⭐ v0.4.0 核心：系统停充就把 SMC 的充电开关写回"允许"。
                    //   放在 pollChargeState 之后 —— 那边刚刷新的 ext/charging 状态
                    //   决定这里要不要动手（只在"有线但没充"时才介入）。
                    smcEnforceIfNeeded();
                    heartbeatTick();     // v0.2.1：60s 一次存活心跳（含充电遥测 + SMC 现场）
                }
            });
            dispatch_resume(gTimer);
        }
    }
}
