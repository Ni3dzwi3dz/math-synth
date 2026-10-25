// Opens the installed MathSynth Audio Unit out of process, the way GarageBand
// does, asks for its editor and reports what comes back. Optionally saves a
// screenshot of the window.
//
//   au-oop [out.png]

#import <AppKit/AppKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudioKit/CoreAudioKit.h>

static void spin(BOOL *done, double seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!*done && [until timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
}

static void dump(NSView *v, int depth) {
    printf("%*s%s frame=%s\n", depth * 2, "", [NSStringFromClass([v class]) UTF8String],
           [NSStringFromRect(v.frame) UTF8String]);
    if (depth < 4) for (NSView *s in v.subviews) dump(s, depth + 1);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        AudioComponentDescription desc = {'aumu', 'MSyn', 'Mthx', 0, 0};
        __block AUAudioUnit *unit = nil;
        __block BOOL done = NO;
        [AUAudioUnit instantiateWithComponentDescription:desc
                                                 options:kAudioComponentInstantiation_LoadOutOfProcess
                                       completionHandler:^(AUAudioUnit *au, NSError *error) {
                                           if (error) printf("instantiate error: %s\n", [[error description] UTF8String]);
                                           unit = au;
                                           done = YES;
                                       }];
        spin(&done, 10);
        if (!unit) return 1;
        printf("unit: %s (%s), providesUserInterface=%d\n", [unit.audioUnitName UTF8String],
               [NSStringFromClass([unit class]) UTF8String], unit.providesUserInterface);

        done = NO;
        __block NSViewController *vc = nil;
        [unit requestViewControllerWithCompletionHandler:^(NSViewController *controller) {
            vc = controller;
            done = YES;
        }];
        spin(&done, 10);
        if (!vc) {
            printf("view controller: nil\n");
            return 2;
        }
        printf("view controller: %s preferredContentSize=%s\n", [NSStringFromClass([vc class]) UTF8String],
               [NSStringFromSize(vc.preferredContentSize) UTF8String]);

        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 660, 480)
                                                       styleMask:NSWindowStyleMaskTitled
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        window.contentViewController = vc;
        [window makeKeyAndOrderFront:nil];
        BOOL never = NO;
        spin(&never, 2); // let the remote view connect and draw
        dump(window.contentView, 0);

        if (argc > 1) {
            CGWindowID wid = (CGWindowID)window.windowNumber;
            NSString *cmd = [NSString stringWithFormat:@"screencapture -x -o -l %u '%s'", wid, argv[1]];
            int rc = system([cmd UTF8String]);
            printf("screencapture exit %d\n", rc);
        }
    }
    return 0;
}
