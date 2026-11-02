#ifndef GENIE_SHADOW_HANDOFF_H
#define GENIE_SHADOW_HANDOFF_H
// Included after the exact-window controls and mainConnection declaration.
static int (*shadowGet)(int, uint32_t, float *, float *, int *, int *, unsigned *);
static int (*shadowSet)(int, uint32_t, float, float, int, int, unsigned);
static NSLock *shadowLock;
static dispatch_queue_t shadowQueue;
@interface DockboardShadowState : NSObject {
  @public
    uint64_t shadowGeneration;
    bool shadowCaptured, shadowFading;
    uint32_t shadowWindow;
    int shadowConnection, shadowX, shadowY;
    unsigned shadowFlags;
    float shadowSigma, shadowDensity;
}
@end
@implementation DockboardShadowState
@end
static NSMutableDictionary<NSNumber *, DockboardShadowState *> *shadowStates;
_Atomic int GenieSpringBoardV5ShadowEnabled, GenieSpringBoardV5ShadowErrors;
_Atomic int GenieSpringBoardV5ShadowWrites, GenieSpringBoardV5ShadowRestores;
_Atomic uint32_t GenieSpringBoardV5ShadowPendingWindow;
#ifdef SELF_TEST
static NSMutableArray *shadowPending;
#endif
static void shadowInit(void) {
    shadowLock = [NSLock new];
    shadowStates = [NSMutableDictionary new];
    shadowQueue = dispatch_queue_create("local.genie.shadow-handoff", DISPATCH_QUEUE_SERIAL);
#ifdef SELF_TEST
    shadowPending = [NSMutableArray new];
#endif
}
static int shadowWrite(DockboardShadowState *state, float density) {
    int error = shadowSet(state->shadowConnection, state->shadowWindow, state->shadowSigma, density,
                          state->shadowX, state->shadowY, state->shadowFlags);
    if (!error)
        atomic_fetch_add(&GenieSpringBoardV5ShadowWrites, 1);
    return error;
}
static bool shadowRestoreLocked(DockboardShadowState *state) {
    if (!state->shadowCaptured)
        return true;
    if (shadowWrite(state, state->shadowDensity)) {
        atomic_fetch_add(&GenieSpringBoardV5ShadowErrors, 1);
        return false;
    }
    state->shadowCaptured = false;
    state->shadowFading = false;
    [shadowStates removeObjectForKey:@(state->shadowWindow)];
    atomic_fetch_sub(&GenieSpringBoardV5ShadowPendingWindow, 1);
    atomic_fetch_add(&GenieSpringBoardV5ShadowRestores, 1);
    return true;
}
static void shadowStopLocked(void) {
    atomic_store(&GenieSpringBoardV5ShadowEnabled, 0);
    for (DockboardShadowState *state in shadowStates.allValues) {
        state->shadowGeneration++;
        state->shadowFading = false;
        shadowRestoreLocked(state);
    }
}
static void shadowCancel(void) {
    [shadowLock lock];
    for (DockboardShadowState *state in shadowStates.allValues) {
        state->shadowGeneration++;
        state->shadowFading = false;
        if (!shadowRestoreLocked(state))
            atomic_store(&GenieSpringBoardV5ShadowEnabled, 0);
    }
    [shadowLock unlock];
}
bool GenieSpringBoardV5SetShadowEnabled(bool value) {
    if (GenieSpringBoardStatus != 1 || !shadowLock || !shadowGet || !shadowSet)
        return false;
    [shadowLock lock];
    bool restored = true;
    for (DockboardShadowState *state in shadowStates.allValues) {
        state->shadowGeneration++;
        state->shadowFading = false;
        if (!shadowRestoreLocked(state))
            restored = false;
    }
    atomic_store(&GenieSpringBoardV5ShadowEnabled, value && restored);
    [shadowLock unlock];
    return restored;
}
static void shadowBegin(uint32_t wid, bool restore, bool animate) {
    [shadowLock lock];
    DockboardShadowState *state = shadowStates[@(wid)];
    if (state) {
        state->shadowGeneration++;
        state->shadowFading = false;
        if (!shadowRestoreLocked(state))
            atomic_store(&GenieSpringBoardV5ShadowEnabled, 0);
    }
    if (!atomic_load(&GenieSpringBoardV5ShadowEnabled) || !restore || !animate || !wid ||
        (atomic_load(&GenieSpringBoardWindow) != UINT32_MAX &&
         wid != atomic_load(&GenieSpringBoardWindow))) {
        [shadowLock unlock];
        return;
    }
    int connection = mainConnection(), x = 0, y = 0;
    unsigned flags = 0;
    float sigma = 0, density = 0;
    if (shadowGet(connection, wid, &sigma, &density, &x, &y, &flags) || !isfinite(sigma) ||
        sigma < 0 || !isfinite(density) || density < 0 || density > 1) {
        atomic_fetch_add(&GenieSpringBoardV5ShadowErrors, 1);
        atomic_store(&GenieSpringBoardV5ShadowEnabled, 0);
        [shadowLock unlock];
        return;
    }
    state = [DockboardShadowState new];
    shadowStates[@(wid)] = state;
    state->shadowConnection = connection;
    state->shadowWindow = wid;
    state->shadowSigma = sigma;
    state->shadowDensity = density;
    state->shadowX = x;
    state->shadowY = y;
    state->shadowFlags = flags;
    state->shadowCaptured = true;
    atomic_fetch_add(&GenieSpringBoardV5ShadowPendingWindow, 1);
    if (shadowWrite(state, 0)) {
        atomic_fetch_add(&GenieSpringBoardV5ShadowErrors, 1);
        shadowStopLocked();
    }
    [shadowLock unlock];
}
static void shadowSchedule(dispatch_block_t block) {
#ifdef SELF_TEST
    [shadowPending addObject:[block copy]];
#else
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC), shadowQueue, block);
#endif
}
static void shadowTick(DockboardShadowState *state, uint64_t generation, uint32_t wid,
                       unsigned step) {
    [shadowLock lock];
    if (generation != state->shadowGeneration || !state->shadowCaptured || !state->shadowFading ||
        !atomic_load(&GenieSpringBoardV5ShadowEnabled) || state->shadowWindow != wid ||
        (atomic_load(&GenieSpringBoardWindow) != UINT32_MAX &&
         wid != atomic_load(&GenieSpringBoardWindow))) {
        [shadowLock unlock];
        return;
    }
    double t = step / 12., smooth = t * t * t * (10 + t * (-15 + 6 * t));
    if (step == 12) {
        if (!shadowRestoreLocked(state))
            shadowStopLocked();
        [shadowLock unlock];
        return;
    }
    if (shadowWrite(state, state->shadowDensity * (float)smooth)) {
        atomic_fetch_add(&GenieSpringBoardV5ShadowErrors, 1);
        shadowStopLocked();
        [shadowLock unlock];
        return;
    }
    [shadowLock unlock];
    shadowSchedule(^{
        shadowTick(state, generation, wid, step + 1);
    });
}
static void shadowEnd(uint32_t wid) {
    [shadowLock lock];
    DockboardShadowState *state = shadowStates[@(wid)];
    bool fade = state && wid &&
                (atomic_load(&GenieSpringBoardWindow) == UINT32_MAX ||
                 wid == atomic_load(&GenieSpringBoardWindow)) &&
                atomic_load(&GenieSpringBoardV5ShadowEnabled) && state->shadowCaptured &&
                state->shadowWindow == wid && !state->shadowFading;
    uint64_t generation = state ? state->shadowGeneration : 0;
    if (fade)
        state->shadowFading = true;
    [shadowLock unlock];
    // shortcut: first tick waits10ms after endMinMax; native caller's warp-clear is not separately
    // hooked.
    if (fade)
        shadowSchedule(^{
            shadowTick(state, generation, wid, 1);
        });
}
#endif
