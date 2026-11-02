#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdatomic.h>

static int (*connection)(void), (*getTags)(int, uint32_t, uint64_t *, int),
    (*setTags)(int, uint32_t, const uint64_t *, int),
    (*clearTags)(int, uint32_t, const uint64_t *, int);
static void (*previousBegin)(id, SEL, double, bool, bool), (*previousEnd)(id, SEL);
static ptrdiff_t widOffset;
static _Atomic uint32_t *selectedWindow;
static int *baseStatus;
static NSMutableDictionary<NSNumber *, NSNumber *> *baselines;
static NSLock *routingLock;
int DockboardInputRoutingStatus;
_Atomic int DockboardInputRoutingEnabled;
_Atomic unsigned DockboardInputRoutingErrors, DockboardInputRoutingBegins,
    DockboardInputRoutingRestores;
// Only change the mutually exclusive ignore/opaque-for-events bits.
static const uint64_t eventBits = 0x600, ignoreEvents = 0x200;
static uint32_t windowID(id tile) {
    uint32_t wid;
    memcpy(&wid, (const char *)(__bridge void *)tile + widOffset, sizeof(wid));
    return wid;
}
static bool writeBits(uint32_t wid, uint64_t bits) {
    uint64_t remove = ~bits & eventBits, add = bits & eventBits;
    int c = connection();
    return !clearTags(c, wid, &remove, 64) && !setTags(c, wid, &add, 64);
}
static bool restore(uint32_t wid) {
    NSNumber *baseline = baselines[@(wid)];
    if (!baseline)
        return true;
    if (!writeBits(wid, baseline.unsignedLongLongValue)) {
        atomic_fetch_add(&DockboardInputRoutingErrors, 1);
        return false;
    }
    [baselines removeObjectForKey:@(wid)];
    atomic_fetch_add(&DockboardInputRoutingRestores, 1);
    return true;
}
bool DockboardInputRoutingSetEnabled(bool enabled) {
    if (DockboardInputRoutingStatus != 1 || ![NSThread isMainThread])
        return false;
    [routingLock lock];
    @try {
        atomic_store(&DockboardInputRoutingEnabled, 0);
        bool clean = true;
        for (NSNumber *wid in baselines.allKeys)
            if (!restore(wid.unsignedIntValue))
                clean = false;
        if (!clean || (enabled && *baseStatus != 1))
            return false;
        atomic_store(&DockboardInputRoutingEnabled, enabled);
        return true;
    } @finally {
        [routingLock unlock];
    }
}
static void begin(id tile, SEL selector, double duration, bool minimizing, bool animate) {
    previousBegin(tile, selector, duration, minimizing, animate);
    uint32_t wid = windowID(tile);
    [routingLock lock];
    @try {
        if (!atomic_load(&DockboardInputRoutingEnabled) || !animate || !wid ||
            (atomic_load(selectedWindow) != UINT32_MAX && wid != atomic_load(selectedWindow)))
            return;
        if (!baselines[@(wid)]) {
            uint64_t tags = 0;
            if (getTags(connection(), wid, &tags, 64)) {
                atomic_fetch_add(&DockboardInputRoutingErrors, 1);
                return;
            }
            baselines[@(wid)] = @(tags & eventBits);
        }
        if (!writeBits(wid, ignoreEvents)) {
            atomic_fetch_add(&DockboardInputRoutingErrors, 1);
            restore(wid);
            return;
        }
        atomic_fetch_add(&DockboardInputRoutingBegins, 1);
    } @finally {
        [routingLock unlock];
    }
}
static void end(id tile, SEL selector) {
    [routingLock lock];
    restore(windowID(tile));
    [routingLock unlock];
    previousEnd(tile, selector);
}
static bool install(void) {
    Class cls = objc_getClass("DOCKWindowTile");
    Method b = class_getInstanceMethod(cls, sel_registerName("beginMinMax:minimizing:animate:"));
    Method e = class_getInstanceMethod(cls, sel_registerName("endMinMax"));
    Ivar wid = class_getInstanceVariable(cls, "_wid");
    if (!b || !e || !wid || strcmp(method_getTypeEncoding(b), "v32@0:8d16B24B28") ||
        strcmp(method_getTypeEncoding(e), "v16@0:8") || strcmp(ivar_getTypeEncoding(wid), "I") ||
        !connection || !getTags || !setTags || !clearTags || !selectedWindow || !baseStatus ||
        *baseStatus != 1)
        return false;
    widOffset = ivar_getOffset(wid);
    if (widOffset <= 0 || (size_t)widOffset + sizeof(uint32_t) > class_getInstanceSize(cls))
        return false;
    baselines = [NSMutableDictionary new];
    routingLock = [NSLock new];
    previousBegin = (void *)method_setImplementation(b, (IMP)begin);
    previousEnd = (void *)method_setImplementation(e, (IMP)end);
    return true;
}
#ifndef SELF_TEST
__attribute__((constructor)) static void load(void) {
    if (strcmp(getprogname(), "Dock"))
        return;
    // The base module validates this Dock's build and UUID before reporting status 1.
    baseStatus = dlsym(RTLD_DEFAULT, "GenieSpringBoardV5Status");
    selectedWindow = dlsym(RTLD_DEFAULT, "GenieSpringBoardV5Window");
    connection = dlsym(RTLD_DEFAULT, "SLSMainConnectionID");
    getTags = dlsym(RTLD_DEFAULT, "SLSGetWindowTags");
    setTags = dlsym(RTLD_DEFAULT, "SLSSetWindowTags");
    clearTags = dlsym(RTLD_DEFAULT, "SLSClearWindowTags");
    DockboardInputRoutingStatus = install() ? 1 : -1;
}
#endif
