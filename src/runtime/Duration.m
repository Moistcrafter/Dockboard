#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <math.h>
#include <stdatomic.h>
#include <sys/sysctl.h>
#ifndef SELF_TEST
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <ptrauth.h>
#endif

typedef void (*MinimizeFn)(id, SEL, id, bool, float);
typedef void (*RestoreFn)(id, SEL, id, uint32_t);
typedef float (*EffectFn)(id, SEL);
static MinimizeFn previousMinimize;
static RestoreFn previousRestore;
static EffectFn previousEffect;
static Class tileClass;
static ptrdiff_t widOffset;
static SEL effectSelector;
static uintptr_t expectedGetterCaller;
static _Atomic int *globalEnabled;
static _Atomic uint32_t *selectedWindow;
static int *v5Status;
static _Atomic float minimizeMilliseconds = 1000, restoreMilliseconds = 1000;
typedef struct {
    void *bar;
    uint32_t window;
    float milliseconds;
} RestoreContext;
static _Thread_local RestoreContext restoring;
_Atomic int GenieIPadDurationEnabled, GenieIPadDurationMinimizeOverrides,
    GenieIPadDurationRestoreOverrides, GenieIPadDurationErrors;
int GenieIPadDurationStatus;

bool GenieIPadDurationSetDurations(float minimize, float restore) {
    if (GenieIPadDurationStatus != 1 || !isfinite(minimize) || !isfinite(restore) ||
        minimize < 100 || restore < 100 || minimize > 5000 || restore > 5000)
        return false;
    atomic_store(&minimizeMilliseconds, minimize);
    atomic_store(&restoreMilliseconds, restore);
    return true;
}
bool GenieIPadDurationSetEnabled(bool value) {
    if (GenieIPadDurationStatus != 1)
        return false;
    atomic_store(&GenieIPadDurationEnabled, value);
    return true;
}
static uint32_t eligibleWindow(id tile) {
    if (!atomic_load(&GenieIPadDurationEnabled) || *v5Status != 1 || !tile ||
        ![tile isKindOfClass:tileClass])
        return 0;
    uint32_t wid;
    memcpy(&wid, (const char *)(__bridge void *)tile + widOffset, sizeof(wid));
    return wid && (atomic_load(globalEnabled) || wid == atomic_load(selectedWindow)) ? wid : 0;
}
static void minimize(id self, SEL selector, id tile, bool animate, float duration) {
    if (animate && eligibleWindow(tile)) {
        float native = previousEffect(self, effectSelector);
        double adjusted = (double)atomic_load(&minimizeMilliseconds) * duration / native;
        // Preserve the native keyboard slow-motion multiplier without changing the preference.
        if (isfinite(native) && native > 0 && isfinite(duration) && duration > 0 &&
            isfinite(adjusted) && adjusted > 0 && adjusted <= 60000) {
            duration = (float)adjusted;
            atomic_fetch_add(&GenieIPadDurationMinimizeOverrides, 1);
        } else
            atomic_fetch_add(&GenieIPadDurationErrors, 1);
    }
    previousMinimize(self, selector, tile, animate, duration);
}
#ifdef SELF_TEST
static uintptr_t syntheticCaller;
static uintptr_t callerPC(void) { return syntheticCaller; }
#else
static __attribute__((always_inline)) inline uintptr_t callerPC(void) {
    return (uintptr_t)ptrauth_strip(__builtin_return_address(0), ptrauth_key_return_address);
}
#endif
static float effect(id self, SEL selector) {
    uintptr_t caller = callerPC();
    float native = previousEffect(self, selector);
    if (restoring.bar == (__bridge void *)self && restoring.window &&
        caller == expectedGetterCaller && atomic_load(&GenieIPadDurationEnabled) &&
        *v5Status == 1 &&
        (atomic_load(globalEnabled) || restoring.window == atomic_load(selectedWindow))) {
        if (isfinite(native) && native > 0) {
            atomic_fetch_add(&GenieIPadDurationRestoreOverrides, 1);
            return restoring.milliseconds;
        }
        atomic_fetch_add(&GenieIPadDurationErrors, 1);
    }
    return native;
}
static void restore(id self, SEL selector, id tile, uint32_t transaction) {
    RestoreContext outer = restoring;
    restoring = (RestoreContext){(__bridge void *)self, eligibleWindow(tile),
                                 atomic_load(&restoreMilliseconds)};
    @try {
        previousRestore(self, selector, tile, transaction);
    } @finally {
        restoring = outer;
    }
}
#ifndef SELF_TEST
static BOOL uuidMatches(const struct mach_header_64 *header) {
    static const unsigned char uuid[16] = {0xc5, 0x39, 0x75, 0xb1, 0x29, 0x56, 0x3e, 0xd4,
                                           0xb6, 0x99, 0xd4, 0xce, 0x2e, 0x6a, 0x60, 0x2c};
    if (!header || header->magic != MH_MAGIC_64 || header->ncmds > 256)
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
#endif
static BOOL install(void) {
    Class bar = objc_getClass("DockBar");
    tileClass = objc_getClass("DOCKWindowTile");
    Method m =
        class_getInstanceMethod(bar, sel_registerName("_handleMinimizeWindow:animate:duration:"));
    Method r =
        class_getInstanceMethod(bar, sel_registerName("_handleMaximizeWindow:transactionID:"));
    effectSelector = sel_registerName("effectDur");
    Method e = class_getInstanceMethod(bar, effectSelector);
    Ivar wid = class_getInstanceVariable(tileClass, "_wid");
    if (!m || !r || !e || !wid || !globalEnabled || !selectedWindow || !v5Status ||
        *v5Status != 1 || strcmp(method_getTypeEncoding(m), "v32@0:8@16B24f28") ||
        strcmp(method_getTypeEncoding(r), "v28@0:8@16I24") ||
        strcmp(method_getTypeEncoding(e), "f16@0:8") || strcmp(ivar_getTypeEncoding(wid), "I"))
        return NO;
    widOffset = ivar_getOffset(wid);
    if (widOffset <= 0 || (size_t)widOffset + sizeof(uint32_t) > class_getInstanceSize(tileClass))
        return NO;
#ifndef SELF_TEST
    uintptr_t base = (uintptr_t)_dyld_get_image_header(0);
    if ((uintptr_t)ptrauth_strip((void *)method_getImplementation(m),
                                 ptrauth_key_function_pointer) != base + 0x91e88 ||
        (uintptr_t)ptrauth_strip((void *)method_getImplementation(r),
                                 ptrauth_key_function_pointer) != base + 0x91b70 ||
        (uintptr_t)ptrauth_strip((void *)method_getImplementation(e),
                                 ptrauth_key_function_pointer) != base + 0x1b89ec)
        return NO;
    // shortcut: exact26B123 DockBar caller only; revalidate native duration construction on another
    // build.
    expectedGetterCaller = base + 0x91c50;
#endif
    previousMinimize = (MinimizeFn)method_getImplementation(m);
    previousRestore = (RestoreFn)method_getImplementation(r);
    previousEffect = (EffectFn)method_getImplementation(e);
    method_setImplementation(m, (IMP)minimize);
    method_setImplementation(r, (IMP)restore);
    method_setImplementation(e, (IMP)effect);
    return YES;
}
#ifndef SELF_TEST
__attribute__((constructor)) static void load(void) {
    if (strcmp(getprogname(), "Dock"))
        return;
    char build[64];
    size_t size = sizeof(build);
    if (sysctlbyname("kern.osversion", build, &size, NULL, 0) || strcmp(build, "26B123") ||
        !uuidMatches((const void *)_dyld_get_image_header(0))) {
        GenieIPadDurationStatus = -1;
        return;
    }
    globalEnabled = dlsym(RTLD_DEFAULT, "GenieSpringBoardGlobalEnabled");
    selectedWindow = dlsym(RTLD_DEFAULT, "GenieSpringBoardV5Window");
    v5Status = dlsym(RTLD_DEFAULT, "GenieSpringBoardV5Status");
    GenieIPadDurationStatus = install() ? 1 : -2;
}
#endif
#ifdef SELF_TEST
#include <assert.h>
@interface DOCKWindowTile : NSObject {
  @public
    uint32_t _wid;
}
@end
@implementation DOCKWindowTile
@end
@interface DurationForeign : NSObject {
  @public
    uint32_t _wid;
}
@end
@implementation DurationForeign
@end
static float nativeDuration = 500, lastMinimize, restoreValues[8], foreignGetter;
static unsigned minimizeCalls, restoreCount;
static bool throwing, nesting, inNested, wrongCaller, disableInside;
static DOCKWindowTile *otherTile;
@interface DockBar : NSObject
- (float)effectDur;
- (void)_handleMinimizeWindow:(id)tile animate:(bool)animate duration:(float)duration;
- (void)_handleMaximizeWindow:(id)tile transactionID:(uint32_t)transaction;
@end
@implementation DockBar
- (float)effectDur {
    return nativeDuration;
}
- (void)_handleMinimizeWindow:(id)tile animate:(bool)animate duration:(float)duration {
    (void)tile;
    (void)animate;
    minimizeCalls++;
    lastMinimize = duration;
    if (throwing)
        @throw [NSException exceptionWithName:@"duration-test" reason:nil userInfo:nil];
}
- (void)_handleMaximizeWindow:(id)tile transactionID:(uint32_t)transaction {
    (void)tile;
    (void)transaction;
    uintptr_t saved = syntheticCaller;
    if (wrongCaller)
        syntheticCaller = 0xdead;
    if (disableInside)
        assert(GenieIPadDurationSetEnabled(false));
    restoreValues[restoreCount++] = [self effectDur];
    syntheticCaller = saved;
    foreignGetter = [[DockBar new] effectDur];
    if (nesting && !inNested) {
        inNested = true;
        [self _handleMaximizeWindow:otherTile transactionID:2];
        inNested = false;
        restoreValues[restoreCount++] = [self effectDur];
    }
    if (throwing)
        @throw [NSException exceptionWithName:@"duration-test" reason:nil userInfo:nil];
}
@end
int main(void) {
    @autoreleasepool {
        _Atomic int mockGlobal = 0;
        _Atomic uint32_t mockSelected = 42;
        int mockStatus = 1;
        globalEnabled = &mockGlobal;
        selectedWindow = &mockSelected;
        v5Status = &mockStatus;
        assert(install());
        GenieIPadDurationStatus = 1;
        expectedGetterCaller = 0x1234;
        syntheticCaller = expectedGetterCaller;
        DOCKWindowTile *tile = [DOCKWindowTile new];
        tile->_wid = 42;
        otherTile = [DOCKWindowTile new];
        otherTile->_wid = 43;
        DurationForeign *foreign = [DurationForeign new];
        foreign->_wid = 42;
        DockBar *bar = [DockBar new];
        [bar _handleMinimizeWindow:tile animate:true duration:500];
        assert(lastMinimize == 500 && minimizeCalls == 1);
        assert(GenieIPadDurationSetDurations(1000, 1100));
        assert(!GenieIPadDurationSetDurations(NAN, 1000) &&
               !GenieIPadDurationSetDurations(99, 1000) &&
               !GenieIPadDurationSetDurations(1000, 5001));
        assert(GenieIPadDurationSetEnabled(true));
        [bar _handleMinimizeWindow:otherTile animate:true duration:500];
        assert(lastMinimize == 500);
        [bar _handleMinimizeWindow:foreign animate:true duration:500];
        assert(lastMinimize == 500);
        [bar _handleMinimizeWindow:tile animate:false duration:500];
        assert(lastMinimize == 500);
        [bar _handleMinimizeWindow:tile animate:true duration:500];
        assert(lastMinimize == 1000);
        [bar _handleMinimizeWindow:tile animate:true duration:5000];
        assert(lastMinimize == 10000);
        [bar _handleMinimizeWindow:tile animate:true duration:INFINITY];
        assert(isinf(lastMinimize) && atomic_load(&GenieIPadDurationErrors) == 1);
        [bar _handleMaximizeWindow:tile transactionID:1];
        assert(restoreValues[0] == 1100 && foreignGetter == 500 && !restoring.bar);
        restoreCount = 0;
        wrongCaller = true;
        [bar _handleMaximizeWindow:tile transactionID:1];
        wrongCaller = false;
        assert(restoreValues[0] == 500);
        restoreCount = 0;
        nesting = true;
        [bar _handleMaximizeWindow:tile transactionID:1];
        nesting = false;
        assert(restoreCount == 3 && restoreValues[0] == 1100 && restoreValues[1] == 500 &&
               restoreValues[2] == 1100 && !restoring.bar);
        restoreCount = 0;
        throwing = true;
        @try {
            [bar _handleMaximizeWindow:tile transactionID:1];
            assert(false);
        } @catch (NSException *e) {
            (void)e;
        }
        throwing = false;
        assert(!restoring.bar && [bar effectDur] == 500);
        restoreCount = 0;
        disableInside = true;
        [bar _handleMaximizeWindow:tile transactionID:1];
        disableInside = false;
        assert(restoreValues[0] == 500 && !restoring.bar &&
               !atomic_load(&GenieIPadDurationEnabled));
        assert(GenieIPadDurationSetEnabled(true));
        atomic_store(&mockGlobal, 1);
        DOCKWindowTile *zero = [DOCKWindowTile new];
        [bar _handleMinimizeWindow:zero animate:true duration:500];
        assert(lastMinimize == 500);
        [bar _handleMinimizeWindow:otherTile animate:true duration:500];
        assert(lastMinimize == 1000);
        atomic_store(&mockGlobal, 0);
        mockStatus = -1;
        [bar _handleMinimizeWindow:tile animate:true duration:500];
        assert(lastMinimize == 500);
        mockStatus = 1;
        assert(GenieIPadDurationSetEnabled(false));
        restoreCount = 0;
        [bar _handleMaximizeWindow:tile transactionID:1];
        assert(restoreValues[0] == 500 && !restoring.bar);
        assert(minimizeCalls == 10);
        puts("Duration checks passed: default off, native/foreign/nonanimated pass-through, "
             "multiplier, exact caller/self, nested TLS, exceptions, disable and invalid config.");
    }
    return 0;
}
#endif
