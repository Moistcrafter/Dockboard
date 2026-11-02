#ifndef NATIVE_DOCK_THUMBNAIL_H
#define NATIVE_DOCK_THUMBNAIL_H
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#include "NativeDockTarget.h"
// Reads native layout only; never mutates Tile._globalBounds or calls Tile.setGlobalFrame:.
static inline bool NativeDockThumbnailMethod(id object, SEL selector, const char *encoding) {
    Method m = object ? class_getInstanceMethod(object_getClass(object), selector) : NULL;
    return m && !strcmp(method_getTypeEncoding(m), encoding);
}
static inline bool NativeDockThumbnailFrame(id tile, CGRect *out) {
    if (!out || !NativeDockTargetLayout.ready ||
        !NativeDockTargetIsClass(tile, NativeDockTargetLayout.tile))
        return false;
    const char *base = (__bridge const void *)tile;
    uintptr_t pp = 0, bb = 0;
    memcpy(&pp, base + NativeDockTargetLayout.rect, sizeof(pp));
    memcpy(&bb, base + NativeDockTargetLayout.dock, sizeof(bb));
    id p = (__bridge id)(void *)pp, b = (__bridge id)(void *)bb;
    if (!NativeDockTargetIsClass(p, NativeDockTargetLayout.property) ||
        !NativeDockTargetIsClass(b, NativeDockTargetLayout.bar))
        return false;
    NativeDockFloatRect r;
    long long orientation;
    memcpy(&r, (const char *)(__bridge const void *)p + NativeDockTargetLayout.now, sizeof(r));
    memcpy(&orientation,
           (const char *)(__bridge const void *)b + NativeDockTargetLayout.orientation,
           sizeof(orientation));
    float w = r.right - r.left, h = r.bottom - r.top;
    if (!isfinite(r.left) || !isfinite(r.top) || !isfinite(w) || !isfinite(h))
        return false;
    if (orientation == 1 || orientation == 2) {
        if (w <= 0 || h < 0 || h > w + .01)
            return false;
        float cy = (r.top + r.bottom) * .5f;
        r.top = cy - w * .5f;
        h = w;
    } else if (orientation == 0) {
        if (h <= 0 || w < 0 || w > h + .01)
            return false;
        float cx = (r.left + r.right) * .5f;
        r.left = cx - h * .5f;
        w = h;
    } else
        return false;
    CGRect global = CGRectMake(floor((double)r.left + .5), floor((double)r.top + .5), floor(w + .5),
                               floor(h + .5));
    SEL windowSEL = sel_registerName("window"),
        convertSEL = sel_registerName("convertRectFromGlobal:");
    if (!NativeDockThumbnailMethod(b, windowSEL, "@16@0:8"))
        return false;
    id window = ((id (*)(id, SEL))objc_msgSend)(b, windowSEL);
    Class windowClass = objc_getClass("WALayerKitWindow");
    if (!windowClass || !NativeDockTargetIsClass(window, windowClass) ||
        !NativeDockThumbnailMethod(
            window, convertSEL,
            "{CGRect={CGPoint=dd}{CGSize=dd}}48@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16"))
        return false;
    CGRect result = ((CGRect (*)(id, SEL, CGRect))objc_msgSend)(window, convertSEL, global);
    if (!IPadWindowRectValid((SBMotionRect){result.origin.x, result.origin.y, result.size.width,
                                            result.size.height}))
        return false;
    *out = result;
    return true;
}
#endif
