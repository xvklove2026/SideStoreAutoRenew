#pragma once
#import <Foundation/Foundation.h>
#import <notify.h>
#import <os/log.h>

#define SRA_DOMAIN "com.xx.autosidestore"
#define SRA_REQUEST SRA_DOMAIN "/request"
#define SRA_STATUS SRA_DOMAIN "/status"
#define SRA_CHANGED SRA_DOMAIN "/changed"
#define SRA_MANUAL SRA_DOMAIN "/manual"
#define SRA_DIAGNOSTIC SRA_DOMAIN "/diagnostic"
#define SRA_PHASE SRA_DOMAIN "/phase"

// Separate from legacy connection diagnostics: high 32 bits response code,
// low 32 bits refresh phase. No account or pairing data is transmitted.
typedef NS_ENUM(uint32_t, SRARefreshPhase) {
    SRARefreshPhaseWaiting = 0,
    SRARefreshPhaseReceived,
    SRARefreshPhaseConfirming,
    SRARefreshPhaseConfirmed,
    SRARefreshPhaseHandling,
    SRARefreshPhaseHandled,
    SRARefreshPhaseUnsupported,
    SRARefreshPhaseTimedOut,
    SRARefreshPhaseUnrecognizedResponse,
    SRARefreshPhaseLaunchWaiting,
    SRARefreshPhaseLaunchTimedOut
};
static inline NSString *SRARefreshPhaseText(uint32_t phase) {
    switch (phase) {
        case SRARefreshPhaseLaunchWaiting: return @"等待 SideStore 前台稳定 12 秒（不代表设备通道已就绪）";
        case SRARefreshPhaseLaunchTimedOut: return @"60 秒内未获得稳定前台，未调用刷新接口";
        case SRARefreshPhaseReceived: return @"SideStore 已收到请求";
        case SRARefreshPhaseConfirming: return @"已调用确认接口，等待回调";
        case SRARefreshPhaseConfirmed: return @"已收到确认回调";
        case SRARefreshPhaseHandling: return @"已调用刷新接口，等待回调";
        case SRARefreshPhaseHandled: return @"已收到刷新回调";
        case SRARefreshPhaseUnsupported: return @"刷新类或处理接口未就绪";
        case SRARefreshPhaseTimedOut: return @"SideStore 操作超时或后台执行结束";
        case SRARefreshPhaseUnrecognizedResponse: return @"SideStore 已返回结果，code 5 的含义待核对；请查看应用中的错误提示";
        default: return @"等待 SideStore 接收请求";
    }
}
#ifndef APELIN_BUILD_ID
#define APELIN_BUILD_ID "unbuilt"
#endif

// notify state conveys a request timestamp or a coarse status, never secrets.
typedef NS_ENUM(uint64_t, SRAStatus) {
    SRAStatusIdle = 0, SRAStatusRequested, SRAStatusRunning,
    SRAStatusResponseSuccess, SRAStatusFailure, SRAStatusUnconfirmed,
    SRAStatusUnsupported, SRAStatusLocked, SRAStatusOpenFailed,
    SRAStatusDirectUnavailable, SRAStatusUnrecognizedResponse
};
// Diagnostic wire format: stage in the high 32 bits, errno in the low 32.
// Legacy builds sent errno alone, which decodes to the unknown stage.
typedef NS_ENUM(uint32_t, SRAConnectionStage) {
    SRAConnectionStageUnknown = 0,
    SRAConnectionStageAddress,
    SRAConnectionStageSocket,
    SRAConnectionStageFlags,
    SRAConnectionStageConnect,
    SRAConnectionStagePoll,
    SRAConnectionStageSocketError
};
static inline NSString *SRAConnectionStageText(uint32_t stage) {
    switch (stage) {
        case SRAConnectionStageAddress: return @"检查本机地址";
        case SRAConnectionStageSocket: return @"创建 TCP socket";
        case SRAConnectionStageFlags: return @"设置非阻塞模式";
        case SRAConnectionStageConnect: return @"发起 TCP connect";
        case SRAConnectionStagePoll: return @"等待连接完成";
        case SRAConnectionStageSocketError: return @"读取连接结果 SO_ERROR";
        default: return @"未知（旧版诊断）";
    }
}
static inline os_log_t SRALog(void) {
    static os_log_t log; static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create(SRA_DOMAIN, "AutoRenew"); });
    return log;
}
static inline id SRARead(NSString *key, id fallback) {
    id value = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR(SRA_DOMAIN)));
    return value ?: fallback;
}
static inline void SRAWrite(NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, CFSTR(SRA_DOMAIN));
    CFPreferencesAppSynchronize(CFSTR(SRA_DOMAIN));
}
static inline NSCalendar *SRACalendar(void) {
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = NSTimeZone.localTimeZone;
    return calendar;
}
// Monday=1 ... Sunday=7, independent of the calendar's first weekday.
static inline NSInteger SRAWeekday(NSCalendar *calendar, NSDate *date) {
    return ([calendar component:NSCalendarUnitWeekday fromDate:date] + 5) % 7 + 1;
}
static inline NSDate *SRAScheduledDate(NSDate *now, NSInteger direction, BOOL includeNow) {
    NSInteger minutes = [SRARead(@"minuteOfDay", @540) integerValue];
    if (minutes < 0 || minutes > 1439) return nil;
    NSCalendar *calendar = SRACalendar();
    NSDate *start = [calendar startOfDayForDate:now];
    for (NSInteger offset = 0; offset <= 7; offset++) {
        NSDate *day = [calendar dateByAddingUnit:NSCalendarUnitDay value:direction * offset toDate:start options:0];
        NSString *key = [NSString stringWithFormat:@"weekday%ld", (long)SRAWeekday(calendar, day)];
        if (![SRARead(key, @NO) boolValue]) continue;
        NSDate *candidate = [calendar dateBySettingHour:minutes / 60 minute:minutes % 60 second:0 ofDate:day options:NSCalendarMatchNextTime];
        if (!candidate || ![calendar isDate:candidate inSameDayAsDate:day]) continue;
        NSComparisonResult comparison = [candidate compare:now];
        if ((direction > 0 && comparison == NSOrderedDescending) ||
            (direction < 0 && comparison == NSOrderedAscending) ||
            (includeNow && comparison == NSOrderedSame)) return candidate;
    }
    return nil;
}
static inline NSString *SRAStatusText(uint64_t status) {
    switch (status) {
        case SRAStatusRequested: return @"已请求打开 SideStore，等待插件响应";
        case SRAStatusRunning: return @"SideStore 正在处理续签请求，具体进度见阶段诊断";
        case SRAStatusResponseSuccess: return @"SideStore 返回成功；请到我的应用核对签名有效期";
        case SRAStatusFailure: return @"SideStore 返回失败，请检查其错误提示、登录和配对文件";
        case SRAStatusDirectUnavailable: return @"本机设备通道不可达，尚未开始续签";
        case SRAStatusUnrecognizedResponse: return @"SideStore 返回未识别结果；请查看应用中的错误提示并核对签名有效期";
        case SRAStatusUnconfirmed: return @"未确认续签完成，请到 SideStore 核对有效期";
        case SRAStatusUnsupported: return @"此版本的续签接口或插件注入未就绪";
        case SRAStatusLocked: return @"等待解锁后执行；过期超过 24 小时的任务跳过";
        case SRAStatusOpenFailed: return @"打开 SideStore 失败，请检查应用是否已安装";
        default: return @"尚无执行记录";
    }
}
