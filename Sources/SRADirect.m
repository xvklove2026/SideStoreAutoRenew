#import "SRADirect.h"
#import "SRACommon.h"
#import <objc/runtime.h>
#import <sys/socket.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <poll.h>
#import <unistd.h>
#import <errno.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <string.h>

// Keep the selected address stable for ConnectionConfig's cached singleton.
static NSString *SRADirectHost;
static NSString *SRALocalWiFiAddress(void) {
    struct ifaddrs *interfaces = NULL;
    NSString *host = nil;
    if (getifaddrs(&interfaces) != 0) return nil;
    for (struct ifaddrs *item = interfaces; item; item = item->ifa_next) {
        if (!item->ifa_addr || item->ifa_addr->sa_family != AF_INET ||
            !(item->ifa_flags & IFF_UP) || (item->ifa_flags & IFF_LOOPBACK) ||
            strcmp(item->ifa_name, "en0") != 0) continue;
        struct sockaddr_in *address = (struct sockaddr_in *)item->ifa_addr;
        char buffer[INET_ADDRSTRLEN] = {0};
        if (inet_ntop(AF_INET, &address->sin_addr, buffer, sizeof(buffer))) {
            NSString *candidate = [NSString stringWithUTF8String:buffer];
            if (![candidate hasPrefix:@"169.254."] && ![candidate isEqualToString:@"0.0.0.0"])
                host = candidate;
        }
        if (host) break;
    }
    freeifaddrs(interfaces);
    return host;
}

extern void MSHookMessageEx(Class cls, SEL selector, IMP replacement, IMP *original);
static BOOL (*SRAOriginalBool)(id, SEL, NSString *);
static NSString *(*SRAOriginalString)(id, SEL, NSString *);
static id (*SRAOriginalObject)(id, SEL, NSString *);

static BOOL SRAOwnDefaults(id receiver) {
    return receiver == NSUserDefaults.standardUserDefaults;
}
static BOOL SRAReadBool(id receiver, SEL selector, NSString *key) {
    if (SRAOwnDefaults(receiver) && [key isEqualToString:@"useLocalVPN"]) return NO;
    return SRAOriginalBool(receiver, selector, key);
}
static NSString *SRAReadString(id receiver, SEL selector, NSString *key) {
    if (SRAOwnDefaults(receiver) && [key isEqualToString:@"RemoteServerIp"]) return SRADirectHost ?: @"127.0.0.1";
    return SRAOriginalString(receiver, selector, key);
}
static id SRAReadObject(id receiver, SEL selector, NSString *key) {
    if (SRAOwnDefaults(receiver)) {
        if ([key isEqualToString:@"useLocalVPN"]) return @NO;
        if ([key isEqualToString:@"RemoteServerIp"]) return SRADirectHost ?: @"127.0.0.1";
    }
    return SRAOriginalObject(receiver, selector, key);
}
void SRAInstallDirectConnection(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SRADirectHost = [SRALocalWiFiAddress() copy] ?: @"127.0.0.1";
        // Install before ConnectionConfig's Swift singleton reads its settings.
        // Use this device's Wi-Fi address when available, not a remote server.
        // These are process-local reads; existing saved VPN configuration is kept.
        MSHookMessageEx(NSUserDefaults.class, @selector(boolForKey:), (IMP)SRAReadBool, (IMP *)&SRAOriginalBool);
        MSHookMessageEx(NSUserDefaults.class, @selector(stringForKey:), (IMP)SRAReadString, (IMP *)&SRAOriginalString);
        MSHookMessageEx(NSUserDefaults.class, @selector(objectForKey:), (IMP)SRAReadObject, (IMP *)&SRAOriginalObject);
        os_log(SRALog(), "Local connection configured wifi=%d; pairing and service validation remain enabled",
               ![SRADirectHost isEqualToString:@"127.0.0.1"]);
    });
}
void SRAProbeDirectConnection(void (^completion)(BOOL reachable, int error, uint32_t stage)) {
    // Probe from the SideStore process, not SpringBoard or a privileged helper.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL reachable = NO;
        int failure = 0;
        uint32_t stage = SRAConnectionStageAddress;
        NSString *host = SRADirectHost ?: @"127.0.0.1";
        NSString *current = SRALocalWiFiAddress() ?: @"127.0.0.1";
        // ConnectionConfig caches its address. Never probe a different address
        // and then claim that the backend's cached connection is usable.
        if (![current isEqualToString:host]) {
            os_log_error(SRALog(), "Local interface changed; relaunch SideStore before retrying");
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, EADDRNOTAVAIL, SRAConnectionStageAddress); });
            return;
        }
        stage = SRAConnectionStageSocket;
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) failure = errno;
        else {
            stage = SRAConnectionStageFlags;
            int flags = fcntl(fd, F_GETFL, 0);
            if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0) failure = errno;
            else {
                struct sockaddr_in address = {0};
                address.sin_len = sizeof(address);
                address.sin_family = AF_INET;
                address.sin_port = htons(62078);
                stage = SRAConnectionStageAddress;
                if (inet_pton(AF_INET, host.UTF8String, &address.sin_addr) != 1) failure = EINVAL;
                else {
                    stage = SRAConnectionStageConnect;
                    int result = connect(fd, (struct sockaddr *)&address, sizeof(address));
                    if (result == 0) reachable = YES;
                    else if (errno != EINPROGRESS) failure = errno;
                    else {
                        stage = SRAConnectionStagePoll;
                        struct pollfd descriptor = {.fd = fd, .events = POLLOUT};
                        int ready;
                        do { ready = poll(&descriptor, 1, 2000); } while (ready < 0 && errno == EINTR);
                        if (ready < 0) failure = errno;
                        else if (ready == 0) failure = ETIMEDOUT;
                        else {
                            stage = SRAConnectionStageSocketError;
                            int error = 0;
                            socklen_t length = sizeof(error);
                            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) != 0) failure = errno;
                            else {
                                failure = error;
                                reachable = error == 0 && (descriptor.revents & POLLOUT) != 0;
                                if (!reachable && !failure) failure = ECONNABORTED;
                            }
                        }
                    }
                }
            }
            close(fd);
        }
        os_log(SRALog(), "Local TCP probe wifi=%d reachable=%d errno=%d stage=%u build=%{public}s",
               ![host isEqualToString:@"127.0.0.1"], reachable, failure, stage, APELIN_BUILD_ID);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(reachable, failure, reachable ? SRAConnectionStageUnknown : stage); });
    });
}
