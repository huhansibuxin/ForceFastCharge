#import <UIKit/UIKit.h>
#import <Preferences/Preferences.h>
#import "FFPaths.h"

@interface FRootListController : PSListController
@end

@implementation FRootListController

- (id)specifiers {
    if (_specifiers == nil) _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers;
}

// 开关/文本变化 → 立即通知 powerd 侧重算 + SpringBoard 侧刷新圆点
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    notify_post(FFSettingsChangedNotifName.UTF8String);
    notify_post(FFChargeStateNotifName.UTF8String);
}

// 「立即应用位置」：先强制收起键盘让 PSEditTextCell 落盘，再通知两侧刷新。
// （输入框的值在结束编辑时才写入偏好，只发通知可能读到旧值。）
- (void)applyDotPosition {
    [self.view endEditing:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        notify_post(FFChargeStateNotifName.UTF8String);
        notify_post(FFSettingsChangedNotifName.UTF8String);
    });
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 【v0.1.3】状态行不再由本控制器回填。
    //   Root.plist 里的 PSValueCell 直接绑定 defaults=com.chargecontrol.ffstatus /
    //   com.chargecontrol.sbstatus 域，而 dylib 现在正是往这两个域写状态，
    //   所以这里只需重新加载 specifier 让它去读最新值即可。
    //   （旧实现用 setPreferenceValue 回填 → 触发自身重写 → 无限递归闪退，已废弃。）
    [self reloadSpecifiers];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.view endEditing:YES];
    notify_post(FFSettingsChangedNotifName.UTF8String);
    notify_post(FFChargeStateNotifName.UTF8String);
}

@end
