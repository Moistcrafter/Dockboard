#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <sys/sysctl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>

static void (*previousBegin)(id, SEL, double, bool, bool);
static bool (*selectWindow)(uint32_t), (*setShadow)(bool);
static int *v5Status;
static ptrdiff_t widOffset;
static NSLock *controlLock;
_Atomic int GenieSpringBoardGlobalEnabled, GenieSpringBoardGlobalRoutes,
    GenieSpringBoardGlobalErrors;
int GenieSpringBoardGlobalStatus;

static bool stopLocked(void) {
    atomic_store(&GenieSpringBoardGlobalEnabled, 0);
    bool windowOK = selectWindow(0), shadowOK = setShadow(false);
    return windowOK && shadowOK;
}
bool GenieSpringBoardGlobalSetEnabled(bool value) {
    if (GenieSpringBoardGlobalStatus != 1)
        return false;
    [controlLock lock];
    bool result;
    if (!value)
        result = stopLocked();
    else if (*v5Status != 1 || !setShadow(true) || !selectWindow(UINT32_MAX)) {
        atomic_fetch_add(&GenieSpringBoardGlobalErrors, 1);
        stopLocked();
        result = false;
    } else {
        atomic_store(&GenieSpringBoardGlobalEnabled, 1);
        result = true;
    }
    [controlLock unlock];
    return result;
}
static void begin(id tile, SEL selector, double duration, bool minimizing, bool animate) {
    uint32_t wid;
    const char *bytes = (__bridge const void *)tile;
    memcpy(&wid, bytes + widOffset, sizeof(wid));
    [controlLock lock];
    if (animate && wid && atomic_load(&GenieSpringBoardGlobalEnabled)) {
        atomic_fetch_add(&GenieSpringBoardGlobalRoutes, 1);
    }
    [controlLock unlock];
    previousBegin(tile, selector, duration, minimizing, animate);
}
static BOOL install(void) {
    Class cls = objc_getClass("DOCKWindowTile");
    Method method =
        class_getInstanceMethod(cls, sel_registerName("beginMinMax:minimizing:animate:"));
    Ivar wid = class_getInstanceVariable(cls, "_wid");
    if (!method || strcmp(method_getTypeEncoding(method), "v32@0:8d16B24B28") || !wid ||
        strcmp(ivar_getTypeEncoding(wid), "I") || !selectWindow || !setShadow || !v5Status ||
        *v5Status != 1)
        return NO;
    widOffset = ivar_getOffset(wid);
    controlLock = [NSLock new];
    previousBegin = (void *)method_setImplementation(method, (IMP)begin);
    return YES;
}
#ifndef SELF_TEST
static BOOL expectedBuild(void) {
    char build[64];
    size_t size = sizeof(build);
    if (sysctlbyname("kern.osversion", build, &size, NULL, 0) || strcmp(build, "26B123"))
        return NO;
    const struct mach_header_64 *header = (const void *)_dyld_get_image_header(0);
    if (!header || header->magic != MH_MAGIC_64 || header->ncmds > 256 ||
        header->sizeofcmds < sizeof(struct load_command))
        return NO;
    const unsigned char uuid[16] = {0xc5, 0x39, 0x75, 0xb1, 0x29, 0x56, 0x3e, 0xd4,
                                    0xb6, 0x99, 0xd4, 0xce, 0x2e, 0x6a, 0x60, 0x2c};
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
__attribute__((constructor)) static void load(void) {
    if (strcmp(getprogname(), "Dock"))
        return;
    if (!expectedBuild()) {
        GenieSpringBoardGlobalStatus = -1;
        return;
    }
    selectWindow = dlsym(RTLD_DEFAULT, "GenieSpringBoardV5SetWindow");
    setShadow = dlsym(RTLD_DEFAULT, "GenieSpringBoardV5SetShadowEnabled");
    v5Status = dlsym(RTLD_DEFAULT, "GenieSpringBoardV5Status");
    GenieSpringBoardGlobalStatus = install() ? 1 : -2;
}
#else
#include <assert.h>
static uint32_t selected;
static bool shadowEnabled, failSelection, failShadow;
static int mockV5Status = 1, forwards;
@interface DOCKWindowTile : NSObject {
  @public
    uint32_t _wid;
}
- (void)beginMinMax:(double)duration minimizing:(bool)minimizing animate:(bool)animate;
@end
@implementation DOCKWindowTile
- (void)beginMinMax:(double)duration minimizing:(bool)minimizing animate:(bool)animate {
    assert(duration == 500);
    (void)minimizing;
    (void)animate;
    forwards++;
}
@end
static bool mockSelect(uint32_t wid) {
    if (failSelection && wid)
        return false;
    selected = wid;
    return true;
}
static bool mockShadow(bool value) {
    if (failShadow && value)
        return false;
    shadowEnabled = value;
    return true;
}
int main(void) {
    @autoreleasepool {
        selectWindow = mockSelect;
        setShadow = mockShadow;
        v5Status = &mockV5Status;
        assert(install());
        GenieSpringBoardGlobalStatus = 1;
        DOCKWindowTile *a = [DOCKWindowTile new], *b = [DOCKWindowTile new];
        a->_wid = 42;
        b->_wid = 43;
        [a beginMinMax:500 minimizing:true animate:true];
        assert(selected == 0 && forwards == 1);
        assert(GenieSpringBoardGlobalSetEnabled(true) && shadowEnabled);
        [a beginMinMax:500 minimizing:true animate:true];
        assert(selected == UINT32_MAX);
        [b beginMinMax:500 minimizing:false animate:true];
        assert(selected == UINT32_MAX);
        [a beginMinMax:500 minimizing:true animate:false];
        assert(selected == UINT32_MAX);
        a->_wid = 0;
        [a beginMinMax:500 minimizing:true animate:true];
        assert(selected == UINT32_MAX);
        a->_wid = 42;
        assert(GenieSpringBoardGlobalSetEnabled(false));
        assert(!selected && !shadowEnabled);
        [a beginMinMax:500 minimizing:true animate:true];
        assert(!selected);
        assert(GenieSpringBoardGlobalSetEnabled(true));
        failSelection = true;
        assert(!GenieSpringBoardGlobalSetEnabled(true));
        [a beginMinMax:500 minimizing:true animate:true];
        assert(!selected && !shadowEnabled && !atomic_load(&GenieSpringBoardGlobalEnabled));
        failSelection = false;
        failShadow = true;
        assert(!GenieSpringBoardGlobalSetEnabled(true));
        assert(!selected && !shadowEnabled);
        failShadow = false;
        mockV5Status = 0;
        assert(!GenieSpringBoardGlobalSetEnabled(true));
        assert(!atomic_load(&GenieSpringBoardGlobalEnabled));
        assert(forwards == 7 && atomic_load(&GenieSpringBoardGlobalRoutes) == 2 &&
               atomic_load(&GenieSpringBoardGlobalErrors) == 3);
        puts("Global shim self-check passed: default off, multiple-window routing, "
             "native/nonanimated forwarding, disable and failure cleanup.");
    }
}
#endif
