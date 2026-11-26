#import <Preferences/PSListController.h>
#import "SRACommon.h"
#import <errno.h>
#import <string.h>

@interface SRATimeController : UIViewController
@property(nonatomic, strong) UIDatePicker *picker;
@property(nonatomic, copy) void (^onSave)(NSInteger minutes);
@property(nonatomic) NSInteger initialMinutes;
@end
@implementation SRATimeController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"执行时间";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave target:self action:@selector(save)];
    self.picker = [[UIDatePicker alloc] init];
    self.picker.datePickerMode = UIDatePickerModeTime;
    self.picker.preferredDatePickerStyle = UIDatePickerStyleWheels;
    self.picker.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    self.picker.calendar = SRACalendar();
    self.picker.timeZone = NSTimeZone.localTimeZone;
    self.picker.date = [SRACalendar() dateBySettingHour:self.initialMinutes / 60 minute:self.initialMinutes % 60 second:0 ofDate:NSDate.date options:0];
    self.picker.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.picker];
    [NSLayoutConstraint activateConstraints:@[
        [self.picker.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:16],
        [self.picker.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
        [self.picker.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerYAnchor]
    ]];
}
- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)save {
    NSDateComponents *parts = [SRACalendar() components:NSCalendarUnitHour | NSCalendarUnitMinute fromDate:self.picker.date];
    if (self.onSave) self.onSave(parts.hour * 60 + parts.minute);
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end

@interface SRARootListController : PSListController
@end
@implementation SRARootListController
- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers;
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateLabels];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(updateLabels)];
}
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    // Keep PreferenceLoader's storage implementation; timestamp changes before
    // posting the setting's change notification so old slots are not replayed.
    SRAWrite(@"scheduleChangedAt", @(NSDate.date.timeIntervalSince1970));
    [super setPreferenceValue:value specifier:specifier];
    [self updateLabels];
}
- (void)updateLabels {
    NSInteger minutes = [SRARead(@"minuteOfDay", @540) integerValue];
    PSSpecifier *time = [self specifierForID:@"time"];
    time.name = [NSString stringWithFormat:@"执行时间  %02ld:%02ld", (long)(minutes / 60), (long)(minutes % 60)];
    if (time) [self reloadSpecifier:time];
    PSSpecifier *next = [self specifierForID:@"next"];
    NSDate *date = SRAScheduledDate(NSDate.date, 1, NO);
    NSString *nextText = @"未启用或未选择星期";
    if ([SRARead(@"enabled", @NO) boolValue] && date) {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
        formatter.dateFormat = @"M月d日 EEEE HH:mm";
        nextText = [formatter stringFromDate:date];
    }
    [next setProperty:nextText forKey:@"footerText"];
    if (next) [self reloadSpecifier:next];
    PSSpecifier *status = [self specifierForID:@"status"];
    NSString *statusText = SRAStatusText([SRARead(@"lastStatus", @0) unsignedLongLongValue]);
    if ([SRARead(@"lastStatus", @0) unsignedLongLongValue] == SRAStatusDirectUnavailable) {
        NSNumber *storedError = SRARead(@"lastConnectionError", nil);
        if (storedError) {
            int error = storedError.intValue;
            NSString *hint = @"请保留此错误码以便进一步诊断";
            if (error == EPERM || error == EACCES) hint = @"访问被拒绝，请检查 SideStore 的本地网络权限";
            else if (error == ETIMEDOUT) hint = @"连接超时，尚未确认设备服务可达";
            else if (error == ECONNREFUSED) hint = @"目标端口拒绝连接";
            else if (error == EADDRNOTAVAIL) hint = @"网络地址已变化，请完全退出后重开 SideStore";
            statusText = [statusText stringByAppendingFormat:@"\n连接诊断 errno=%d (%s)\n%@", error, strerror(error), hint];
        }
    }
    [status setProperty:statusText forKey:@"footerText"];
    if (status) [self reloadSpecifier:status];
}
- (void)showTimePicker {
    SRATimeController *controller = [[SRATimeController alloc] init];
    controller.initialMinutes = [SRARead(@"minuteOfDay", @540) integerValue];
    __weak typeof(self) weakSelf = self;
    controller.onSave = ^(NSInteger minutes) {
        PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:@"执行时间" target:weakSelf set:NULL get:NULL detail:Nil cell:PSEditTextCell edit:Nil];
        [specifier setProperty:@"minuteOfDay" forKey:@"key"];
        [specifier setProperty:@SRA_DOMAIN forKey:@"defaults"];
        [specifier setProperty:@SRA_CHANGED forKey:@"PostNotification"];
        [weakSelf setPreferenceValue:@(minutes) specifier:specifier];
    };
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:controller];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:navigation animated:YES completion:nil];
}
- (void)runNow {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"立即续签" message:@"将打开 SideStore 并调用刷新全部。插件会先检测本机直连通道；仍需有效的 SideStore 账号和配对文件。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"执行" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { notify_post(SRA_MANUAL); }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
