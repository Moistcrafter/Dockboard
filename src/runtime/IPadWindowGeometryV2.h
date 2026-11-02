#ifndef IPAD_WINDOW_GEOMETRY_V2_H
#define IPAD_WINDOW_GEOMETRY_V2_H
#include "IPadWindowGeometry.h"
#include "IPadWindowPhysicsV2.h"

static inline bool IPadWindowWarpGridV2(SBMotionRect window, SBMotionRect target, double seconds,
                                        bool restoring, IPadWindowDockEdge edge,
                                        SBMotionVertex out[289],
                                        IPadWindowPhysicsState *physicsOut) {
    if (!out)
        return false;
    SBMotionRect canonicalWindow, canonicalTarget;
    IPadWindowPhysicsState state;
    if (!IPadWindowCanonicalRect(window, edge, &canonicalWindow) ||
        !IPadWindowCanonicalRect(target, edge, &canonicalTarget) ||
        !IPadWindowPhysicsV2AtTime(canonicalWindow, canonicalTarget, seconds, restoring, &state))
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
