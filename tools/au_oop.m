// Opens an installed Audio Unit out of process, the way GarageBand does,
// asks for its editor and reports what comes back, or renders a note. The
// component is identified from a bundle's Info.plist (e.g. the build output).
//
//   au-oop <bundle.component> [out.png]
//   au-oop <bundle.component> render <sample rate>

#import <AppKit/AppKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudioKit/CoreAudioKit.h>

static void spin(BOOL *done, double seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!*done && [until timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
}

static AudioComponentDescription descFromBundle(const char *path) {
    NSBundle *bundle = [NSBundle bundleWithPath:[NSString stringWithUTF8String:path]];
    NSDictionary *info = [bundle.infoDictionary[@"AudioComponents"] firstObject];
    if (!info) {
        fprintf(stderr, "%s: no AudioComponents in Info.plist\n", path);
        exit(1);
    }
    AudioComponentDescription d = {0};
    d.componentType = NSHFSTypeCodeFromFileType([NSString stringWithFormat:@"'%@'", info[@"type"]]);
    d.componentSubType = NSHFSTypeCodeFromFileType([NSString stringWithFormat:@"'%@'", info[@"subtype"]]);
    d.componentManufacturer = NSHFSTypeCodeFromFileType([NSString stringWithFormat:@"'%@'", info[@"manufacturer"]]);
    return d;
}

static void dump(NSView *v, int depth) {
    printf("%*s%s frame=%s\n", depth * 2, "", [NSStringFromClass([v class]) UTF8String],
           [NSStringFromRect(v.frame) UTF8String]);
    if (depth < 4) for (NSView *s in v.subviews) dump(s, depth + 1);
}

// Renders A4 through the out-of-process unit with AVAudioEngine's offline
// mode at `rate` and reports level and pitch (from zero crossings).
static int renderTest(AudioComponentDescription desc, double rate) {
    __block AVAudioUnit *node = nil;
    __block BOOL done = NO;
    [AVAudioUnit instantiateWithComponentDescription:desc
                                             options:kAudioComponentInstantiation_LoadOutOfProcess
                                   completionHandler:^(AVAudioUnit *u, NSError *e) {
                                       if (e) printf("instantiate error: %s\n", e.description.UTF8String);
                                       node = u;
                                       done = YES;
                                   }];
    spin(&done, 10);
    if (![node isKindOfClass:[AVAudioUnitMIDIInstrument class]]) {
        printf("not a MIDI instrument: %s\n", NSStringFromClass([node class]).UTF8String);
        return 1;
    }
    AVAudioUnitMIDIInstrument *synth = (AVAudioUnitMIDIInstrument *)node;

    AVAudioEngine *engine = [AVAudioEngine new];
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:2];
    NSError *error = nil;
    const AVAudioFrameCount block = 512;
    if (![engine enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline format:format maximumFrameCount:block error:&error]) {
        printf("manual rendering: %s\n", error.description.UTF8String);
        return 1;
    }
    [engine attachNode:synth];
    [engine connect:synth to:engine.mainMixerNode format:format];
    if (![engine startAndReturnError:&error]) {
        printf("engine start: %s\n", error.description.UTF8String);
        return 1;
    }

    AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:engine.manualRenderingFormat frameCapacity:block];
    const AVAudioFramePosition total = (AVAudioFramePosition)rate; // 1 s
    float *mono = calloc((size_t)total, sizeof(float));
    AVAudioFramePosition pos = 0;
    [synth startNote:69 withVelocity:100 onChannel:0];
    while (pos < total) {
        AVAudioFrameCount n = (AVAudioFrameCount)MIN((AVAudioFramePosition)block, total - pos);
        AVAudioEngineManualRenderingStatus st = [engine renderOffline:n toBuffer:buf error:&error];
        if (st != AVAudioEngineManualRenderingStatusSuccess) {
            printf("render status %ld %s\n", (long)st, error.description.UTF8String);
            return 1;
        }
        memcpy(mono + pos, buf.floatChannelData[0], buf.frameLength * sizeof(float));
        pos += buf.frameLength;
    }
    [synth stopNote:69 onChannel:0];

    // Skip the attack, then measure.
    AVAudioFramePosition start = total / 10;
    double sum = 0;
    float peak = 0;
    int crossings = 0;
    for (AVAudioFramePosition i = start; i < total; i++) {
        sum += mono[i] * mono[i];
        peak = fmaxf(peak, fabsf(mono[i]));
        if (i > start && mono[i - 1] <= 0 && mono[i] > 0) crossings++;
    }
    double seconds = (double)(total - start) / rate;
    printf("rate=%.0f Hz: peak=%.3f rms=%.3f pitch~%.1f Hz (expected 440)\n", rate, peak,
           sqrt(sum / (double)(total - start)), crossings / seconds);
    free(mono);
    [engine stop];
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: au-oop <bundle.component> [out.png] | render <rate>\n");
        return 1;
    }
    AudioComponentDescription desc = descFromBundle(argv[1]);
    argc--;
    argv++;
    if (argc > 2 && strcmp(argv[1], "render") == 0) {
        @autoreleasepool {
            return renderTest(desc, atof(argv[2]));
        }
    }
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

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
