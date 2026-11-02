#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <sys/sysctl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>

static void (*previousBegin)(id, SEL, double, bool, bool);
static void (*previousUpdate)(id, SEL), (*previousEnd)(id, SEL);
static int (*getLevel)(int, uint32_t, int *), (*setLevel)(int, uint32_t, int), (*connection)(void);
static _Atomic uint32_t *selectedWindow;
static _Atomic int *globalEnabled;
static int *v5Status;
static ptrdiff_t widOffset;
static NSLock *levelLock;
@interface DockboardLevelState : NSObject {
  @public
    uint32_t heldWindow;
    int heldConnection, originalLevel, targetLevel;
}
@end
@implementation DockboardLevelState
@end
static NSMutableDictionary<NSNumber *, DockboardLevelState *> *states;
_Atomic int GenieTransitionLevelEnabled, GenieTransitionLevelErrors;
_Atomic int GenieTransitionLevelWrites, GenieTransitionLevelRestores;
_Atomic int GenieTransitionLevelLastObserved, GenieTransitionLevelVerifiedReads;
_Atomic uint32_t GenieTransitionLevelPendingWindow;
int GenieTransitionLevelStatus, GenieTransitionLevelMinimum;

static uint32_t windowID(id tile) {
    uint32_t wid;
    const char *bytes = (__bridge const void *)tile;
    memcpy(&wid, bytes + widOffset, sizeof(wid));
    return wid;
}
static bool writeLevel(DockboardLevelState *state, int level) {
    if (setLevel(state->heldConnection, state->heldWindow, level)) {
        atomic_fetch_add(&GenieTransitionLevelErrors, 1);
        return false;
    }
    atomic_fetch_add(&GenieTransitionLevelWrites, 1);
    return true;
}
static bool restoreLocked(DockboardLevelState *state) {
    if (!state->heldWindow)
        return true;
    if (!writeLevel(state, state->originalLevel))
        return false;
    [states removeObjectForKey:@(state->heldWindow)];
    state->heldWindow = 0;
    atomic_fetch_sub(&GenieTransitionLevelPendingWindow, 1);
    atomic_fetch_add(&GenieTransitionLevelRestores, 1);
    return true;
}
static void failLocked(DockboardLevelState *state) {
    atomic_store(&GenieTransitionLevelEnabled, 0);
    restoreLocked(state); // Keep pending baseline observable if restoration fails.
}
bool GenieTransitionLevelSetEnabled(bool value) {
    if (GenieTransitionLevelStatus != 1)
        return false;
    [levelLock lock];
    atomic_store(&GenieTransitionLevelEnabled, 0);
    bool restored = true;
    for (DockboardLevelState *state in states.allValues)
        if (!restoreLocked(state))
            restored = false;
    bool ready = restored && (!value || (*v5Status == 1 && atomic_load(globalEnabled)));
    if (ready && value)
        atomic_store(&GenieTransitionLevelEnabled, 1);
    [levelLock unlock];
    return ready;
}
static bool selected(uint32_t wid) {
    return wid && atomic_load(&GenieTransitionLevelEnabled) && atomic_load(globalEnabled) &&
           (atomic_load(selectedWindow) == UINT32_MAX || wid == atomic_load(selectedWindow));
}
static void reinforce(uint32_t wid) {
    [levelLock lock];
    DockboardLevelState *state = states[@(wid)];
    if (!selected(wid)) {
        [levelLock unlock];
        return;
    }
    if (!state) {
        int level = 0, c = connection();
        if (getLevel(c, wid, &level)) {
            atomic_fetch_add(&GenieTransitionLevelErrors, 1);
            atomic_store(&GenieTransitionLevelEnabled, 0);
            [levelLock unlock];
            return;
        }
        state = [DockboardLevelState new];
        states[@(wid)] = state;
        state->heldWindow = wid;
        state->heldConnection = c;
        state->originalLevel = level;
        state->targetLevel = MAX(level, GenieTransitionLevelMinimum);
        atomic_fetch_add(&GenieTransitionLevelPendingWindow, 1);
    }
    if (state->heldWindow == wid) {
        int current = 0;
        if (getLevel(state->heldConnection, wid, &current)) {
            atomic_fetch_add(&GenieTransitionLevelErrors, 1);
            failLocked(state);
        } else if (current < state->targetLevel) {
            if (!writeLevel(state, state->targetLevel))
                failLocked(state);
        } else {
            atomic_store(&GenieTransitionLevelLastObserved, current);
            atomic_fetch_add(&GenieTransitionLevelVerifiedReads, 1);
        }
    }
    [levelLock unlock];
}
static void begin(id tile, SEL selector, double duration, bool minimizing, bool animate) {
    uint32_t wid = windowID(tile);
    bool eligible =
        animate && wid && atomic_load(&GenieTransitionLevelEnabled) && atomic_load(globalEnabled);
    previousBegin(tile, selector, duration, minimizing, animate);
    if (eligible)
        reinforce(wid);
}
static void update(id tile, SEL selector) {
    previousUpdate(tile, selector);
    // Reinforce only the existing transition, never adopt an unrelated update midway.
    uint32_t wid = windowID(tile);
    [levelLock lock];
    bool held = states[@(wid)] != nil;
    [levelLock unlock];
    if (held)
        reinforce(wid);
}
static void end(id tile, SEL selector) {
    uint32_t wid = windowID(tile);
    [levelLock lock];
    DockboardLevelState *state = states[@(wid)];
    if (state && !restoreLocked(state))
        atomic_store(&GenieTransitionLevelEnabled, 0);
    [levelLock unlock];
    previousEnd(tile, selector);
}
static BOOL install(void) {
    Class cls = objc_getClass("DOCKWindowTile");
    Method b = class_getInstanceMethod(cls, sel_registerName("beginMinMax:minimizing:animate:"));
    Method u = class_getInstanceMethod(cls, sel_registerName("updateTransition"));
    Method e = class_getInstanceMethod(cls, sel_registerName("endMinMax"));
    Ivar wid = class_getInstanceVariable(cls, "_wid");
    if (!b || !u || !e || strcmp(method_getTypeEncoding(b), "v32@0:8d16B24B28") ||
        strcmp(method_getTypeEncoding(u), "v16@0:8") ||
        strcmp(method_getTypeEncoding(e), "v16@0:8") || !wid ||
        strcmp(ivar_getTypeEncoding(wid), "I") || !getLevel || !setLevel || !connection ||
        !selectedWindow || !globalEnabled || !v5Status || *v5Status != 1)
        return NO;
    widOffset = ivar_getOffset(wid);
    levelLock = [NSLock new];
    states = [NSMutableDictionary new];
    GenieTransitionLevelMinimum = (int)CGWindowLevelForKey(kCGDockWindowLevelKey) + 1;
    previousBegin = (void *)method_setImplementation(b, (IMP)begin);
    previousUpdate = (void *)method_setImplementation(u, (IMP)update);
    previousEnd = (void *)method_setImplementation(e, (IMP)end);
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
        GenieTransitionLevelStatus = -1;
        return;
    }
    getLevel = dlsym(RTLD_DEFAULT, "SLSGetWindowLevel");
    setLevel = dlsym(RTLD_DEFAULT, "SLSSetWindowLevel");
    connection = dlsym(RTLD_DEFAULT, "SLSMainConnectionID");
    selectedWindow = dlsym(RTLD_DEFAULT, "GenieSpringBoardV5Window");
    globalEnabled = dlsym(RTLD_DEFAULT, "GenieSpringBoardGlobalEnabled");
    v5Status = dlsym(RTLD_DEFAULT, "GenieSpringBoardV5Status");
    GenieTransitionLevelStatus = install() ? 1 : -2;
}
#endif
#ifdef SELF_TEST
#include <assert.h>
static _Atomic uint32_t mockSelected;
static _Atomic int mockGlobal = 1;
static int mockStatus = 1, levels[2], setFailures, mockGets, sets, ends;
@interface DOCKWindowTile : NSObject {
  @public
    uint32_t _wid;
}
- (void)beginMinMax:(double)duration minimizing:(bool)minimizing animate:(bool)animate;
- (void)updateTransition;
- (void)endMinMax;
@end
@implementation DOCKWindowTile
- (void)beginMinMax:(double)duration minimizing:(bool)minimizing animate:(bool)animate {
    assert(duration == 500);
    (void)minimizing;
    if (animate && _wid && atomic_load(&mockGlobal))
        atomic_store(&mockSelected, UINT32_MAX);
}
- (void)updateTransition {
}
- (void)endMinMax {
    ends++;
}
@end
static int mockConnection(void) { return 7; }
static int mockGet(int c, uint32_t wid, int *level) {
    assert(c == 7 && wid >= 42 && wid <= 43);
    mockGets++;
    *level = levels[wid - 42];
    return 0;
}
static int mockSet(int c, uint32_t wid, int level) {
    assert(c == 7 && wid >= 42 && wid <= 43);
    sets++;
    if (setFailures) {
        setFailures--;
        return 1;
    }
    levels[wid - 42] = level;
    return 0;
}
int main(void) {
    @autoreleasepool {
        getLevel = mockGet;
        setLevel = mockSet;
        connection = mockConnection;
        selectedWindow = &mockSelected;
        globalEnabled = &mockGlobal;
        v5Status = &mockStatus;
        assert(install());
        GenieTransitionLevelStatus = 1;
        assert(GenieTransitionLevelMinimum == 21);
        DOCKWindowTile *a = [DOCKWindowTile new], *b = [DOCKWindowTile new];
        a->_wid = 42;
        b->_wid = 43;
        [a beginMinMax:500 minimizing:true animate:true];
        assert(levels[0] == 0 && mockGets == 0);
        assert(GenieTransitionLevelSetEnabled(true));
        [a beginMinMax:500 minimizing:true animate:true];
        assert(levels[0] == 21 && states[@42] != nil);
        [b beginMinMax:500 minimizing:true animate:false];
        assert(levels[0] == 21 && levels[1] == 0 && states[@42] != nil);
        [b updateTransition];
        assert(levels[0] == 21 && levels[1] == 0);
        levels[0] = 0;
        [a updateTransition];
        assert(levels[0] == 21);
        [a endMinMax];
        assert(levels[0] == 0 && !states.count && ends == 1);
        levels[0] = 100;
        int before = sets;
        [a beginMinMax:500 minimizing:false animate:true];
        assert(levels[0] == 100 && sets == before);
        [a endMinMax];
        assert(levels[0] == 100 && !states.count);
        levels[0] = 0;
        [a beginMinMax:500 minimizing:true animate:true];
        [b beginMinMax:500 minimizing:true animate:true];
        assert(levels[0] == 21 && levels[1] == 21 && states.count == 2);
        [a endMinMax];
        assert(levels[0] == 0 && levels[1] == 21 && states.count == 1);
        assert(GenieTransitionLevelSetEnabled(false));
        assert(levels[1] == 0 && !states.count);
        assert(GenieTransitionLevelSetEnabled(true));
        setFailures = 1;
        [a beginMinMax:500 minimizing:false animate:true];
        assert(levels[0] == 0 && !states.count && !atomic_load(&GenieTransitionLevelEnabled));
        assert(atomic_load(&GenieTransitionLevelErrors) == 1 &&
               !atomic_load(&GenieTransitionLevelPendingWindow));
        assert(atomic_load(&mockGlobal) ==
               1); // Failure never disables the user's motion experiment.
        puts("Level shim self-check passed: 0→21→0, native-level reset, higher baseline, "
             "independent overlapping windows, foreign/nonanimated, disable and failure restore.");
    }
}
#endif
