#import <UIKit/UIKit.h>
#import <Intents/Intents.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "SRACommon.h"
#import "SRADirect.h"

static int SRARequestToken, SRAStatusToken, SRADiagnosticToken;
static BOOL SRABusy;
static uint64_t SRAHandled;
static NSDate *SRAStarted;
static UIBackgroundTaskIdentifier SRABackground;
static id SRAIntent;
static id SRAHandler;
static NSTimer *SRATimer;
static uint64_t SRAActiveRequest;

static BOOL SRAIsSideStoreProcess(void) {
    // Match the executable selected by our injection filter, independent of signing ID.
    return [[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleExecutable"] isEqualToString:@"SideStore"];
}

static void SRAReport(SRAStatus status) {
    notify_set_state(SRAStatusToken, status);
    notify_post(SRA_STATUS);
    os_log(SRALog(), "Renewal state=%llu build=%{public}s", (unsigned long long)status, APELIN_BUILD_ID);
}
static void SRAFinish(SRAStatus status) {
    SRAReport(status);
    SRABusy = NO;
    SRAIntent = nil; SRAHandler = nil;
    if (SRABackground != UIBackgroundTaskInvalid) {
        [UIApplication.sharedApplication endBackgroundTask:SRABackground];
        SRABackground = UIBackgroundTaskInvalid;
    }
}
static void SRAHandleRequest(void) {
    uint64_t request = 0;
    notify_get_state(SRARequestToken, &request);
    NSTimeInterval age = NSDate.date.timeIntervalSince1970 - request / 1000.0;
    uint64_t persisted = (uint64_t)[[NSUserDefaults.standardUserDefaults objectForKey:@"SRAAutoRenew.lastRequest"] unsignedLongLongValue];
    if (!request || request <= MAX(SRAHandled, persisted) || age < -60 || age > 600 || SRABusy) return;
    SRAHandled = request;
    [NSUserDefaults.standardUserDefaults setObject:@(request) forKey:@"SRAAutoRenew.lastRequest"];
    SRAActiveRequest = request;
    Class intentClass = NSClassFromString(@"RefreshAllIntent");
    if (!intentClass) intentClass = NSClassFromString(@"SideStore.RefreshAllIntent");
    if (!intentClass) { SRAReport(SRAStatusUnsupported); return; }
    id intent = [[intentClass alloc] init];
    id<UIApplicationDelegate> delegate = UIApplication.sharedApplication.delegate;
    if (![delegate respondsToSelector:@selector(application:handlerForIntent:)]) {
        SRAReport(SRAStatusUnsupported); return;
    }
    id handler = [delegate application:UIApplication.sharedApplication handlerForIntent:intent];
    SEL confirm = NSSelectorFromString(@"confirmRefreshAll:completion:");
    SEL handle = NSSelectorFromString(@"handleRefreshAll:completion:");
    if (![handler respondsToSelector:confirm] || ![handler respondsToSelector:handle]) {
        SRAReport(SRAStatusUnsupported); return;
    }
    SRABusy = YES; SRAIntent = intent; SRAHandler = handler;
    SRAReport(SRAStatusRunning);
    SRABackground = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"SRARefreshAll" expirationHandler:^{
        if (SRABusy && SRAActiveRequest == request) SRAFinish(SRAStatusUnconfirmed);
    }];
    // Retain the actual operation inputs independently of the global timeout state.
    void (^handled)(id) = ^(id response) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!SRABusy || SRAActiveRequest != request) return;
            SEL codeSelector = NSSelectorFromString(@"code");
            if (![response respondsToSelector:codeSelector]) { SRAFinish(SRAStatusUnconfirmed); return; }
            NSInteger code = ((NSInteger (*)(id, SEL))objc_msgSend)(response, codeSelector);
            // SiriKit generated codes: success=4, failure=5. A success may be
            // optimistic in SideStore: never represent it as verified expiry.
            if (code == 4) SRAFinish(SRAStatusResponseSuccess);
            else if (code >= 5) SRAFinish(SRAStatusFailure);
            // ready/inProgress: retain until a terminal response or timeout.
        });
    };
    // Confirmation callbacks can arrive more than once; dispatch handle only once.
    __block BOOL handleDispatched = NO;
    SRAProbeDirectConnection(^(BOOL reachable, int error, uint32_t stage) {
        if (!SRABusy || SRAActiveRequest != request) return;
        // Publish before the terminal status; SpringBoard reads both together.
        uint64_t diagnostic = ((uint64_t)stage << 32) | (uint32_t)MAX(error, 0);
        notify_set_state(SRADiagnosticToken, diagnostic);
        if (!reachable) { SRAFinish(SRAStatusDirectUnavailable); return; }
        ((void (*)(id, SEL, id, id))objc_msgSend)(handler, confirm, intent, ^(id response) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!SRABusy || SRAActiveRequest != request || handleDispatched) return;
                handleDispatched = YES;
                SEL codeSelector = NSSelectorFromString(@"code");
                if (![response respondsToSelector:codeSelector]) { SRAFinish(SRAStatusUnconfirmed); return; }
                NSInteger code = ((NSInteger (*)(id, SEL))objc_msgSend)(response, codeSelector);
                if (code >= 5) { SRAFinish(SRAStatusFailure); return; }
                ((void (*)(id, SEL, id, id))objc_msgSend)(handler, handle, intent, handled);
            });
        });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 180 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (SRABusy && SRAActiveRequest == request) SRAFinish(SRAStatusUnconfirmed);
    });
}

static BOOL SRAIsLocked(void) {
    Class lockClass = NSClassFromString(@"SBLockScreenManager");
    SEL shared = NSSelectorFromString(@"sharedInstance");
    SEL locked = NSSelectorFromString(@"isUILocked");
    if (![lockClass respondsToSelector:shared]) return YES;
    id manager = ((id (*)(id, SEL))objc_msgSend)(lockClass, shared);
    if (![manager respondsToSelector:locked]) return YES;
    return ((BOOL (*)(id, SEL))objc_msgSend)(manager, locked);
}
static void SRAStartRequest(NSDate *slot) {
    if (SRAStarted && -SRAStarted.timeIntervalSinceNow < 240) return;
    if (SRAIsLocked()) {
        if ([SRARead(@"lastStatus", @0) unsignedLongLongValue] != SRAStatusLocked)
            SRAWrite(@"lastStatus", @(SRAStatusLocked));
        return;
    }
    uint64_t request = (uint64_t)(NSDate.date.timeIntervalSince1970 * 1000);
    SRAStarted = NSDate.date;
    SRAWrite(@"lastStatus", @(SRAStatusRequested));
    SRAWrite(@"lastConnectionError", nil);
    SRAWrite(@"lastConnectionStage", nil);
    notify_set_state(SRADiagnosticToken, 0);
    SRAWrite(@"lastAttempt", @(NSDate.date.timeIntervalSince1970));
    if (slot) SRAWrite(@"lastSlot", @(slot.timeIntervalSince1970));
    notify_set_state(SRARequestToken, request);
    notify_set_state(SRAStatusToken, SRAStatusRequested);
    // LaunchServices chooses the app currently registered for this scheme.
    SEL open = NSSelectorFromString(@"openURL:options:completionHandler:");
    NSURL *url = [NSURL URLWithString:@"sidestore://sra-refresh"];
    if (![UIApplication.sharedApplication respondsToSelector:open]) {
        SRAWrite(@"lastStatus", @(SRAStatusOpenFailed)); return;
    }
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL success) {
        if (!success) { SRAWrite(@"lastStatus", @(SRAStatusOpenFailed)); return; }
        notify_post(SRA_REQUEST);
        // Cold launch: the SideStore constructor also reads pending notify state.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            notify_post(SRA_REQUEST);
        });
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        uint64_t current = 0; notify_get_state(SRARequestToken, &current);
        NSInteger status = [SRARead(@"lastStatus", @0) integerValue];
        if (current == request && (status == SRAStatusRequested || status == SRAStatusRunning))
            SRAWrite(@"lastStatus", @(SRAStatusUnconfirmed));
    });
}
static void SRATick(void) {
    if (![SRARead(@"enabled", @NO) boolValue]) return;
    NSDate *now = NSDate.date;
    NSDate *slot = SRAScheduledDate(now, -1, YES);
    NSTimeInterval enabledAt = [SRARead(@"scheduleChangedAt", @(now.timeIntervalSince1970)) doubleValue];
    NSTimeInterval consumed = [SRARead(@"lastSlot", @0) doubleValue];
    if (!slot || [now timeIntervalSinceDate:slot] > 86400 || slot.timeIntervalSince1970 < enabledAt || slot.timeIntervalSince1970 <= consumed) return;
    SRAStartRequest(slot);
}
__attribute__((constructor)) static void SRAInitialize(void) {
    SRABackground = UIBackgroundTaskInvalid;
    @autoreleasepool {
        if (SRAIsSideStoreProcess())
            SRAInstallDirectConnection();
    }
    os_log(SRALog(), "ApelinLoaded %{public}s", APELIN_BUILD_ID);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
        BOOL springboard = [bundle isEqualToString:@"com.apple.springboard"];
        notify_register_check(SRA_REQUEST, &SRARequestToken);
        notify_register_check(SRA_DIAGNOSTIC, &SRADiagnosticToken);
        if (springboard) {
            notify_register_dispatch(SRA_STATUS, &SRAStatusToken, dispatch_get_main_queue(), ^(int token) {
                uint64_t status = 0; notify_get_state(token, &status);
                if (status == SRAStatusDirectUnavailable) {
                    uint64_t diagnostic = 0; notify_get_state(SRADiagnosticToken, &diagnostic);
                    SRAWrite(@"lastConnectionError", @((uint32_t)diagnostic));
                    SRAWrite(@"lastConnectionStage", @((uint32_t)(diagnostic >> 32)));
                }
                SRAWrite(@"lastStatus", @(status));
                SRAWrite(@"lastResponse", @(NSDate.date.timeIntervalSince1970));
            });
            static int changedToken, manualToken;
            notify_register_dispatch(SRA_CHANGED, &changedToken, dispatch_get_main_queue(), ^(int token) { SRATick(); });
            notify_register_dispatch(SRA_MANUAL, &manualToken, dispatch_get_main_queue(), ^(int token) { SRAStartRequest(nil); });
            SRATimer = [NSTimer scheduledTimerWithTimeInterval:20 repeats:YES block:^(NSTimer *timer) { SRATick(); }];
            SRATimer.tolerance = 2;
            [NSRunLoop.mainRunLoop addTimer:SRATimer forMode:NSRunLoopCommonModes];
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationSignificantTimeChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { SRATick(); }];
            SRATick();
        } else if (SRAIsSideStoreProcess()) {
            notify_register_check(SRA_STATUS, &SRAStatusToken);
            // Observe the same signal with a separate token: keep the state token.
            static int listenerToken;
            notify_register_dispatch(SRA_REQUEST, &listenerToken, dispatch_get_main_queue(), ^(int token) { SRAHandleRequest(); });
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { SRAHandleRequest(); }];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ SRAHandleRequest(); });
        }
    });
}
