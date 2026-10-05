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

// 开关变化立即通知 powerd 侧生效（powerd 监听该 Darwin 通知）
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    notify_post(FFSettingsChangedNotifName.UTF8String);
    // 通知 SpringBoard 侧指示点刷新（坐标/模式/开关都可能变了）
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
    NSDictionary *st = [NSDictionary dictionaryWithContentsOfFile:FFStatusPath()];
    BOOL loaded = [st[@"hookInstalled"] boolValue];
    NSNumber *blocked = st[@"blockedWriteCount"];

    [self setPreferenceValue:(loaded ? @"YES" : @"NO")
                   specifier:[self specifierForKey:@"loaded"]];
    [self setPreferenceValue:(blocked ? blocked.stringValue : @"-")
                   specifier:[self specifierForKey:@"blocked"]];
}

- (PSSpecifier *)specifierForKey:(NSString *)key {
    for (PSSpecifier *s in self.specifiers) {
        if ([[s propertyForKey:@"key"] isEqualToString:key]) return s;
    }
    return nil;
}

@end
