#import "SRADirect.h"
#import "SRARelay.h"
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

static NSString *SRADirectHost;
static BOOL SRAWiFiDirectEnabled;

static NSString *SRALocalEndpointAddress(void) {
    struct ifaddrs *interfaces = NULL;
    NSString *wifiHost = nil;
    NSString *cellularHost = nil;
    if (getifaddrs(&interfaces) != 0) return nil;
    for (struct ifaddrs *item = interfaces; item; item = item->ifa_next) {
        if (!item->ifa_addr || !item->ifa_name || item->ifa_addr->sa_family != AF_INET ||
            !(item->ifa_flags & IFF_UP) || (item->ifa_flags & IFF_LOOPBACK)) continue;
        BOOL wifi = strcmp(item->ifa_name, "en0") == 0;
        BOOL cellular = strncmp(item->ifa_name, "pdp_ip", 6) == 0;
        if (!wifi && !cellular) continue;
        struct sockaddr_in *address = (struct sockaddr_in *)item->ifa_addr;
        uint32_t value = ntohl(address->sin_addr.s_addr);
        if (!value || value >> 24 == 127 || (value >> 16) == 0xa9fe) continue;
        char buffer[INET_ADDRSTRLEN] = {0};
        if (!inet_ntop(AF_INET, &address->sin_addr, buffer, sizeof(buffer))) continue;
        NSString *host = [NSString stringWithUTF8String:buffer];
        if (wifi) { wifiHost = host; break; }
        if (!cellularHost) cellularHost = host;
    }
    freeifaddrs(interfaces);
    return wifiHost ?: cellularHost;
}

NSString *SRACurrentDeviceHost(void) {
    return SRALocalEndpointAddress();
}

BOOL SRAWiFiDirectActive(void) {
    return SRAWiFiDirectEnabled;
}

extern void MSHookMessageEx(Class cls, SEL selector, IMP replacement, IMP *original);
static BOOL (*SRAOriginalBool)(id, SEL, NSString *);
static NSString *(*SRAOriginalString)(id, SEL, NSString *);
static id (*SRAOriginalObject)(id, SEL, NSString *);

static BOOL SRAOwnDefaults(id receiver) {
    return receiver == NSUserDefaults.standardUserDefaults;
}
static BOOL SRAReadBool(id receiver, SEL selector, NSString *key) {
    if (SRAWiFiDirectEnabled && SRAOwnDefaults(receiver) && [key isEqualToString:@"useLocalVPN"])
        return NO;
    return SRAOriginalBool(receiver, selector, key);
}
static NSString *SRAReadString(id receiver, SEL selector, NSString *key) {
    if (SRAWiFiDirectEnabled && SRAOwnDefaults(receiver) && [key isEqualToString:@"RemoteServerIp"])
        return SRADirectHost;
    return SRAOriginalString(receiver, selector, key);
}
static id SRAReadObject(id receiver, SEL selector, NSString *key) {
    if (SRAWiFiDirectEnabled && SRAOwnDefaults(receiver)) {
        if ([key isEqualToString:@"useLocalVPN"]) return @NO;
        if ([key isEqualToString:@"RemoteServerIp"]) return SRADirectHost;
    }
    return SRAOriginalObject(receiver, selector, key);
}

void SRAInstallDirectConnection(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SRADirectHost = [SRALocalEndpointAddress() copy];
        SRAWiFiDirectEnabled = SRADirectHost.length > 0;
        if (!SRAWiFiDirectEnabled) {
            os_log(SRALog(), "No local Wi-Fi or cellular IPv4 endpoint; preserving SideStore connection settings build=%{public}s",
                   APELIN_BUILD_ID);
            return;
        }
        SRAInstallRelayClient(SRADirectHost);
        // Install before SideStore's connection configuration singleton reads its settings.
        MSHookMessageEx(NSUserDefaults.class, @selector(boolForKey:), (IMP)SRAReadBool, (IMP *)&SRAOriginalBool);
        MSHookMessageEx(NSUserDefaults.class, @selector(stringForKey:), (IMP)SRAReadString, (IMP *)&SRAOriginalString);
        MSHookMessageEx(NSUserDefaults.class, @selector(objectForKey:), (IMP)SRAReadObject, (IMP *)&SRAOriginalObject);
        os_log(SRALog(), "Local endpoint relay enabled (Wi-Fi preferred, cellular fallback); VPN setting overridden only in SideStore host build=%{public}s",
               APELIN_BUILD_ID);
    });
}

void SRAProbeDirectConnection(void (^completion)(BOOL reachable, int error, uint32_t stage)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL reachable = NO;
        int failure = 0;
        uint32_t stage = SRAConnectionStageAddress;
        NSString *host = SRADirectHost;
        if (!SRAWiFiDirectEnabled || !host.length) {
            failure = ENETUNREACH;
        } else {
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
        }
        os_log(SRALog(), "Wi-Fi direct TCP probe reachable=%d errno=%d stage=%u build=%{public}s",
               reachable, failure, stage, APELIN_BUILD_ID);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(reachable, failure, reachable ? SRAConnectionStageUnknown : stage); });
    });
}
