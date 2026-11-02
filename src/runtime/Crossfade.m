#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <sys/sysctl.h>
#include "DirectionalCrossfade.h"
#include "IPadWindowGeometryV2.h"
#include "RetainedPreviewPlacement.h"
#include "ThumbnailWarpMesh.h"
#ifndef SELF_TEST
#include "NativeDockThumbnail.h"
#else
static bool NativeDockTargetInit(Class cls);
static bool NativeDockThumbnailFrame(id tile, CGRect *out);
static bool NativeDockTargetRead(id tile, bool restoring, SBMotionRect *out,
                                 IPadWindowDockEdge *edge);
#endif
// Dock hit-tests this tree; decorative previews must not intercept tile clicks.
@interface DockboardPreviewLayer : CALayer
@end
@implementation DockboardPreviewLayer
- (CALayer *)hitTest:(CGPoint)point {
    (void)point;
    return nil;
}
@end
static void (*previousBegin)(id, SEL, double, bool, bool);
static void (*previousUpdate)(id, SEL), (*previousEnd)(id, SEL);
static int (*getAlpha)(int, uint32_t, float *), (*setAlpha)(int, uint32_t, float),
    (*connection)(void);
static bool (*compositionElapsed)(uint32_t, double *);
static _Atomic uint32_t *selectedWindow;
static _Atomic int *globalEnabled;
static int *v5Status;
static ptrdiff_t windowOffset, widOffset, minimizingOffset, maximizingOffset, animateOffset;
static Ivar maskIvar, layerIvar, storedImageIvar;
static id (*imageLayerGetter)(id, SEL);
static CGRect (*computeLayout)(id, SEL, CGRect);
static NSLock *fadeLock;
@interface DockboardFadeState : NSObject {
  @public
    uint32_t heldWindow;
    bool heldClosing;
    unsigned opaqueFrames;
    int heldConnection;
    float originalAlpha, originalMaskOpacity;
    CALayer *savedMask, *preview, *previewImage, *retainedRoot;
    id retainedImage, cachedImage;
    __weak id cachedTile;
    uint32_t cachedWindow;
}
@end
@implementation DockboardFadeState
@end
static NSMapTable<id, DockboardFadeState *> *states;
// Called with fadeLock held; weak keys release cached thumbnails with their native tiles.
static DockboardFadeState *stateForTile(id tile) {
    DockboardFadeState *state = [states objectForKey:tile];
    if (!state) {
        state = [DockboardFadeState new];
        [states setObject:state forKey:tile];
    }
    return state;
}
static CGError (*captureWindow)(int, const uint32_t *, int, uint32_t, CGImageRef *, CGRect);
_Atomic int GenieCrossfadeV24Enabled, GenieCrossfadeV24Frames, GenieCrossfadeV24Errors;
_Atomic int GenieCrossfadeV24AlphaWrites, GenieCrossfadeV24Restores, GenieCrossfadeV24ImageWaits;
_Atomic int GenieCrossfadeV24PreviewCreates, GenieCrossfadeV24PreviewRemoves,
    GenieCrossfadeV24HandoffMisses;
_Atomic uint32_t GenieCrossfadeV24PendingWindow;
int GenieCrossfadeV24Status;
_Atomic uint32_t GenieCrossfadeV24TestWindow;
_Atomic unsigned DockboardFadeFailureLine, DockboardFadeFailureWindow;
static uint32_t windowID(id tile) {
    uint32_t wid;
    memcpy(&wid, (const char *)(__bridge const void *)tile + widOffset, sizeof(wid));
    return wid;
}
static double displayScaleForTarget(SBMotionRect target) {
#ifdef SELF_TEST
    (void)target;
    return 2;
#else
    CGDirectDisplayID display;
    uint32_t count = 0;
    CGPoint point = CGPointMake(target.x + target.width / 2, target.y + target.height / 2);
    if (CGGetDisplaysWithPoint(point, 1, &display, &count) != kCGErrorSuccess || !count)
        return 1;
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display);
    if (!mode)
        return 1;
    size_t width = CGDisplayModeGetWidth(mode), pixels = CGDisplayModeGetPixelWidth(mode);
    CGDisplayModeRelease(mode);
    double scale = width ? (double)pixels / width : 1;
    return isfinite(scale) && scale >= 1 && scale <= 4 ? scale : 1;
#endif
}
static bool validRect(CGRect r) {
    return isfinite(r.origin.x) && isfinite(r.origin.y) && isfinite(r.size.width) &&
           isfinite(r.size.height) && r.size.width > 0 && r.size.height > 0;
}
static bool usableImage(id image) {
    return image && CFGetTypeID((__bridge CFTypeRef)image) == CGImageGetTypeID() &&
           CGImageGetWidth((__bridge CGImageRef)image) > 0 &&
           CGImageGetHeight((__bridge CGImageRef)image) > 0;
}
static bool visibleRawImage(CGImageRef image) {
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    // shortcut: cap validation at64MiB; larger windows keep the source without a custom fade.
    if (!width || !height || width > 8192 || height > 8192)
        return false;
    CGContextRef context =
        CGBitmapContextCreate(NULL, width, height, 8, width, NULL, (CGBitmapInfo)kCGImageAlphaOnly);
    if (!context)
        return false;
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    const unsigned char *alpha = CGBitmapContextGetData(context);
    size_t stride = CGBitmapContextGetBytesPerRow(context);
    bool visible = false;
    for (size_t y = 0; y < height && !visible; y++)
        for (size_t x = 0; x < width; x++)
            if (alpha[y * stride + x]) {
                visible = true;
                break;
            }
    CGContextRelease(context);
    return visible;
}
#ifndef SELF_TEST
static id windowForTile(id tile) {
    uintptr_t dockPointer = 0;
    memcpy(&dockPointer, (const char *)(__bridge const void *)tile + NativeDockTargetLayout.dock,
           sizeof(dockPointer));
    id dock = (__bridge id)(void *)dockPointer;
    if (!NativeDockTargetIsClass(dock, NativeDockTargetLayout.bar) ||
        !NativeDockThumbnailMethod(dock, sel_registerName("window"), "@16@0:8"))
        return nil;
    id window = ((id (*)(id, SEL))objc_msgSend)(dock, sel_registerName("window"));
    return NativeDockTargetIsClass(window, objc_getClass("WALayerKitWindow")) ? window : nil;
}
static CALayer *rootForTile(id tile, CALayer *layer) {
    id window = windowForTile(tile);
    if (!NativeDockThumbnailMethod(window, sel_registerName("layer"), "@16@0:8"))
        return nil;
    id root = ((id (*)(id, SEL))objc_msgSend)(window, sel_registerName("layer"));
    return [root isKindOfClass:CALayer.class] && layer.superlayer == root &&
                   CATransform3DIsIdentity([(CALayer *)root sublayerTransform])
               ? root
               : nil;
}
static bool rootRect(id tile, CGRect global, CGRect *out) {
    id window = windowForTile(tile);
    SEL convert = sel_registerName("convertRectFromGlobal:");
    if (!out || !NativeDockThumbnailMethod(
                    window, convert,
                    "{CGRect={CGPoint=dd}{CGSize=dd}}48@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16"))
        return false;
    CGRect result = ((CGRect (*)(id, SEL, CGRect))objc_msgSend)(window, convert, global);
    if (!validRect(result))
        return false;
    *out = result;
    return true;
}
#else
static CALayer *rootForTile(id tile, CALayer *layer);
static bool rootRect(id tile, CGRect global, CGRect *out);
#endif
static void removePreviewLocked(DockboardFadeState *state) {
    if (state->preview) {
        [state->preview removeFromSuperlayer];
        atomic_fetch_add(&GenieCrossfadeV24PreviewRemoves, 1);
    }
    state->preview = nil;
    state->previewImage = nil;
    state->retainedRoot = nil;
    state->retainedImage = nil;
}
static bool writeAlpha(DockboardFadeState *state, float value) {
    if (setAlpha(state->heldConnection, state->heldWindow, value)) {
        atomic_fetch_add(&GenieCrossfadeV24Errors, 1);
        return false;
    }
    atomic_fetch_add(&GenieCrossfadeV24AlphaWrites, 1);
    return true;
}
static void restoreMaskLocked(DockboardFadeState *state) {
    if (state->savedMask) {
        state->savedMask.opacity = state->originalMaskOpacity;
        state->savedMask = nil;
    }
}
static bool restoreAlphaLocked(DockboardFadeState *state) {
    if (!state->heldWindow)
        return true;
    if (!writeAlpha(state, state->originalAlpha))
        return false;
    state->heldWindow = 0;
    atomic_fetch_sub(&GenieCrossfadeV24PendingWindow, 1);
    atomic_fetch_add(&GenieCrossfadeV24Restores, 1);
    return true;
}
static bool restoreLocked(DockboardFadeState *state) {
    state->opaqueFrames = 0;
    if (!restoreAlphaLocked(state))
        return false; // Keep the last state->preview visible and ownership retryable on API
                      // failure.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    restoreMaskLocked(state);
    removePreviewLocked(state);
    [CATransaction commit];
    return true;
}
static void failLocked(DockboardFadeState *state, unsigned line) {
    atomic_store(&DockboardFadeFailureLine, line);
    atomic_store(&DockboardFadeFailureWindow, state->heldWindow);
    atomic_store(&GenieCrossfadeV24Enabled, 0);
    restoreLocked(state);
}
bool GenieCrossfadeV24SetEnabled(bool value) {
    if (GenieCrossfadeV24Status != 1 || ![NSThread isMainThread])
        return false;
    [fadeLock lock];
    atomic_store(&GenieCrossfadeV24Enabled, 0);
    bool ready = !value || *v5Status == 1;
    for (DockboardFadeState *state in states.objectEnumerator) {
        if (!restoreLocked(state))
            ready = false;
        if (!value && !state->heldWindow) {
            state->cachedImage = nil;
            state->cachedTile = nil;
            state->cachedWindow = 0;
        }
    }
    if (ready && value)
        atomic_store(&GenieCrossfadeV24Enabled, 1);
    [fadeLock unlock];
    return ready;
}
static CALayer *nativeImageLayer(id layer) {
    id image = layer ? imageLayerGetter(layer, sel_registerName("imageLayer")) : nil;
    return [image isKindOfClass:CALayer.class] ? image : nil;
}
static bool thumbnailGeometryMatches(CGRect native, CGRect endpoint) {
    return validRect(native) && validRect(endpoint) &&
           fabs(native.origin.x - endpoint.origin.x) <= .25 &&
           fabs(native.origin.y - endpoint.origin.y) <= .25 &&
           fabs(native.size.width - endpoint.size.width) <= .25 &&
           fabs(native.size.height - endpoint.size.height) <= .25;
}
bool DockboardMinimizePreviewReady(id tile) {
    [fadeLock lock];
    DockboardFadeState *state = [states objectForKey:tile];
    bool ready = atomic_load(&GenieCrossfadeV24Enabled) && state && state->heldWindow &&
                 state->heldClosing && state->opaqueFrames >= 2 && state->preview &&
                 state->preview.superlayer == state->retainedRoot && state->retainedImage;
    [fadeLock unlock];
    return ready;
}
static void apply(id tile, bool starting) {
    uint32_t wid = windowID(tile);
    [fadeLock lock];
    DockboardFadeState *state = stateForTile(tile);
    if (!atomic_load(&GenieCrossfadeV24Enabled) || !wid || state->heldWindow != wid ||
        (atomic_load(selectedWindow) != UINT32_MAX && wid != atomic_load(selectedWindow)) ||
        *v5Status != 1) {
        if (state->heldWindow &&
            (atomic_load(selectedWindow) != UINT32_MAX &&
             state->heldWindow != atomic_load(selectedWindow)) &&
            !restoreLocked(state))
            atomic_store(&GenieCrossfadeV24Enabled, 0);
        [fadeLock unlock];
        return;
    }
    const char *bytes = (__bridge const void *)tile;
    if (!bytes[animateOffset] ||
        (!starting && !(bytes[minimizingOffset] || bytes[maximizingOffset]))) {
        [fadeLock unlock];
        return;
    }
    double elapsed = 0;
    bool restoring = !state->heldClosing;
    IPadWindowSpringState spring;
    if (!compositionElapsed(wid, &elapsed) ||
        !IPadWindowSpringAtTime(elapsed, restoring ? .384 : .375, restoring ? .85 : 1.1, &spring)) {
        atomic_fetch_add(&GenieCrossfadeV24Errors, 1);
        failLocked(state, __LINE__);
        [fadeLock unlock];
        return;
    }
    CALayer *tileLayer = object_getIvar(tile, layerIvar),
            *root = tileLayer ? rootForTile(tile, tileLayer) : nil;
    CGRect fullFrame;
    if (!tileLayer || ![tileLayer isKindOfClass:objc_getClass("DOCKTileLayer")] || !root ||
        !NativeDockThumbnailFrame(tile, &fullFrame) || !validRect(fullFrame)) {
        // Begin can precede native parent/layout attachment. No alpha reduction until ready.
        if (starting && !state->preview) {
            atomic_fetch_add(&GenieCrossfadeV24ImageWaits, 1);
            [fadeLock unlock];
            return;
        }
        atomic_fetch_add(&GenieCrossfadeV24Errors, 1);
        failLocked(state, __LINE__);
        [fadeLock unlock];
        return;
    }
    if (state->retainedRoot && state->retainedRoot != root) {
        atomic_fetch_add(&GenieCrossfadeV24Errors, 1);
        failLocked(state, __LINE__);
        [fadeLock unlock];
        return;
    }
    CALayer *image = nativeImageLayer(tileLayer);

    if (!state->retainedImage) {
        if (!writeAlpha(state, state->originalAlpha))
            failLocked(state, __LINE__);
        atomic_fetch_add(&GenieCrossfadeV24ImageWaits, 1);
        [fadeLock unlock];
        return;
    }
    CGRect imageFrame =
        computeLayout(tileLayer, sel_registerName("_computeLayoutFrameFromBounds:"),
                      CGRectMake(0, 0, fullFrame.size.width, fullFrame.size.height));
    CALayer *mask = object_getIvar(tile, maskIvar);
    if (!validRect(imageFrame) || !mask) {
        atomic_fetch_add(&GenieCrossfadeV24Errors, 1);
        failLocked(state, __LINE__);
        [fadeLock unlock];
        return;
    }
    SBMotionRect window, target, canonicalWindow, canonicalTarget;
    IPadWindowDockEdge edge;
    memcpy(&window, bytes + windowOffset, sizeof(window));
    IPadWindowPhysicsState physics;
    IPadWindowProjection projection;
    CGRect movingRoot;
    if (!NativeDockTargetRead(tile, restoring, &target, &edge) ||
        !IPadWindowCanonicalRect(window, edge, &canonicalWindow) ||
        !IPadWindowCanonicalRect(target, edge, &canonicalTarget) ||
        !IPadWindowPhysicsV2AtTime(canonicalWindow, canonicalTarget, elapsed, restoring,
                                   &physics) ||
        !IPadWindowProjectionForState(canonicalWindow, canonicalTarget, &physics, &projection)) {
        atomic_fetch_add(&GenieCrossfadeV24Errors, 1);
        failLocked(state, __LINE__);
        [fadeLock unlock];
        return;
    }
    // Native accessory uses parent position/scale and aspect-fit, independently of the app mesh.
    double fit = fmin(projection.viewWidth / canonicalTarget.width,
                      projection.viewHeight / canonicalTarget.height) *
                 projection.scale;
    double width = canonicalTarget.width * fit, height = canonicalTarget.height * fit;
    double x = projection.centerX, y = projection.centerY;
    if (edge == IPadWindowDockLeft) {
        double old = x;
        x = -y;
        y = old;
        double w = width;
        width = height;
        height = w;
    } else if (edge == IPadWindowDockRight) {
        double old = x;
        x = y;
        y = -old;
        double w = width;
        width = height;
        height = w;
    }
    if (!rootRect(tile, CGRectMake(x - width / 2, y - height / 2, width, height), &movingRoot)) {
        atomic_fetch_add(&GenieCrossfadeV24Errors, 1);
        failLocked(state, __LINE__);
        [fadeLock unlock];
        return;
    }
    CGRect targetRoot;
    RetainedPreviewPlacement placement;
    if (!rootRect(tile, CGRectMake(target.x, target.y, target.width, target.height), &targetRoot) ||
        !RetainedPreviewPlace(fullFrame, targetRoot, movingRoot, &placement)) {
        failLocked(state, __LINE__);
        [fadeLock unlock];
        return;
    }
    CGRect ownExtent = CGRectMake(placement.position.x, placement.position.y,
                                  fullFrame.size.width * placement.scale.width,
                                  fullFrame.size.height * placement.scale.height);
    SBMotionVertex globalGrid[289], rootGrid[289];
    CGRect originRoot, xRoot, yRoot;
    if (!IPadWindowWarpGridV2(window, target, elapsed, restoring, edge, globalGrid, NULL) ||
        !rootRect(tile, CGRectMake(0, 0, 1, 1), &originRoot) ||
        !rootRect(tile, CGRectMake(1, 0, 1, 1), &xRoot) ||
        !rootRect(tile, CGRectMake(0, 1, 1, 1), &yRoot)) {
        failLocked(state, __LINE__);
        [fadeLock unlock];
        return;
    }
    bool flipX = xRoot.origin.x < originRoot.origin.x, flipY = yRoot.origin.y < originRoot.origin.y;
    for (unsigned r = 0; r < 17; r++)
        for (unsigned c = 0; c < 17; c++) {
            SBMotionVertex vertex = globalGrid[(flipY ? 16 - r : r) * 17 + (flipX ? 16 - c : c)];
            CGRect converted;
            if (!rootRect(tile,
                          CGRectMake(vertex.destinationX - .5, vertex.destinationY - .5, 1, 1),
                          &converted)) {
                failLocked(state, __LINE__);
                [fadeLock unlock];
                return;
            }
            rootGrid[r * 17 + c] = (SBMotionVertex){c / 16., r / 16., CGRectGetMidX(converted),
                                                    CGRectGetMidY(converted)};
        }
    CGRect endpointImage = CGRectOffset(imageFrame, fullFrame.origin.x, fullFrame.origin.y);
    CGRect movingImage =
        CGRectMake(placement.position.x + imageFrame.origin.x * placement.scale.width,
                   placement.position.y + imageFrame.origin.y * placement.scale.height,
                   imageFrame.size.width * placement.scale.width,
                   imageFrame.size.height * placement.scale.height);
    ThumbnailMeshVertex vertices[289];
    id mesh = ThumbnailWarpVertices(endpointImage, targetRoot, movingImage, rootGrid, vertices)
                  ? ThumbnailWarpTransform(vertices)
                  : nil;
    if (!mesh) {
        failLocked(state, __LINE__);
        [fadeLock unlock];
        return;
    }
    // Do not fade the source into a root mask or known clipped moving representation.
    if (root.mask || root.hidden || !validRect(ownExtent) ||
        (root.masksToBounds &&
         (!validRect(root.bounds) || !CGRectContainsRect(root.bounds, ownExtent)))) {
        atomic_fetch_add(&GenieCrossfadeV24Errors, 1);
        failLocked(state, __LINE__);
        [fadeLock unlock];
        return;
    }
    SBCrossfade fade;
    if (!SBDirectionalCrossfade(restoring ? spring.progress : 1 - spring.progress, restoring,
                                &fade)) {
        failLocked(state, __LINE__);
        [fadeLock unlock];
        return;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (state->savedMask != mask) {
        restoreMaskLocked(state);
        state->savedMask = mask;
        state->originalMaskOpacity = mask.opacity;
    }
    // Blend into the actual native layer before endMinMax removes our state->preview.
    double handoff = 0;
    // Native image bounds still expand during the tile insertion; do not blend mismatched canvases.
    CGRect nativeFrame = image ? [image convertRect:image.bounds toLayer:root] : CGRectZero;
    if (!restoring && image.contents == state->retainedImage && !image.hidden &&
        thumbnailGeometryMatches(nativeFrame, endpointImage)) {
        double t = fmax(0, fmin(1, (elapsed - .90) / .25));
        handoff = t * t * (3 - 2 * t);
    }
    // An opaque base avoids the source-over opacity dip from fading both layers.
    mask.opacity = handoff > 0 ? 1 : 0;
    if (!state->preview) {
        state->preview = [DockboardPreviewLayer layer];
        state->previewImage = [CALayer layer];
        state->preview.name = @"GenieRetainedPreviewV23";
        state->preview.anchorPoint = CGPointZero;
        state->previewImage.anchorPoint = CGPointZero;
        state->previewImage.contents = state->retainedImage;
        state->previewImage.contentsScale = image ? image.contentsScale : 1;
        state->previewImage.contentsRect = CGRectMake(0, 0, 1, 1);
        state->previewImage.contentsGravity = kCAGravityResizeAspect;
        state->previewImage.minificationFilter = image ? image.minificationFilter : kCAFilterLinear;
        state->previewImage.magnificationFilter =
            image ? image.magnificationFilter : kCAFilterLinear;
        [state->preview addSublayer:state->previewImage];
        state->preview.zPosition = tileLayer.zPosition;
        [root insertSublayer:state->preview above:tileLayer];
        state->retainedRoot = root;
        atomic_fetch_add(&GenieCrossfadeV24PreviewCreates, 1);
    }
    state->preview.bounds = CGRectMake(0, 0, fullFrame.size.width, fullFrame.size.height);
    state->preview.position = placement.position;
    state->preview.transform =
        CATransform3DMakeScale(placement.scale.width, placement.scale.height, 1);
    double rasterScale = displayScaleForTarget(target);
    state->preview.rasterizationScale = rasterScale;
    state->previewImage.rasterizationScale = rasterScale;
    state->previewImage.contentsScale = rasterScale;
    state->previewImage.frame = imageFrame;
    ((void (*)(id, SEL, id))objc_msgSend)(state->previewImage,
                                          sel_registerName("setMeshTransform:"), mesh);
    state->preview.opacity = fade.thumbnail * (1 - handoff);
    [CATransaction commit];
    if (!writeAlpha(state, state->originalAlpha * fade.window)) {
        failLocked(state, __LINE__);
        [fadeLock unlock];
        return;
    }
    // Require successive successful frames; never acknowledge on a timer or failed alpha write.
    state->opaqueFrames = !starting && !restoring && fade.window == 0 && fade.thumbnail == 1
                              ? MIN(state->opaqueFrames + 1, 2u)
                              : 0;
    atomic_fetch_add(&GenieCrossfadeV24Frames, 1);
    [fadeLock unlock];
}
static void (*previousDraw)(id, SEL, id);
static void (*previousSetImage)(id, SEL, id, NSInteger);
static _Thread_local void *drawingTile;
static void drawNative(id tile, SEL selector, id parent) {
    void *saved = drawingTile;
    drawingTile = (__bridge void *)tile;
    @try {
        previousDraw(tile, selector, parent);
    } @finally {
        drawingTile = saved;
    }
}
static void receiveNativeImage(id tile, SEL selector, id image, NSInteger style) {
    // A redraw after acknowledgement may capture an already hidden source window.
    [fadeLock lock];
    DockboardFadeState *held = [states objectForKey:tile];
    if (atomic_load(&GenieCrossfadeV24Enabled) && held && held->heldClosing &&
        held->heldWindow == windowID(tile) && held->retainedImage)
        image = held->retainedImage;
    [fadeLock unlock];
    if (drawingTile == (__bridge void *)tile && atomic_load(&GenieCrossfadeV24Enabled) &&
        (!atomic_load(&GenieCrossfadeV24TestWindow) ||
         windowID(tile) == atomic_load(&GenieCrossfadeV24TestWindow)) &&
        usableImage(image) && visibleRawImage((__bridge CGImageRef)image)) {
        [fadeLock lock];
        DockboardFadeState *state = stateForTile(tile);
        state->cachedImage = image;
        state->cachedTile = tile;
        state->cachedWindow = windowID(tile);
        [fadeLock unlock];
    }
    previousSetImage(tile, selector, image, style);
}
static void begin(id tile, SEL selector, double duration, bool minimizing, bool animate) {
    uint32_t wid = windowID(tile);
    bool eligible = animate && wid &&
                    (!atomic_load(&GenieCrossfadeV24TestWindow) ||
                     wid == atomic_load(&GenieCrossfadeV24TestWindow)) &&
                    atomic_load(&GenieCrossfadeV24Enabled) &&
                    (atomic_load(globalEnabled) || (atomic_load(selectedWindow) == UINT32_MAX ||
                                                    wid == atomic_load(selectedWindow)));
    if (eligible) {
        [fadeLock lock];
        DockboardFadeState *state = stateForTile(tile);
        bool repeated = state->heldWindow == wid && state->heldClosing == minimizing;
        if (!repeated && !restoreLocked(state))
            atomic_store(&GenieCrossfadeV24Enabled, 0);
        if (!repeated && atomic_load(&GenieCrossfadeV24Enabled)) {
            float alpha = 0;
            int c = connection();
            if (getAlpha(c, wid, &alpha) || !isfinite(alpha) || alpha < 0 || alpha > 1) {
                atomic_fetch_add(&GenieCrossfadeV24Errors, 1);
                atomic_store(&GenieCrossfadeV24Enabled, 0);
            } else {
                state->heldWindow = wid;
                state->heldClosing = minimizing;
                state->heldConnection = c;
                state->originalAlpha = alpha;
                atomic_fetch_add(&GenieCrossfadeV24PendingWindow, 1);
                if (state->cachedTile == tile && state->cachedWindow == wid)
                    state->retainedImage = state->cachedImage;
            }
        }
        [fadeLock unlock];
    }
    previousBegin(tile, selector, duration, minimizing, animate);
    if (eligible) {
        if ((atomic_load(selectedWindow) == UINT32_MAX || wid == atomic_load(selectedWindow)))
            apply(tile, true);
        else {
            [fadeLock lock];
            DockboardFadeState *state = stateForTile(tile);
            if (!restoreLocked(state))
                atomic_store(&GenieCrossfadeV24Enabled, 0);
            [fadeLock unlock];
        }
    }
}
static void update(id tile, SEL selector) {
    if (!atomic_load(&GenieCrossfadeV24Enabled) ||
        (atomic_load(selectedWindow) != UINT32_MAX &&
         windowID(tile) != atomic_load(selectedWindow))) {
        previousUpdate(tile, selector);
        return;
    }
    // Native Dock owns the frame transaction; update tokens wait while its input lock is held.
    @try {
        previousUpdate(tile, selector);
        apply(tile, false);
        [CATransaction flush];
    } @catch (NSException *exception) {
        [fadeLock lock];
        DockboardFadeState *state = stateForTile(tile);
        failLocked(state, __LINE__);
        [fadeLock unlock];
        @throw exception;
    }
}
static void end(id tile, SEL selector) {
    uint32_t wid = windowID(tile);
    CALayer *endingPreview = nil;
    bool closing = false, owned = false;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [fadeLock lock];
    DockboardFadeState *state = stateForTile(tile);
    if (state->heldWindow == wid) {
        owned = true;
        closing = state->heldClosing;
        if (restoreAlphaLocked(state)) {
            restoreMaskLocked(state);
            endingPreview = state->preview;
            state->preview = nil;
            state->previewImage = nil;
            state->retainedRoot = nil;
            state->retainedImage = nil;
        } else
            atomic_store(&GenieCrossfadeV24Enabled,
                         0); // Preserve state->preview + baseline until explicit retry.
    }
    [fadeLock unlock];
    @try {
        previousEnd(tile, selector);
        // Native may publish its image during end; only the post-forward state determines handoff
        // readiness.
        if (owned && closing &&
            !usableImage(nativeImageLayer(object_getIvar(tile, layerIvar)).contents))
            atomic_fetch_add(&GenieCrossfadeV24HandoffMisses, 1);
    } @catch (NSException *exception) {
        atomic_fetch_add(&GenieCrossfadeV24Errors, 1);
        @throw exception;
    } @finally {
        if (owned && !closing) {
            [fadeLock lock];
            if (!state->heldWindow && state->cachedTile == tile) {
                state->cachedImage = nil;
                state->cachedTile = nil;
                state->cachedWindow = 0;
            }
            [fadeLock unlock];
        }
        if (endingPreview) {
            [endingPreview removeFromSuperlayer];
            atomic_fetch_add(&GenieCrossfadeV24PreviewRemoves, 1);
        }
        [CATransaction commit];
    }
}
static BOOL offset(Class cls, const char *name, const char *type, ptrdiff_t *out) {
    Ivar ivar = class_getInstanceVariable(cls, name);
    if (!ivar || strcmp(ivar_getTypeEncoding(ivar), type))
        return NO;
    *out = ivar_getOffset(ivar);
    return YES;
}
#ifndef SELF_TEST
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
static BOOL uuidMatches(const struct mach_header_64 *header, const unsigned char uuid[16]) {
    if (!header || header->magic != MH_MAGIC_64 || header->ncmds > 256 ||
        header->sizeofcmds < sizeof(struct load_command))
        return NO;
    const char *cursor = (const char *)(header + 1), *limit = cursor + header->sizeofcmds;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (cursor > limit - (ptrdiff_t)sizeof(struct load_command))
            return NO;
        const struct load_command *command = (const void *)cursor;
        if (command->cmdsize < sizeof(*command) || command->cmdsize > (size_t)(limit - cursor))
            return NO;
        if (command->cmd == LC_UUID && command->cmdsize >= sizeof(struct uuid_command))
            return !memcmp(((const struct uuid_command *)command)->uuid, uuid, 16);
        cursor += command->cmdsize;
    }
    return NO;
}
static BOOL bindClock(void) {
    compositionElapsed = dlsym(RTLD_DEFAULT, "GenieCompositionV8GetElapsed");
    return compositionElapsed != NULL;
}
#endif
static BOOL install(void) {
    Class cls = objc_getClass("DOCKWindowTile");
    Method b = class_getInstanceMethod(cls, sel_registerName("beginMinMax:minimizing:animate:"));
    Method u = class_getInstanceMethod(cls, sel_registerName("updateTransition"));
    Method e = class_getInstanceMethod(cls, sel_registerName("endMinMax"));
    maskIvar = class_getInstanceVariable(cls, "_mask");
    layerIvar = class_getInstanceVariable(cls, "_layer");
    storedImageIvar = class_getInstanceVariable(cls, "_storedLayerImage");
    Method imageMethod =
        class_getInstanceMethod(objc_getClass("DOCKTileLayer"), sel_registerName("imageLayer"));
    Method computeMethod = class_getInstanceMethod(
        objc_getClass("DOCKTileLayer"), sel_registerName("_computeLayoutFrameFromBounds:"));
    if (!b || !u || !e || !storedImageIvar || strcmp(ivar_getTypeEncoding(storedImageIvar), "@") ||
        !imageMethod || strcmp(method_getTypeEncoding(imageMethod), "@16@0:8") || !computeMethod ||
        strcmp(method_getTypeEncoding(computeMethod),
               "{CGRect={CGPoint=dd}{CGSize=dd}}48@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16") ||
        !NativeDockTargetInit(cls) || strcmp(method_getTypeEncoding(b), "v32@0:8d16B24B28") ||
        strcmp(method_getTypeEncoding(u), "v16@0:8") ||
        strcmp(method_getTypeEncoding(e), "v16@0:8") || !maskIvar ||
        strcmp(ivar_getTypeEncoding(maskIvar), "@\"CALayer\"") || !layerIvar ||
        strcmp(ivar_getTypeEncoding(layerIvar), "@\"DOCKTileLayer\"") || !captureWindow ||
        !getAlpha || !setAlpha || !connection || !selectedWindow || !globalEnabled || !v5Status ||
        *v5Status != 1 ||
        !offset(cls, "_windowRect",
                "{CGRect=\"origin\"{CGPoint=\"x\"d\"y\"d}\"size\"{CGSize=\"width\"d\"height\"d}}",
                &windowOffset) ||
        !offset(cls, "_wid", "I", &widOffset) ||
        !offset(cls, "_minimizing", "B", &minimizingOffset) ||
        !offset(cls, "_maximizing", "B", &maximizingOffset) ||
        !offset(cls, "_animateWindow", "B", &animateOffset))
        return NO;
#ifndef SELF_TEST
    if (!bindClock())
        return NO;
#endif
    if (!compositionElapsed ||
        ![CALayer instancesRespondToSelector:sel_registerName("setMeshTransform:")])
        return NO;
    computeLayout = (void *)method_getImplementation(computeMethod);
    imageLayerGetter = (void *)method_getImplementation(imageMethod);
    Method draw = class_getInstanceMethod(cls, sel_registerName("_drawWithParentTile:"));
    Method setImage = class_getInstanceMethod(
        objc_getClass("Tile"), sel_registerName("setImage:preferredGlassBackgroundStyle:"));
    if (!draw || !setImage || strcmp(method_getTypeEncoding(draw), "v24@0:8@16") ||
        strcmp(method_getTypeEncoding(setImage), "v32@0:8@16q24"))
        return NO;
    fadeLock = [NSLock new];
    states = [NSMapTable weakToStrongObjectsMapTable];
    previousDraw = (void *)method_setImplementation(draw, (IMP)drawNative);
    previousSetImage = (void *)method_setImplementation(setImage, (IMP)receiveNativeImage);
    previousBegin = (void *)method_setImplementation(b, (IMP)begin);
    previousUpdate = (void *)method_setImplementation(u, (IMP)update);
    previousEnd = (void *)method_setImplementation(e, (IMP)end);
    return YES;
}
#ifndef SELF_TEST
__attribute__((constructor)) static void load(void) {
    if (strcmp(getprogname(), "Dock"))
        return;
    char build[64];
    size_t size = sizeof(build);
    const unsigned char uuid[16] = {0xc5, 0x39, 0x75, 0xb1, 0x29, 0x56, 0x3e, 0xd4,
                                    0xb6, 0x99, 0xd4, 0xce, 0x2e, 0x6a, 0x60, 0x2c};
    if (sysctlbyname("kern.osversion", build, &size, NULL, 0) || strcmp(build, "26B123") ||
        !uuidMatches((const void *)_dyld_get_image_header(0), uuid)) {
        GenieCrossfadeV24Status = -1;
        return;
    }
    captureWindow = dlsym(RTLD_DEFAULT, "CGSCaptureWindowsContentsToRectWithOptions");
    getAlpha = dlsym(RTLD_DEFAULT, "SLSGetWindowAlpha");
    setAlpha = dlsym(RTLD_DEFAULT, "SLSSetWindowAlpha");
    connection = dlsym(RTLD_DEFAULT, "SLSMainConnectionID");
    selectedWindow = dlsym(RTLD_DEFAULT, "GenieSpringBoardV5Window");
    globalEnabled = dlsym(RTLD_DEFAULT, "GenieSpringBoardGlobalEnabled");
    v5Status = dlsym(RTLD_DEFAULT, "GenieSpringBoardV5Status");
    GenieCrossfadeV24Status = install() ? 1 : -2;
}
#endif
