#ifndef THUMBNAIL_WARP_MESH_H
#define THUMBNAIL_WARP_MESH_H
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include "SpringBoardMotion.h"
typedef struct {
    CGPoint from;
    struct {
        double x, y, z;
    } to;
} ThumbnailMeshVertex;
typedef struct {
    unsigned indices[4];
    float attributes[4];
} ThumbnailMeshFace;
// Extend the boundary cells through native canvas padding, keeping the badge attached.
static inline bool ThumbnailWarpVertices(CGRect endpointImage, CGRect endpointPhoto,
                                         CGRect movingImage, const SBMotionVertex grid[289],
                                         ThumbnailMeshVertex out[289]) {
    if (!grid || !out)
        return false;
    CGRect rects[] = {endpointImage, endpointPhoto, movingImage};
    for (unsigned i = 0; i < 3; i++)
        if (!isfinite(rects[i].origin.x) || !isfinite(rects[i].origin.y) ||
            !isfinite(rects[i].size.width) || !isfinite(rects[i].size.height) ||
            rects[i].size.width <= 0 || rects[i].size.height <= 0)
            return false;
    ThumbnailMeshVertex result[289];
    for (unsigned r = 0; r < 17; r++)
        for (unsigned c = 0; c < 17; c++) {
            double u = c / 16., v = r / 16.;
            double x =
                (endpointImage.origin.x + u * endpointImage.size.width - endpointPhoto.origin.x) /
                endpointPhoto.size.width * 16;
            double y =
                (endpointImage.origin.y + v * endpointImage.size.height - endpointPhoto.origin.y) /
                endpointPhoto.size.height * 16;
            int col = (int)fmax(0, fmin(15, floor(x))), row = (int)fmax(0, fmin(15, floor(y)));
            double a = x - col, b = y - row;
            const SBMotionVertex *p[] = {&grid[row * 17 + col], &grid[row * 17 + col + 1],
                                         &grid[(row + 1) * 17 + col],
                                         &grid[(row + 1) * 17 + col + 1]};
            double w[] = {(1 - a) * (1 - b), a * (1 - b), (1 - a) * b, a * b}, dx = 0, dy = 0;
            for (unsigned k = 0; k < 4; k++) {
                dx += w[k] * p[k]->destinationX;
                dy += w[k] * p[k]->destinationY;
            }
            dx = (dx - movingImage.origin.x) / movingImage.size.width;
            dy = (dy - movingImage.origin.y) / movingImage.size.height;
            if (!isfinite(dx) || !isfinite(dy))
                return false;
            result[r * 17 + c] = (ThumbnailMeshVertex){{u, v}, {dx, dy, 0}};
        }
    memcpy(out, result, sizeof(result));
    return true;
}
static inline id ThumbnailWarpTransform(const ThumbnailMeshVertex vertices[289]) {
    Class cls = NSClassFromString(@"CAMutableMeshTransform");
    SEL make = sel_registerName(
        "meshTransformWithVertexCount:vertices:faceCount:faces:depthNormalization:");
    Method method = class_getClassMethod(cls, make);
    if (!method ||
        strcmp(method_getTypeEncoding(method), "@56@0:8Q16r^{CAMeshVertex={CGPoint=dd}{CAPoint3D="
                                               "ddd}}24Q32r^{CAMeshFace=[4I][4f]}40@48"))
        return nil;
    ThumbnailMeshFace faces[256] = {0};
    for (unsigned r = 0; r < 16; r++)
        for (unsigned c = 0; c < 16; c++) {
            unsigned i = r * 17 + c;
            faces[r * 16 + c] = (ThumbnailMeshFace){{i, i + 1, i + 18, i + 17}, {0, 0, 0, 0}};
        }
    id mesh = ((id (*)(id, SEL, NSUInteger, const ThumbnailMeshVertex *, NSUInteger,
                       const ThumbnailMeshFace *, id))objc_msgSend)(cls, make, 289, vertices, 256,
                                                                    faces, @"none");
    // Already subdivided by the recovered mesh helper; do not smooth it a second time.
    if (![mesh respondsToSelector:sel_registerName("setSubdivisionSteps:")])
        return nil;
    ((void (*)(id, SEL, int))objc_msgSend)(mesh, sel_registerName("setSubdivisionSteps:"), 0);
    return mesh;
}
#endif
