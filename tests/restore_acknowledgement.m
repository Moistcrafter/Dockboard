#define SELF_TEST 1
#include "../src/runtime/RestoreAcknowledgement.m"
#include <assert.h>
@interface DockFloatAnimatedProperty : NSObject {
  @public
    bool active;
}
@end
@implementation DockFloatAnimatedProperty
@end
@interface DOCKWindowTile : NSObject {
  @public
    uint32_t _wid;
    uint64_t tx;
    bool _minimizing, _maximizing;
    DockFloatAnimatedProperty *_trans;
    void (*_transEndCallback)(id);
}
- (bool)minimizingOrMaximizing;
- (void)updateTransition;
- (ProcessSerial)owner;
- (uint64_t)transactionID;
- (void)setTransactionID:(uint64_t)t;
@end
@implementation DOCKWindowTile
- (bool)minimizingOrMaximizing {
    return _minimizing || _maximizing;
}
- (void)updateTransition {
}
- (ProcessSerial)owner {
    return (ProcessSerial){0, 88};
}
- (uint64_t)transactionID {
    return tx;
}
- (void)setTransactionID:(uint64_t)t {
    tx = t;
}
@end
static unsigned forwards, sends;
static bool fail, missing;
@interface DockBar : NSObject
@property NSMutableArray *tiles;
- (id)miniWindowTiles;
- (void)_handleMinimizeWindow:(id)t animate:(bool)a duration:(float)d;
- (void)_handleMaximizeWindow:(id)t transactionID:(uint32_t)x;
@end
@implementation DockBar
- (id)miniWindowTiles {
    return self.tiles;
}
- (void)_handleMinimizeWindow:(id)t animate:(bool)a duration:(float)d {
    (void)a;
    (void)d;
    DOCKWindowTile *tile = t;
    for (DOCKWindowTile *other in self.tiles)
        if (other != tile && other->_wid == tile->_wid)
            assert(!other->_maximizing && !other->_minimizing);
    tile->_minimizing = true;
    tile->_trans->active = true;
    tile->_transEndCallback = finishMinimize;
}
- (void)_handleMaximizeWindow:(id)t transactionID:(uint32_t)x {
    forwards++;
    ((DOCKWindowTile *)t)->tx = x;
}
@end
static mach_port_t port(const ProcessSerial *p) {
    assert(p->low == 88);
    return missing ? 0 : 42;
}
static kern_return_t ack(mach_port_t p, uint32_t timeout, uint32_t wid, uint32_t tx,
                         uint32_t state) {
    assert(p == 42 && timeout == 0 && (wid == 77 || wid == 78) && tx == 123 && state <= 1);
    sends++;
    return fail ? MACH_SEND_TIMED_OUT : KERN_SUCCESS;
}
static bool ready;
static bool mockReady(id tile) {
    (void)tile;
    return ready;
}
static unsigned completions;
static DockBar *testBar;
static bool active(id p) { return p && ((DockFloatAnimatedProperty *)p)->active; }
static void stop(id p) { ((DockFloatAnimatedProperty *)p)->active = false; }
static void complete(id object) {
    DOCKWindowTile *tile = object;
    assert(!active(tile->_trans) && !tile->_transEndCallback);
    completions++;
    bool opening = tile->_maximizing;
    tile->_minimizing = tile->_maximizing = false;
    if (opening)
        [testBar.tiles removeObjectIdenticalTo:tile];
}
static DOCKWindowTile *animated(uint32_t wid, bool opening) {
    DOCKWindowTile *tile = [DOCKWindowTile new];
    tile->_wid = wid;
    tile->_minimizing = !opening;
    tile->_maximizing = opening;
    tile->_trans = [DockFloatAnimatedProperty new];
    tile->_trans->active = true;
    tile->_transEndCallback = complete;
    return tile;
}
int main(void) {
    @autoreleasepool {
        restoreRequestCaller = 1234;
        previewReady = mockReady;
        finishMinimize = finishRestore = complete;
        stopProperty = stop;
        propertyActive = active;
        lookupPort = port;
        sendAck = ack;
        assert(install());
        EarlyRestoreAckV2Status = 1;
        DockBar *b = [DockBar new];
        DOCKWindowTile *t = [DOCKWindowTile new];
        t->_wid = 77;
        [b _handleMaximizeWindow:t transactionID:123];
        assert(!sends && t->tx == 123);
        assert(EarlyRestoreAckV2Select(77));
        [b _handleMaximizeWindow:t transactionID:0];
        assert(!sends);
        t->_wid = 78;
        [b _handleMaximizeWindow:t transactionID:123];
        assert(!sends);
        t->_wid = 77;
        fail = true;
        [b _handleMaximizeWindow:t transactionID:123];
        assert(sends == 1 && t->tx == 123);
        fail = false;
        missing = true;
        [b _handleMaximizeWindow:t transactionID:123];
        assert(sends == 1 && t->tx == 123);
        missing = false;
        [b _handleMaximizeWindow:t transactionID:123];
        assert(sends == 2 && t->tx == 0 && EarlyRestoreAckV2Sent == 1);
        assert(EarlyRestoreAckV2Select(0));
        [b _handleMaximizeWindow:t transactionID:123];
        assert(sends == 2 && forwards == 7);
        assert(EarlyRestoreAckV2Select(UINT32_MAX));
        t->_wid = 78;
        [b _handleMaximizeWindow:t transactionID:123];
        assert(sends == 3 && t->tx == 0);
        t->_wid = 0;
        [b _handleMaximizeWindow:t transactionID:123];
        assert(sends == 3 && t->tx == 123);
        assert(EarlyRestoreAckV2Select(0));
        t->_wid = 78;
        [b _handleMaximizeWindow:t transactionID:123];
        assert(sends == 3 && t->tx == 123);
        testBar = b;
        b.tiles = [NSMutableArray new];
        DOCKWindowTile *opening = animated(77, true), *other = animated(78, true);
        DOCKWindowTile *replacement = animated(77, false);
        [b.tiles addObjectsFromArray:@[ opening, other, replacement ]];
        assert(EarlyRestoreAckV2Select(UINT32_MAX));
        [b _handleMinimizeWindow:replacement animate:true duration:1200];
        assert(completions == 1 && !opening->_maximizing && other->_maximizing);
        assert(replacement->_minimizing && active(replacement->_trans) && b.tiles.count == 2);
        [b _handleMinimizeWindow:replacement animate:true duration:1200];
        assert(completions == 1); // Repeated request never completes the new animation.
        [b _handleMaximizeWindow:replacement transactionID:123];
        assert(completions == 2 && !replacement->_minimizing && other->_maximizing);
        finishConflicts(b, replacement, false);
        assert(completions == 2); // Retired callbacks cannot run a second time.
        replacement->_minimizing = true;
        replacement->tx = 123;
        [replacement updateTransition];
        assert(replacement->tx == 123 && !DockboardMinimizeAcknowledged);
        assert([replacement minimizingOrMaximizing]);
        testBusyCaller = restoreRequestCaller;
        assert([replacement minimizingOrMaximizing]);
        ready = true;
        assert(![replacement minimizingOrMaximizing]);
        testBusyCaller = 0;
        assert([replacement minimizingOrMaximizing]);
        fail = true;
        [replacement updateTransition];
        assert(replacement->tx == 123 && !DockboardMinimizeAcknowledged);
        fail = false;
        [replacement updateTransition];
        [replacement updateTransition];
        assert(!replacement->tx && DockboardMinimizeAcknowledged == 1);
        replacement->tx = UINT64_MAX;
        [replacement updateTransition];
        assert(replacement->tx == UINT64_MAX && DockboardMinimizeAcknowledged == 1);
        puts("Interrupted restore/minimize: same-window replacement completes once, foreign "
             "animation continues, repeated minimize remains active.");
        puts("Global and zero-window guards passed. Early ack: off, foreign, zero transaction, "
             "send failure, missing port, success and disable passed.");
    }
    return 0;
}
