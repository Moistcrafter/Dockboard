#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdatomic.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <sys/sysctl.h>
#ifndef SELF_TEST
#include <ptrauth.h>
#endif
typedef struct CPSProcessSerNum {
    uint32_t high, low;
} ProcessSerial;
static void (*previousMinimize)(id, SEL, id, bool, float);
static void (*finishMinimize)(id), (*finishRestore)(id), (*stopProperty)(id);
static bool (*propertyActive)(id);
static Ivar transIvar;
static ptrdiff_t callbackOffset, minimizingOffset, maximizingOffset;
static void (*previousRestore)(id, SEL, id, uint32_t);
static mach_port_t (*lookupPort)(const ProcessSerial *);
static kern_return_t (*sendAck)(mach_port_t, uint32_t, uint32_t, uint32_t, uint32_t);
static Class tileClass;
static void (*previousUpdate)(id, SEL);
static bool (*previewReady)(id);
static bool (*previousBusy)(id, SEL);
static uintptr_t restoreRequestCaller;
#ifdef SELF_TEST
static uintptr_t testBusyCaller;
#endif
_Atomic unsigned DockboardMinimizeAcknowledged;
static ptrdiff_t widOffset;
int EarlyRestoreAckV2Status;
_Atomic uint32_t EarlyRestoreAckV2Window;
_Atomic unsigned EarlyRestoreAckV2Sent, EarlyRestoreAckV2Failures;
_Atomic unsigned DockboardInterruptedTransitions;
// UINT32_MAX selects all windows; zero disables early acknowledgement.
bool EarlyRestoreAckV2Select(uint32_t wid) {
    if (EarlyRestoreAckV2Status != 1)
        return false;
    atomic_store(&EarlyRestoreAckV2Window, wid);
    return true;
}
static uint32_t windowID(id tile) {
    uint32_t wid;
    memcpy(&wid, (const char *)(__bridge void *)tile + widOffset, sizeof(wid));
    return wid;
}
static bool busy(id tile, SEL selector) {
#ifdef SELF_TEST
    uintptr_t caller = testBusyCaller;
#else
    uintptr_t caller =
        (uintptr_t)ptrauth_strip(__builtin_return_address(0), ptrauth_key_return_address);
#endif
    uint32_t selected = atomic_load(&EarlyRestoreAckV2Window);
    if (caller == restoreRequestCaller && selected &&
        (selected == UINT32_MAX || selected == windowID(tile)) && previewReady(tile))
        return false;
    return previousBusy(tile, selector);
}
static void finishConflicts(id bar, id tile, bool minimizing) {
    uint32_t selected = atomic_load(&EarlyRestoreAckV2Window);
    if (!selected || ![tile isKindOfClass:tileClass])
        return;
    uint32_t wid = windowID(tile);
    if (!wid || (selected != UINT32_MAX && selected != wid))
        return;
    NSArray *tiles =
        [((id (*)(id, SEL))objc_msgSend)(bar, sel_registerName("miniWindowTiles")) copy];
    for (id old in tiles) {
        if (![old isKindOfClass:tileClass] || windowID(old) != wid)
            continue;
        char *bytes = (__bridge void *)old;
        bool closing = bytes[minimizingOffset], opening = bytes[maximizingOffset];
        if ((!closing && !opening) || (old == tile && closing == minimizing))
            continue;
        id property = object_getIvar(old, transIvar);
        uintptr_t callback;
        memcpy(&callback, bytes + callbackOffset, sizeof(callback));
#ifdef SELF_TEST
        uintptr_t expected = (uintptr_t)(opening ? finishRestore : finishMinimize);
#else
        callback = (uintptr_t)ptrauth_strip((void *)callback, ptrauth_key_function_pointer);
        uintptr_t expected = (uintptr_t)ptrauth_strip(opening ? finishRestore : finishMinimize,
                                                      ptrauth_key_function_pointer);
#endif
        if (callback != expected || !propertyActive(property))
            continue;
        // Native completion must run before the replacement owns the window, including
        // warp/release.
        stopProperty(property);
        memset(bytes + callbackOffset, 0, sizeof(callback));
        (opening ? finishRestore : finishMinimize)(old);
        atomic_fetch_add(&DockboardInterruptedTransitions, 1);
    }
}
static void minimize(id bar, SEL selector, id tile, bool animate, float duration) {
    finishConflicts(bar, tile, true);
    previousMinimize(bar, selector, tile, animate, duration);
}
static void acknowledge(id tile, uint32_t transaction, bool minimizing) {
    uint32_t selected = atomic_load(&EarlyRestoreAckV2Window);
    if (!selected || !transaction || ![tile isKindOfClass:tileClass])
        return;
    uint32_t wid = 0;
    memcpy(&wid, (const char *)(__bridge void *)tile + widOffset, 4);
    if (!wid || (selected != UINT32_MAX && wid != selected))
        return;
    uint64_t current =
        ((uint64_t (*)(id, SEL))objc_msgSend)(tile, sel_registerName("transactionID"));
    if (current != transaction)
        return;
    ProcessSerial owner =
        ((ProcessSerial (*)(id, SEL))objc_msgSend)(tile, sel_registerName("owner"));
    mach_port_t port = lookupPort(&owner);
    // Zero send timeout: on failure keep native completion responsible for the transaction.
    if (!port || sendAck(port, 0, wid, transaction, minimizing ? 1 : 0) != KERN_SUCCESS) {
        atomic_fetch_add(&EarlyRestoreAckV2Failures, 1);
        return;
    }
    ((void (*)(id, SEL, uint64_t))objc_msgSend)(tile, sel_registerName("setTransactionID:"), 0);
    atomic_fetch_add(minimizing ? &DockboardMinimizeAcknowledged : &EarlyRestoreAckV2Sent, 1);
}
static void restore(id bar, SEL selector, id tile, uint32_t transaction) {
    finishConflicts(bar, tile, false);
    previousRestore(bar, selector, tile, transaction);
    acknowledge(tile, transaction, false);
}
static void update(id tile, SEL selector) {
    previousUpdate(tile, selector);
    const char *bytes = (__bridge const void *)tile;
    if (!atomic_load(&EarlyRestoreAckV2Window) || !bytes[minimizingOffset] || !previewReady(tile))
        return;
    uint64_t tx = ((uint64_t (*)(id, SEL))objc_msgSend)(tile, sel_registerName("transactionID"));
    if (tx && tx <= UINT32_MAX)
        acknowledge(tile, (uint32_t)tx, true);
}
static bool method(Class cls, const char *name, const char *type) {
    Method m = class_getInstanceMethod(cls, sel_registerName(name));
    return m && !strcmp(method_getTypeEncoding(m), type);
}
static bool offset(Class cls, const char *name, const char *type, size_t size, ptrdiff_t *out) {
    Ivar ivar = class_getInstanceVariable(cls, name);
    if (!ivar || strcmp(ivar_getTypeEncoding(ivar), type))
        return false;
    *out = ivar_getOffset(ivar);
    return *out > 0 && (size_t)*out + size <= class_getInstanceSize(cls);
}
static bool install(void) {
    Class bar = objc_getClass("DockBar");
    tileClass = objc_getClass("DOCKWindowTile");
    Ivar wid = class_getInstanceVariable(tileClass, "_wid");
    transIvar = class_getInstanceVariable(tileClass, "_trans");
    if (!restoreRequestCaller || !method(tileClass, "minimizingOrMaximizing", "B16@0:8") ||
        !previewReady || !method(tileClass, "updateTransition", "v16@0:8") || !finishMinimize ||
        !finishRestore || !stopProperty || !propertyActive || !transIvar ||
        strcmp(ivar_getTypeEncoding(transIvar), "@\"DockFloatAnimatedProperty\"") ||
        !offset(tileClass, "_transEndCallback", "^?", sizeof(void *), &callbackOffset) ||
        !offset(tileClass, "_minimizing", "B", 1, &minimizingOffset) ||
        !offset(tileClass, "_maximizing", "B", 1, &maximizingOffset) ||
        !method(bar, "miniWindowTiles", "@16@0:8") ||
        !method(bar, "_handleMinimizeWindow:animate:duration:", "v32@0:8@16B24f28") ||
        !method(bar, "_handleMaximizeWindow:transactionID:", "v28@0:8@16I24") ||
        !method(tileClass, "owner", "{CPSProcessSerNum=II}16@0:8") ||
        !method(tileClass, "transactionID", "Q16@0:8") ||
        !method(tileClass, "setTransactionID:", "v24@0:8Q16") || !wid ||
        strcmp(ivar_getTypeEncoding(wid), "I"))
        return false;
    widOffset = ivar_getOffset(wid);
    if (widOffset <= 0 || (size_t)widOffset + 4 > class_getInstanceSize(tileClass))
        return false;
    previousBusy = (void *)method_setImplementation(
        class_getInstanceMethod(tileClass, sel_registerName("minimizingOrMaximizing")), (IMP)busy);
    previousUpdate = (void *)method_setImplementation(
        class_getInstanceMethod(tileClass, sel_registerName("updateTransition")), (IMP)update);
    previousMinimize = (void *)method_setImplementation(
        class_getInstanceMethod(bar, sel_registerName("_handleMinimizeWindow:animate:duration:")),
        (IMP)minimize);
    previousRestore = (void *)method_setImplementation(
        class_getInstanceMethod(bar, sel_registerName("_handleMaximizeWindow:transactionID:")),
        (IMP)restore);
    return true;
}
#ifndef SELF_TEST
__attribute__((constructor)) static void load(void) {
    if (strcmp(getprogname(), "Dock"))
        return;
    char build[64];
    size_t size = sizeof(build);
    if (sysctlbyname("kern.osversion", build, &size, NULL, 0) || strcmp(build, "26B123")) {
        EarlyRestoreAckV2Status = -1;
        return;
    }
    const struct mach_header_64 *h = (const void *)_dyld_get_image_header(0);
    const unsigned char uuid[] = {0xc5, 0x39, 0x75, 0xb1, 0x29, 0x56, 0x3e, 0xd4,
                                  0xb6, 0x99, 0xd4, 0xce, 0x2e, 0x6a, 0x60, 0x2c};
    bool valid = false;
    const char *cursor = (const char *)(h + 1), *limit = cursor + h->sizeofcmds;
    if (h->magic != MH_MAGIC_64 || h->ncmds > 256) {
        EarlyRestoreAckV2Status = -1;
        return;
    }
    for (uint32_t i = 0; i < h->ncmds; i++) {
        if (limit - cursor < (ptrdiff_t)sizeof(struct load_command))
            break;
        const struct load_command *c = (const void *)cursor;
        if (c->cmdsize < sizeof(*c) || c->cmdsize > (size_t)(limit - cursor))
            break;
        if (c->cmd == LC_UUID && c->cmdsize >= sizeof(struct uuid_command))
            valid = !memcmp(((const struct uuid_command *)c)->uuid, uuid, 16);
        cursor += c->cmdsize;
    }
    if (!valid) {
        EarlyRestoreAckV2Status = -1;
        return;
    }
    lookupPort = ptrauth_sign_unauthenticated((void *)((uintptr_t)h + 0x18bfc),
                                              ptrauth_key_function_pointer, 0);
    sendAck = ptrauth_sign_unauthenticated((void *)((uintptr_t)h + 0x271fc),
                                           ptrauth_key_function_pointer, 0);
    finishMinimize = ptrauth_sign_unauthenticated((void *)((uintptr_t)h + 0x26f04),
                                                  ptrauth_key_function_pointer, 0);
    finishRestore = ptrauth_sign_unauthenticated((void *)((uintptr_t)h + 0x27dc8),
                                                 ptrauth_key_function_pointer, 0);
    stopProperty = ptrauth_sign_unauthenticated((void *)((uintptr_t)h + 0x22efac),
                                                ptrauth_key_function_pointer, 0);
    propertyActive = ptrauth_sign_unauthenticated((void *)((uintptr_t)h + 0x22f088),
                                                  ptrauth_key_function_pointer, 0);
    restoreRequestCaller = (uintptr_t)h + 0x54398;
    previewReady = dlsym(RTLD_DEFAULT, "DockboardMinimizePreviewReady");
    EarlyRestoreAckV2Status = install() ? 1 : -2;
}
#endif
