#ifndef IPAD_WINDOW_GEOMETRY_H
#define IPAD_WINDOW_GEOMETRY_H
#include "IPadWindowPhysics.h"
#include "SpringBoardSubdivision.h"

typedef enum { IPadWindowDockBottom, IPadWindowDockLeft, IPadWindowDockRight } IPadWindowDockEdge;
typedef struct {
    double paddedWidth, paddedHeight, meshWidth, meshHeight, viewWidth, viewHeight;
    double centerX, centerY, scale;
} IPadWindowProjection;

static inline bool IPadWindowCanonicalRect(SBMotionRect rect, IPadWindowDockEdge edge,
                                           SBMotionRect *out) {
    if (!out || !IPadWindowRectValid(rect))
        return false;
    SBMotionRect result;
    switch (edge) {
    case IPadWindowDockBottom:
        result = rect;
        break;
    case IPadWindowDockLeft:
        result = (SBMotionRect){rect.y, -rect.x - rect.width, rect.height, rect.width};
        break;
    case IPadWindowDockRight:
        result = (SBMotionRect){-rect.y - rect.height, rect.x, rect.height, rect.width};
        break;
    default:
        return false;
    }
    if (!IPadWindowRectValid(result))
        return false;
    *out = result;
    return true;
}
static inline bool IPadWindowProjectionForState(SBMotionRect window, SBMotionRect target,
                                                const IPadWindowPhysicsState *state,
                                                IPadWindowProjection *out) {
    if (!state || !out || !IPadWindowRectValid(window) || !IPadWindowRectValid(target))
        return false;
    IPadWindowProjection result = {
        window.width + IPAD_WINDOW_PADDING_X,
        window.height + IPAD_WINDOW_PADDING_Y,
        window.width + IPAD_WINDOW_PADDING_X +
            (state->minimizedWidth - window.width) * state->meshBoundsPhase,
        window.height + IPAD_WINDOW_PADDING_Y +
            (state->minimizedHeight - window.height) * state->meshBoundsPhase,
        window.width + (state->minimizedWidth - window.width) * state->viewBoundsPhase,
        window.height + (state->minimizedHeight - window.height) * state->viewBoundsPhase,
        window.x + window.width / 2 +
            (target.x + target.width / 2 - window.x - window.width / 2) *
                state->parentPositionPhase,
        window.y + window.height / 2 +
            (target.y + target.height / 2 - window.y - window.height / 2) *
                state->parentPositionPhase,
        1 + (state->finalTargetScale - 1) * state->parentScalePhase};
    double values[] = {result.paddedWidth, result.paddedHeight, result.meshWidth,
                       result.meshHeight,  result.viewWidth,    result.viewHeight,
                       result.centerX,     result.centerY,      result.scale};
    for (unsigned i = 0; i < sizeof(values) / sizeof(values[0]); i++)
        if (!IPadWindowFitsFloat(values[i]))
            return false;
    if (result.meshWidth <= 0 || result.meshHeight <= 0 || result.viewWidth <= 0 ||
        result.viewHeight <= 0 || result.scale <= 0)
        return false;
    *out = result;
    return true;
}

// Native normalized mesh before its viewport/layer transforms; source UVs include padded-container
// scaling.
static inline bool IPadWindowPaddedControlMesh(SBMotionRect window, SBMotionRect target,
                                               const IPadWindowPhysicsState *state,
                                               SBMotionVertex out[9]) {
    IPadWindowProjection p;
    if (!out || !IPadWindowProjectionForState(window, target, state, &p) ||
        state->minimizedScale <= 0)
        return false;
    double b = state->meshBoundsPhase, m = state->minimizedScale, g = IPAD_WINDOW_GENIE_SCALE;
    double denominator = m * g + (1 - b) * (1 - m * g);
    if (!isfinite(denominator) || denominator <= 0)
        return false;
    double factor = (m + (1 - m) * (1 - b)) / denominator;
    double counter = state->minimizedWidth * (.5 - state->rawHorizontalProgress) * (1 - g);
    double offset =
        counter * ((factor - 1) / (1 / g - 1)) / (state->minimizedWidth + IPAD_WINDOW_PADDING_X);
    double centerX = state->properties[8], centerY = state->properties[9];
    SBMotionVertex control[9];
    for (int row = 0; row < 3; row++)
        for (int column = 0; column < 3; column++) {
            unsigned i = (unsigned)(row * 3 + column);
            double u = column / 2., v = row / 2.;
            double values[] = {
                p.meshWidth / p.paddedWidth * u, p.meshHeight / p.paddedHeight * v,
                p.meshWidth / p.paddedWidth *
                    (offset + centerX + (state->properties[2 * i] - centerX) * factor),
                p.meshHeight / p.paddedHeight *
                    (centerY + (state->properties[2 * i + 1] - centerY) * factor)};
            for (unsigned k = 0; k < 4; k++)
                if (!IPadWindowFitsFloat(values[k]))
                    return false;
            control[i] = (SBMotionVertex){values[0], values[1], values[2], values[3]};
        }
    for (unsigned i = 0; i < 9; i++)
        out[i] = control[i];
    return true;
}
static inline bool IPadWindowPaddedMesh(SBMotionRect window, SBMotionRect target,
                                        const IPadWindowPhysicsState *state,
                                        SBMotionVertex out[289]) {
    SBMotionVertex control[9];
    return out && IPadWindowPaddedControlMesh(window, target, state, control) &&
           SBMotionSubdivide(control, out);
}

// Match native (0,1,2)/(2,3,0) triangles and perspective UV interpolation of homogeneous corners.
static inline bool IPadWindowMeshPoint(const SBMotionVertex grid[289], double u, double v,
                                       double *x, double *y) {
    if (!grid || !x || !y || !isfinite(u) || !isfinite(v) || u < 0 || u > 1 || v < 0 || v > 1)
        return false;
    double column = u * 16, row = v * 16;
    int c = (int)fmin(15, floor(column)), r = (int)fmin(15, floor(row));
    u = column - c;
    v = row - r;
    const SBMotionVertex *points[] = {&grid[r * 17 + c], &grid[r * 17 + c + 1],
                                      &grid[(r + 1) * 17 + c + 1], &grid[(r + 1) * 17 + c]};
    double px[4], py[4], weight[4] = {1, 1, 1, 1};
    for (unsigned i = 0; i < 4; i++) {
        px[i] = points[i]->destinationX;
        py[i] = points[i]->destinationY;
        if (!isfinite(px[i]) || !isfinite(py[i]))
            return false;
    }
    double dx = px[0] + px[2] - px[1] - px[3], dy = py[0] + py[2] - py[1] - py[3];
    if (fmax(fabs(dx), fabs(dy)) >= 1e-6) {
        double ax = px[1] - px[2], ay = py[1] - py[2], bx = px[3] - px[2], by = py[3] - py[2];
        double determinant = ax * by - bx * ay;
        if (!isfinite(determinant) || determinant == 0)
            return false;
        double g = (dx * by - bx * dy) / determinant, h = (ax * dy - dx * ay) / determinant;
        weight[1] = 1 + g;
        weight[2] = 1 + g + h;
        weight[3] = 1 + h;
    }
    double barycentric[4];
    if (u >= v) {
        barycentric[0] = 1 - u;
        barycentric[1] = u - v;
        barycentric[2] = v;
        barycentric[3] = 0;
    } else {
        barycentric[0] = 1 - v;
        barycentric[1] = 0;
        barycentric[2] = u;
        barycentric[3] = v - u;
    }
    double sum = 0, resultX = 0, resultY = 0;
    for (unsigned i = 0; i < 4; i++) {
        if (!isfinite(weight[i]) || weight[i] <= 0)
            return false;
        double w = barycentric[i] * weight[i];
        sum += w;
        resultX += w * px[i];
        resultY += w * py[i];
    }
    if (!isfinite(sum) || sum <= 0 || !isfinite(resultX / sum) || !isfinite(resultY / sum))
        return false;
    *x = resultX / sum;
    *y = resultY / sum;
    return true;
}

// Full-preview adaptation: the original photo fills the current child-content rectangle, without
// cropping pixels.
static inline bool IPadWindowPhotoPoint(SBMotionRect window, SBMotionRect target,
                                        const IPadWindowPhysicsState *state,
                                        const SBMotionVertex mesh[289], double s, double t,
                                        double *x, double *y) {
    IPadWindowProjection p;
    if (!x || !y || !isfinite(s) || !isfinite(t) || s < 0 || s > 1 || t < 0 || t > 1 ||
        !IPadWindowProjectionForState(window, target, state, &p))
        return false;
    double u = (IPAD_WINDOW_PADDING_X / 2 + s * p.viewWidth) / p.meshWidth;
    double v = (IPAD_WINDOW_PADDING_Y / 2 + t * p.viewHeight) / p.meshHeight;
    double nx, ny;
    if (!IPadWindowMeshPoint(mesh, u, v, &nx, &ny))
        return false;
    double resultX =
        p.centerX + p.scale * (nx * p.paddedWidth - IPAD_WINDOW_PADDING_X / 2 - p.viewWidth / 2);
    double resultY =
        p.centerY + p.scale * (ny * p.paddedHeight - IPAD_WINDOW_PADDING_Y / 2 - p.viewHeight / 2);
    if (!IPadWindowFitsFloat(resultX) || !IPadWindowFitsFloat(resultY))
        return false;
    *x = resultX;
    *y = resultY;
    return true;
}

static inline bool IPadWindowWarpGrid(SBMotionRect window, SBMotionRect target, double seconds,
                                      bool restoring, IPadWindowDockEdge edge,
                                      SBMotionVertex out[289], IPadWindowPhysicsState *physicsOut) {
    if (!out)
        return false;
    SBMotionRect canonicalWindow, canonicalTarget;
    IPadWindowPhysicsState state;
    if (!IPadWindowCanonicalRect(window, edge, &canonicalWindow) ||
        !IPadWindowCanonicalRect(target, edge, &canonicalTarget) ||
        !IPadWindowPhysicsAtTime(canonicalWindow, canonicalTarget, seconds, restoring, &state))
        return false;
    SBMotionVertex mesh[289], result[289];
    if (!IPadWindowPaddedMesh(canonicalWindow, canonicalTarget, &state, mesh))
        return false;
    for (int row = 0; row < 17; row++)
        for (int column = 0; column < 17; column++) {
            unsigned i = (unsigned)(row * 17 + column);
            double s = column / 16., t = row / 16., u = s, v = t;
            if (edge == IPadWindowDockLeft) {
                u = t;
                v = 1 - s;
            } else if (edge == IPadWindowDockRight) {
                u = 1 - t;
                v = s;
            }
            double x, y;
            if (!IPadWindowPhotoPoint(canonicalWindow, canonicalTarget, &state, mesh, u, v, &x, &y))
                return false;
            if (edge == IPadWindowDockLeft) {
                double oldX = x;
                x = -y;
                y = oldX;
            } else if (edge == IPadWindowDockRight) {
                double oldX = x;
                x = y;
                y = -oldX;
            }
            result[i] = (SBMotionVertex){s * window.width, t * window.height, x, y};
        }
    for (unsigned i = 0; i < 289; i++)
        out[i] = result[i];
    if (physicsOut)
        *physicsOut = state;
    return true;
}
#endif
