#pragma once
#import <Foundation/Foundation.h>
void SRAInstallDirectConnection(void);
BOOL SRAWiFiDirectActive(void);
NSString *SRACurrentDeviceHost(void);
void SRAProbeDirectConnection(void (^completion)(BOOL reachable, int error, uint32_t stage));
