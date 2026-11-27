#import "SRACellular.h"
#import "SRACommon.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#define SRA_CELL_REQUEST SRA_DOMAIN "/cellular-request"
#define SRA_CELL_REPLY SRA_DOMAIN "/cellular-reply"
#define SRA_CELL_OFF @"SRA.Internal.CellularOff"
#define SRA_CELL_ON @"SRA.Internal.CellularOn"
extern void MSHookMessageEx(Class, SEL, IMP, IMP *);
static Boolean (*SRADataEnabled)(void);
static void (*SRASetDataEnabled)(Boolean);
static BOOL SRAOwnsData;
static uint64_t SRAControllerGeneration;
static int SRAReplyToken;
static void (^SRAPendingReply)(BOOL);
static uint64_t SRAPendingID;
static NSMutableArray *SRAQueuedDataRequests;

static void SRAClearRestore(void) {
    SRAOwnsData = NO;
    SRAWrite(@"cellularRestorePending", @NO);
}
static void SRARestoreAttempt(NSUInteger attempt) {
    if (!SRAOwnsData || !SRADataEnabled || !SRASetDataEnabled) return;
    if (SRADataEnabled()) { SRAClearRestore(); return; }
    uint64_t generation = SRAControllerGeneration;
    SRASetDataEnabled(YES);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (generation != SRAControllerGeneration) return;
        if (SRADataEnabled()) {
            SRAClearRestore();
            os_log(SRALog(), "Cellular original enabled state restored");
        } else if (attempt < 10) SRARestoreAttempt(attempt + 1);
        else {
            os_log_error(SRALog(), "Cellular restoration unconfirmed; retrying with recovery marker retained");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                if (generation == SRAControllerGeneration) SRARestoreAttempt(0);
            });
        }
    });
}
void SRARestoreCellularData(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ SRARestoreAttempt(0); });
}
static void SRAReply(uint64_t identifier, BOOL success) {
    notify_set_state(SRAReplyToken, (identifier << 1) | (success ? 1 : 0));
    notify_post(SRA_CELL_REPLY);
}
static void SRAVerifyData(uint64_t identifier, BOOL enabled, NSUInteger attempt) {
    if (identifier != SRAControllerGeneration) return;
    if ((BOOL)SRADataEnabled() == enabled) {
        if (enabled) {
            SRAClearRestore();
            os_log(SRALog(), "Cellular data restored");
        }
        SRAReply(identifier, YES);
        os_log(SRALog(), "Cellular switch verified enabled=%d", enabled);
    } else if (attempt < 30) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            SRAVerifyData(identifier, enabled, attempt + 1);
        });
    } else {
        SRAReply(identifier, NO);
        SRARestoreCellularData();
    }
}
void SRAStartCellularController(void) {
    void *framework = dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony", RTLD_NOW);
    SRADataEnabled = framework ? dlsym(framework, "CTCellularDataPlanGetIsEnabled") : NULL;
    SRASetDataEnabled = framework ? dlsym(framework, "CTCellularDataPlanSetIsEnabled") : NULL;
    notify_register_check(SRA_CELL_REPLY, &SRAReplyToken);
    if (SRADataEnabled && SRASetDataEnabled) {
        SRAOwnsData = [SRARead(@"cellularRestorePending", @NO) boolValue];
        if (SRAOwnsData) SRARestoreCellularData();
    }
    static int checkToken;
    notify_register_check(SRA_CELL_REQUEST, &checkToken);
    uint64_t previousRequest = 0;
    notify_get_state(checkToken, &previousRequest);
    SRAControllerGeneration = previousRequest >> 1;
    static int token;
    notify_register_dispatch(SRA_CELL_REQUEST, &token, dispatch_get_main_queue(), ^(int requestToken) {
        uint64_t wire = 0; notify_get_state(requestToken, &wire);
        uint64_t identifier = wire >> 1;
        BOOL enabled = (wire & 1) != 0;
        if (!identifier) return;
        if (identifier <= SRAControllerGeneration) return;
        SRAControllerGeneration = identifier;
        if (!SRADataEnabled || !SRASetDataEnabled) { SRAReply(identifier, NO); return; }
        if (!enabled && !SRAOwnsData) {
            // Do not claim ownership of data that was already disabled by the user.
            if (!SRADataEnabled()) { SRAReply(identifier, NO); return; }
            SRAOwnsData = YES;
            SRAWrite(@"cellularRestorePending", @YES);
        }
        if (enabled && !SRAOwnsData) { SRAReply(identifier, YES); return; }
        SRASetDataEnabled(enabled);
        SRAVerifyData(identifier, enabled, 0);
        if (!enabled) {
            // SpringBoard owns recovery even if SideStore dies mid-install.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 180 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                if (SRAOwnsData && SRAControllerGeneration == identifier) SRARestoreCellularData();
            });
        }
    });
    os_log(SRALog(), "Cellular controller available=%d", SRADataEnabled && SRASetDataEnabled);
}

static void SRAPumpDataRequests(void);
static void SRACompletePending(BOOL success) {
    void (^completion)(BOOL) = SRAPendingReply;
    SRAPendingReply = nil;
    // Every queued caller must receive a result, including recovery requests
    // after a failed close. Never drop continuations on an error.
    if (completion) completion(success);
    dispatch_async(dispatch_get_main_queue(), ^{ SRAPumpDataRequests(); });
}
static void SRAPumpDataRequests(void) {
    if (SRAPendingReply || !SRAQueuedDataRequests.count) return;
    NSDictionary *request = SRAQueuedDataRequests.firstObject;
    [SRAQueuedDataRequests removeObjectAtIndex:0];
    BOOL enabled = [request[@"enabled"] boolValue];
    id completionValue = request[@"completion"];
    void (^completion)(BOOL) = completionValue == NSNull.null ? nil : completionValue;
    static int requestToken;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ notify_register_check(SRA_CELL_REQUEST, &requestToken); });
    uint64_t previousWire = 0;
    notify_get_state(requestToken, &previousWire);
    uint64_t identifier = MAX(MAX(SRAPendingID + 1, (previousWire >> 1) + 1),
                              (uint64_t)(NSDate.date.timeIntervalSince1970 * 1000));
    SRAPendingID = identifier;
    SRAPendingReply = completion ?: ^(BOOL result) {};
    notify_set_state(requestToken, (identifier << 1) | (enabled ? 1 : 0));
    notify_post(SRA_CELL_REQUEST);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 9 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (SRAPendingID == identifier && SRAPendingReply) SRACompletePending(NO);
    });
}
static void SRARequestData(BOOL enabled, void (^completion)(BOOL)) {
    if (!SRAQueuedDataRequests) SRAQueuedDataRequests = [NSMutableArray array];
    [SRAQueuedDataRequests addObject:@{@"enabled": @(enabled), @"completion": [completion copy] ?: (id)NSNull.null}];
    SRAPumpDataRequests();
}
static void (*SRAOriginalOpenURL)(id, SEL, NSURL *, NSDictionary *, void (^)(BOOL));
static void SRAOpenURL(id self, SEL selector, NSURL *url, NSDictionary *options, void (^completion)(BOOL)) {
    NSURLComponents *parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if ([parts.scheme.lowercaseString isEqualToString:@"shortcuts"] &&
        [parts.host.lowercaseString isEqualToString:@"run-shortcut"]) {
        NSString *name = nil;
        for (NSURLQueryItem *item in parts.queryItems) if ([item.name isEqualToString:@"name"]) name = item.value;
        if ([name isEqualToString:SRA_CELL_OFF] || [name isEqualToString:SRA_CELL_ON]) {
            BOOL enabled = [name isEqualToString:SRA_CELL_ON];
            dispatch_async(dispatch_get_main_queue(), ^{ SRARequestData(enabled, completion); });
            return;
        }
    }
    SRAOriginalOpenURL(self, selector, url, options, completion);
}
static BOOL (*SRAOriginalEnabled)(id, SEL);
static id (*SRAOriginalOffName)(id, SEL);
static id (*SRAOriginalOnName)(id, SEL);
static BOOL SRAEnabled(id self, SEL selector) {
    return self == NSUserDefaults.standardUserDefaults ? YES : SRAOriginalEnabled(self, selector);
}
static id SRAOffName(id self, SEL selector) {
    return self == NSUserDefaults.standardUserDefaults ? SRA_CELL_OFF : SRAOriginalOffName(self, selector);
}
static id SRAOnName(id self, SEL selector) {
    return self == NSUserDefaults.standardUserDefaults ? SRA_CELL_ON : SRAOriginalOnName(self, selector);
}
void SRAInstallCellularClient(void) {
    Class defaults = NSUserDefaults.class;
    SEL enabled = NSSelectorFromString(@"isCellularRefreshEnabled");
    SEL off = NSSelectorFromString(@"turnOffDataShortcutName");
    SEL on = NSSelectorFromString(@"turnOnDataShortcutName");
    if (!class_getInstanceMethod(defaults, enabled) || !class_getInstanceMethod(defaults, off) ||
        !class_getInstanceMethod(defaults, on)) {
        os_log_error(SRALog(), "Native cellular preference selectors missing; integration not installed");
        return;
    }
    MSHookMessageEx(UIApplication.class, @selector(openURL:options:completionHandler:), (IMP)SRAOpenURL, (IMP *)&SRAOriginalOpenURL);
    MSHookMessageEx(defaults, enabled, (IMP)SRAEnabled, (IMP *)&SRAOriginalEnabled);
    MSHookMessageEx(defaults, off, (IMP)SRAOffName, (IMP *)&SRAOriginalOffName);
    MSHookMessageEx(defaults, on, (IMP)SRAOnName, (IMP *)&SRAOriginalOnName);
    static int replyListener;
    notify_register_dispatch(SRA_CELL_REPLY, &replyListener, dispatch_get_main_queue(), ^(int token) {
        uint64_t wire = 0; notify_get_state(token, &wire);
        if ((wire >> 1) == SRAPendingID && SRAPendingReply) SRACompletePending((wire & 1) != 0);
    });
    os_log(SRALog(), "Native cellular shortcut replacement installed; saved settings unchanged");
}
