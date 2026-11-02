#import <Foundation/Foundation.h>
#include "NativeDockTarget.h"
#include <assert.h>
@interface DockFloatRectAnimatedProperty : NSObject {
  @public
    NativeDockFloatRect _now;
}
@end
@implementation DockFloatRectAnimatedProperty
@end
@interface DockBar : NSObject {
  @public
    long long barOrientation;
    float tileInset;
}
@end
@implementation DockBar
@end
@interface DOCKWindowTile : NSObject {
  @public
    DockFloatRectAnimatedProperty *_rect;
    DockBar *_dock;
    NativeDockFloatRect _iconRect;
}
@end
@implementation DOCKWindowTile
@end
int main(void) {
    @autoreleasepool {
        assert(NativeDockTargetInit([DOCKWindowTile class]));
        DOCKWindowTile *t = [DOCKWindowTile new];
        t->_rect = [DockFloatRectAnimatedProperty new];
        t->_dock = [DockBar new];
        t->_dock->barOrientation = 1;
        t->_dock->tileInset = 1;
        t->_iconRect = (NativeDockFloatRect){4, 22.90909194946289f, 124, 105.09091186523438f};
        SBMotionRect a = {0}, b = {0};
        IPadWindowDockEdge e;
        for (int i = 0; i <= 100; i++) {
            float h = 47 * i / 100.f;
            t->_rect->_now = (NativeDockFloatRect){12, 1239.0750732421875f - h / 2, 59,
                                                   1239.0750732421875f + h / 2};
            assert(NativeDockTargetRead(t, false, &a, &e));
            assert(e == IPadWindowDockLeft);
            assert(fabs(a.width - 42.0625) < 1e-6);
            assert(fabs(a.height - 32.176025390625) < .001);
            assert(NativeDockTargetRead(t, true, &b, &e));
            assert(!memcmp(&a, &b, sizeof(a)));
        }
        SBMotionRect sentinel = {1, 2, 3, 4};
        a = sentinel;
        t->_dock->barOrientation = 99;
        assert(!NativeDockTargetRead(t, false, &a, &e));
        assert(!memcmp(&a, &sentinel, sizeof(a)));
        assert(!NativeDockTargetRead([NSObject new], false, &a, &e));
        assert(!NativeDockTargetInit([NSObject class]));
        puts("NativeDockTarget mocks: 101 partial heights, both directions, invalid "
             "orientation/class/init passed");
    }
}
