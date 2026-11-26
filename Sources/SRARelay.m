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
// Version 2 connects the client's original socket; never replaces its identity.
static const uint32_t SRARelayMagic = 0x53524132;
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
        if (count < 0) return NO;
        if (count == 0) { errno = ECONNRESET; return NO; }
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
static int SRAConnectLocal(int fd, uint16_t port) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) return -1;
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address); address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK); address.sin_port = htons(port);
    int result = connect(fd, (struct sockaddr *)&address, sizeof(address));
    if (result < 0 && errno == EINPROGRESS) {
        struct pollfd item = { .fd = fd, .events = POLLOUT };
        do { result = poll(&item, 1, 1500); } while (result < 0 && errno == EINTR);
        if (result > 0) {
            int error = 0; socklen_t length = sizeof(error);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) < 0) result = -1;
            else if (error) { errno = error; result = -1; }
            else result = 0;
        } else { if (result == 0) errno = ETIMEDOUT; result = -1; }
    }
    int error = result < 0 ? errno : 0;
    if (fcntl(fd, F_SETFL, flags) < 0 && !error) error = errno;
    if (error) { errno = error; return -1; }
    return 0;
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
        if (!trusted) { close(peer); return; }
        SRAOpen request = {0};
        struct iovec vector = { .iov_base = &request, .iov_len = sizeof(request) };
        union { struct cmsghdr alignment; char bytes[CMSG_SPACE(sizeof(int) * 8)]; } control = {0};
        struct msghdr message = {0}; message.msg_iov = &vector; message.msg_iovlen = 1;
        message.msg_control = control.bytes; message.msg_controllen = sizeof(control.bytes);
        ssize_t count;
        do { count = recvmsg(peer, &message, MSG_WAITALL); } while (count < 0 && errno == EINTR);
        int remote = -1; unsigned descriptorCount = 0;
        for (struct cmsghdr *header = CMSG_FIRSTHDR(&message); header; header = CMSG_NXTHDR(&message, header)) {
            if (header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS || header->cmsg_len < CMSG_LEN(0)) continue;
            size_t bytes = header->cmsg_len - CMSG_LEN(0);
            for (size_t offset = 0; offset + sizeof(int) <= bytes; offset += sizeof(int)) {
                int candidate = -1; memcpy(&candidate, (char *)CMSG_DATA(header) + offset, sizeof(candidate));
                descriptorCount++;
                if (remote < 0) remote = candidate; else close(candidate);
            }
        }
        if (count > 0 && (size_t)count < sizeof(request) &&
            SRAExactIO(peer, (char *)&request + count, sizeof(request) - (size_t)count, NO)) count = sizeof(request);
        int error = 0;
        if (count != sizeof(request) || (message.msg_flags & (MSG_TRUNC | MSG_CTRUNC)) ||
            descriptorCount != 1 || remote < 0 || ntohl(request.magic) != SRARelayMagic ||
            request.reserved || !SRAPortAllowed(ntohs(request.port))) error = EPROTO;
        int type = 0; socklen_t typeSize = sizeof(type);
        struct sockaddr_storage local = {0}, connected = {0};
        socklen_t localSize = sizeof(local), connectedSize = sizeof(connected);
        if (!error && (getsockopt(remote, SOL_SOCKET, SO_TYPE, &type, &typeSize) != 0 ||
            type != SOCK_STREAM || getsockname(remote, (struct sockaddr *)&local, &localSize) != 0 ||
            local.ss_family != AF_INET)) error = EINVAL;
        if (!error) {
            int result = getpeername(remote, (struct sockaddr *)&connected, &connectedSize);
            if (result == 0) error = EISCONN;
            else if (errno != ENOTCONN) error = errno;
        }
        if (!error && SRAConnectLocal(remote, ntohs(request.port)) != 0) error = errno;
        uint32_t response = htonl((uint32_t)error);
        BOOL sent = SRAExactIO(peer, &response, sizeof(response), YES);
        os_log(SRALog(), "Local relay original-socket port=%u errno=%d sent=%d build=%{public}s", (unsigned)ntohs(request.port), error, sent, APELIN_BUILD_ID);
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
    int error = 0;
    const char *stage = "ipc-connect";
    os_log(SRALog(), "Local relay begin fd=%d port=%u nonblocking=%d build=%{public}s", fd, (unsigned)ntohs(target->sin_port), (flags & O_NONBLOCK) != 0, APELIN_BUILD_ID);
    SRAConsoleRelay(fd, ntohs(target->sin_port), (flags & O_NONBLOCK) != 0, stage, 0);
    if (SRAOriginalConnect(peer, (struct sockaddr *)&endpoint, endpoint.sun_len) != 0) error = errno;
    if (!error) stage = "ipc-request";
    SRAOpen request = { .magic = htonl(SRARelayMagic), .port = target->sin_port, .reserved = 0 };
    if (!error) {
        struct iovec vector = { .iov_base = &request, .iov_len = sizeof(request) };
        union { struct cmsghdr alignment; char bytes[CMSG_SPACE(sizeof(int))]; } control = {0};
        struct msghdr message = {0}; message.msg_iov = &vector; message.msg_iovlen = 1;
        message.msg_control = control.bytes; message.msg_controllen = sizeof(control.bytes);
        struct cmsghdr *header = CMSG_FIRSTHDR(&message);
        header->cmsg_level = SOL_SOCKET; header->cmsg_type = SCM_RIGHTS; header->cmsg_len = CMSG_LEN(sizeof(int));
        memcpy(CMSG_DATA(header), &fd, sizeof(fd));
        ssize_t sent;
        do { sent = sendmsg(peer, &message, 0); } while (sent < 0 && errno == EINTR);
        if (sent < 0) error = errno;
        else if (sent == 0) error = ECONNRESET;
        else if ((size_t)sent < sizeof(request) &&
                 !SRAExactIO(peer, (char *)&request + sent, sizeof(request) - (size_t)sent, YES)) error = errno ?: ECONNRESET;
    }
    if (!error) {
        stage = "ipc-response";
        uint32_t response = 0;
        if (!SRAExactIO(peer, &response, sizeof(response), NO)) error = errno ?: ECONNRESET;
        else error = (int)ntohl(response);
    }
    close(peer);
    if (!error) {
        stage = "verify-original";
        struct sockaddr_in connected = {0}; socklen_t connectedSize = sizeof(connected);
        if (getpeername(fd, (struct sockaddr *)&connected, &connectedSize) != 0) error = errno;
        else if (connected.sin_family != AF_INET || connected.sin_addr.s_addr != htonl(INADDR_LOOPBACK) ||
                 connected.sin_port != target->sin_port) error = EPROTO;
        if (!error && fcntl(fd, F_GETFL, 0) != flags) error = EIO;
        if (!error && fcntl(fd, F_GETFD, 0) != descriptorFlags) error = EIO;
        if (!error) stage = "connected-original";
    }
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
