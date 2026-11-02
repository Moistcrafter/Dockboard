#define SELF_TEST 1
#include "../src/runtime/Crossfade.m"
#include <assert.h>
static _Atomic uint32_t mockSelected;
static _Atomic int mockGlobal = 1;
static int mockStatus = 1, setFailures, writes;
static float alphas[2] = {.7f, .4f};
static double mockElapsed;
static bool nativeConsume, nestedUpdate, publishAtEnd, throwEnd;
static bool throwUpdate;
@interface DOCKTileLayer : CALayer
@property(strong) CALayer *mockImage;
- (id)imageLayer;
- (CGSize)size;
- (CGRect)_computeLayoutFrameFromBounds:(CGRect)bounds;
@end
@implementation DOCKTileLayer
- (id)imageLayer {
    return self.mockImage;
}
- (CGSize)size {
    return self.bounds.size;
}
- (CGRect)_computeLayoutFrameFromBounds:(CGRect)b {
    return CGRectInset(b, 1, 1);
}
@end
@interface Tile : NSObject
- (void)setImage:(id)image preferredGlassBackgroundStyle:(NSInteger)style;
@end
@implementation Tile
- (void)setImage:(id)image preferredGlassBackgroundStyle:(NSInteger)style {
    (void)image;
    (void)style;
}
@end
@interface DOCKWindowTile : Tile {
  @public
    CGRect _windowRect;
    uint32_t _wid;
    float _transformNow;
    bool _minimizing, _maximizing, _animateWindow;
    CALayer *_mask;
    DOCKTileLayer *_layer;
    id _storedLayerImage;
    CALayer *_root;
    CGRect _nativeFrame, _nativeBounds;
    CGPoint _nativePosition;
    id _expectedNativeImage;
}
- (void)_drawWithParentTile:(id)parent;
- (void)beginMinMax:(double)duration minimizing:(bool)minimizing animate:(bool)animate;
- (void)updateTransition;
- (void)endMinMax;
@end
@implementation DOCKWindowTile
- (void)_drawWithParentTile:(id)parent {
    [self setImage:parent preferredGlassBackgroundStyle:0];
}
- (void)beginMinMax:(double)duration minimizing:(bool)minimizing animate:(bool)animate {
    assert(duration == 1200 || duration == 850);
    _minimizing = minimizing;
    _maximizing = !minimizing;
    _animateWindow = animate;
    _transformNow = minimizing ? 0 : 1;
    _mask = [CALayer layer];
    _mask.opacity = 0;
    _layer.mask = _mask;
    _storedLayerImage = _layer.mockImage.contents;
    _layer.mockImage.contents = nil;
    _expectedNativeImage = nil;
    _nativeFrame = _layer.frame;
    _nativeBounds = _layer.bounds;
    _nativePosition = _layer.position;
    if (animate) {
        atomic_store(&mockSelected, _wid);
        mockElapsed = 0;
    }
    if (nestedUpdate)
        [self updateTransition];
}
- (void)updateTransition {
    if (throwUpdate)
        @throw [NSException exceptionWithName:@"MockUpdateThrow" reason:@"test" userInfo:nil];
    assert(CGRectEqualToRect(_layer.frame, _nativeFrame) &&
           CGRectEqualToRect(_layer.bounds, _nativeBounds) &&
           CGPointEqualToPoint(_layer.position, _nativePosition));
    assert(_layer.mockImage.contents == _expectedNativeImage);
    if (nativeConsume && _storedLayerImage) {
        _layer.mockImage.contents = _storedLayerImage;
        _expectedNativeImage = _storedLayerImage;
        _storedLayerImage = nil;
    }
    // Native partial geometry is intentionally stable and MUST remain native-owned.
    _mask.opacity = 0;
}
- (void)endMinMax {
    assert(CGRectEqualToRect(_layer.frame, _nativeFrame) &&
           CGRectEqualToRect(_layer.bounds, _nativeBounds));
    assert(alphas[_wid - 42] == (_wid == 42 ? .7f : .4f));
    if (publishAtEnd && _storedLayerImage) {
        _layer.mockImage.contents = _storedLayerImage;
        _expectedNativeImage = _storedLayerImage;
        _storedLayerImage = nil;
    }
    if (throwEnd)
        @throw [NSException exceptionWithName:@"MockEndThrow" reason:@"test" userInfo:nil];
    _layer.mask = nil;
    _mask = nil;
    _minimizing = false;
    _maximizing = false;
}
@end
static bool NativeDockTargetInit(Class cls) { return cls == DOCKWindowTile.class; }
static bool NativeDockThumbnailFrame(id tile, CGRect *out) {
    (void)tile;
    *out = CGRectMake(20, 30, 48, 48);
    return true;
}
static bool rootRect(id tile, CGRect global, CGRect *out) {
    (void)tile;
    *out = global;
    return validRect(global);
}
static bool NativeDockTargetRead(id tile, bool restoring, SBMotionRect *out,
                                 IPadWindowDockEdge *edge) {
    (void)tile;
    (void)restoring;
    *out = (SBMotionRect){21, 31, 46, 46};
    *edge = IPadWindowDockLeft;
    return true;
}
static CALayer *rootForTile(id tile, CALayer *layer) {
    CALayer *root = ((DOCKWindowTile *)tile)->_root;
    return layer.superlayer == root ? root : nil;
}
static int mockConnection(void) { return 7; }
static int mockGet(int c, uint32_t wid, float *out) {
    assert(c == 7 && wid >= 42 && wid <= 43);
    *out = alphas[wid - 42];
    return 0;
}
static int mockSet(int c, uint32_t wid, float value) {
    assert(c == 7 && wid >= 42 && wid <= 43);
    writes++;
    if (setFailures) {
        setFailures--;
        return 1;
    }
    assert(isfinite(value) && value >= 0 && value <= 1);
    alphas[wid - 42] = value;
    return 0;
}
static bool mockClock(uint32_t wid, double *out) {
    assert(atomic_load(&mockSelected) == UINT32_MAX || wid == atomic_load(&mockSelected));
    *out = mockElapsed;
    return true;
}
static id image(void) {
    uint32_t pixel = 0xff2456aa;
    CGColorSpaceRef colors = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(&pixel, 1, 1, 8, 4, colors,
                                                 (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGImageRef cg = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    CGColorSpaceRelease(colors);
    return CFBridgingRelease(cg);
}
static DOCKWindowTile *tile(uint32_t wid) {
    DOCKWindowTile *t = [DOCKWindowTile new];
    t->_windowRect = CGRectMake(150, 788, 660, 452);
    t->_wid = wid;
    t->_root = [CALayer layer];
    t->_layer = [DOCKTileLayer layer];
    t->_layer.frame = CGRectMake(4, 5, 37, 0);
    t->_layer.mockImage = [CALayer layer];
    [t->_root addSublayer:t->_layer];
    t->_layer.mockImage.contents = image();
    return t;
}
static void finish(DOCKWindowTile *t) {
    t->_minimizing = false;
    t->_maximizing = false;
    [t endMinMax];
    DockboardFadeState *state = stateForTile(t);
    assert(!state->heldWindow && !state->preview && !state->retainedImage);
}

static unsigned captures;
static bool captureFails, blankCapture;
static id alphaImage(bool opaque) {
    unsigned char pixels[9] = {0};
    if (opaque)
        pixels[8] = 255;
    CGContextRef c =
        CGBitmapContextCreate(pixels, 3, 3, 8, 3, NULL, (CGBitmapInfo)kCGImageAlphaOnly);
    assert(c);
    CGImageRef i = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    return CFBridgingRelease(i);
}
static CGError mockCapture(int c, const uint32_t *wid, int n, uint32_t options, CGImageRef *out,
                           CGRect rect) {
    assert(c == 7 && *wid == 42 && n == 1 && options == 0 && CGRectIsNull(rect));
    captures++;
    if (captureFails)
        return 1;
    *out = CGImageRetain((__bridge CGImageRef)(blankCapture ? alphaImage(false) : image()));
    return 0;
}
static void previewInputCheck(void) {
    CALayer *root = [CALayer layer], *tile = [CALayer layer], *content = [CALayer layer];
    root.frame = tile.frame = content.frame = CGRectMake(0, 0, 200, 200);
    CALayer *decoration = [CALayer layer];
    decoration.frame = root.bounds;
    [root addSublayer:tile];
    [root addSublayer:decoration];
    [decoration addSublayer:content];
    CGPoint point = CGPointMake(100, 100);
    assert([root hitTest:point] == content);
    [decoration removeFromSuperlayer];
    decoration = [DockboardPreviewLayer layer];
    decoration.frame = root.bounds;
    [decoration addSublayer:content];
    [root addSublayer:decoration];
    for (NSNumber *opacity in @[ @1, @0.5, @0 ]) {
        decoration.opacity = opacity.floatValue;
        assert([root hitTest:point] == tile);
    }
}
int main(void) {
    @autoreleasepool {
        previewInputCheck();
        selectedWindow = &mockSelected;
        globalEnabled = &mockGlobal;
        v5Status = &mockStatus;
        getAlpha = mockGet;
        setAlpha = mockSet;
        connection = mockConnection;
        compositionElapsed = mockClock;
        captureWindow = mockCapture;
        assert(install());
        GenieCrossfadeV24Status = 1;
        DOCKWindowTile *a = tile(42);
        DockboardFadeState *state = stateForTile(a);
        assert(GenieCrossfadeV24SetEnabled(true));
        id fresh = image();
        [a setImage:fresh preferredGlassBackgroundStyle:0];
        assert(!state->cachedImage);
        [a _drawWithParentTile:fresh];
        assert(state->cachedImage == fresh && state->cachedTile == a);
        [a beginMinMax:1200 minimizing:YES animate:YES];
        assert([state->preview isKindOfClass:DockboardPreviewLayer.class] &&
               state->retainedImage == fresh && captures == 0);
        mockElapsed = .2;
        [a updateTransition];
        assert(state->previewImage.rasterizationScale == 2 &&
               state->previewImage.contentsScale == 2 && state->preview.rasterizationScale == 2);
        a->_layer.mockImage.contents = fresh;
        a->_expectedNativeImage = fresh;
        [a->_root addSublayer:a->_layer.mockImage];
        a->_layer.mockImage.frame = CGRectMake(21, 35, 46, 38);
        mockElapsed = 1.025;
        [a updateTransition];
        assert(a->_mask.opacity == 0 && state->preview.opacity > .999);
        a->_layer.mockImage.frame = CGRectMake(21, 31, 46, 46);
        mockElapsed = 1.025;
        [a updateTransition];
        assert(a->_mask.opacity == 1 && fabs(state->preview.opacity - .5) < 1e-5);
        for (unsigned i = 0; i <= 50; i++) {
            mockElapsed = .90 + i * .005;
            [a updateTransition];
            double combined =
                state->preview.opacity + (1 - state->preview.opacity) * a->_mask.opacity;
            assert(fabs(combined - 1) < 1e-6);
        }
        mockElapsed = 1.15;
        [a updateTransition];
        assert(a->_mask.opacity == 1 && state->preview.opacity == 0);
        finish(a);
        assert(state->cachedImage == fresh);
        [a beginMinMax:1200 minimizing:NO animate:YES];
        assert(state->preview && state->retainedImage == fresh);
        CALayer *samePreview = state->preview;
        float baseline = state->originalAlpha;
        [a beginMinMax:1200 minimizing:NO animate:YES];
        assert(state->preview == samePreview && state->originalAlpha == baseline &&
               state->retainedImage == fresh);
        finish(a);
        assert(!state->cachedImage);
        [a _drawWithParentTile:alphaImage(false)];
        assert(!state->cachedImage);
        [a beginMinMax:1200 minimizing:YES animate:YES];
        assert(!state->preview && alphas[0] == .7f);
        finish(a);
        [a _drawWithParentTile:fresh];
        [a beginMinMax:1200 minimizing:YES animate:YES];
        throwUpdate = true;
        bool caught = false;
        @try {
            [a updateTransition];
        } @catch (NSException *e) {
            caught = [e.name isEqualToString:@"MockUpdateThrow"];
        }
        throwUpdate = false;
        assert(caught && !state->preview && alphas[0] == .7f);
        finish(a);
        assert(GenieCrossfadeV24SetEnabled(true));
        [a _drawWithParentTile:fresh];
        [a beginMinMax:1200 minimizing:YES animate:YES];
        [a updateTransition];
        assert(state->preview && atomic_load(&GenieCrossfadeV24Enabled));
        finish(a);
        assert(GenieCrossfadeV24SetEnabled(false));
        assert(!state->cachedImage && !drawingTile);
        assert(GenieCrossfadeV24SetEnabled(true));
        atomic_store(&mockSelected, UINT32_MAX);
        DOCKWindowTile *b = tile(43);
        DockboardFadeState *second = stateForTile(b);
        id secondImage = image();
        [a _drawWithParentTile:fresh];
        [b _drawWithParentTile:secondImage];
        [a beginMinMax:1200 minimizing:YES animate:YES];
        [b beginMinMax:850 minimizing:NO animate:YES];
        assert(state->preview && second->preview && state->preview != second->preview);
        assert(state->retainedImage == fresh && second->retainedImage == secondImage);
        assert(atomic_load(&GenieCrossfadeV24PendingWindow) == 2);
        [a _drawWithParentTile:alphaImage(false)];
        assert(state->cachedImage == fresh && state->retainedImage == fresh);
        CALayer *firstPreview = state->preview, *secondPreview = second->preview;
        [a beginMinMax:1200 minimizing:YES animate:YES];
        assert(state->preview == firstPreview && second->preview == secondPreview);
        mockElapsed = .2;
        assert(!DockboardMinimizePreviewReady(a));
        [a updateTransition];
        assert(!DockboardMinimizePreviewReady(a));
        [a updateTransition];
        assert(DockboardMinimizePreviewReady(a));
        assert(!DockboardMinimizePreviewReady(b));
        [b updateTransition];
        // Reverse an opening window while another window is still minimizing.
        [b beginMinMax:1200 minimizing:YES animate:YES];
        assert(second->heldClosing && second->originalAlpha == .4f);
        assert(state->preview == firstPreview && atomic_load(&GenieCrossfadeV24PendingWindow) == 2);
        secondPreview = second->preview;
        [b updateTransition];
        finish(a);
        assert(!DockboardMinimizePreviewReady(a));
        assert(second->preview == secondPreview && second->heldWindow == 43);
        assert(atomic_load(&GenieCrossfadeV24PendingWindow) == 1);
        finish(b);
        assert(atomic_load(&GenieCrossfadeV24PendingWindow) == 0);
        assert(alphas[0] == .7f && alphas[1] == .4f);
        puts("V24: native draw provenance, blank rejection, retained close/restore, exception "
             "cleanup passed.");
    }
    return 0;
}
