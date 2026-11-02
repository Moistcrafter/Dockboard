#ifndef GENIE_CROSSFADE_CURVES_H
#define GENIE_CROSSFADE_CURVES_H
#include "SpringBoardMotion.h"
typedef struct {
    float window, thumbnail;
} SBCrossfade;
static inline float SBCrossfadeBezier(float input) {
    const double cx = .75, bx = -.75, ax = 1, y1 = (double).1f;
    const double cy = 3 * y1, by = 3 * (1 - y1) - cy, ay = 1 - 3 * (1 - y1);
    double t = input, error = 1;
    for (int i = 0; i < 8; i++) {
        error = (cx + (bx + ax * t) * t) * t - input;
        if (fabs(error) < 1e-5)
            break;
        double derivative = cx + (2 * bx + 3 * ax * t) * t;
        if (fabs(derivative) < 1e-6)
            break;
        t -= error / derivative;
    }
    if (fabs(error) >= 1e-5) {
        double lo = 0, hi = 1;
        t = SBMotionClamp(input, 0, 1);
        for (int i = 0; i < 1024; i++) {
            error = (cx + (bx + ax * t) * t) * t - input;
            if (fabs(error) < 1e-5 || lo >= hi)
                break;
            if (error >= 0)
                hi = t;
            else
                lo = t;
            t = lo + (hi - lo) * .5;
        }
    }
    return (float)((cy + (by + ay * t) * t) * t);
}
static inline SBCrossfade SBCrossfadeForPresentation(float p) {
    float input = (float)SBMotionClamp((p - .25) / .35, 0, 1);
    if (input <= 0)
        return (SBCrossfade){0, 1};
    if (input >= 1)
        return (SBCrossfade){1, 0};
    float icon = 1 - SBCrossfadeBezier(input);
    return (SBCrossfade){(float)SBMotionClamp(((double)icon - .9) / -.1 + 1, 0, 1), icon};
}
static inline bool SBCrossfadeAtTime(double elapsed, bool restoring, SBCrossfade *out) {
    if (!out || !isfinite(elapsed) || elapsed < 0)
        return false;
    double phase = SBMotionSettledProgress(elapsed, .336);
    *out = SBCrossfadeForPresentation((float)(restoring ? phase : 1 - phase));
    return isfinite(out->window) && isfinite(out->thumbnail);
}
#endif
