#ifndef IPAD_WINDOW_PHYSICS_V2_H
#define IPAD_WINDOW_PHYSICS_V2_H
#include "IPadWindowPhysics.h"

// Actual Windowed Apps restore presentation trajectories share the C2 spring.
// Keep V1 intact: the earlier UIKit getter metadata is retained for reproduction.
static inline bool IPadWindowPhysicsV2AtTime(SBMotionRect window, SBMotionRect target,
                                             double seconds, bool restoring,
                                             IPadWindowPhysicsState *out) {
    IPadWindowPhysicsState state;
    if (!out || !IPadWindowPhysicsAtTime(window, target, seconds, restoring, &state))
        return false;
    if (restoring) {
        state.viewBoundsPhase = state.parentPositionPhase = state.parentScalePhase =
            state.meshBoundsPhase;
        state.viewBoundsVelocity = state.parentPositionVelocity = state.parentScaleVelocity =
            state.meshBoundsVelocity;
        state.fadeRaw = 1 - state.viewBoundsPhase;
        state.fadeVelocity = -state.viewBoundsVelocity;
    }
    *out = state;
    return true;
}
#endif
