#ifndef GENIE_DIRECTIONAL_CROSSFADE_H
#define GENIE_DIRECTIONAL_CROSSFADE_H
#include "CrossfadeCurves.h"

// The native callback normalizes in double before converting the solver input to float.
static inline bool SBDirectionalCrossfade(double phase, bool opening, SBCrossfade *out) {
    if (!out || !isfinite(phase))
        return false;
    float input = (float)SBMotionClamp(opening ? (phase - .15) / .45 : (phase - .25) / .35, 0, 1);
    if (input <= 0) {
        *out = (SBCrossfade){0, 1};
        return true;
    }
    if (input >= 1) {
        *out = (SBCrossfade){1, 0};
        return true;
    }
    float icon = 1 - SBCrossfadeBezier(input);
    *out = (SBCrossfade){(float)SBMotionClamp(((double)icon - .9) / -.1 + 1, 0, 1), icon};
    return true;
}
#endif
