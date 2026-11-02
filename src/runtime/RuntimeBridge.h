#ifndef DOCKBOARD_RUNTIME_BRIDGE_H
#define DOCKBOARD_RUNTIME_BRIDGE_H
#include <stdatomic.h>
#include <stdint.h>
#include "SpringBoardMotion.h"

typedef int (*DockboardWarpFunction)(int, uint32_t, int, int, const SBMotionVertex *);
typedef bool (*DockboardInstallWarpFunction)(DockboardWarpFunction, DockboardWarpFunction *,
                                             _Atomic uint64_t **, _Atomic bool **, _Atomic int *);
#endif
