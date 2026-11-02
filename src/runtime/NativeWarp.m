#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <math.h>
#include <stdatomic.h>
#ifndef SELF_TEST
#include <mach-o/dyld.h>
#include <ptrauth.h>
#endif

static void (*previousUpdate)(id, SEL);
static NSInteger (*previousEffect)(id, SEL);
static _Atomic uint32_t *selectedWindow;
static _Atomic int *compositionEnabled;
static int *compositionStatus;
static ptrdiff_t widOffset, animateOffset, minimizingOffset, maximizingOffset, progressOffset,
    transformerOffset;
static uintptr_t expectedCaller;
static _Thread_local bool suppressNative;
_Atomic int DockboardNativeWarpEnabled;
_Atomic unsigned DockboardNativeWarpSuppressed;
int DockboardNativeWarpStatus;
bool DockboardNativeWarpSetEnabled(bool enabled) {
    if (DockboardNativeWarpStatus != 1 || !compositionStatus || *compositionStatus != 1 ||
        (enabled && !atomic_load(compositionEnabled)))
        return false;
    atomic_store(&DockboardNativeWarpEnabled, enabled);
    return true;
}
#ifdef SELF_TEST
static uintptr_t syntheticCaller;
#endif
static NSInteger effect(id bar, SEL selector) {
#ifdef SELF_TEST
    uintptr_t caller = syntheticCaller;
#else
    uintptr_t caller =
        (uintptr_t)ptrauth_strip(__builtin_return_address(0), ptrauth_key_return_address);
#endif
    // Only the transformer dispatch skips native geometry; all other preference reads are native.
    if (suppressNative && caller == expectedCaller) {
        atomic_fetch_add(&DockboardNativeWarpSuppressed, 1);
        return 0;
    }
    return previousEffect(bar, selector);
}
static void update(id tile, SEL selector) {
    char *bytes = (__bridge void *)tile;
    uint32_t wid;
    float progress;
    memcpy(&wid, bytes + widOffset, sizeof(wid));
    memcpy(&progress, bytes + progressOffset, sizeof(progress));
    bool eligible =
        atomic_load(&DockboardNativeWarpEnabled) && atomic_load(compositionEnabled) &&
        *compositionStatus == 1 && wid &&
        (atomic_load(selectedWindow) == UINT32_MAX || wid == atomic_load(selectedWindow)) &&
        bytes[animateOffset] && (bytes[minimizingOffset] || bytes[maximizingOffset]) &&
        isfinite(progress);
    bool outer = suppressNative;
    unsigned char tiny = bytes[transformerOffset + 16];
    suppressNative = eligible;
    if (eligible) {
        // Keep Scale's endpoint publication; tiny-window dispatch otherwise forces native Scale.
        float tileBuild = (cosf(progress * 3.1416f) * -.5f + .5f) < 1 ? 0 : 1;
        memcpy(bytes + transformerOffset, &tileBuild, sizeof(tileBuild));
        bytes[transformerOffset + 16] = 0;
    }
    @try {
        previousUpdate(tile, selector);
    } @finally {
        if (eligible)
            bytes[transformerOffset + 16] = tiny;
        suppressNative = outer;
    }
}
static bool offset(Class cls, const char *name, const char *type, size_t size, ptrdiff_t *out) {
    Ivar ivar = class_getInstanceVariable(cls, name);
    if (!ivar || strcmp(ivar_getTypeEncoding(ivar), type))
        return false;
    *out = ivar_getOffset(ivar);
    return *out > 0 && (size_t)*out + size <= class_getInstanceSize(cls);
}
static bool install(void) {
    Class cls = objc_getClass("DOCKWindowTile");
    Method u = class_getInstanceMethod(cls, sel_registerName("updateTransition"));
    Method e =
        class_getInstanceMethod(objc_getClass("DockBar"), sel_registerName("minimizeEffect"));
    if (!u || !e || strcmp(method_getTypeEncoding(u), "v16@0:8") ||
        strcmp(method_getTypeEncoding(e), "q16@0:8") || !selectedWindow || !compositionEnabled ||
        !compositionStatus || *compositionStatus != 1 || !expectedCaller ||
        !offset(cls, "_wid", "I", 4, &widOffset) ||
        !offset(cls, "_animateWindow", "B", 1, &animateOffset) ||
        !offset(cls, "_minimizing", "B", 1, &minimizingOffset) ||
        !offset(cls, "_maximizing", "B", 1, &maximizingOffset) ||
        !offset(cls, "_transformNow", "f", 4, &progressOffset) ||
        !offset(cls, "_transformer", "{Transformer=\"tileBuild\"f\"direction\"q\"tinyWindow\"B}",
                24, &transformerOffset))
        return false;
    previousEffect = (void *)method_setImplementation(e, (IMP)effect);
    previousUpdate = (void *)method_setImplementation(u, (IMP)update);
    return true;
}
#ifndef SELF_TEST
__attribute__((constructor)) static void load(void) {
    if (strcmp(getprogname(), "Dock"))
        return;
    // Composition validates the exact Dock build and UUID before exposing status 1.
    compositionStatus = dlsym(RTLD_DEFAULT, "GenieCompositionV8Status");
    compositionEnabled = dlsym(RTLD_DEFAULT, "GenieCompositionV8Enabled");
    selectedWindow = dlsym(RTLD_DEFAULT, "GenieSpringBoardV5Window");
    expectedCaller = (uintptr_t)_dyld_get_image_header(0) + 0x261a0;
    DockboardNativeWarpStatus = install() ? 1 : -1;
}
#endif
