#ifndef SPRINGBOARD_SUBDIVISION_H
#define SPRINGBOARD_SUBDIVISION_H
#include "SpringBoardMotion.h"

// Regular zero-sharpness quad topology: three Catmull-Clark steps, fixed corners.
static inline bool SBMotionSubdivide(const SBMotionVertex control[9], SBMotionVertex out[289]) {
    if (!control || !out)
        return false;
    double grid[289][4], horizontal[289][4], next[289][4];
    for (int i = 0; i < 9; i++) {
        const float values[4] = {control[i].sourceX, control[i].sourceY, control[i].destinationX,
                                 control[i].destinationY};
        for (int k = 0; k < 4; k++) {
            if (!isfinite(values[k]))
                return false;
            grid[i][k] = values[k];
        }
    }
    int size = 3;
    for (int step = 0; step < 3; step++) {
        int expanded = 2 * size - 1;
        for (int row = 0; row < size; row++)
            for (int x = 0; x < expanded; x++)
                for (int k = 0; k < 4; k++) {
                    int old = x / 2;
                    double value = grid[row * size + old][k];
                    if (x & 1)
                        value = .5 * (value + grid[row * size + old + 1][k]);
                    else if (old > 0 && old < size - 1)
                        value = .75 * value + .125 * (grid[row * size + old - 1][k] +
                                                      grid[row * size + old + 1][k]);
                    horizontal[row * expanded + x][k] = value;
                }
        for (int y = 0; y < expanded; y++)
            for (int x = 0; x < expanded; x++)
                for (int k = 0; k < 4; k++) {
                    int old = y / 2;
                    double value = horizontal[old * expanded + x][k];
                    if (y & 1)
                        value = .5 * (value + horizontal[(old + 1) * expanded + x][k]);
                    else if (old > 0 && old < size - 1)
                        value = .75 * value + .125 * (horizontal[(old - 1) * expanded + x][k] +
                                                      horizontal[(old + 1) * expanded + x][k]);
                    next[y * expanded + x][k] = value;
                }
        size = expanded;
        for (int i = 0; i < size * size; i++)
            for (int k = 0; k < 4; k++)
                grid[i][k] = next[i][k];
    }
    for (int i = 0; i < 289; i++)
        out[i] = (SBMotionVertex){grid[i][0], grid[i][1], grid[i][2], grid[i][3]};
    return true;
}
#endif
