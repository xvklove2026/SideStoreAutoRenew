#import "SRARelay.h"
#import "SRACommon.h"
#import <objc/message.h>
#import <dlfcn.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <sys/socket.h>
#import <sys/uio.h>
#import <sys/time.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <poll.h>
#import <unistd.h>
#import <errno.h>
#import <limits.h>
#import <stdlib.h>
#import <stddef.h>
#import <netinet/tcp.h>
#import <string.h>
#import <stdio.h>

// Mirror coarse diagnostics to the host's existing stderr capture, not a file.
// Socket hooks must not change errno merely by reporting a result.
static void SRAConsoleRelay(int fd, uint16_t port, int nonblocking, const char *stage, int error) {
    int saved = errno;
    fprintf(stderr, "[SRA relay] fd=%d port=%u nonblocking=%d stage=%s errno=%d build=%s\n",
            fd, (unsigned)port, nonblocking, stage, error, APELIN_BUILD_ID);
    errno = saved;
}

extern void MSHookFunction(void *, void *, void **);
static int (*SRAOriginalConnect)(int, const struct sockaddr *, socklen_t);
static in_addr_t SRARelayHost;
static NSString *SRAClientPath;
static NSString *SRAServerPath;
static NSString *SRAServerExecutable;
static int SRAServerFD = -1;
static dispatch_source_t SRAServerSource;
static dispatch_semaphore_t SRAServerSlots;
static const uint32_t SRARelayMagic = 0x53524131;
typedef struct { uint32_t magic; uint16_t port; uint16_t reserved; } SRAOpen;

static BOOL SRAPortAllowed(uint16_t port) { return port == 62078 || port >= 49152; }
static NSString *SRASocketPath(NSString *container) {
    if (!container.length) return nil;
    char resolved[PATH_MAX];
    if (!realpath(container.fileSystemRepresentation, resolved)) return nil;
    NSString *path = [[NSString stringWithUTF8String:resolved] stringByAppendingPathComponent:@"tmp/sra-relay.sock"];
    return strlen(path.fileSystemRepresentation) < sizeof(((struct sockaddr_un *)0)->sun_path) ? path : nil;
}
static BOOL SRAUnixAddress(NSString *path, struct sockaddr_un *address) {
    if (!path || strlen(path.fileSystemRepresentation) >= sizeof(address->sun_path)) return NO;
    memset(address, 0, sizeof(*address));
    address->sun_family = AF_UNIX;
    strlcpy(address->sun_path, path.fileSystemRepresentation, sizeof(address->sun_path));
    address->sun_len = (uint8_t)(offsetof(struct sockaddr_un, sun_path) + strlen(address->sun_path) + 1);
    return YES;
}
static BOOL SRAExactIO(int fd, void *data, size_t length, BOOL writing) {
    size_t offset = 0;
    while (offset < length) {
        ssize_t count = writing ? send(fd, (char *)data + offset, length - offset, 0) : recv(fd, (char *)data + offset, length - offset, 0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return NO;
        offset += (size_t)count;
    }
    return YES;
}
static void SRATimeout(int fd) {
    struct timeval timeout = { .tv_sec = 2, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    int enabled = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
}
static int SRAOpenLocal(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) { int e = errno; close(fd); errno = e; return -1; }
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address); address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK); address.sin_port = htons(port);
    int result = connect(fd, (struct sockaddr *)&address, sizeof(address));
    if (result < 0 && errno == EINPROGRESS) {
        struct pollfd item = { .fd = fd, .events = POLLOUT };
        result = poll(&item, 1, 1500);
        if (result > 0) {
            int error = 0; socklen_t length = sizeof(error);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) < 0) result = -1;
            else if (error) { errno = error; result = -1; }
            else result = 0;
        } else { if (result == 0) errno = ETIMEDOUT; result = -1; }
    }
    int error = errno;
    if (result < 0) { close(fd); errno = error; return -1; }
    if (fcntl(fd, F_SETFL, flags) < 0) { error = errno; close(fd); errno = error; return -1; }
    return fd;
}
static void SRAHandlePeer(int peer, NSString *executable) {
    @autoreleasepool {
        SRATimeout(peer);
        pid_t pid = 0; socklen_t size = sizeof(pid);
        char path[4096] = {0};
        int (*readProcessPath)(int, void *, uint32_t) = dlsym(RTLD_DEFAULT, "proc_pidpath");
        char expected[PATH_MAX] = {0}; char actual[PATH_MAX] = {0};
        BOOL trusted = getsockopt(peer, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 && pid > 0 &&
            readProcessPath && readProcessPath(pid, path, sizeof(path)) > 0 &&
            realpath(path, actual) && realpath(executable.fileSystemRepresentation, expected) && strcmp(actual, expected) == 0;
        SRAOpen request = {0};
        if (!trusted || !SRAExactIO(peer, &request, sizeof(request), NO) || ntohl(request.magic) != SRARelayMagic || request.reserved || !SRAPortAllowed(ntohs(request.port))) {
            close(peer); return;
        }
        int remote = SRAOpenLocal(ntohs(request.port));
        int error = remote < 0 ? errno : 0;
        uint32_t response = htonl((uint32_t)error);
        struct iovec vector = { .iov_base = &response, .iov_len = sizeof(response) };
        union { struct cmsghdr alignment; char bytes[CMSG_SPACE(sizeof(int))]; } control = {0};
        struct msghdr message = {0}; message.msg_iov = &vector; message.msg_iovlen = 1;
        if (remote >= 0) {
            message.msg_control = control.bytes; message.msg_controllen = sizeof(control.bytes);
            struct cmsghdr *header = CMSG_FIRSTHDR(&message);
            header->cmsg_level = SOL_SOCKET; header->cmsg_type = SCM_RIGHTS; header->cmsg_len = CMSG_LEN(sizeof(int));
            memcpy(CMSG_DATA(header), &remote, sizeof(remote));
        }
        ssize_t sent = sendmsg(peer, &message, 0);
        os_log(SRALog(), "Local relay response port=%u errno=%d sent=%d build=%{public}s", (unsigned)ntohs(request.port), error, sent == sizeof(response), APELIN_BUILD_ID);
        if (remote >= 0) close(remote);
        close(peer);
    }
}
static void SRAConfigureRelayServer(void) {
    // Resolve the current app each time; never persist a container or bootstrap path.
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    SEL shared = NSSelectorFromString(@"defaultWorkspace");
    SEL find = NSSelectorFromString(@"applicationsAvailableForHandlingURLScheme:");
    if (![workspaceClass respondsToSelector:shared]) return;
    id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, shared);
    if (![workspace respondsToSelector:find]) return;
    NSArray *apps = ((id (*)(id, SEL, id))objc_msgSend)(workspace, find, @"sidestore");
    if (apps.count != 1) return;
    id app = apps.firstObject;
    SEL dataSelector = NSSelectorFromString(@"dataContainerURL");
    SEL bundleSelector = NSSelectorFromString(@"bundleURL");
    if (![app respondsToSelector:dataSelector] || ![app respondsToSelector:bundleSelector]) return;
    NSURL *container = ((id (*)(id, SEL))objc_msgSend)(app, dataSelector);
    NSURL *bundleURL = ((id (*)(id, SEL))objc_msgSend)(app, bundleSelector);
    NSBundle *bundle = [NSBundle bundleWithURL:bundleURL];
    if (![[bundle objectForInfoDictionaryKey:@"CFBundleExecutable"] isEqualToString:@"SideStore"]) return;
    NSString *path = SRASocketPath(container.path);
    NSString *executable = bundle.executablePath;
    if (!path || !executable) return;
    if (SRAServerFD >= 0) {
        if (![path isEqualToString:SRAServerPath]) os_log_error(SRALog(), "SideStore container changed; restart SpringBoard before retrying relay");
        return;
    }
    struct sockaddr_un address;
    if (!SRAUnixAddress(path, &address)) return;
    struct stat previous;
    if (lstat(path.fileSystemRepresentation, &previous) == 0) {
        if (!S_ISSOCK(previous.st_mode) || previous.st_uid != getuid()) return;
        int test = socket(AF_UNIX, SOCK_STREAM, 0);
        if (test < 0) return;
        SRATimeout(test);
        int alive = connect(test, (struct sockaddr *)&address, address.sun_len);
        int error = errno; close(test);
        if (alive == 0 || (error != ECONNREFUSED && error != ENOENT)) return;
        if (unlink(path.fileSystemRepresentation) != 0) return;
    }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return;
    if (bind(fd, (struct sockaddr *)&address, address.sun_len) != 0 || chmod(path.fileSystemRepresentation, 0600) != 0 || listen(fd, 8) != 0) {
        int error = errno; close(fd); os_log_error(SRALog(), "Local relay listener errno=%d", error); return;
    }
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) { close(fd); return; }
    SRAServerFD = fd; SRAServerPath = [path copy]; SRAServerExecutable = [executable copy];
    SRAServerSlots = dispatch_semaphore_create(8);
    dispatch_queue_t queue = dispatch_queue_create("local.apelin.sidestore.autorenew.relay", DISPATCH_QUEUE_SERIAL);
    SRAServerSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, queue);
    dispatch_source_set_event_handler(SRAServerSource, ^{
        for (;;) {
            int peer = accept(fd, NULL, NULL);
            if (peer < 0) break;
            if (dispatch_semaphore_wait(SRAServerSlots, DISPATCH_TIME_NOW) != 0) { close(peer); continue; }
            NSString *expected = SRAServerExecutable;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                SRAHandlePeer(peer, expected); dispatch_semaphore_signal(SRAServerSlots);
            });
        }
    });
    dispatch_resume(SRAServerSource);
    os_log(SRALog(), "Local relay listener ready build=%{public}s", APELIN_BUILD_ID);
}
void SRAStartRelayServer(void) {
    static dispatch_queue_t setup;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ setup = dispatch_queue_create("local.apelin.sidestore.autorenew.relay.setup", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(setup, ^{ @autoreleasepool { SRAConfigureRelayServer(); } });
}
static int SRARelayConnect(int fd, const struct sockaddr *address, socklen_t length) {
    if (!address || length < sizeof(struct sockaddr_in) || address->sa_family != AF_INET) return SRAOriginalConnect(fd, address, length);
    const struct sockaddr_in *target = (const struct sockaddr_in *)address;
    if ((target->sin_addr.s_addr != SRARelayHost && target->sin_addr.s_addr != htonl(INADDR_LOOPBACK)) || !SRAPortAllowed(ntohs(target->sin_port))) return SRAOriginalConnect(fd, address, length);
    int type = 0; socklen_t typeSize = sizeof(type);
    if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &typeSize) != 0 || type != SOCK_STREAM) return SRAOriginalConnect(fd, address, length);
    // Never introduce a blocking IPC handshake on the app's main thread.
    if (NSThread.isMainThread) {
        SRAConsoleRelay(fd, ntohs(target->sin_port), -1, "main-thread", EWOULDBLOCK);
        errno = EWOULDBLOCK; return -1;
    }
    int flags = fcntl(fd, F_GETFL, 0); int descriptorFlags = fcntl(fd, F_GETFD, 0);
    struct sockaddr_storage existing; socklen_t existingSize = sizeof(existing);
    if (getpeername(fd, (struct sockaddr *)&existing, &existingSize) == 0) {
        SRAConsoleRelay(fd, ntohs(target->sin_port), flags < 0 ? -1 : (flags & O_NONBLOCK) != 0, "already-connected", EISCONN);
        errno = EISCONN; return -1;
    }
    struct sockaddr_un endpoint;
    if (flags < 0 || descriptorFlags < 0 || !SRAUnixAddress(SRAClientPath, &endpoint)) {
        SRAConsoleRelay(fd, ntohs(target->sin_port), flags < 0 ? -1 : (flags & O_NONBLOCK) != 0, "client-setup", EINVAL);
        errno = EINVAL; return -1;
    }
    int peer = socket(AF_UNIX, SOCK_STREAM, 0);
    if (peer < 0) {
        int error = errno;
        SRAConsoleRelay(fd, ntohs(target->sin_port), (flags & O_NONBLOCK) != 0, "ipc-socket", error);
        errno = error; return -1;
    }
    SRATimeout(peer);
    int received = -1; int error = 0;
    const char *stage = "ipc-connect";
    os_log(SRALog(), "Local relay begin fd=%d port=%u nonblocking=%d build=%{public}s", fd, (unsigned)ntohs(target->sin_port), (flags & O_NONBLOCK) != 0, APELIN_BUILD_ID);
    SRAConsoleRelay(fd, ntohs(target->sin_port), (flags & O_NONBLOCK) != 0, stage, 0);
    if (SRAOriginalConnect(peer, (struct sockaddr *)&endpoint, endpoint.sun_len) != 0) error = errno;
    if (!error) stage = "ipc-request";
    SRAOpen request = { .magic = htonl(SRARelayMagic), .port = target->sin_port, .reserved = 0 };
    if (!error && !SRAExactIO(peer, &request, sizeof(request), YES)) error = errno ?: ECONNRESET;
    if (!error) {
        stage = "ipc-response";
        uint32_t response = 0;
        struct iovec vector = { .iov_base = &response, .iov_len = sizeof(response) };
        union { struct cmsghdr alignment; char bytes[CMSG_SPACE(sizeof(int))]; } control = {0};
        struct msghdr message = {0}; message.msg_iov = &vector; message.msg_iovlen = 1;
        message.msg_control = control.bytes; message.msg_controllen = sizeof(control.bytes);
        ssize_t count = recvmsg(peer, &message, MSG_WAITALL);
        struct cmsghdr *header = CMSG_FIRSTHDR(&message);
        if (header && header->cmsg_level == SOL_SOCKET && header->cmsg_type == SCM_RIGHTS && header->cmsg_len == CMSG_LEN(sizeof(int))) memcpy(&received, CMSG_DATA(header), sizeof(received));
        if (count != sizeof(response) || (message.msg_flags & (MSG_TRUNC | MSG_CTRUNC))) error = count < 0 ? errno : EPROTO;
        else error = (int)ntohl(response);
        if (!error && received < 0) error = EPROTO;
    }
    close(peer);
    if (!error) {
        stage = "socket-options";
        const int levels[] = { SOL_SOCKET, IPPROTO_TCP, SOL_SOCKET };
        const int options[] = { SO_KEEPALIVE, TCP_NODELAY, SO_NOSIGPIPE };
        for (size_t i = 0; i < sizeof(options) / sizeof(options[0]); i++) {
            int value = 0; socklen_t size = sizeof(value);
            if (getsockopt(fd, levels[i], options[i], &value, &size) != 0 ||
                setsockopt(received, levels[i], options[i], &value, size) != 0) {
                error = errno;
                os_log_error(SRALog(), "Local relay option=%d errno=%d", options[i], error);
                break;
            }
        }
        const int timeoutOptions[] = { SO_RCVTIMEO, SO_SNDTIMEO };
        if (!error) stage = "socket-timeouts";
        for (size_t i = 0; !error && i < sizeof(timeoutOptions) / sizeof(timeoutOptions[0]); i++) {
            struct timeval timeout = {0}; socklen_t timeoutSize = sizeof(timeout);
            if (getsockopt(fd, SOL_SOCKET, timeoutOptions[i], &timeout, &timeoutSize) != 0 ||
                setsockopt(received, SOL_SOCKET, timeoutOptions[i], &timeout, timeoutSize) != 0) { error = errno; break; }
        }
        if (!error) { stage = "status-flags"; if (fcntl(received, F_SETFL, flags) < 0) error = errno; }
        if (!error) { stage = "dup2"; if (dup2(received, fd) < 0) error = errno; }
        if (!error) { stage = "descriptor-flags"; if (fcntl(fd, F_SETFD, descriptorFlags) < 0) error = errno; }
        if (!error) stage = "connected";
    }
    if (received >= 0) close(received);
    os_log(SRALog(), "Local relay connect fd=%d port=%u nonblocking=%d stage=%{public}s errno=%d build=%{public}s", fd, (unsigned)ntohs(target->sin_port), (flags & O_NONBLOCK) != 0, stage, error, APELIN_BUILD_ID);
    SRAConsoleRelay(fd, ntohs(target->sin_port), (flags & O_NONBLOCK) != 0, stage, error);
    if (error) { errno = error; return -1; }
    return 0;
}
void SRAInstallRelayClient(NSString *host) {
    struct in_addr address;
    if (inet_pton(AF_INET, host.UTF8String, &address) != 1) return;
    SRAClientPath = SRASocketPath(NSHomeDirectory());
    if (!SRAClientPath) { os_log_error(SRALog(), "Local relay container path unavailable"); return; }
    SRARelayHost = address.s_addr;
    void *symbol = dlsym(RTLD_DEFAULT, "connect");
    if (symbol) MSHookFunction(symbol, (void *)SRARelayConnect, (void **)&SRAOriginalConnect);
    // The host starts capturing stderr after constructors have completed.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        SRAConsoleRelay(-1, 0, -1, SRAOriginalConnect ? "hook-ready" : "hook-unavailable", SRAOriginalConnect ? 0 : ENOSYS);
    });
}
