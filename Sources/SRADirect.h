#pragma once
#import <Foundation/Foundation.h>
void SRAInstallDirectConnection(void);
void SRAProbeDirectConnection(void (^completion)(BOOL reachable));
