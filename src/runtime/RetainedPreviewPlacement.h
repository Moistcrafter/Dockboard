#ifndef RETAINED_PREVIEW_PLACEMENT_H
#define RETAINED_PREVIEW_PLACEMENT_H
#import <CoreGraphics/CoreGraphics.h>
#include <math.h>
typedef struct {
    CGPoint position;
    CGSize scale;
} RetainedPreviewPlacement;
static inline bool RetainedPreviewRectValid(CGRect r) {
    return isfinite(r.origin.x) && isfinite(r.origin.y) && isfinite(r.size.width) &&
           isfinite(r.size.height) && r.size.width > 0 && r.size.height > 0;
}
// All three rectangles are in the SAME native window-root coordinate system.
// Map intended endpoint photo rect T onto moving photo bbox B; F is full native tile.
// Local image viewport is left unchanged: no second inset or aspect compensation.
static inline bool RetainedPreviewPlace(CGRect full, CGRect target, CGRect moving,
                                        RetainedPreviewPlacement *out) {
    if (!out || !RetainedPreviewRectValid(full) || !RetainedPreviewRectValid(target) ||
        !RetainedPreviewRectValid(moving))
        return false;
    RetainedPreviewPlacement p = {
        {moving.origin.x +
             (full.origin.x - target.origin.x) * moving.size.width / target.size.width,
         moving.origin.y +
             (full.origin.y - target.origin.y) * moving.size.height / target.size.height},
        {moving.size.width / target.size.width, moving.size.height / target.size.height}};
    if (!isfinite(p.position.x) || !isfinite(p.position.y) || !isfinite(p.scale.width) ||
        !isfinite(p.scale.height) || p.scale.width <= 0 || p.scale.height <= 0)
        return false;
    *out = p;
    return true;
}
#endif
