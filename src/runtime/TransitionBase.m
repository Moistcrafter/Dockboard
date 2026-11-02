#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <sys/sysctl.h>
#include <time.h>
#include "SpringBoardSubdivision.h"
#include "RuntimeBridge.h"

// Separate symbols keep the disabled first prototype independently controllable.
#define GenieSpringBoardWindow GenieSpringBoardV5Window
#define GenieSpringBoardFrames GenieSpringBoardV5Frames
#define GenieSpringBoardErrors GenieSpringBoardV5Errors
#define GenieSpringBoardEnds GenieSpringBoardV5Ends
#define GenieSpringBoardStatus GenieSpringBoardV5Status
#define GenieSpringBoardSetWindow GenieSpringBoardV5SetWindow

typedef struct {
    uint64_t time, tile;
    uint32_t window, kind;
    double elapsed, duration;
    float progress;
    unsigned char minimizing, maximizing, animate;
} SBMotionEvent;
SBMotionEvent GenieSpringBoardV5Events[2048];
_Atomic unsigned GenieSpringBoardV5EventCount;

static void (*previousBegin)(id, SEL, double, bool, bool);
static void (*previousUpdate)(id, SEL), (*previousEnd)(id, SEL);
static int (*setWarp)(int, uint32_t, int, int, const SBMotionVertex *);
static int (*mainConnection)(void);
static ptrdiff_t windowOffset, imageOffset, progressOffset, widOffset;
static ptrdiff_t minimizingOffset, maximizingOffset, animateOffset;
static Ivar maskIvar;
static NSLock *maskLock;
@interface DockboardWindowState : NSObject {
  @public
    CALayer *savedMask;
    float savedOpacity;
    uint32_t savedMaskWindow;
    uint64_t start;
    bool reverse;
    SBMotionRect window;
}
@end
@implementation DockboardWindowState
@end
static NSMapTable<id, DockboardWindowState *> *states;
static DockboardWindowState *stateForTile(id tile) {
    DockboardWindowState *state = [states objectForKey:tile];
    if (!state) {
        state = [DockboardWindowState new];
        [states setObject:state forKey:tile];
    }
    return state;
}
static _Atomic uint64_t started;
static _Atomic bool restoring;
static _Atomic int *compositionEnabled;
_Atomic uint32_t GenieSpringBoardWindow;
_Atomic int GenieSpringBoardFrames, GenieSpringBoardErrors, GenieSpringBoardEnds;
int GenieSpringBoardStatus;
int DockboardConcurrentRuntimeVersion = 1;

bool DockboardInstallWarpInterceptorV2(DockboardWarpFunction replacement,
                                       DockboardWarpFunction *previous, _Atomic uint64_t **clock,
                                       _Atomic bool **direction, _Atomic int *enabled) {
    static bool installed;
    if (installed || GenieSpringBoardStatus != 1 || !setWarp || !replacement || !previous ||
        !clock || !direction || !enabled)
        return false;
    *previous = setWarp;
    *clock = &started;
    *direction = &restoring;
    compositionEnabled = enabled;
    setWarp = replacement;
    installed = true;
    return true;
}

#include "ShadowHandoff.h"

static uint64_t nanoseconds(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC_RAW, &t))
        return 0;
    return (uint64_t)t.tv_sec * 1000000000ULL + (uint64_t)t.tv_nsec;
}
static uint32_t windowID(id tile) {
    uint32_t wid;
    const char *bytes = (__bridge const void *)tile;
    memcpy(&wid, bytes + widOffset, sizeof(wid));
    return wid;
}
static void record(id tile, unsigned kind, double elapsed, double duration) {
    unsigned index = atomic_fetch_add(&GenieSpringBoardV5EventCount, 1);
    if (index >= 2048)
        return;
    const char *bytes = (__bridge const void *)tile;
    float progress;
    memcpy(&progress, bytes + progressOffset, sizeof(progress));
    GenieSpringBoardV5Events[index] = (SBMotionEvent){nanoseconds(),
                                                      (uintptr_t)(__bridge void *)tile,
                                                      windowID(tile),
                                                      kind,
                                                      elapsed,
                                                      duration,
                                                      progress,
                                                      bytes[minimizingOffset],
                                                      bytes[maximizingOffset],
                                                      bytes[animateOffset]};
}
static void opacity(CALayer *mask, float value) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    mask.opacity = value;
    [CATransaction commit];
}
static void restoreMaskLocked(DockboardWindowState *state) {
    if (!state->savedMask)
        return;
    opacity(state->savedMask, state->savedOpacity);
    state->savedMask = nil;
    state->savedMaskWindow = 0;
}
static void hideMask(id tile) {
    uint32_t wid = windowID(tile);
    if (!wid || (atomic_load(&GenieSpringBoardWindow) != UINT32_MAX &&
                 wid != atomic_load(&GenieSpringBoardWindow)))
        return;
    CALayer *mask = object_getIvar(tile, maskIvar);
    [maskLock lock];
    DockboardWindowState *state = stateForTile(tile);
    if ((atomic_load(&GenieSpringBoardWindow) != UINT32_MAX &&
         wid != atomic_load(&GenieSpringBoardWindow))) {
        [maskLock unlock];
        return;
    }
    if (state->savedMask != mask || state->savedMaskWindow != wid) {
        restoreMaskLocked(state);
        if (mask) {
            state->savedMask = mask;
            state->savedOpacity = mask.opacity;
            state->savedMaskWindow = wid;
        }
    }
    if (state->savedMask)
        opacity(state->savedMask, 0);
    [maskLock unlock];
}
// Zero disables. Enabling waits for the next native begin; never adopt a transition midway.
bool GenieSpringBoardSetWindow(uint32_t wid) {
    if (GenieSpringBoardStatus != 1)
        return false;
    atomic_store(&GenieSpringBoardWindow, 0);
    shadowCancel();
    [maskLock lock];
    for (DockboardWindowState *state in states.objectEnumerator) {
        restoreMaskLocked(state);
        state->start = 0;
    }
    [maskLock unlock];
    atomic_store(&started, 0);
    atomic_store(&GenieSpringBoardWindow, wid);
    return true;
}
static void begin(id tile, SEL selector, double duration, bool minimizing, bool animate) {
    uint32_t wid = windowID(tile);
    if (wid && (atomic_load(&GenieSpringBoardWindow) == UINT32_MAX ||
                wid == atomic_load(&GenieSpringBoardWindow))) {
        shadowBegin(wid, !minimizing, animate);
        [maskLock lock];
        DockboardWindowState *state = stateForTile(tile);
        restoreMaskLocked(state);
        record(tile, 1, 0, duration);
        atomic_store(&restoring, !minimizing);
        state->start = animate ? nanoseconds() : 0;
        state->reverse = !minimizing;
        memcpy(&state->window, (const char *)(__bridge void *)tile + windowOffset,
               sizeof(state->window));
        atomic_store(&started, state->start);
        [maskLock unlock];
    }
    previousBegin(tile, selector, duration, minimizing, animate);
    if (animate)
        hideMask(tile);
}
static void update(id tile, SEL selector) {
    [maskLock lock];
    DockboardWindowState *active = [states objectForKey:tile];
    if (active && active->start) {
        // Native bounds notifications can report the warped presentation during this transition.
        memcpy((char *)(__bridge void *)tile + windowOffset, &active->window,
               sizeof(active->window));
    }
    [maskLock unlock];
    const char *before = (__bridge const void *)tile;
    if (before[animateOffset] && (before[minimizingOffset] || before[maximizingOffset]))
        hideMask(tile);
    previousUpdate(tile, selector);
    uint32_t wid = windowID(tile);
    if (!wid || (atomic_load(&GenieSpringBoardWindow) != UINT32_MAX &&
                 wid != atomic_load(&GenieSpringBoardWindow)))
        return;
    const char *bytes = (__bridge const void *)tile;
    [maskLock lock];
    DockboardWindowState *state = stateForTile(tile);
    uint64_t start = state->start, now = nanoseconds();
    bool reverse = state->reverse;
    [maskLock unlock];
    if (!start || now < start || !bytes[animateOffset] ||
        !(bytes[minimizingOffset] || bytes[maximizingOffset]))
        return;
    float progress, image[4];
    SBMotionRect window;
    memcpy(&progress, bytes + progressOffset, sizeof(progress));
    memcpy(&window, bytes + windowOffset, sizeof(window));
    memcpy(image, bytes + imageOffset, sizeof(image));
    SBMotionRect destination = {image[0], image[1], image[2] - image[0], image[3] - image[1]};
    double elapsed = (now - start) / 1e9;
    record(tile, 2, elapsed, 0);
    // shortcut: native duration is retained; a shorter transition snaps to its exact endpoint.
    if ((!reverse && progress >= 1) || (reverse && progress <= 0))
        elapsed = 2;
    SBMotionVertex control[9], grid[289];
    // Composition supplies destination geometry; native partial thumbnails may have zero extent.
    bool composed = compositionEnabled && atomic_load(compositionEnabled);
    if (!SBMotionGrid(window, composed ? window : destination, composed ? 0 : elapsed,
                      composed ? false : reverse, control) ||
        !SBMotionSubdivide(control, grid)) {
        atomic_fetch_add(&GenieSpringBoardErrors, 1);
        return;
    }
    if (setWarp(mainConnection(), wid, 17, 17, grid))
        atomic_fetch_add(&GenieSpringBoardErrors, 1);
    else
        atomic_fetch_add(&GenieSpringBoardFrames, 1);
}
static void end(id tile, SEL selector) {
    uint32_t wid = windowID(tile);
    if (wid && (atomic_load(&GenieSpringBoardWindow) == UINT32_MAX ||
                wid == atomic_load(&GenieSpringBoardWindow))) {
        [maskLock lock];
        DockboardWindowState *state = stateForTile(tile);
        restoreMaskLocked(state);
        state->start = 0;
        [maskLock unlock];
        record(tile, 3, 0, 0);
        atomic_store(&started, 0);
        atomic_fetch_add(&GenieSpringBoardEnds, 1);
    }
    previousEnd(tile, selector);
    shadowEnd(wid);
}
static BOOL offset(Class cls, const char *name, const char *type, ptrdiff_t *out) {
    Ivar ivar = class_getInstanceVariable(cls, name);
    if (!ivar || strcmp(ivar_getTypeEncoding(ivar), type))
        return NO;
    *out = ivar_getOffset(ivar);
    return YES;
}
static BOOL install(void) {
    Class cls = objc_getClass("DOCKWindowTile");
    Method b = class_getInstanceMethod(cls, sel_registerName("beginMinMax:minimizing:animate:"));
    Method u = class_getInstanceMethod(cls, sel_registerName("updateTransition"));
    Method e = class_getInstanceMethod(cls, sel_registerName("endMinMax"));
    if (!b || !u || !e || !setWarp || !mainConnection ||
        strcmp(method_getTypeEncoding(b), "v32@0:8d16B24B28") ||
        strcmp(method_getTypeEncoding(u), "v16@0:8") ||
        strcmp(method_getTypeEncoding(e), "v16@0:8") ||
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
    maskIvar = class_getInstanceVariable(cls, "_mask");
    if (!maskIvar || strcmp(ivar_getTypeEncoding(maskIvar), "@\"CALayer\""))
        return NO;
    maskLock = [NSLock new];
    states = [NSMapTable weakToStrongObjectsMapTable];
    shadowInit();
    previousBegin = (void *)method_setImplementation(b, (IMP)begin);
    previousEnd = (void *)method_setImplementation(e, (IMP)end);
    previousUpdate = (void *)method_setImplementation(u, (IMP)update);
    return YES;
}
#ifndef SELF_TEST
__attribute__((constructor)) static void load(void) {
    if (strcmp(getprogname(), "Dock"))
        return;
    char build[64];
    size_t size = sizeof(build);
    // shortcut: only the traced 26B123 native Genie tile path; revalidate before another build.
    if (sysctlbyname("kern.osversion", build, &size, NULL, 0) || strcmp(build, "26B123")) {
        GenieSpringBoardStatus = -1;
        return;
    }
    setWarp = dlsym(RTLD_DEFAULT, "CGSSetWindowWarp");
    mainConnection = dlsym(RTLD_DEFAULT, "SLSMainConnectionID");
    shadowGet = dlsym(RTLD_DEFAULT, "SLSGetWindowShadowAndRimParameters");
    shadowSet = dlsym(RTLD_DEFAULT, "SLSSetWindowShadowAndRimParameters");
    GenieSpringBoardStatus = install() ? 1 : -2;
}
#endif
#ifdef SELF_TEST
#import <CoreGraphics/CoreGraphics.h>
#include <assert.h>
typedef struct FloatRect {
    float left, top, right, bottom;
} FloatRect;
static int begins, updates, ends, submissions;
static BOOL expectHidden;
@interface DOCKWindowTile : NSObject {
  @public
    CGRect _windowRect;
    FloatRect _imageRect;
    float _transformNow;
    uint32_t _wid;
    bool _minimizing, _maximizing, _animateWindow;
    CALayer *_mask;
}
- (void)beginMinMax:(double)duration minimizing:(bool)minimizing animate:(bool)animate;
- (void)updateTransition;
- (void)endMinMax;
@end
@implementation DOCKWindowTile
- (void)beginMinMax:(double)duration minimizing:(bool)minimizing animate:(bool)animate {
    assert(duration == 500);
    begins++;
    _mask = [CALayer layer];
    _mask.opacity = .37f;
    _minimizing = minimizing;
    _maximizing = !minimizing;
    _animateWindow = animate;
}
- (void)updateTransition {
    updates++;
    assert(_mask.opacity == (expectHidden ? 0 : .37f));
}
- (void)endMinMax {
    ends++;
    _minimizing = false;
    _maximizing = false;
}
@end
static int mockConnection(void) { return 7; }
static int mockWarp(int connection, uint32_t wid, int columns, int rows,
                    const SBMotionVertex *grid) {
    assert(connection == 7 && (wid == 42 || wid == 43) && columns == 17 && rows == 17 && grid);
    submissions++;
    return 0;
}
static float mockShadowDensity = .7f, secondShadowDensity = .4f;
static int mockShadowCalls, mockShadowFailures;
static int mockGetShadow(int connection, uint32_t wid, float *sigma, float *density, int *x, int *y,
                         unsigned *flags) {
    assert(connection == 7 && (wid == 42 || wid == 43));
    *sigma = 32.941177f;
    *density = wid == 42 ? mockShadowDensity : secondShadowDensity;
    *x = 0;
    *y = 18;
    *flags = 7;
    return 0;
}
static int mockSetShadow(int connection, uint32_t wid, float sigma, float density, int x, int y,
                         unsigned flags) {
    assert(connection == 7 && (wid == 42 || wid == 43) && sigma == 32.941177f && x == 0 &&
           y == 18 && flags == 7);
    mockShadowCalls++;
    if (mockShadowFailures) {
        mockShadowFailures--;
        return 1;
    }
    assert(isfinite(density) && density >= 0 && density <= .7f);
    if (wid == 42)
        mockShadowDensity = density;
    else
        secondShadowDensity = density;
    return 0;
}
static void flushShadow(void) {
    while (shadowPending.count) {
        dispatch_block_t block = shadowPending.firstObject;
        [shadowPending removeObjectAtIndex:0];
        block();
    }
}
int main(void) {
    @autoreleasepool {
        shadowGet = mockGetShadow;
        shadowSet = mockSetShadow;
        setWarp = mockWarp;
        mainConnection = mockConnection;
        assert(install());
        GenieSpringBoardStatus = 1;
        DOCKWindowTile *t = [DOCKWindowTile new], *foreign = [DOCKWindowTile new];
        DockboardWindowState *state = stateForTile(t);
        t->_windowRect = CGRectMake(150, 788, 660, 452);
        t->_imageRect = (FloatRect){14, 1200, 56, 1232};
        t->_wid = 42;
        foreign->_wid = 43;
        [t beginMinMax:500 minimizing:true animate:true];
        [t updateTransition];
        assert(t->_mask.opacity == .37f && !state->savedMask && submissions == 0);
        assert(GenieSpringBoardSetWindow(42));
        [t beginMinMax:500 minimizing:true animate:true];
        CALayer *first = t->_mask;
        assert(first.opacity == 0 && state->savedMask == first && state->savedOpacity == .37f);
        expectHidden = YES;
        t->_transformNow = 1;
        CGRect originalWindow = t->_windowRect;
        t->_windowRect = CGRectMake(100, 1100, 52, 60);
        [t updateTransition];
        assert(CGRectEqualToRect(t->_windowRect, originalWindow));
        assert(first.opacity == 0 && submissions == 1);
        expectHidden = NO;
        [foreign beginMinMax:500 minimizing:true animate:true];
        [foreign updateTransition];
        assert(foreign->_mask.opacity == .37f && first.opacity == 0);
        [t endMinMax];
        assert(first.opacity == .37f && !state->savedMask && ends == 1);
        [t beginMinMax:500 minimizing:false animate:true];
        CALayer *second = t->_mask;
        assert(second.opacity == 0);
        assert(GenieSpringBoardSetWindow(0));
        assert(second.opacity == .37f && !state->savedMask);
        [t updateTransition];
        assert(second.opacity == .37f && submissions == 1);
        assert(GenieSpringBoardSetWindow(42));
        [t beginMinMax:500 minimizing:true animate:true];
        CALayer *third = t->_mask;
        [t beginMinMax:500 minimizing:true animate:true];
        assert(third.opacity == .37f && t->_mask != third && t->_mask.opacity == 0);
        CALayer *fourth = t->_mask, *replacement = [CALayer layer];
        replacement.opacity = .37f;
        t->_mask = replacement;
        expectHidden = YES;
        [t updateTransition];
        assert(fourth.opacity == .37f && replacement.opacity == 0 &&
               state->savedMask == replacement);
        assert(GenieSpringBoardSetWindow(0));
        assert(replacement.opacity == .37f && !state->savedMask);
        assert(atomic_load(&GenieSpringBoardErrors) == 0);
        // Shadow defaults off and never touched the normal mask-only checks.
        assert(mockShadowCalls == 0 && !atomic_load(&GenieSpringBoardV5ShadowEnabled));
        assert(GenieSpringBoardSetWindow(42) && GenieSpringBoardV5SetShadowEnabled(true));
        shadowBegin(42, true, true);
        assert(mockShadowDensity == 0 && (shadowStates[@42] != nil));
        shadowEnd(42);
        assert(shadowPending.count == 1);
        float last = 0;
        while (shadowPending.count) {
            dispatch_block_t block = shadowPending.firstObject;
            [shadowPending removeObjectAtIndex:0];
            block();
            assert(mockShadowDensity >= last);
            last = mockShadowDensity;
        }
        assert(mockShadowDensity == .7f && !(shadowStates[@42] != nil) &&
               !atomic_load(&GenieSpringBoardV5ShadowPendingWindow));
        assert(atomic_load(&GenieSpringBoardV5ShadowErrors) == 0);
        shadowBegin(42, true, true);
        shadowEnd(42);
        assert(GenieSpringBoardV5SetShadowEnabled(false));
        int afterCancel = mockShadowCalls;
        flushShadow();
        assert(mockShadowDensity == .7f && mockShadowCalls == afterCancel &&
               !(shadowStates[@42] != nil));
        assert(GenieSpringBoardV5SetShadowEnabled(true));
        shadowBegin(42, true, true);
        shadowEnd(42);
        shadowBegin(42, false, true); // New minimize cancels prior restore fade.
        afterCancel = mockShadowCalls;
        flushShadow();
        assert(mockShadowDensity == .7f && mockShadowCalls == afterCancel);
        shadowBegin(42, true, true);
        shadowEnd(42);
        assert(GenieSpringBoardSetWindow(43));
        afterCancel = mockShadowCalls;
        flushShadow();
        assert(mockShadowDensity == .7f && mockShadowCalls == afterCancel);
        shadowBegin(42, true, true);
        assert(mockShadowCalls == afterCancel); // Foreign window.
        assert(GenieSpringBoardSetWindow(42));
        mockShadowFailures = 1;
        shadowBegin(42, true, true);
        assert(mockShadowDensity == .7f && !(shadowStates[@42] != nil) &&
               !atomic_load(&GenieSpringBoardV5ShadowEnabled));
        assert(atomic_load(&GenieSpringBoardV5ShadowErrors) == 1);
        assert(GenieSpringBoardSetWindow(0));
        assert(GenieSpringBoardSetWindow(UINT32_MAX));
        assert(GenieSpringBoardV5SetShadowEnabled(true));
        foreign->_windowRect = t->_windowRect;
        foreign->_imageRect = t->_imageRect;
        [t beginMinMax:500 minimizing:false animate:true];
        [foreign beginMinMax:500 minimizing:false animate:true];
        DockboardWindowState *otherState = stateForTile(foreign);
        assert(state->start && otherState->start && t->_mask.opacity == 0 &&
               foreign->_mask.opacity == 0);
        assert(shadowStates.count == 2 && mockShadowDensity == 0 && secondShadowDensity == 0);
        expectHidden = YES;
        [t updateTransition];
        [foreign updateTransition];
        [t endMinMax];
        flushShadow();
        assert(!state->start && otherState->start && foreign->_mask.opacity == 0);
        assert(mockShadowDensity == .7f && secondShadowDensity == 0 && shadowStates.count == 1);
        [foreign updateTransition];
        [foreign endMinMax];
        flushShadow();
        assert(secondShadowDensity == .4f && !shadowStates.count);
        assert(foreign->_mask.opacity == .37f && t->_mask.opacity == .37f);
        assert(GenieSpringBoardSetWindow(0));
        puts("V5 shadow self-check passed: monotone fade/exact baseline; stale work canceled on "
             "toggle/new begin/window change; API failure restores baseline and stops.");
        puts("V5 mask self-check passed: opacity hidden during native update; saved opacity "
             "restored on end/disable/new begin/replacement; foreign window untouched.");
    }
    return 0;
}
#endif
