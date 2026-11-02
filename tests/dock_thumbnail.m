#import <Foundation/Foundation.h>
#include "NativeDockThumbnail.h"
#include <assert.h>
@interface DockFloatRectAnimatedProperty : NSObject {
  @public
    NativeDockFloatRect _now;
}
@end
@implementation DockFloatRectAnimatedProperty
@end
@interface WALayerKitWindow : NSObject
- (CGRect)convertRectFromGlobal:(CGRect)r;
@end
@implementation WALayerKitWindow
- (CGRect)convertRectFromGlobal:(CGRect)r {
    r.origin.x -= 10;
    r.origin.y -= 20;
    return r;
}
@end
@interface DockBar : NSObject {
  @public
    long long barOrientation;
    float tileInset;
}
@end
@implementation DockBar
- (id)window {
    return [WALayerKitWindow new];
}
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
            CGRect full;
            assert(NativeDockThumbnailFrame(t, &full));
            assert(full.size.width == 47 && full.size.height == 47 && full.origin.x == 2);
        }
        SBMotionRect sentinel = {1, 2, 3, 4};
        a = sentinel;
        t->_dock->barOrientation = 99;
        assert(!NativeDockTargetRead(t, false, &a, &e));
        assert(!memcmp(&a, &sentinel, sizeof(a)));
        assert(!NativeDockTargetRead([NSObject new], false, &a, &e));
        assert(!NativeDockTargetInit([NSObject class]));
        CGRect sentinelRect = CGRectMake(1, 2, 3, 4), full = sentinelRect;
        assert(!NativeDockThumbnailFrame(t, &full));
        assert(CGRectEqualToRect(full, sentinelRect));
        t->_dock->barOrientation = 0;
        t->_rect->_now = (NativeDockFloatRect){100, 200, 120, 247};
        assert(NativeDockTargetInit([DOCKWindowTile class]));
        assert(NativeDockThumbnailFrame(t, &full));
        assert(full.size.width == 47 && full.size.height == 47 && full.origin.x == 77 &&
               full.origin.y == 180);
        t->_dock->barOrientation = 1;
        t->_rect->_now = (NativeDockFloatRect){-11.8f, -30, -1.8f, -20};
        assert(NativeDockThumbnailFrame(t, &full));
        assert(full.origin.x == -22 && full.origin.y == -50);
        t->_rect->_now.left = NAN;
        assert(!NativeDockThumbnailFrame(t, &full));
        puts("NativeDockTarget mocks: 101 partial heights, both directions, invalid "
             "orientation/class/init passed");
    }
}
