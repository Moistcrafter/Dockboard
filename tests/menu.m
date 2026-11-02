#define main dockboard_main
#import "../src/app/Main.m"
#undef main
#include <assert.h>

int main(void) {
    @autoreleasepool {
        DockboardController *controller = [DockboardController new];
        controller.status = [NSMenuItem new];
        controller.enable = [NSMenuItem new];
        controller.disable = [NSMenuItem new];
        controller.refresh = [NSMenuItem new];
        controller.quitItem = [NSMenuItem new];
        for (NSString *state in @[ @"enabled", @"native", @"partial" ]) {
            [controller updateMenu:@{@"ok" : @YES, @"state" : state}];
            assert(controller.enable.state == ([state isEqual:@"enabled"] ? 1 : 0));
            assert(controller.disable.state == ([state isEqual:@"native"] ? 1 : 0));
            assert(controller.enable.enabled && controller.disable.enabled);
        }
        [controller updateMenu:@{@"ok" : @NO, @"message" : @"Unavailable"}];
        assert(controller.enable.state == 0 && controller.disable.state == 0);
        assert(!controller.enable.enabled && !controller.disable.enabled);
        assert(controller.refresh.enabled && controller.quitItem.enabled);
        assert([controller.status.toolTip isEqual:@"Unavailable"]);
        // Selecting the current choice must not start another debugger operation.
        [controller updateMenu:@{@"ok" : @YES, @"state" : @"enabled"}];
        [controller enableAnimation:nil];
        assert(!controller.busy);
        [controller updateMenu:@{@"ok" : @YES, @"state" : @"native"}];
        [controller disableAnimation:nil];
        assert(!controller.busy);
    }
    puts("menu: passed");
    return 0;
}
