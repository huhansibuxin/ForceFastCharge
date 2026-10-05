#import <UIKit/UIKit.h>
#import <Preferences/Preferences.h>
#import "FFPaths.h"

@interface FRootListController : PSListController
@end

@implementation FRootListController

// ⚠️ 递归防护（v0.1.1 修复闪退）：
//    refreshStatusRows 通过 setPreferenceValue:specifier: 回填 PSValueCell，
//    而该方法已被本类重写并会回调 refreshStatusRows → 无限递归 → 栈溢出闪退。
static BOOL gRefreshingStatus = NO;

- (id)specifiers {
    if (_specifiers == nil) _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers;
}

// 开关/文本变化立即通知 powerd 侧生效，并让 SpringBoard 指示点刷新
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    if (gRefreshingStatus) return;      // 内部回填，不再发通知也不再递归
    notify_post(FFSettingsChangedNotifName.UTF8String);
    notify_post(FFChargeStateNotifName.UTF8String);
    [self refreshStatusRows];
}

// 「立即应用位置」：强制收起键盘让 PSEditTextCell 落盘，再通知两侧刷新。
// （输入框的值是在结束编辑时才写入偏好的，只发通知可能读到旧值。）
- (void)applyDotPosition {
    [self.view endEditing:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        notify_post(FFChargeStateNotifName.UTF8String);
        notify_post(FFSettingsChangedNotifName.UTF8String);
        [self refreshStatusRows];
    });
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.view endEditing:YES];
    notify_post(FFSettingsChangedNotifName.UTF8String);
    notify_post(FFChargeStateNotifName.UTF8String);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self refreshStatusRows];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshStatusRows];
}

// 从两个状态文件回填：powerd 侧 status.plist、SpringBoard 侧 sb_status.plist
- (void)refreshStatusRows {
    if (gRefreshingStatus) return;
    gRefreshingStatus = YES;
    @try {
        NSDictionary *st = [NSDictionary dictionaryWithContentsOfFile:FFStatusPath()];
        BOOL loaded = [st[@"hookInstalled"] boolValue];
        NSNumber *blocked = st[@"blockedWriteCount"];
        [self setKey:@"loaded"  value:(loaded ? @"是" : @"否")];
        [self setKey:@"blocked" value:(blocked ? blocked.stringValue : @"-")];

        NSDictionary *sb = [NSDictionary dictionaryWithContentsOfFile:
                            [FFLogDir() stringByAppendingPathComponent:@"sb_status.plist"]];
        BOOL dotLoaded  = [sb[@"loaded"] boolValue];
        BOOL winCreated = [sb[@"windowCreated"] boolValue];
        [self setKey:@"dotLoaded" value:(dotLoaded ? @"是" : @"否")];
        [self setKey:@"dotWindow" value:(winCreated ? @"已创建" : @"未创建")];
    } @catch (NSException *e) {}
    gRefreshingStatus = NO;
}

- (void)setKey:(NSString *)key value:(NSString *)value {
    PSSpecifier *sp = [self specifierForKey:key];
    if (sp) [self setPreferenceValue:value specifier:sp];
}

- (PSSpecifier *)specifierForKey:(NSString *)key {
    for (PSSpecifier *s in self.specifiers) {
        if ([[s propertyForKey:@"key"] isEqualToString:key]) return s;
    }
    return nil;
}

@end
