//
//  FFIndicatorTweak.xm — SpringBoard 侧指示点驱动
//
//  只注入 SpringBoard，负责：
//   1. 监听 powerd 侧 post 的 FFChargeStateNotif；
//   2. 读状态文件与偏好，判断是否应显示圆点、显示什么颜色；
//   3. 驱动 FFIndicator 更新（UI 实现在 FFIndicator.h，完全对齐 TGK 方案）。
//
//  与 powerd 侧解耦：即使 powerd 未就绪，本 tweak 也会在 2s 轮询兜底下
//  直接读偏好 + 状态文件，保证圆点最终能对上真实状态。
//

#import <Foundation/Foundation.h>
#import <notify.h>
#import "FFIndicator.h"
#import "FFPaths.h"

static BOOL gLastForce = NO;
static BOOL gLastThermal = NO;
static BOOL gLastCharging = NO;
static int gNotifyToken = -1;

static BOOL readBool(NSString *key, BOOL def) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:FFPrefPath()];
        id v = d[key];
        if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
        if ([v isKindOfClass:[NSString class]]) return [v boolValue];
    } @catch (NSException *e) {}
    return def;
}

// 充电状态以 powerd 写的 status.plist 为准（powerd 才有权威读数）
static BOOL readChargingFromStatus(void) {
    @try {
        NSDictionary *st = [NSDictionary dictionaryWithContentsOfFile:FFStatusPath()];
        id v = st[@"charging"];
        if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    } @catch (NSException *e) {}
    return NO;
}

static void refreshIndicator(BOOL forceNotify) {
    BOOL force   = readBool(kFFForceFastChargeKey, NO);
    BOOL thermal = readBool(kFFThermalOverrideKey, NO);
    if (!force) thermal = NO;
    BOOL charging = readChargingFromStatus();

    if (!forceNotify &&
        force == gLastForce && thermal == gLastThermal && charging == gLastCharging) {
        return;   // 无变化不刷新 UI
    }
    gLastForce = force; gLastThermal = thermal; gLastCharging = charging;
    [[FFIndicator shared] updateWithForceOn:force thermalOn:thermal charging:charging];
}

static void stateChanged(CFNotificationCenterRef center, void *observer,
                          CFNotificationName name, const void *object,
                          CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    refreshIndicator(NO);
}

%ctor {
    @autoreleasepool {
        NSString *proc = [NSProcessInfo processInfo].processName;
        if (![proc isEqualToString:@"SpringBoard"]) return;

        // 先按当前状态显示一次
        refreshIndicator(YES);

        // 监听 powerd 的充电状态 / 开关变化通知
        notify_register_check(FFChargeStateNotif, &gNotifyToken);
        notify_add_observer(gNotifyToken, stateChanged, NULL, NULL, NULL);
        // 设置页改开关也会 post settingsChanged，这里一并监听
        int setToken = -1;
        notify_register_check(FFSettingsChangedNotif, &setToken);
        notify_add_observer(setToken, stateChanged, NULL, NULL, NULL);

        // 2s 兜底轮询：覆盖通知丢失 / 状态文件写入竞态
        dispatch_source_t timer = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        if (timer) {
            dispatch_source_set_timer(timer,
                                      dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                                      2 * NSEC_PER_SEC,
                                      300 * NSEC_MSEC);
            dispatch_source_set_event_handler(timer, ^{ refreshIndicator(NO); });
            dispatch_resume(timer);
        }
    }
}
