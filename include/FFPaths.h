#ifndef FF_PATHS_H
#define FF_PATHS_H

#import <Foundation/Foundation.h>
#import <notify.h>
#include <stdint.h>

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
static const char *FFSettingsChangedNotif = "com.chargecontrol/settingsChanged";
// 充电状态变化通知（powerd 侧 post，SpringBoard 侧监听以更新指示点）
static const char *FFChargeStateNotif = "com.chargecontrol/chargeStateChanged";

// 诊断日志路径（安装/升级时由 postinst 清除，保证每次测试干净开始）
static NSString *FFLogDir(void) {
    return @"/var/mobile/ForceFastCharge";
}

static NSString *FFPrefPath(void) {
    return [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", FFPrefDomain];
}

// 状态标志文件：由 powerd 侧写入，设置页读取并展示「是否真的在生效」
static NSString *FFStatusPath(void) {
    return [FFLogDir() stringByAppendingPathComponent:@"status.plist"];
}

#endif
