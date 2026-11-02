#define SELF_TEST 1
#include "../src/runtime/InputRouting.m"
#include <assert.h>
@interface DOCKWindowTile : NSObject {
  @public
    uint32_t _wid;
}
- (void)beginMinMax:(double)duration minimizing:(bool)minimizing animate:(bool)animate;
- (void)endMinMax;
@end
static unsigned forwards, ends, failSet, failClear, failGet;
static uint64_t tags[2];
static _Atomic uint32_t selection;
static int status = 1;
@implementation DOCKWindowTile
- (void)beginMinMax:(double)d minimizing:(bool)m animate:(bool)a {
    (void)d;
    (void)m;
    (void)a;
    forwards++;
}
- (void)endMinMax {
    ends++;
}
@end
static int conn(void) { return 7; }
static unsigned indexFor(int c, uint32_t wid, int count) {
    assert(c == 7 && (wid == 42 || wid == 43) && count == 64);
    return wid - 42;
}
static int get(int c, uint32_t w, uint64_t *bits, int n) {
    unsigned i = indexFor(c, w, n);
    if (failGet) {
        failGet--;
        return 1;
    }
    *bits = tags[i];
    return 0;
}
static int set(int c, uint32_t w, const uint64_t *bits, int n) {
    unsigned i = indexFor(c, w, n);
    if (failSet) {
        failSet--;
        return 1;
    }
    tags[i] |= *bits;
    return 0;
}
static int clear(int c, uint32_t w, const uint64_t *bits, int n) {
    unsigned i = indexFor(c, w, n);
    if (failClear) {
        failClear--;
        return 1;
    }
    tags[i] &= ~*bits;
    return 0;
}
int main(void) {
    @autoreleasepool {
        connection = conn;
        getTags = get;
        setTags = set;
        clearTags = clear;
        selectedWindow = &selection;
        baseStatus = &status;
        assert(install());
        DockboardInputRoutingStatus = 1;
        DOCKWindowTile *a = [DOCKWindowTile new], *b = [DOCKWindowTile new];
        a->_wid = 42;
        b->_wid = 43;
        selection = 42;
        const uint64_t native = 1ull << 34;
        tags[0] = native | 0x400;
        tags[1] = native | 0x200;
        [a beginMinMax:1200 minimizing:true animate:true];
        assert(tags[0] == (native | 0x400) && !baselines.count);
        assert(DockboardInputRoutingSetEnabled(true));
        [b beginMinMax:850 minimizing:false animate:true];
        [a beginMinMax:0 minimizing:true animate:false];
        assert(!baselines.count);
        [a beginMinMax:1200 minimizing:true animate:true];
        assert(tags[0] == (native | 0x200) && baselines.count == 1);
        [a beginMinMax:850 minimizing:false animate:true];
        selection = 43;
        [b beginMinMax:850 minimizing:false animate:true];
        assert(baselines.count == 2);
        [a endMinMax];
        assert(tags[0] == (native | 0x400) && baselines.count == 1);
        assert(DockboardInputRoutingSetEnabled(false));
        assert(tags[1] == (native | 0x200) && !baselines.count);
        [b endMinMax];
        assert(ends == 2 && forwards == 6);
        selection = 42;
        assert(DockboardInputRoutingSetEnabled(true));
        failGet = 1;
        [a beginMinMax:1200 minimizing:true animate:true];
        assert(!baselines.count && tags[0] == (native | 0x400));
        failSet = 1;
        [a beginMinMax:1200 minimizing:true animate:true];
        assert(!baselines.count && tags[0] == (native | 0x400));
        [a beginMinMax:1200 minimizing:true animate:true];
        failClear = 2;
        [a endMinMax];
        assert(baselines.count == 1 && ends == 3);
        assert(!DockboardInputRoutingSetEnabled(false));
        assert(baselines.count == 1 && !DockboardInputRoutingEnabled);
        assert(DockboardInputRoutingSetEnabled(false));
        assert(!baselines.count && tags[0] == (native | 0x400));
        selection = UINT32_MAX;
        assert(DockboardInputRoutingSetEnabled(true));
        [a beginMinMax:1200 minimizing:true animate:true];
        [b beginMinMax:850 minimizing:false animate:true];
        assert(baselines.count == 2);
        [a endMinMax];
        assert(baselines.count == 1 && tags[0] == (native | 0x400));
        [b endMinMax];
        assert(!baselines.count);
        status = 0;
        assert(!DockboardInputRoutingSetEnabled(true));
        puts("Input routing: guards, overlapping windows, reversal, native bits, failures and "
             "cleanup passed.");
    }
}
