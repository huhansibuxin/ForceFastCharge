#ifndef FF_PATHS_H
#define FF_PATHS_H

#import <Foundation/Foundation.h>
#import <notify.h>
#import <dlfcn.h>
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
// 【v0.1.4 起只有两项，设置页也只暴露这两项】
//
// 老板的核心诉求只有一句：**我们插件真在干活时亮红点** —— 圆点就是用来判断
// 「强制快充到底有没有起作用」的。所以默认落在「仅强制」，开箱即只有一个判断点。
//
//   2 = 仅强制（**默认**）：只有我们真的拦到系统降流时才显示红点；我们没干活就不显示。
//   1 = 常显（备选，老板自己不用）：只要在充电就显示
//         绿 = 系统原生充电（我们没介入，系统自己就充得很好）
//         红 = 我们正在拦系统的降流写（强制快充确实在干活）
//   ⚠️ 不充电时两个模式都不显示。
//
// ⚠️ 判据不是「强制快充开关开没开」（老板的开关是常开的），而是
//    「我们这一轮充电里有没有真的拦到系统降流」= powerd 侧的 sessionBlocked > 0。
//
// ⚠️ 数值刻意沿用 1/2：旧版的 1=常显、2=仅强制 语义与此一致，
//    老配置不会错位，**无需任何迁移代码**。
//    旧值 0（「自动」）已废弃，归一化为 2（见 Settings/FRootListController.m）。
static const NSInteger kFFShowModeAlways    = 1;
static const NSInteger kFFShowModeForceOnly = 2;
// 关闭：不再出现在设置页，仅保留为代码级兜底（临时屏蔽圆点用）
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

// ================================================================ jbroot 定位
// 【为什么必须做，v0.1.3 核心修复】
// roothide 隐根下，被 RootHide 处理过的进程（设置 App、SpringBoard）读写
//   /var/mobile/Library/Preferences/x.plist
// 会被**自动重定向**到 jbroot 内：
//   /var/mobile/Containers/Shared/AppGroup/.jbroot-XXXX/var/mobile/Library/Preferences/x.plist
// 而注入 powerd 的 dylib 跑在系统进程里，直读直写的是**真实 rootfs** 那份。
// 两边根本不是同一个文件 → 「开关打开了没反应」「设置页永远显示未加载」。
// 实测铁证（2026-10-05）：
//   真实 rootfs /var/mobile/Library/Preferences/com.chargecontrol.plist —— 不存在
//   jbroot    .jbroot-XXXX/var/mobile/Library/Preferences/com.chargecontrol.plist —— 设置页写的在这
// 所以必须自己算出 jbroot 前缀，让 dylib 与设置页读写同一份文件。
//
// 三级回退：① dladdr 从自身镜像物理路径反推 → ② 扫目录找 .jbroot-* → ③ /var/jb
static FF_UNUSED NSString *FFJbrootPrefix(void) {
    static NSString *prefix = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @autoreleasepool {
            // ① dladdr：被注入的 dylib 物理路径形如
            //    /private/var/containers/Bundle/Application/.jbroot-XXXX/usr/lib/TweakInject/X.dylib
            //    掐掉 /usr/lib/TweakInject/ 之前那段就是 jbroot 前缀。
            @try {
                Dl_info info;
                if (dladdr((const void *)&FFJbrootPrefix, &info) && info.dli_fname) {
                    NSString *p = [NSString stringWithUTF8String:info.dli_fname];
                    NSArray<NSString *> *marks = @[
                        @"/usr/lib/TweakInject/",
                        @"/Library/MobileSubstrate/DynamicLibraries/",
                        // 设置 bundle 自己也要能定位（它在 /Library/PreferenceBundles/ 下）。
                        // 不写这条时设置进程只能靠下面的目录扫描兜底 —— 能work但绕远。
                        @"/Library/PreferenceBundles/"
                    ];
                    for (NSString *m in marks) {
                        NSRange r = [p rangeOfString:m];
                        if (r.location != NSNotFound && r.location > 0) {
                            NSString *cand = [p substringToIndex:r.location];
                            if ([cand containsString:@".jbroot-"]) { prefix = cand; break; }
                        }
                    }
                }
            } @catch (NSException *e) {}

            // ② 目录扫描（系统进程里 dladdr 可能只给逻辑路径，拿不到 .jbroot- 串）。
            //    ⚠️ 每次重启 jbroot 随机串都会变，旧目录可能残留 → 不能盲取第一个，
            //    优先选「里面确实有本插件偏好文件」的那个，避免读到已废弃的旧 jbroot。
            if (!prefix.length) {
                @try {
                    NSFileManager *fm = [NSFileManager defaultManager];
                    NSArray<NSString *> *bases = @[
                        @"/var/containers/Bundle/Application",
                        @"/var/mobile/Containers/Shared/AppGroup"
                    ];
                    NSString *probe = [NSString stringWithFormat:
                        @"/var/mobile/Library/Preferences/%@.plist", FFPrefDomain];
                    NSString *firstFound = nil;
                    for (NSString *base in bases) {
                        for (NSString *e in [fm contentsOfDirectoryAtPath:base error:nil]) {
                            if (![e hasPrefix:@".jbroot-"]) continue;
                            NSString *cand = [base stringByAppendingPathComponent:e];
                            if (!firstFound) firstFound = cand;
                            // 命中「偏好文件存在」→ 这就是当前活跃的 jbroot，直接采用
                            if ([fm fileExistsAtPath:[cand stringByAppendingString:probe]]) {
                                firstFound = cand;
                                prefix = cand;
                                break;
                            }
                        }
                        if (prefix.length) break;
                    }
                    if (!prefix.length && firstFound) prefix = firstFound;
                } @catch (NSException *e) {}
            }
        }
        if (!prefix) prefix = @"";
    });
    return prefix;
}

// 把「逻辑路径」映射到当前进程该用的实际路径（有 jbroot 前缀就带上）
static FF_UNUSED NSString *FFJbrootPath(NSString *absPath) {
    if (![absPath hasPrefix:@"/"]) return absPath;
    NSString *jb = FFJbrootPrefix();
    if (jb.length > 0) return [jb stringByAppendingString:absPath];
    return absPath;
}

// ---------------------------------------------------------------- 偏好读写路径
// 读：把「所有能发现的 jbroot 版本」+ 真实版 + /var/jb 版都列上，逐个试、
//     取第一个真正含关键键的（见 FFReadPrefsDict）。
// ⚠️ 只列「自己推导出的那一个 jbroot」不够稳：若推导偏了（dladdr 拿不到、
//    扫描撞上残留旧目录），就会整个读空。这里把所有 .jbroot-* 都枚举进来兜底。
static FF_UNUSED NSArray<NSString *> *FFPrefCandidates(void) {
    NSString *rel = [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", FFPrefDomain];
    NSMutableArray<NSString *> *a = [NSMutableArray array];

    // ① 自己推导出的 jbroot（最可能对，排最前）
    NSString *jb = FFJbrootPrefix();
    if (jb.length) [a addObject:[jb stringByAppendingString:rel]];

    // ② 其余所有 .jbroot-*（含可能残留的旧目录，顺序靠后不影响正确性）
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray<NSString *> *bases = @[
            @"/var/containers/Bundle/Application",
            @"/var/mobile/Containers/Shared/AppGroup"
        ];
        for (NSString *base in bases) {
            for (NSString *e in [fm contentsOfDirectoryAtPath:base error:nil]) {
                if (![e hasPrefix:@".jbroot-"]) continue;
                NSString *p = [[base stringByAppendingPathComponent:e] stringByAppendingString:rel];
                if (![a containsObject:p]) [a addObject:p];
            }
        }
    } @catch (NSException *e) {}

    // ③ 真实 rootfs 与 /var/jb 兜底
    [a addObject:rel];
    [a addObject:[@"/var/jb" stringByAppendingString:rel]];
    return a;
}

static FF_UNUSED NSString *FFPrefPath(void) {
    NSArray<NSString *> *cands = FFPrefCandidates();
    for (NSString *p in cands) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return p;
    }
    return cands.firstObject ?: cands[0];
}

// 读偏好字典：逐个候选路径找**确实含本插件开关键**的那份。
// ⚠️ 不能只取「第一个存在的文件」——残留的旧 jbroot 里可能有一份陈旧副本，
//    取到它就会读到过期的开关值。以关键键是否存在为准，最后回退到第一个非空。
static FF_UNUSED NSDictionary *FFReadPrefsDict(void) {
    NSDictionary *firstNonEmpty = nil;
    for (NSString *p in FFPrefCandidates()) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (!d.count) continue;
        if (!firstNonEmpty) firstNonEmpty = d;
        if (d[kFFForceFastChargeKey] || d[kFFThermalOverrideKey]) return d;
    }
    return firstNonEmpty;
}

// 写状态文件：供设置页 PSValueCell 从 defaults=com.chargecontrol.<suffix> 域读取。
// ⚠️ 设置页（被 roothide 重定向到 jbroot）与 powerd（可能直读真实 rootfs）看到的
//    不是同一个文件，所以这里**把所有候选路径都写一遍**（幂等、代价极小），
//    保证无论哪一侧、无论 jbroot 推导成功与否，都能读到同一份最新状态。
//    返回第一个写成功的路径（仅用于诊断日志）。
static FF_UNUSED NSString *FFWriteDomainPlist(NSString *suffix, NSDictionary *dict) {
    NSString *rel = [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.%@.plist",
                     FFPrefDomain, suffix];
    NSMutableArray<NSString *> *cands = [NSMutableArray array];
    NSString *jb = FFJbrootPrefix();
    if (jb.length) [cands addObject:[jb stringByAppendingString:rel]];
    [cands addObject:rel];
    [cands addObject:[@"/var/jb" stringByAppendingString:rel]];
    NSString *okPath = nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in cands) {
        @try {
            // 父目录不存在则先建（jbroot 内的 Preferences 目录在部分场景下可能缺失）
            [fm createDirectoryAtPath:[p stringByDeletingLastPathComponent]
          withIntermediateDirectories:YES attributes:nil error:nil];
            if ([dict writeToFile:p atomically:YES] && !okPath) okPath = p;
        } @catch (NSException *e) {}
    }
    return okPath;
}

// 写回**主偏好域**的一个键（设置页做旧值归一化用）。
// 与 FFWriteDomainPlist 同理：所有候选路径都写，避免写错 jbroot 那一份。
// 注意先读出「确实含本插件键」的那份再改，否则会把别的键一起洗掉。
static FF_UNUSED void FFUpdatePrefsKey(NSString *key, id value) {
    if (!key.length || !value) return;
    NSDictionary *cur = FFReadPrefsDict();
    NSMutableDictionary *d = cur ? [cur mutableCopy] : [NSMutableDictionary dictionary];
    d[key] = value;

    NSString *rel = [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", FFPrefDomain];
    NSMutableArray<NSString *> *cands = [NSMutableArray array];
    NSString *jb = FFJbrootPrefix();
    if (jb.length) [cands addObject:[jb stringByAppendingString:rel]];
    [cands addObject:rel];
    [cands addObject:[@"/var/jb" stringByAppendingString:rel]];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in cands) {
        @try {
            [fm createDirectoryAtPath:[p stringByDeletingLastPathComponent]
          withIntermediateDirectories:YES attributes:nil error:nil];
            [d writeToFile:p atomically:YES];
        } @catch (NSException *e) {}
    }
}

// ---------------------------------------------------------------- 诊断日志目录
// ⚠️ 必须放 mobile 可写的位置。
// 教训（v0.1.2 实机）：日志写在 /var/mobile/ForceFastCharge/，该目录是 powerd(root)
// 创建的 root:mobile 0755 —— SpringBoard 以 mobile 身份运行，**写不进去且静默失败**，
// 于是"SB 侧一行日志都没有"，白白排查半天。
// /var/mobile/Documents 是 mobile 拥有、且不会被 RootHide 重定向的位置（多个插件已验证）。
static FF_UNUSED NSString *FFLogDir(void) {
    return @"/var/mobile/Documents/ForceFastCharge";
}

// powerd 侧写的诊断状态文件（SpringBoard 侧读它兜底拿 charging 状态）。
// v0.1.3：与设置页读的「域文件」分开——域文件是给 PSValueCell 的，
// 诊断文件字段更全，供人肉排查 / 指示器回退读取。
static FF_UNUSED NSString *FFStatusPath(void) {
    return [FFLogDir() stringByAppendingPathComponent:@"ff_status.plist"];
}

// ---------------------------------------------------------------- 早期诊断
// 纯 POSIX 写盘，不依赖 ObjC 运行时/Foundation，保证只要 dylib 被加载就一定有痕迹。
// 目录权限用 0777 并显式 chmod：这样无论 powerd(root) 还是 SpringBoard(mobile)
// 谁先创建，另一个都能继续写。
static FF_UNUSED void FFBootLog(const char *tag) {
    mkdir("/var/mobile/Documents/ForceFastCharge", 0777);
    chmod("/var/mobile/Documents/ForceFastCharge", 0777);
    // 多路径回退：万一某进程沙盒限制写不进 /var/mobile，至少 /var/tmp、/tmp 留痕，
    // 用于严格区分「%ctor 没跑」与「跑了但写盘被拒」。
    const char *cands[3] = {
        "/var/mobile/Documents/ForceFastCharge/boot.log",
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
    NSString *b = [[[NSProcessInfo processInfo] processName] lastPathComponent].lowercaseString;
    return ([a rangeOfString:k].location != NSNotFound) ||
           ([b rangeOfString:k].location != NSNotFound);
}

#endif
