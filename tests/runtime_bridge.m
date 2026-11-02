#define SELF_TEST 1
#define main base_self_test_main
#include "../src/runtime/TransitionBase.m"
#undef main

static unsigned routed;
static _Atomic int enabled;
static int replacement(int connection, uint32_t window, int columns, int rows,
                       const SBMotionVertex *points) {
    assert(connection == 7 && window == 42 && columns == 17 && rows == 17 && points);
    routed++;
    return 0;
}
int main(void) {
    @autoreleasepool {
        GenieSpringBoardStatus = 1;
        setWarp = mockWarp;
        DockboardWarpFunction previous = NULL;
        _Atomic uint64_t *clock = NULL;
        _Atomic bool *direction = NULL;
        assert(!DockboardInstallWarpInterceptorV2(NULL, &previous, &clock, &direction, &enabled));
        assert(DockboardInstallWarpInterceptorV2(replacement, &previous, &clock, &direction,
                                                 &enabled));
        assert(previous == mockWarp);
        atomic_store(&started, 123);
        atomic_store(&restoring, true);
        assert(atomic_load(clock) == 123 && atomic_load(direction));
        SBMotionVertex vertices[289] = {0};
        assert(setWarp(7, 42, 17, 17, vertices) == 0 && routed == 1);
        assert(!DockboardInstallWarpInterceptorV2(replacement, &previous, &clock, &direction,
                                                  &enabled));
        mainConnection = mockConnection;
        assert(install());
        DOCKWindowTile *tile = [DOCKWindowTile new];
        tile->_wid = 42;
        tile->_windowRect = CGRectMake(100, 100, 1000, 700);
        expectHidden = YES;
        for (unsigned restore = 0; restore < 2; restore++) {
            assert(GenieSpringBoardSetWindow(42));
            [tile beginMinMax:500 minimizing:!restore animate:true];
            atomic_store(&enabled, 1);
            unsigned before = routed;
            for (unsigned i = 0; i < 100; i++) {
                tile->_imageRect = (FloatRect){1800, 1000, 1800, 1040};
                [tile updateTransition];
            }
            assert(routed == before + 100 && !atomic_load(&GenieSpringBoardErrors));
            // Disabling composition retains the legacy validator and never sends invalid geometry.
            atomic_store(&enabled, 0);
            [tile updateTransition];
            assert(routed == before + 100 && atomic_load(&GenieSpringBoardErrors) == 1);
            atomic_store(&GenieSpringBoardErrors, 0);
            [tile endMinMax];
        }
        puts("Runtime bridge: interception, shared clock, direction and duplicate-install "
             "rejection passed.");
    }
    return 0;
}
