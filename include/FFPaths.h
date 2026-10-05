#ifndef FF_PATHS_H
#define FF_PATHS_H

#import <Foundation/Foundation.h>
#import <notify.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>

// 偏好域与上次 ChargeControl 保持一致，方便直接沿用已有开关状态
static NSString *const FFPrefDomain = @"com.chargecontrol";

// 开关键
static NSString *const kFFForceFastChargeKey  = @"forceChargeEnabled";
// 高温强制：额外吞掉温控派生的降流键（默认关，风险高，详见 README）
static NSString *const kFFThermalOverrideKey  = @"forceThermalOverrideEnabled";
// 指示点显示模式（整数偏好）
//   0 = 自动（默认）：强制快充开启时，充电中显示蓝色，不充电显示绿色
//   1 = 常显：强制快充一开就一直显示
//   2 = 仅强制：只看开关，不区分充电色
//   3 = 关闭：完全不显示
static const NSInteger kFFShowModeAuto      = 0;
static const NSInteger kFFShowModeAlways    = 1;
static const NSInteger kFFShowModeForceOnly = 2;
static const NSInteger kFFShowModeOff       = 3;
static NSString *const kFFIndicatorModeKey   = @"indicatorShowMode";
// 指示点坐标（可配置，空/0 回退默认）
static NSString *const kFFDotXKey             = @"dotX";
static NSString *const kFFDotYKey             = @"dotY";

// 默认坐标：灵动岛右侧外、与系统绿点同水平线（对齐 TGK v1.0.64 实测值）
static const CGFloat kFFDotXDefault = 294.0;
static const CGFloat kFFDotYDefault = 29.4;

// 设置变更 Darwin 通知（设置页 post，powerd 侧监听即时生效）
// ⚠️ 必须是 CFStringRef —— CFNotificationCenterAddObserver 要 CFStringRef，
//    notify_post 接受 const char*，两者可由同一字面量分别包装。
static NSString *const FFSettingsChangedNotifName = @"com.chargecontrol/settingsChanged";
// 充电状态变化通知（powerd 侧 post，SpringBoard 侧监听以更新指示点）
static NSString *const FFChargeStateNotifName = @"com.chargecontrol/chargeStateChanged";

// 注意：设置 bundle 与指示器 target 都 include 本头文件但未必用到每个 helper，
// Theos 默认 -Werror 会因未使用的 static inline 函数报错，故统一标 unused。
#define FF_UNUSED __attribute__((unused))

static FF_UNUSED NSString *FFLogDir(void) {
    return @"/var/mobile/ForceFastCharge";
}

static FF_UNUSED NSString *FFPrefPath(void) {
    return [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", FFPrefDomain];
}

// 状态标志文件：由 powerd 侧写入，设置页读取并展示「是否真的在生效」
static FF_UNUSED NSString *FFStatusPath(void) {
    return [FFLogDir() stringByAppendingPathComponent:@"status.plist"];
}

// ---------------------------------------------------------------- 早期诊断
// 【为什么需要它】v0.1.0/v0.1.1 的 %ctor 用
//     if (![[NSProcessInfo processInfo].processName isEqualToString:@"powerd"]) return;
// 做进程判定。实测（CocoaTop 可见 dylib 已在进程内，但零日志/零功能）：
// 系统守护进程（powerd 等非 App bundle）的 processName 并不保证返回短名，
// 判定为 false → %ctor 直接 return → 后面所有日志与 hook 一行都不执行，
// 表现为「注入了却什么都没发生」，极难排查。
// 这里做两件事：
//   1) FFBootLog：纯 POSIX 写盘，不依赖 ObjC 运行时/Foundation，
//      保证只要 dylib 被加载就一定能留下痕迹（含真实进程名）。
//   2) FFProcName：优先 getprogname()（argv[0] basename，最可靠），
//      回退 NSProcessInfo.processName，调用方再用「包含匹配」兜底。
static FF_UNUSED void FFBootLog(const char *tag) {
    mkdir("/var/mobile/ForceFastCharge", 0755);
    // 多路径回退：万一被注入进程有沙盒限制写不进 /var/mobile，
    // 仍能在 /var/tmp 留下痕迹——用于严格区分「%ctor 没跑」与「跑了但写盘被拒」。
    const char *cands[3] = {
        "/var/mobile/ForceFastCharge/boot.log",
        "/var/tmp/ff_boot.log",
        "/tmp/ff_boot.log"
    };
    for (int i = 0; i < 3; i++) {
        int fd = open(cands[i], O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd < 0) continue;
        const char *pg = getprogname();
        char buf[640];
        int n = snprintf(buf, sizeof(buf), "[%s] path=%s pid=%d progname=%s\n",
                         tag ? tag : "?", cands[i], (int)getpid(), pg ? pg : "(null)");
        if (n > 0) (void)write(fd, buf, (size_t)n);
        close(fd);
        return;
    }
}

// 进程短名：getprogname() 优先（对 daemon 也返回 argv[0] 的 basename）
static FF_UNUSED NSString *FFProcName(void) {
    const char *pg = getprogname();
    if (pg && strlen(pg) > 0) return [NSString stringWithUTF8String:pg];
    NSString *n = [NSProcessInfo processInfo].processName;
    return n ? [n lastPathComponent] : @"";
}

// 进程判定：短名与 processName 任一「包含」关键字即命中（大小写不敏感）。
// 刻意不用 isEqualToString——那正是 v0.1.x 全盘失效的原因。
static FF_UNUSED BOOL FFIsProcess(NSString *keyword) {
    if (keyword.length == 0) return NO;
    NSString *k = [keyword lowercaseString];
    NSString *a = [FFProcName() lowercaseString];
    NSString *b = [[[NSProcessInfo processInfo].processName lastPathComponent] lowercaseString];
    return ([a rangeOfString:k].location != NSNotFound) ||
           ([b rangeOfString:k].location != NSNotFound);
}

#endif
