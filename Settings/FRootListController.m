#import <UIKit/UIKit.h>
#import <Preferences/Preferences.h>
#import "FFPaths.h"

@interface FRootListController : PSListController
@end

@implementation FRootListController

// ⚠️ 递归防护（v0.1.1 修复闪退）：
//    refreshStatusRows 通过 setPreferenceValue:specifier: 回填两个 PSValueCell，
//    而该方法已被本类重写并会回调 refreshStatusRows → 无限递归 → 栈溢出闪退。
static BOOL gRefreshingStatus = NO;

- (id)specifiers {
    if (_specifiers == nil) _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers;
}

// 开关变化立即通知 powerd 侧生效，并让 SpringBoard 指示点刷新
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    if (gRefreshingStatus) return;      // 内部回填，不再发通知也不再递归
    notify_post(FFSettingsChangedNotifName.UTF8String);
    notify_post(FFChargeStateNotifName.UTF8String);
    [self refreshStatusRows];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    notify_post(FFSettingsChangedNotifName.UTF8String);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self refreshStatusRows];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshStatusRows];
}

// 从 powerd 侧写的 status.plist 读取运行状态，回填到两个 PSValueCell
- (void)refreshStatusRows {
    if (gRefreshingStatus) return;
    gRefreshingStatus = YES;
    @try {
        NSDictionary *st = [NSDictionary dictionaryWithContentsOfFile:FFStatusPath()];
        BOOL loaded = [st[@"hookInstalled"] boolValue];
        NSNumber *blocked = st[@"blockedWriteCount"];
        [self setPreferenceValue:(loaded ? @"YES" : @"NO")
                       specifier:[self specifierForKey:@"loaded"]];
        [self setPreferenceValue:(blocked ? blocked.stringValue : @"-")
                       specifier:[self specifierForKey:@"blocked"]];
    } @catch (NSException *e) {}
    gRefreshingStatus = NO;
}

- (PSSpecifier *)specifierForKey:(NSString *)key {
    for (PSSpecifier *s in self.specifiers) {
        if ([[s propertyForKey:@"key"] isEqualToString:key]) return s;
    }
    return nil;
}

@end
