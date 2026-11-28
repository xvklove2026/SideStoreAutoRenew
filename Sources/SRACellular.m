#import "SRACellular.h"
#import "SRACommon.h"
#import <dlfcn.h>
#include <stdbool.h>
#include <stdint.h>

extern void MSHookFunction(void *, void *, void **);

// Hook Network.framework's C entry point instead of the Swift value-type
// wrapper. Its ABI is nw_path_t + nw_interface_type_t -> bool, which avoids
// calling NWPath's Swift thunk with an incorrectly guessed struct convention.
typedef bool (*SRANWPathUsesInterfaceType)(void *path, uint32_t type);
static SRANWPathUsesInterfaceType SRAOriginalNWPathUsesInterfaceType;
static unsigned SRAClassificationReports;

static bool SRAHookedNWPathUsesInterfaceType(void *path, uint32_t type) {
    if (!SRAOriginalNWPathUsesInterfaceType) return false;

    const uint32_t wifiType = 1;
    const uint32_t cellularType = 2;
    const bool cellular = SRAOriginalNWPathUsesInterfaceType(path, cellularType);
    const bool wifi = SRAOriginalNWPathUsesInterfaceType(path, wifiType);
    if (cellular && !wifi) {
        if (SRAClassificationReports < 8) {
            SRAClassificationReports++;
            os_log(SRALog(), "Cellular NWPath presented as Wi-Fi to refresh policy; actual path unchanged build=%{public}s",
                   APELIN_BUILD_ID);
        }
        if (type == wifiType) return true;
        if (type == cellularType) return false;
    }
    return SRAOriginalNWPathUsesInterfaceType(path, type);
}

void SRAInstallCellularClient(void) {
    // Only SideStore calls this entry point. It loads Network.framework and
    // calls nw_path_uses_interface_type through NWPath. The kernel route,
    // sockets, pairing and cellular-data settings are left untouched.
    void *symbol = dlsym(RTLD_DEFAULT, "nw_path_uses_interface_type");
    if (!symbol) {
        os_log_error(SRALog(), "nw_path_uses_interface_type symbol missing; path classification left unchanged");
        return;
    }
    MSHookFunction(symbol, (void *)SRAHookedNWPathUsesInterfaceType,
                   (void **)&SRAOriginalNWPathUsesInterfaceType);
    os_log(SRALog(), "SideStore Network.framework C path-classification hook installed; cellular shortcuts disabled build=%{public}s",
           APELIN_BUILD_ID);
}
