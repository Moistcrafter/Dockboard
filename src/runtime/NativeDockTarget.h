#ifndef NATIVE_DOCK_TARGET_H
#define NATIVE_DOCK_TARGET_H
#include "IPadWindowGeometry.h"
#import <objc/runtime.h>
#include <string.h>
/* Read-only, runtime-layout guarded. 26B123 evidence: native-full-dock-target.json.
   The layout assigns _now AND _to each frame; _from is not an endpoint.
   A side Dock builds the along-Dock extent of a square about its center. */
typedef struct FloatRect {
    float left, top, right, bottom;
} NativeDockFloatRect;
static struct {
    Class tile, property, bar;
    ptrdiff_t rect, icon, dock, now, orientation, inset;
    bool ready;
} NativeDockTargetLayout;
static inline bool NativeDockTargetIvar(Class c, const char *name, const char *type,
                                        ptrdiff_t *offset, size_t bytes) {
    Ivar v = class_getInstanceVariable(c, name);
    if (!v || strcmp(ivar_getTypeEncoding(v), type))
        return false;
    ptrdiff_t n = ivar_getOffset(v);
    size_t size = class_getInstanceSize(c);
    if (n < 0 || (size_t)n > size || bytes > size - (size_t)n)
        return false;
    *offset = n;
    return true;
}
static inline bool NativeDockTargetIsClass(id o, Class expected) {
    for (Class c = o ? object_getClass(o) : Nil; c; c = class_getSuperclass(c))
        if (c == expected)
            return true;
    return false;
}
static inline bool NativeDockTargetInit(Class tileClass) {
    NativeDockTargetLayout.ready = false;
    Class p = objc_getClass("DockFloatRectAnimatedProperty"), b = objc_getClass("DockBar");
    if (!tileClass || !p || !b || strcmp(class_getName(tileClass), "DOCKWindowTile"))
        return false;
    const char *fr = "{FloatRect=ffff}",
               *named = "{FloatRect=\"left\"f\"top\"f\"right\"f\"bottom\"f}";
    Ivar icon = class_getInstanceVariable(tileClass, "_iconRect"),
         now = class_getInstanceVariable(p, "_now");
    if (!icon || !now)
        return false;
    const char *it = ivar_getTypeEncoding(icon), *nt = ivar_getTypeEncoding(now);
    if ((strcmp(it, fr) && strcmp(it, named)) || (strcmp(nt, fr) && strcmp(nt, named)))
        return false;
    if (!NativeDockTargetIvar(tileClass, "_rect", "@\"DockFloatRectAnimatedProperty\"",
                              &NativeDockTargetLayout.rect, sizeof(id)) ||
        !NativeDockTargetIvar(tileClass, "_dock", "@\"DockBar\"", &NativeDockTargetLayout.dock,
                              sizeof(id)) ||
        !NativeDockTargetIvar(tileClass, "_iconRect", it, &NativeDockTargetLayout.icon,
                              sizeof(NativeDockFloatRect)) ||
        !NativeDockTargetIvar(p, "_now", nt, &NativeDockTargetLayout.now,
                              sizeof(NativeDockFloatRect)) ||
        !NativeDockTargetIvar(b, "barOrientation", "q", &NativeDockTargetLayout.orientation,
                              sizeof(long long)) ||
        !NativeDockTargetIvar(b, "tileInset", "f", &NativeDockTargetLayout.inset, sizeof(float)))
        return false;
    NativeDockTargetLayout.tile = tileClass;
    NativeDockTargetLayout.property = p;
    NativeDockTargetLayout.bar = b;
    NativeDockTargetLayout.ready = true;
    return true;
}
static inline bool NativeDockTargetFormula(NativeDockFloatRect r, NativeDockFloatRect icon,
                                           float inset, long long orientation, SBMotionRect *out,
                                           IPadWindowDockEdge *edge) {
    float a[] = {r.left,   r.top,      r.right,     r.bottom, icon.left,
                 icon.top, icon.right, icon.bottom, inset};
    for (unsigned i = 0; i < sizeof(a) / sizeof(a[0]); i++)
        if (!isfinite(a[i]))
            return false;
    if (!out || !edge || inset < 0 || inset > 32 || icon.left < 0 || icon.top < 0 ||
        icon.right > 128 || icon.bottom > 128 || icon.right <= icon.left || icon.bottom <= icon.top)
        return false;
    float w = r.right - r.left, h = r.bottom - r.top;
    IPadWindowDockEdge e;
    if (orientation == 1 || orientation == 2) {
        if (w <= 0 || h < 0 || h > w + 0.01f)
            return false;
        float cy = (r.top + r.bottom) * .5f;
        r.top = cy - w * .5f;
        r.bottom = cy + w * .5f;
        h = w;
        e = orientation == 1 ? IPadWindowDockLeft : IPadWindowDockRight;
    } else if (orientation == 0) {
        if (h <= 0 || w < 0 || w > h + .01f)
            return false;
        float cx = (r.left + r.right) * .5f;
        r.left = cx - h * .5f;
        r.right = cx + h * .5f;
        w = h;
        e = IPadWindowDockBottom;
    } else
        return false;
    float l = r.left + (icon.left * w) * .0078125f + inset,
          t = r.top + (h * icon.top) * .0078125f - inset;
    float right = r.left + (w * icon.right) * .0078125f - inset,
          bottom = r.top + (h * icon.bottom) * .0078125f + inset;
    SBMotionRect result = {l, t, (double)right - l, (double)bottom - t};
    if (!IPadWindowRectValid(result))
        return false;
    *out = result;
    *edge = e;
    return true;
}
static inline bool NativeDockTargetRead(id tile, bool restoring, SBMotionRect *out,
                                        IPadWindowDockEdge *edge) {
    (void)restoring;
    if (!NativeDockTargetLayout.ready ||
        !NativeDockTargetIsClass(tile, NativeDockTargetLayout.tile))
        return false;
    uintptr_t pp = 0, bb = 0;
    const char *base = (const char *)(__bridge const void *)tile;
    memcpy(&pp, base + NativeDockTargetLayout.rect, sizeof(pp));
    memcpy(&bb, base + NativeDockTargetLayout.dock, sizeof(bb));
    id p = (__bridge id)(void *)pp, b = (__bridge id)(void *)bb;
    if (!NativeDockTargetIsClass(p, NativeDockTargetLayout.property) ||
        !NativeDockTargetIsClass(b, NativeDockTargetLayout.bar))
        return false;
    NativeDockFloatRect r, icon;
    float inset;
    long long orientation;
    memcpy(&r, (const char *)(__bridge const void *)p + NativeDockTargetLayout.now, sizeof(r));
    memcpy(&icon, base + NativeDockTargetLayout.icon, sizeof(icon));
    memcpy(&inset, (const char *)(__bridge const void *)b + NativeDockTargetLayout.inset,
           sizeof(inset));
    memcpy(&orientation,
           (const char *)(__bridge const void *)b + NativeDockTargetLayout.orientation,
           sizeof(orientation));
    return NativeDockTargetFormula(r, icon, inset, orientation, out, edge);
}
#endif
