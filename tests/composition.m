#define SELF_TEST 1
#include "../src/runtime/Composition.m"
#include <assert.h>

struct FloatRect {
    float left, top, right, bottom;
};
static SBMotionRect mockTarget = {10, 480, 42, 32};
static IPadWindowDockEdge mockEdge = IPadWindowDockLeft;
static bool targetValid = true, targetInitValid = true, throwFromUpdate, durationSetterValid = true;
static unsigned durationSetterCalls;
static bool mockSetDurations(float closeDuration, float openDuration) {
    assert(closeDuration == 1200 && openDuration == 850);
    durationSetterCalls++;
    return durationSetterValid;
}
static unsigned calls, beginCalls, updateCalls;
static int nativeResult;
static uint32_t passedWindow;
static int passedConnection, passedColumns, passedRows;
static const SBMotionVertex *passedPointer;
static SBMotionVertex captured[289], source[289];
static void *tileSeen;
static double passedDuration;
static bool passedMinimizing, passedAnimate, beginDuringEnd;

@interface DOCKWindowTile : NSObject {
  @public
    CGRect _windowRect;
    struct FloatRect _imageRect;
    float _transformNow;
    uint32_t _wid;
    bool _minimizing, _maximizing, _animateWindow;
}
- (void)updateTransition;
- (void)beginMinMax:(double)duration minimizing:(bool)minimizing animate:(bool)animate;
@end
@implementation DOCKWindowTile
- (void)endMinMax {
    if (beginDuringEnd)
        [self beginMinMax:1200 minimizing:true animate:true];
}
- (void)updateTransition {
    updateCalls++;
    tileSeen = activeTile;
    if (throwFromUpdate)
        @throw [NSException exceptionWithName:@"MockException" reason:@"cleanup test" userInfo:nil];
    submit(7, _wid, 17, 17, source, expectedCaller);
}
- (void)beginMinMax:(double)duration minimizing:(bool)minimizing animate:(bool)animate {
    beginCalls++;
    passedDuration = duration;
    passedMinimizing = minimizing;
    passedAnimate = animate;
}
@end
static bool NativeDockTargetInit(Class cls) {
    return targetInitValid && cls == [DOCKWindowTile class];
}
static bool NativeDockTargetRead(id tile, bool restoring, SBMotionRect *out,
                                 IPadWindowDockEdge *edge) {
    assert([tile isKindOfClass:[DOCKWindowTile class]]);
    assert(restoring == !clocks[@(((DOCKWindowTile *)tile)->_wid)]->closing);
    if (!targetValid)
        return false;
    *out = mockTarget;
    *edge = mockEdge;
    return true;
}
static int mockWarp(int connection, uint32_t wid, int columns, int rows,
                    const SBMotionVertex *points) {
    calls++;
    passedConnection = connection;
    passedWindow = wid;
    passedColumns = columns;
    passedRows = rows;
    passedPointer = points;
    if (points && columns == 17 && rows == 17)
        memcpy(captured, points, sizeof(captured));
    return nativeResult;
}
static _Atomic uint64_t started;
static _Atomic bool restoring;
static _Atomic uint32_t selected;
static _Atomic int durationIsEnabled;
static int upstreamStatus = 1;
static void resetClock(uint32_t wid, double elapsed) {
    DockboardMotionClock *clock = [DockboardMotionClock new];
    clock->start = nanoseconds() - (uint64_t)(elapsed * 1e9);
    clock->multiplier = 1;
    clock->closing = true;
    clocks[@(wid)] = clock;
    atomic_store(&selected, wid);
}
static void expectForward(DOCKWindowTile *tile, uintptr_t caller, uint32_t wid, int columns,
                          int rows, const SBMotionVertex *points) {
    activeTile = (__bridge void *)tile;
    unsigned before = calls;
    int result = submit(19, wid, columns, rows, points, caller);
    assert(result == nativeResult && calls == before + 1 && passedConnection == 19 &&
           passedWindow == wid);
    assert(passedColumns == columns && passedRows == rows && passedPointer == points);
}
int main(void) {
    @autoreleasepool {
        double uninitializedElapsed = 123;
        assert(!GenieCompositionV8GetElapsed(42, &uninitializedElapsed));
        assert(uninitializedElapsed == 123);
        durationEnabled = &durationIsEnabled;
        atomic_store(durationEnabled, 1);
        v5Started = &started;
        v5Restoring = &restoring;
        selectedWindow = &selected;
        v5Status = &upstreamStatus;
        setDurations = mockSetDurations;
        originalWarp = mockWarp;
        previousWarp = mockWarp;
        expectedCaller = 0x12345678;
        targetInitValid = false;
        assert(!install());
        targetInitValid = true;
        assert(install());
        GenieCompositionV8Status = 1;
        assert(GenieCompositionV8SetEnabled(true));
        assert(durationSetterCalls == 1);
        DOCKWindowTile *tile = [DOCKWindowTile new];
        tile->_windowRect = CGRectMake(400, 180, 660, 452);
        tile->_wid = 42;
        tile->_transformNow = 1;
        tile->_animateWindow = true;
        tile->_minimizing = true;
        for (int i = 0; i < 289; i++)
            source[i] = (SBMotionVertex){i * .317f, -i * .119f, 999 + i, 888 - i};
        resetClock(42, .25);
        activeTile = (__bridge void *)tile;
        unsigned before = calls;
        assert(submit(7, 42, 17, 17, source, expectedCaller) == 0);
        assert(calls == before + 1 && passedPointer != source && passedWindow == 42 &&
               passedConnection == 7);
        assert(atomic_load(&GenieCompositionV8Frames) == 1 &&
               atomic_load(&GenieCompositionV8Errors) == 0);
        for (int i = 0; i < 289; i++) {
            assert(!memcmp(&captured[i].sourceX, &source[i].sourceX, sizeof(float)));
            assert(!memcmp(&captured[i].sourceY, &source[i].sourceY, sizeof(float)));
        }
        // Native progress1 is not permission to force the iPad physical endpoint at250ms.
        assert(hypot(captured[0].destinationX - mockTarget.x,
                     captured[0].destinationY - mockTarget.y) > 10);
        IPadWindowPhysicsState state;
        SBMotionRect cw, ct;
        assert(IPadWindowCanonicalRect((SBMotionRect){400, 180, 660, 452}, mockEdge, &cw));
        assert(IPadWindowCanonicalRect(mockTarget, mockEdge, &ct));
        assert(IPadWindowPhysicsV2AtTime(cw, ct, .25, false, &state));
        assert(state.meshBoundsPhase != 1);
        resetClock(42, .5);
        atomic_store(&restoring, true);
        clocks[@42]->closing = false;
        tile->_minimizing = false;
        tile->_maximizing = true;
        before = calls;
        assert(!submit(7, 42, 17, 17, source, expectedCaller));
        assert(calls == before + 1);
        assert(IPadWindowPhysicsV2AtTime(cw, ct, .5, true, &state));
        assert(state.parentScalePhase < 0); // raw spring overshoot
        assert(hypot(captured[0].destinationX - 400, captured[0].destinationY - 180) > .01);
        atomic_store(&restoring, false);
        clocks[@42]->closing = true;
        tile->_minimizing = true;
        tile->_maximizing = false;

        [tile beginMinMax:2400 minimizing:true animate:true];
        assert(beginCalls == 1 && passedDuration == 2400 && passedMinimizing && passedAnimate);
        assert(clocks[@42]->multiplier == 2);
        clocks[@42]->start = nanoseconds() - 400000000ULL;
        double elapsed = 0;
        assert(GenieCompositionV8GetElapsed(42, &elapsed));
        assert(elapsed >= .2 && elapsed < .3);
        [tile beginMinMax:1200 minimizing:false animate:false];
        assert(beginCalls == 2 && clocks[@42]->multiplier == 2);
        [tile beginMinMax:850 minimizing:false animate:true];
        assert(clocks[@42]->multiplier == 1);
        uint64_t retainedStart = clocks[@42]->start;
        [tile beginMinMax:850 minimizing:false animate:true];
        assert(clocks[@42]->start == retainedStart && clocks[@42]->multiplier == 1);
        assert(atomic_load(&GenieCompositionV8RepeatedBegins) == 1);
        [tile endMinMax];
        assert(!clocks[@42]);
        [tile beginMinMax:1700 minimizing:false animate:true];
        assert(clocks[@42]->multiplier == 2);
        clocks[@42]->start = 0;
        assert(!GenieCompositionV8GetElapsed(43, &elapsed));
        assert(!GenieCompositionV8GetElapsed(42, NULL));
        atomic_store(&selected, 43);
        assert(!GenieCompositionV8GetElapsed(42, &elapsed));
        atomic_store(&selected, 42);
        clocks[@42]->start = nanoseconds() - 400000000ULL;
        uint64_t savedStart = clocks[@42]->start;
        clocks[@42]->start = 0;
        assert(!GenieCompositionV8GetElapsed(42, &elapsed));
        clocks[@42]->start = nanoseconds() + 1000000000ULL;
        assert(!GenieCompositionV8GetElapsed(42, &elapsed));
        clocks[@42]->start = savedStart;
        clocks[@42]->multiplier = 0;
        assert(!GenieCompositionV8GetElapsed(42, &elapsed));
        clocks[@42]->multiplier = NAN;
        assert(!GenieCompositionV8GetElapsed(42, &elapsed));
        clocks[@42]->multiplier = 2;
        clocks[@42]->start = 0;
        assert(!GenieCompositionV8GetElapsed(42, &elapsed));
        int errors = atomic_load(&GenieCompositionV8Errors);
        expectForward(tile, expectedCaller, 42, 17, 17, source);
        assert(atomic_load(&GenieCompositionV8Errors) == errors + 1);
        resetClock(42, .2);

        // Filters forward the exact original invocation once and do not count geometry errors.
        errors = atomic_load(&GenieCompositionV8Errors);
        expectForward(nil, expectedCaller, 42, 17, 17, source);
        expectForward(tile, expectedCaller + 1, 42, 17, 17, source);
        expectForward(tile, expectedCaller, 43, 17, 17, source);
        expectForward(tile, expectedCaller, 42, 9, 17, source);
        expectForward(tile, expectedCaller, 42, 17, 9, source);
        expectForward(tile, expectedCaller, 42, 17, 17, NULL);
        tile->_wid = 43;
        expectForward(tile, expectedCaller, 42, 17, 17, source);
        tile->_wid = 42;
        tile->_animateWindow = false;
        expectForward(tile, expectedCaller, 42, 17, 17, source);
        tile->_animateWindow = true;
        tile->_minimizing = false;
        expectForward(tile, expectedCaller, 42, 17, 17, source);
        tile->_minimizing = true;
        upstreamStatus = 0;
        expectForward(tile, expectedCaller, 42, 17, 17, source);
        upstreamStatus = 1;
        assert(atomic_load(&GenieCompositionV8Errors) == errors);

        targetValid = false;
        expectForward(tile, expectedCaller, 42, 17, 17, source);
        targetValid = true;
        assert(atomic_load(&GenieCompositionV8Errors) == ++errors);
        tile->_transformNow = NAN;
        expectForward(tile, expectedCaller, 42, 17, 17, source);
        tile->_transformNow = 1;
        assert(atomic_load(&GenieCompositionV8Errors) == ++errors);
        tile->_windowRect.size.width = 0;
        expectForward(tile, expectedCaller, 42, 17, 17, source);
        tile->_windowRect.size.width = 660;
        assert(atomic_load(&GenieCompositionV8Errors) == ++errors);
        nativeResult = 73;
        activeTile = (__bridge void *)tile;
        before = calls;
        assert(submit(7, 42, 17, 17, source, expectedCaller) == 73 && calls == before + 1);
        assert(atomic_load(&GenieCompositionV8Errors) == ++errors);
        nativeResult = 0;

        void *outer = (void *)0x1234;
        activeTile = outer;
        before = calls;
        [tile updateTransition];
        assert(updateCalls == 1 && tileSeen == (__bridge void *)tile && activeTile == outer &&
               calls == before + 1);
        throwFromUpdate = true;
        bool caught = false;
        @try {
            [tile updateTransition];
        } @catch (NSException *exception) {
            caught = [exception.name isEqualToString:@"MockException"];
        }
        assert(caught && activeTile == outer);
        throwFromUpdate = false;
        unsigned setterCallsBeforeDisable = durationSetterCalls;
        assert(GenieCompositionV8SetEnabled(false));
        assert(durationSetterCalls == setterCallsBeforeDisable);
        expectForward(tile, expectedCaller, 42, 17, 17, source);
        atomic_store(durationEnabled, 0);
        assert(!GenieCompositionV8SetEnabled(true));
        atomic_store(durationEnabled, 1);
        durationSetterValid = false;
        assert(!GenieCompositionV8SetEnabled(true));
        assert(!atomic_load(&GenieCompositionV8Enabled));
        durationSetterValid = true;
        assert(GenieCompositionV8SetEnabled(true));
        upstreamStatus = 0;
        assert(!GenieCompositionV8SetEnabled(true));
        upstreamStatus = 1;
        DOCKWindowTile *second = [DOCKWindowTile new];
        second->_wid = 43;
        atomic_store(&selected, UINT32_MAX);
        [tile endMinMax];
        [tile beginMinMax:1200 minimizing:true animate:true];
        clocks[@42]->start -= 300000000;
        uint64_t firstStart = clocks[@42]->start;
        [second beginMinMax:1700 minimizing:false animate:true];
        assert(clocks[@42]->start == firstStart && clocks[@43]->multiplier == 2);
        double firstElapsed, secondElapsed;
        assert(GenieCompositionV8GetElapsed(42, &firstElapsed));
        assert(GenieCompositionV8GetElapsed(43, &secondElapsed));
        assert(firstElapsed > .3 && secondElapsed < .1);
        [tile beginMinMax:1200 minimizing:true animate:true];
        assert(clocks[@42]->start == firstStart);
        DockboardMotionClock *secondClock = clocks[@43];
        [tile beginMinMax:850 minimizing:false animate:true];
        DockboardMotionClock *openingClock = clocks[@42];
        openingClock->start -= 150000000;
        [tile beginMinMax:1200 minimizing:true animate:true];
        assert(clocks[@42] != openingClock && clocks[@42]->closing);
        assert(clocks[@43] == secondClock);
        assert(GenieCompositionV8GetElapsed(42, &firstElapsed) && firstElapsed < .1);
        [tile endMinMax];
        assert(!clocks[@42] && GenieCompositionV8GetElapsed(43, &secondElapsed));
        [second endMinMax];
        assert(!clocks.count);
        [tile beginMinMax:1200 minimizing:true animate:true];
        DockboardMotionClock *endingClock = clocks[@42];
        beginDuringEnd = true;
        [tile endMinMax];
        beginDuringEnd = false;
        assert(clocks[@42] && clocks[@42] != endingClock && clocks[@42]->active);
        assert(GenieCompositionV8GetElapsed(42, &firstElapsed));
        [tile endMinMax];
        NSLog(@"CompositionV8 offline tests passed: %u native calls; exact forwarding/UVs, TLS "
              @"cleanup, duration clocks, raw springs, filters/errors",
              calls);
    }
    return 0;
}
