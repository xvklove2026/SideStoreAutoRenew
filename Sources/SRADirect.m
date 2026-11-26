#import "SRADirect.h"
#import "SRACommon.h"
#import <objc/runtime.h>
#import <sys/socket.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <poll.h>
#import <unistd.h>
#import <errno.h>

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
    if (SRAOwnDefaults(receiver) && [key isEqualToString:@"RemoteServerIp"]) return @"127.0.0.1";
    return SRAOriginalString(receiver, selector, key);
}
static id SRAReadObject(id receiver, SEL selector, NSString *key) {
    if (SRAOwnDefaults(receiver)) {
        if ([key isEqualToString:@"useLocalVPN"]) return @NO;
        if ([key isEqualToString:@"RemoteServerIp"]) return @"127.0.0.1";
    }
    return SRAOriginalObject(receiver, selector, key);
}
void SRAInstallDirectConnection(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Install before ConnectionConfig's Swift singleton reads its settings.
        // These are process-local reads; existing saved VPN configuration is kept.
        MSHookMessageEx(NSUserDefaults.class, @selector(boolForKey:), (IMP)SRAReadBool, (IMP *)&SRAOriginalBool);
        MSHookMessageEx(NSUserDefaults.class, @selector(stringForKey:), (IMP)SRAReadString, (IMP *)&SRAOriginalString);
        MSHookMessageEx(NSUserDefaults.class, @selector(objectForKey:), (IMP)SRAReadObject, (IMP *)&SRAOriginalObject);
        os_log(SRALog(), "Direct loopback mode installed; pairing and service validation remain enabled");
    });
}
void SRAProbeDirectConnection(void (^completion)(BOOL reachable)) {
    // Probe from the SideStore process, not SpringBoard or a privileged helper.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL reachable = NO;
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd >= 0) {
            int flags = fcntl(fd, F_GETFL, 0);
            if (flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0) {
                struct sockaddr_in address = {0};
                address.sin_len = sizeof(address);
                address.sin_family = AF_INET;
                address.sin_port = htons(62078);
                inet_pton(AF_INET, "127.0.0.1", &address.sin_addr);
                int result = connect(fd, (struct sockaddr *)&address, sizeof(address));
                if (result == 0) reachable = YES;
                else if (errno == EINPROGRESS) {
                    struct pollfd descriptor = {.fd = fd, .events = POLLOUT};
                    if (poll(&descriptor, 1, 2000) > 0 && (descriptor.revents & POLLOUT)) {
                        int error = 0;
                        socklen_t length = sizeof(error);
                        reachable = getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0;
                    }
                }
            }
            close(fd);
        }
        os_log(SRALog(), "SideStore loopback TCP probe reachable=%d", reachable);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(reachable); });
    });
}
