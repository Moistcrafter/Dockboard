#ifndef SPRINGBOARD_MOTION_H
#define SPRINGBOARD_MOTION_H
#include <stdbool.h>
#include <math.h>

typedef struct {
    double x, y, width, height;
} SBMotionRect;
typedef struct {
    float sourceX, sourceY, destinationX, destinationY;
} SBMotionVertex;

static inline double SBMotionClamp(double value, double low, double high) {
    return fmax(low, fmin(high, value));
}
static inline double SBMotionProgress(double seconds, double response) {
    double age = fmax(0, seconds), omega = 6.2831853071795864769 / response;
    return 1 - (1 + omega * age) * exp(-omega * age);
}
static inline double SBMotionSettledProgress(double seconds, double response) {
    if (seconds >= .5)
        return 1;
    double raw = SBMotionProgress(seconds, response);
    // Native handoff ends at .5s; remove residual spring displacement with zero slope/curvature at
    // both blend ends.
    double u = SBMotionClamp((seconds - .32) / .18, 0, 1);
    double blend = u * u * u * (10 + u * (-15 + 6 * u));
    return raw + (1 - raw) * blend;
}
static inline double SBMotionRow(double value, double direction) {
    return direction >= 0 ? sqrt(value) : 1 - sqrt(1 - value);
}

// shortcut: zero-velocity tap motion with rectangular preview endpoints, extend for interactive
// reversal later.
static inline bool SBMotionGrid(SBMotionRect window, SBMotionRect target, double elapsed,
                                bool restoring, SBMotionVertex out[9]) {
    if (!out || !isfinite(elapsed) || elapsed < 0 || !isfinite(window.x) || !isfinite(window.y) ||
        !isfinite(window.width) || !isfinite(window.height) || !isfinite(target.x) ||
        !isfinite(target.y) || !isfinite(target.width) || !isfinite(target.height) ||
        window.width <= 0 || window.height <= 0 || target.width <= 0 || target.height <= 0)
        return false;
    const double response = .336, g = .4, m = 160. / 402.;
    // Dock targets can lie outside the window; keep local mesh targets inside, move the enclosing
    // rectangle separately.
    double ix = SBMotionClamp((target.x + target.width / 2 - window.x) / window.width, 0, 1);
    double iy = SBMotionClamp((target.y + target.height / 2 - window.y) / window.height, 0, 1);
    double gx = SBMotionClamp(2 * (ix - .5), -1, 1);
    double gy = SBMotionClamp(2 * (iy - .5), -1, 1);
    if (gy < 0)
        gy *= .75;
    double phase = SBMotionSettledProgress(elapsed, response);
    double b = restoring ? 1 - phase : phase;
    double factor = (m + (1 - m) * (1 - b)) / (m * g + (1 - b) * (1 - m * g));
    double ox = (.5 - ix) * (1 - g) * ((factor - 1) / (1 / g - 1));
    double oy = (.5 - iy) * (1 - g) * ((factor - 1) / (1 / g - 1));
    double px[9], py[9];
    for (int row = 0; row < 3; row++)
        for (int column = 0; column < 3; column++) {
            int i = row * 3 + column;
            double u = column / 2., v = row / 2.;
            double vertexResponse = response * (1 + .5 * gx * (1 - 2 * SBMotionRow(u, gx))) *
                                    (1 + .5 * gy * (1 - 2 * SBMotionRow(v, gy)));
            double vertexPhase = SBMotionSettledProgress(elapsed, vertexResponse);
            double amount = restoring ? 1 - vertexPhase : vertexPhase;
            px[i] = u + ((g * u + (1 - g) * ix) - u) * amount;
            py[i] = v + ((g * v + (1 - g) * iy) - v) * amount;
        }
    double width = window.width + (target.width - window.width) * b;
    double height = window.height + (target.height - window.height) * b;
    double x = window.x + (target.x - window.x) * b;
    double y = window.y + (target.y - window.y) * b;
    SBMotionVertex result[9];
    for (int i = 0; i < 9; i++) {
        double dx = x + width * (ox + px[4] + (px[i] - px[4]) * factor);
        double dy = y + height * (oy + py[4] + (py[i] - py[4]) * factor);
        result[i] =
            (SBMotionVertex){(i % 3) * window.width / 2, (i / 3) * window.height / 2, dx, dy};
        if (!isfinite(result[i].sourceX) || !isfinite(result[i].sourceY) ||
            !isfinite(result[i].destinationX) || !isfinite(result[i].destinationY))
            return false;
    }
    for (int i = 0; i < 9; i++)
        out[i] = result[i];
    return true;
}
#endif
