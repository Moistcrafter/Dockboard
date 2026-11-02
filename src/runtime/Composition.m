#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <sys/sysctl.h>
#include <time.h>
#include "IPadWindowGeometryV2.h"
#include "RuntimeBridge.h"
#ifndef SELF_TEST
#include "NativeDockTarget.h"
#else
static bool NativeDockTargetInit(Class cls);
static bool NativeDockTargetRead(id tile, bool restoring, SBMotionRect *out,
                                 IPadWindowDockEdge *edge);
#endif

typedef int (*WarpFn)(int, uint32_t, int, int, const SBMotionVertex *);
static WarpFn originalWarp, previousWarp;
static void (*previousUpdate)(id, SEL);
static void (*previousBegin)(id, SEL, double, bool, bool);
@interface DockboardMotionClock : NSObject {
  @public
    double multiplier;
    uint64_t start;
    bool active, closing;
}
@end
@implementation DockboardMotionClock
@end
static NSMutableDictionary<NSNumber *, DockboardMotionClock *> *clocks;
static NSLock *clockLock;
static void (*previousEnd)(id, SEL);
static _Atomic int *durationEnabled;
static bool (*setDurations)(float, float);
static _Thread_local void *activeTile;
static _Atomic uint64_t *v5Started;
static _Atomic bool *v5Restoring;
static _Atomic uint32_t *selectedWindow;
static int *v5Status;
static uintptr_t expectedCaller;
static ptrdiff_t windowOffset, imageOffset, progressOffset, widOffset, minimizingOffset,
    maximizingOffset, animateOffset;
_Atomic int GenieCompositionV8Enabled, GenieCompositionV8Frames, GenieCompositionV8Errors;
int GenieCompositionV8Status;
_Atomic unsigned GenieCompositionV8RepeatedBegins;
_Atomic unsigned DockboardMotionClockErrors, DockboardMotionTargetErrors, DockboardMotionGridErrors;
_Atomic unsigned DockboardMotionLastErrorWindow;

bool GenieCompositionV8SetEnabled(bool value) {
    if (GenieCompositionV8Status != 1 || *v5Status != 1 ||
        (value && (!durationEnabled || !atomic_load(durationEnabled) || !setDurations ||
                   !setDurations(1200, 850))))
        return false;
    atomic_store(&GenieCompositionV8Enabled, value);
    return true;
}
static uint64_t nanoseconds(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC_RAW, &t))
        return 0;
    return (uint64_t)t.tv_sec * 1000000000ULL + (uint64_t)t.tv_nsec;
}
bool GenieCompositionV8GetElapsed(uint32_t wid, double *out) {
    if (GenieCompositionV8Status != 1 || !v5Started || !selectedWindow || !out || !wid ||
        !atomic_load(&GenieCompositionV8Enabled))
        return false;
    [clockLock lock];
    DockboardMotionClock *clock = clocks[@(wid)];
    uint64_t start = clock ? clock->start : 0, now = nanoseconds();
    double multiplier = clock ? clock->multiplier : 0;
    [clockLock unlock];
    if ((atomic_load(selectedWindow) != UINT32_MAX && wid != atomic_load(selectedWindow)) ||
        !start || now < start || !isfinite(multiplier) || multiplier <= 0)
        return false;
    *out = (now - start) / 1e9 / multiplier;
    return true;
}
static void begin(id tile, SEL selector, double duration, bool minimizing, bool animate) {
    uint32_t wid;
    memcpy(&wid, (const char *)(__bridge void *)tile + widOffset, sizeof(wid));
    bool eligible = atomic_load(&GenieCompositionV8Enabled) && animate && wid &&
                    isfinite(duration) && duration > 0;
    if (eligible) {
        [clockLock lock];
        DockboardMotionClock *clock = clocks[@(wid)];
        bool repeated = clock && clock->active && clock->closing == minimizing;
        if (repeated)
            atomic_fetch_add(&GenieCompositionV8RepeatedBegins, 1);
        else {
            clock = [DockboardMotionClock new];
            clock->multiplier = duration / (minimizing ? 1200.0 : 850.0);
            clock->start = nanoseconds();
            clock->closing = minimizing;
            clock->active = true;
            clocks[@(wid)] = clock;
        }
        [clockLock unlock];
    }
    previousBegin(tile, selector, duration, minimizing, animate);
}
static void end(id tile, SEL selector) {
    uint32_t wid;
    memcpy(&wid, (const char *)(__bridge void *)tile + widOffset, sizeof(wid));
    [clockLock lock];
    DockboardMotionClock *endingClock = clocks[@(wid)];
    if (endingClock)
        endingClock->active = false;
    [clockLock unlock];
    @try {
        previousEnd(tile, selector);
    } @finally {
        [clockLock lock];
        if (clocks[@(wid)] == endingClock)
            [clocks removeObjectForKey:@(wid)];
        [clockLock unlock];
    }
}
static int submit(int connection, uint32_t wid, int columns, int rows, const SBMotionVertex *points,
                  uintptr_t caller) {
    id tile = (__bridge id)activeTile;
    if (!atomic_load(&GenieCompositionV8Enabled) || !tile || caller != expectedCaller || !wid ||
        (atomic_load(selectedWindow) != UINT32_MAX && wid != atomic_load(selectedWindow)) ||
        columns != 17 || rows != 17 || !points || *v5Status != 1)
        return originalWarp(connection, wid, columns, rows, points);
    const char *bytes = (__bridge const void *)tile;
    uint32_t tileWindow;
    memcpy(&tileWindow, bytes + widOffset, sizeof(tileWindow));
    if (wid != tileWindow || !bytes[animateOffset] ||
        !(bytes[minimizingOffset] || bytes[maximizingOffset]))
        return originalWarp(connection, wid, columns, rows, points);
    SBMotionRect window, target;
    float progress;
    double elapsed;
    memcpy(&window, bytes + windowOffset, sizeof(window));
    memcpy(&progress, bytes + progressOffset, sizeof(progress));
    [clockLock lock];
    DockboardMotionClock *clock = clocks[@(wid)];
    bool restoring = clock && !clock->closing;
    [clockLock unlock];
    IPadWindowDockEdge edge;
    SBMotionVertex grid[289];
    bool clockOK = GenieCompositionV8GetElapsed(wid, &elapsed) && isfinite(progress);
    bool targetOK = clockOK && NativeDockTargetRead(tile, restoring, &target, &edge);
    bool gridOK =
        targetOK && IPadWindowWarpGridV2(window, target, elapsed, restoring, edge, grid, NULL);
    if (!gridOK) {
        atomic_store(&DockboardMotionLastErrorWindow, wid);
        atomic_fetch_add(!clockOK    ? &DockboardMotionClockErrors
                         : !targetOK ? &DockboardMotionTargetErrors
                                     : &DockboardMotionGridErrors,
                         1);
        atomic_fetch_add(&GenieCompositionV8Errors, 1);
        return originalWarp(connection, wid, columns, rows, points);
    }
    // V5 supplies the full-window preview UVs; replace destination geometry only.
    for (int i = 0; i < 289; i++) {
        grid[i].sourceX = points[i].sourceX;
        grid[i].sourceY = points[i].sourceY;
    }
    int result = originalWarp(connection, wid, 17, 17, grid);
    if (result)
        atomic_fetch_add(&GenieCompositionV8Errors, 1);
    else
        atomic_fetch_add(&GenieCompositionV8Frames, 1);
    return result;
}
static void update(id tile, SEL selector) {
    void *outer = activeTile;
    activeTile = (__bridge void *)tile;
    @try {
        previousUpdate(tile, selector);
    } @finally {
        activeTile = outer;
    }
}
static BOOL offset(Class cls, const char *name, const char *type, ptrdiff_t *out) {
    Ivar ivar = class_getInstanceVariable(cls, name);
    if (!ivar || strcmp(ivar_getTypeEncoding(ivar), type))
        return NO;
    *out = ivar_getOffset(ivar);
    return YES;
}
#ifndef SELF_TEST
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
static int intercept(int connection, uint32_t wid, int columns, int rows,
                     const SBMotionVertex *points) {
    // Tail-call preserves the previous revision's exact caller-PC filter when disabled.
    if (!atomic_load(&GenieCompositionV8Enabled)) {
        __attribute__((musttail)) return previousWarp(connection, wid, columns, rows, points);
    }
    return submit(connection, wid, columns, rows, points, expectedCaller);
}
static BOOL uuidMatches(const struct mach_header_64 *header, const unsigned char uuid[16]) {
    if (!header || header->magic != MH_MAGIC_64 || header->ncmds > 256 ||
        header->sizeofcmds < sizeof(struct load_command))
        return NO;
    const char *cursor = (const char *)(header + 1), *limit = cursor + header->sizeofcmds;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (cursor > limit - (ptrdiff_t)sizeof(struct load_command))
            return NO;
        const struct load_command *command = (const void *)cursor;
        if (command->cmdsize < sizeof(*command) || command->cmdsize > (size_t)(limit - cursor))
            return NO;
        if (command->cmd == LC_UUID && command->cmdsize >= sizeof(struct uuid_command))
            return !memcmp(((const struct uuid_command *)command)->uuid, uuid, 16);
        cursor += command->cmdsize;
    }
    return NO;
}
static BOOL installOwnedPointer(void) {
    DockboardInstallWarpFunction installWarp =
        dlsym(RTLD_DEFAULT, "DockboardInstallWarpInterceptorV2");
    originalWarp = dlsym(RTLD_DEFAULT, "CGSSetWindowWarp");
    if (!installWarp || !originalWarp)
        return NO;
    expectedCaller = 1;
    return installWarp(intercept, &previousWarp, &v5Started, &v5Restoring,
                       &GenieCompositionV8Enabled);
}
#endif
static BOOL install(void) {
    Class cls = objc_getClass("DOCKWindowTile");
    Method method = class_getInstanceMethod(cls, sel_registerName("updateTransition"));
    Method b = class_getInstanceMethod(cls, sel_registerName("beginMinMax:minimizing:animate:"));
    Method e = class_getInstanceMethod(cls, sel_registerName("endMinMax"));
    if (!e || strcmp(method_getTypeEncoding(e), "v16@0:8"))
        return NO;
    if (!b || strcmp(method_getTypeEncoding(b), "v32@0:8d16B24B28") || !NativeDockTargetInit(cls) ||
        !durationEnabled || !setDurations || !method ||
        strcmp(method_getTypeEncoding(method), "v16@0:8") || !selectedWindow || !v5Status ||
        *v5Status != 1 ||
        !offset(cls, "_windowRect",
                "{CGRect=\"origin\"{CGPoint=\"x\"d\"y\"d}\"size\"{CGSize=\"width\"d\"height\"d}}",
                &windowOffset) ||
        !offset(cls, "_imageRect", "{FloatRect=\"left\"f\"top\"f\"right\"f\"bottom\"f}",
                &imageOffset) ||
        !offset(cls, "_transformNow", "f", &progressOffset) ||
        !offset(cls, "_wid", "I", &widOffset) ||
        !offset(cls, "_minimizing", "B", &minimizingOffset) ||
        !offset(cls, "_maximizing", "B", &maximizingOffset) ||
        !offset(cls, "_animateWindow", "B", &animateOffset))
        return NO;
#ifndef SELF_TEST
    if (!installOwnedPointer())
        return NO;
#endif
    previousEnd = (void *)method_setImplementation(e, (IMP)end);
    clockLock = [NSLock new];
    clocks = [NSMutableDictionary new];
    previousBegin = (void *)method_setImplementation(b, (IMP)begin);
    previousUpdate = (void *)method_setImplementation(method, (IMP)update);
    return YES;
}
#ifndef SELF_TEST
__attribute__((constructor)) static void load(void) {
    if (strcmp(getprogname(), "Dock"))
        return;
    char build[64];
    size_t size = sizeof(build);
    const unsigned char dockUUID[16] = {0xc5, 0x39, 0x75, 0xb1, 0x29, 0x56, 0x3e, 0xd4,
                                        0xb6, 0x99, 0xd4, 0xce, 0x2e, 0x6a, 0x60, 0x2c};
    if (sysctlbyname("kern.osversion", build, &size, NULL, 0) || strcmp(build, "26B123") ||
        !uuidMatches((const void *)_dyld_get_image_header(0), dockUUID)) {
        GenieCompositionV8Status = -1;
        return;
    }
    selectedWindow = dlsym(RTLD_DEFAULT, "GenieSpringBoardV5Window");
    v5Status = dlsym(RTLD_DEFAULT, "GenieSpringBoardV5Status");
    durationEnabled = dlsym(RTLD_DEFAULT, "GenieIPadDurationEnabled");
    setDurations = dlsym(RTLD_DEFAULT, "GenieIPadDurationSetDurations");
    GenieCompositionV8Status = install() ? 1 : -2;
}
#endif
