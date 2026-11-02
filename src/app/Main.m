#import <Cocoa/Cocoa.h>

static NSDictionary *perform(NSString *action) {
    NSURL *resources = NSBundle.mainBundle.resourceURL;
    NSURL *temporary =
        [NSURL fileURLWithPath:[NSTemporaryDirectory()
                                   stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
                   isDirectory:YES];
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:temporary
                                withIntermediateDirectories:NO
                                                 attributes:@{
                                                     NSFilePosixPermissions : @0700
                                                 }
                                                      error:&error])
        return @{@"ok" : @NO, @"message" : error.localizedDescription};
    NSURL *result = [temporary URLByAppendingPathComponent:@"result.json"];
    NSURL *logURL = [temporary URLByAppendingPathComponent:@"session.log"];
    [NSFileManager.defaultManager createFileAtPath:logURL.path contents:nil attributes:nil];
    NSFileHandle *log = [NSFileHandle fileHandleForWritingAtPath:logURL.path];
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
    task.arguments = @[
        @"lldb", @"--batch", @"-o",
        @"script import os, runpy; runpy.run_path(os.environ['DOCKBOARD_DRIVER'], run_name='__main__')",
        @"-o", @"quit"
    ];
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    environment[@"DOCKBOARD_ACTION"] = action;
    environment[@"DOCKBOARD_DRIVER"] = [resources URLByAppendingPathComponent:@"driver.py"].path;
    environment[@"DOCKBOARD_RUNTIME_DIR"] = [resources URLByAppendingPathComponent:@"runtime"].path;
    environment[@"DOCKBOARD_RESULT"] = result.path;
    task.environment = environment;
    task.standardOutput = log;
    task.standardError = log;
    NSDictionary *response = nil;
    @try {
        if ([task launchAndReturnError:&error]) {
            [task waitUntilExit];
            NSData *data = [NSData dataWithContentsOfURL:result];
            id value =
                data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
            if ([value isKindOfClass:NSDictionary.class])
                response = value;
            else
                response = @{
                    @"ok" : @NO,
                    @"message" : @"The debugger did not return a result. Check that Xcode Command "
                                 @"Line Tools are available."
                };
        } else
            response = @{@"ok" : @NO, @"message" : error.localizedDescription};
    } @finally {
        [log closeFile];
        [NSFileManager.defaultManager removeItemAtURL:temporary error:nil];
    }
    return response;
}

@interface DockboardController : NSObject <NSApplicationDelegate>
@property(strong) NSStatusItem *item;
@property(strong) NSMenuItem *status;
@property(strong) NSMenuItem *enable;
@property(strong) NSMenuItem *disable;
@property(strong) NSMenuItem *refresh;
@property(strong) NSMenuItem *quitItem;
@property BOOL busy;
@end

@implementation DockboardController
- (NSMenuItem *)add:(NSString *)title action:(SEL)action menu:(NSMenu *)menu {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    [menu addItem:item];
    return item;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.item.button.image =
        [NSImage imageWithSystemSymbolName:@"arrow.down.right.and.arrow.up.left"
                  accessibilityDescription:@"Dockboard window animations"];
    self.item.button.toolTip = @"Dockboard — experimental window animations";
    NSMenu *menu = [NSMenu new];
    menu.autoenablesItems = NO;
    self.status = [self add:@"Checking…" action:NULL menu:menu];
    self.status.enabled = NO;
    self.enable = [self add:@"Dockboard" action:@selector(enableAnimation:) menu:menu];
    self.disable = [self add:@"macOS Default" action:@selector(disableAnimation:) menu:menu];
    [menu addItem:NSMenuItem.separatorItem];
    self.refresh = [self add:@"Refresh Status" action:@selector(refreshStatus:) menu:menu];
    [menu addItem:NSMenuItem.separatorItem];
    self.quitItem = [self add:@"Quit Dockboard" action:@selector(quit:) menu:menu];
    self.quitItem.keyEquivalent = @"q";
    self.quitItem.toolTip = @"The selected animation stays active after quitting Dockboard.";
    self.item.menu = menu;
    [self run:@"status"];
}
- (void)updateMenu:(NSDictionary *)result {
    BOOL ok = [result[@"ok"] boolValue];
    NSString *state = result[@"state"];
    BOOL enabled = ok && [state isEqual:@"enabled"];
    BOOL native = ok && [state isEqual:@"native"];
    self.status.title = !ok ? @"Animation Unavailable"
                            : (enabled || native ? @"Window Animation" : @"Restore macOS Default");
    self.status.toolTip = result[@"message"];
    self.enable.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.disable.state = native ? NSControlStateValueOn : NSControlStateValueOff;
    self.enable.enabled = self.disable.enabled = ok;
    self.refresh.enabled = self.quitItem.enabled = YES;
}
- (void)run:(NSString *)action {
    if (self.busy)
        return;
    self.busy = YES;
    self.enable.enabled = self.disable.enabled = self.refresh.enabled = self.quitItem.enabled = NO;
    self.status.title =
        [action isEqual:@"status"] ? @"Checking Animation…" : @"Changing Animation…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *result = perform(action);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            [self updateMenu:result];
            if (![result[@"ok"] boolValue]) {
                NSAlert *alert = [NSAlert new];
                alert.messageText = @"Dockboard could not complete this action";
                alert.informativeText = result[@"message"] ?: @"Unknown error";
                [alert runModal];
            }
        });
    });
}
- (void)enableAnimation:(id)sender {
    (void)sender;
    if (self.enable.state != NSControlStateValueOn)
        [self run:@"enable"];
}
- (void)disableAnimation:(id)sender {
    (void)sender;
    if (self.disable.state != NSControlStateValueOn)
        [self run:@"disable"];
}
- (void)refreshStatus:(id)sender {
    (void)sender;
    [self run:@"status"];
}
- (void)quit:(id)sender {
    (void)sender;
    if (!self.busy)
        [NSApp terminate:nil];
}
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc == 2) {
            NSString *argument = [NSString stringWithUTF8String:argv[1]];
            NSDictionary *actions =
                @{@"--status" : @"status", @"--enable" : @"enable", @"--disable" : @"disable"};
            NSString *action = actions[argument];
            if (!action)
                return 2;
            NSDictionary *result = perform(action);
            NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
            fwrite(data.bytes, 1, data.length, stdout);
            fputc('\n', stdout);
            return [result[@"ok"] boolValue] ? 0 : 1;
        }
        if (argc != 1)
            return 2;
        [NSApplication sharedApplication];
        DockboardController *controller = [DockboardController new];
        NSApp.delegate = controller;
        [NSApp run];
    }
    return 0;
}
