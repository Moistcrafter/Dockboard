#ifndef IPAD_WINDOW_PHYSICS_H
#define IPAD_WINDOW_PHYSICS_H
#include <float.h>
#include "SpringBoardMotion.h"

#define IPAD_WINDOW_PADDING_X 392.0
#define IPAD_WINDOW_PADDING_Y 588.0
#define IPAD_WINDOW_GENIE_SCALE 0.5

typedef struct {
    double progress, velocity;
} IPadWindowSpringState;
typedef struct {
    double properties[18], velocities[18], vertexResponses[9];
    double meshBoundsPhase, meshBoundsVelocity;
    double viewBoundsPhase, viewBoundsVelocity;
    double parentPositionPhase, parentPositionVelocity;
    double parentScalePhase, parentScaleVelocity;
    double fadeRaw, fadeVelocity;
    double finalTargetScale, minimizedScale, minimizedWidth, minimizedHeight;
    double rawHorizontalProgress, paddedHorizontalProgress, directionX, directionY;
} IPadWindowPhysicsState;

static inline bool IPadWindowFitsFloat(double value) {
    return isfinite(value) && fabs(value) <= FLT_MAX;
}
static inline bool IPadWindowRectValid(SBMotionRect rect) {
    return IPadWindowFitsFloat(rect.x) && IPadWindowFitsFloat(rect.y) &&
           IPadWindowFitsFloat(rect.width) && IPadWindowFitsFloat(rect.height) &&
           (float)rect.width > 0 && (float)rect.height > 0 &&
           IPadWindowFitsFloat(rect.x + rect.width) && IPadWindowFitsFloat(rect.y + rect.height);
}
// Zero-velocity analytic segment; values are never clamped or completed at an arbitrary time.
static inline bool IPadWindowSpringAtTime(double seconds, double response, double damping,
                                          IPadWindowSpringState *out) {
    if (!out || !isfinite(seconds) || seconds < 0 || !isfinite(response) || response <= 0 ||
        !isfinite(damping) || damping < 0)
        return false;
    double omega = 6.283185307179586476925286766559 / response, a = omega * seconds;
    if (!isfinite(omega) || !isfinite(a))
        return false;
    IPadWindowSpringState result = {0, 0};
    if (seconds != 0) {
        if (damping == 1) {
            double envelope = exp(-a);
            result.progress = -expm1(-a) - a * envelope;
            result.velocity = omega * (a * envelope);
        } else if (damping < 1) {
            double q = sqrt((1 - damping) * (1 + damping)), angle = q * a,
                   envelope = exp(-damping * a);
            result.progress =
                -expm1(-damping * a) +
                envelope * (2 * sin(angle / 2) * sin(angle / 2) - damping / q * sin(angle));
            result.velocity = omega * (envelope * sin(angle) / q);
        } else {
            double q = sqrt((damping - 1) * (damping + 1)), sum = damping + q;
            if (!isfinite(q) || !isfinite(sum))
                return false;
            double envelope = exp(-a / sum), difference = -expm1(-2 * q * a);
            result.progress = -expm1(-a / sum) - envelope * difference / (2 * q * sum);
            result.velocity = omega * (envelope * difference / (2 * q));
        }
    }
    if (!isfinite(result.progress) || !isfinite(result.velocity))
        return false;
    *out = result;
    return true;
}

// Phases are closed amounts:0 is the real window,1 is the minimized endpoint. Completion
// publication is separate.
static inline bool IPadWindowPhysicsAtTime(SBMotionRect window, SBMotionRect target, double seconds,
                                           bool restoring, IPadWindowPhysicsState *out) {
    if (!out || !IPadWindowRectValid(window) || !IPadWindowRectValid(target) ||
        !isfinite(seconds) || seconds < 0)
        return false;
    IPadWindowPhysicsState state = {0};
    double g = IPAD_WINDOW_GENIE_SCALE;
    state.finalTargetScale = fmax(target.width / window.width, target.height / window.height);
    if (!IPadWindowFitsFloat(state.finalTargetScale) || (float)state.finalTargetScale <= 0)
        return false;
    state.minimizedScale = state.finalTargetScale / g;
    state.minimizedWidth = target.width / state.finalTargetScale;
    state.minimizedHeight = target.height / state.finalTargetScale;
    state.rawHorizontalProgress = (target.x + target.width / 2 - window.x) / window.width;
    state.paddedHorizontalProgress =
        (IPAD_WINDOW_PADDING_X / 2 + state.rawHorizontalProgress * state.minimizedWidth) /
        (state.minimizedWidth + IPAD_WINDOW_PADDING_X);
    double metadata[] = {state.finalTargetScale,      state.minimizedScale,
                         state.minimizedWidth,        state.minimizedHeight,
                         state.rawHorizontalProgress, state.paddedHorizontalProgress};
    for (unsigned i = 0; i < sizeof(metadata) / sizeof(metadata[0]); i++)
        if (!IPadWindowFitsFloat(metadata[i]))
            return false;
    if ((float)state.finalTargetScale <= 0 || (float)state.minimizedWidth <= 0 ||
        (float)state.minimizedHeight <= 0)
        return false;
    double dx = SBMotionClamp(
        2 * (target.x + target.width / 2 - window.x - window.width / 2) / window.width, -1, 1);
    double dy = SBMotionClamp(
        2 * (target.y + target.height / 2 - window.y - window.height / 2) / window.height, -1, 1);
    if (fabs(dx) > 2 * fabs(dy))
        dy = 0;
    else
        dx = 0;
    if (fabs(dx) < .25)
        dx = 0;
    if (fabs(dy) < .25)
        dy = 0;
    if (restoring) {
        dx = -dx;
        dy = -dy;
    }
    double length = hypot(dx, dy);
    if (length) {
        dx /= length;
        dy /= length;
    }
    state.directionX = dx;
    state.directionY = dy;
    double response = restoring ? .384 : .375, damping = restoring ? .85 : 1.1;
    IPadWindowSpringState mesh, view, position, scale;
    if (!IPadWindowSpringAtTime(seconds, response, damping, &mesh) ||
        !IPadWindowSpringAtTime(seconds, restoring ? .54 : .375, restoring ? .8 : 1.1, &view) ||
        !IPadWindowSpringAtTime(seconds, restoring ? .54 : .55, restoring ? .8 : .86, &position) ||
        !IPadWindowSpringAtTime(seconds, restoring ? .54 : .5, .8, &scale))
        return false;
    double sign = restoring ? -1 : 1;
    state.meshBoundsPhase = restoring ? 1 - mesh.progress : mesh.progress;
    state.meshBoundsVelocity = sign * mesh.velocity;
    state.viewBoundsPhase = restoring ? 1 - view.progress : view.progress;
    state.viewBoundsVelocity = sign * view.velocity;
    state.parentPositionPhase = restoring ? 1 - position.progress : position.progress;
    state.parentPositionVelocity = sign * position.velocity;
    state.parentScalePhase = restoring ? 1 - scale.progress : scale.progress;
    state.parentScaleVelocity = sign * scale.velocity;
    state.fadeRaw = 1 - state.viewBoundsPhase;
    state.fadeVelocity = -state.viewBoundsVelocity;
    for (int row = 0; row < 3; row++)
        for (int column = 0; column < 3; column++) {
            unsigned vertex = (unsigned)(row * 3 + column);
            double u = column / 2., v = row / 2.;
            // Native SDIV occurs before SCVTF/pow; the middle row/column uses0, not0.5.
            double qx = (double)(column / 2), qy = pow((double)(row / 2), .75);
            double rate = response * (1 + .5 * dx * (1 - 2 * qx)) * (1 + .5 * dy * (1 - 2 * qy));
            state.vertexResponses[vertex] = rate;
            IPadWindowSpringState spring;
            if (!IPadWindowSpringAtTime(seconds, rate, damping, &spring))
                return false;
            double initial[] = {u, v},
                   collapsed[] = {g * u + (1 - g) * state.paddedHorizontalProgress,
                                  g * v + (1 - g) * .5};
            for (unsigned axis = 0; axis < 2; axis++) {
                unsigned index = vertex * 2 + axis;
                double start = restoring ? collapsed[axis] : initial[axis],
                       end = restoring ? initial[axis] : collapsed[axis];
                state.properties[index] = start + (end - start) * spring.progress;
                state.velocities[index] = (end - start) * spring.velocity;
                if (!IPadWindowFitsFloat(state.properties[index]) ||
                    !IPadWindowFitsFloat(state.velocities[index]))
                    return false;
            }
        }
    double phases[] = {
        state.meshBoundsPhase,    state.meshBoundsVelocity,  state.viewBoundsPhase,
        state.viewBoundsVelocity, state.parentPositionPhase, state.parentPositionVelocity,
        state.parentScalePhase,   state.parentScaleVelocity, state.fadeRaw,
        state.fadeVelocity};
    for (unsigned i = 0; i < sizeof(phases) / sizeof(phases[0]); i++)
        if (!IPadWindowFitsFloat(phases[i]))
            return false;
    *out = state;
    return true;
}
#endif
