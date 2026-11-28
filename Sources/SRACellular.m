#import "SRACellular.h"
#import "SRACommon.h"
#import <dlfcn.h>
#include <stdint.h>

extern void MSHookFunction(void *, void *, void **);

// Swift Network.NWPath.usesInterfaceType(_:) from the installed SideStore
// binary. NWPath carries one opaque path reference on arm64; the network
// interface type is the next register-sized ABI argument and Bool is returned
// in w0. The target path performs the real classification first, so we only
// augment a cellular-only path with the policy's Wi-Fi answer.
typedef BOOL (*SRAUsesInterfaceTypeIMP)(void *path, uint64_t type);
static SRAUsesInterfaceTypeIMP SRAOriginalUsesInterfaceType;
static unsigned SRAClassificationReports;
static const char SRAWiFiClassificationSymbol[] =
    "_$s7Network6NWPathV17usesInterfaceTypeySbAA11NWInterfaceV0dE0OF";

static BOOL SRAUsesInterfaceType(void *path, uint64_t type) {
    if (!SRAOriginalUsesInterfaceType) return NO;

    const uint64_t wifiType = 1;
    const uint64_t cellularType = 2;
    BOOL cellular = SRAOriginalUsesInterfaceType(path, cellularType);
    BOOL wifi = SRAOriginalUsesInterfaceType(path, wifiType);
    if (cellular && !wifi) {
        if (SRAClassificationReports < 8) {
            SRAClassificationReports++;
            os_log(SRALog(), "Cellular NWPath presented as Wi-Fi to refresh policy; actual path unchanged build=%{public}s",
                   APELIN_BUILD_ID);
        }
        if (type == wifiType) return YES;
        if (type == cellularType) return NO;
    }
    return SRAOriginalUsesInterfaceType(path, type);
}

void SRAInstallCellularClient(void) {
    // Only SideStore calls this entry point. Its installed binary contains
    // CellularRefreshManager's Wi-Fi skip branch and imports this Swift symbol.
    // No shortcut URL or CoreTelephony data toggle is intercepted anymore.
    void *symbol = dlsym(RTLD_DEFAULT, SRAWiFiClassificationSymbol + 1);
    if (!symbol) {
        os_log_error(SRALog(), "NWPath.usesInterfaceType symbol missing; cellular path left unchanged");
        return;
    }
    MSHookFunction(symbol, (void *)SRAUsesInterfaceType,
                   (void **)&SRAOriginalUsesInterfaceType);
    os_log(SRALog(), "SideStore NWPath Wi-Fi classification hook installed; cellular shortcuts disabled build=%{public}s",
           APELIN_BUILD_ID);
}
