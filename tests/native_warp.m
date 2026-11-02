#define SELF_TEST 1
#include "../src/runtime/NativeWarp.m"
#include <assert.h>
@interface DockBar : NSObject
- (NSInteger)minimizeEffect;
@end
@implementation DockBar
- (NSInteger)minimizeEffect {
    return 2;
}
@end
@interface DOCKWindowTile : NSObject {
  @public
    uint32_t _wid;
    bool _animateWindow, _minimizing, _maximizing;
    float _transformNow;
    struct Transformer {
        float tileBuild;
        NSInteger direction;
        bool tinyWindow;
    } _transformer;
}
- (void)updateTransition;
@end
static DockBar *bar;
static unsigned nativeWarps, forwards;
static bool throwInside, nestInside;
static DOCKWindowTile *foreign;
@implementation DOCKWindowTile
- (void)updateTransition {
    forwards++;
    syntheticCaller = expectedCaller;
    if ([bar minimizeEffect] || _transformer.tinyWindow)
        nativeWarps++;
    syntheticCaller = 0;
    assert([bar minimizeEffect] == 2);
    if (nestInside && self != foreign) {
        [foreign updateTransition];
        syntheticCaller = expectedCaller;
        assert([bar minimizeEffect] == 0);
    }
    if (throwInside)
        @throw [NSException exceptionWithName:@"test" reason:nil userInfo:nil];
}
@end
int main(void) {
    @autoreleasepool {
        _Atomic uint32_t selected = 42;
        _Atomic int composed = 1;
        int status = 1;
        selectedWindow = &selected;
        compositionEnabled = &composed;
        compositionStatus = &status;
        expectedCaller = 0x1234;
        assert(install());
        DockboardNativeWarpStatus = 1;
        bar = [DockBar new];
        DOCKWindowTile *tile = [DOCKWindowTile new];
        foreign = [DOCKWindowTile new];
        tile->_wid = 42;
        foreign->_wid = 43;
        tile->_animateWindow = foreign->_animateWindow = true;
        tile->_minimizing = foreign->_minimizing = true;
        tile->_transformer.tinyWindow = true;
        [tile updateTransition];
        assert(nativeWarps == 1);
        assert(DockboardNativeWarpSetEnabled(true));
        [tile updateTransition];
        assert(nativeWarps == 1 && tile->_transformer.tinyWindow &&
               tile->_transformer.tileBuild == 0);
        tile->_transformNow = 1;
        [tile updateTransition];
        assert(nativeWarps == 1 && tile->_transformer.tileBuild == 1);
        nestInside = true;
        [tile updateTransition];
        nestInside = false;
        assert(nativeWarps == 2 && !suppressNative);
        throwInside = true;
        @try {
            [tile updateTransition];
            assert(false);
        } @catch (NSException *e) {
            (void)e;
        }
        throwInside = false;
        assert(!suppressNative && tile->_transformer.tinyWindow);
        tile->_minimizing = false;
        tile->_maximizing = true;
        tile->_transformNow = .5;
        [tile updateTransition];
        assert(nativeWarps == 2);
        atomic_store(&composed, 0);
        [tile updateTransition];
        assert(nativeWarps == 3);
        assert(!DockboardNativeWarpSetEnabled(true));
        atomic_store(&composed, 1);
        assert(DockboardNativeWarpSetEnabled(false));
        [tile updateTransition];
        assert(nativeWarps == 4);
        assert(forwards == 9);
        atomic_store(&selected, UINT32_MAX);
        assert(DockboardNativeWarpSetEnabled(true));
        [foreign updateTransition];
        [tile updateTransition];
        assert(nativeWarps == 4 && !suppressNative);
        puts("Native warp: exact caller, tiny-window override, endpoint, nested foreign update, "
             "exception and disable passed.");
    }
    return 0;
}
