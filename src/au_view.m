// Cocoa view factory for the Audio Unit. AU hosts find this class by name in
// the plugin bundle and check it conforms to AUCocoaUIBase, which needs real
// Objective-C metadata in the binary, so it lives here rather than in Zig.
// Everything else is forwarded to src/au.zig. Compiled without ARC.

#import <AppKit/AppKit.h>
#import <AudioToolbox/AUCocoaUIView.h>

#ifndef MATHSYNTH_VIEW_FACTORY
#error "MATHSYNTH_VIEW_FACTORY must name the factory class"
#endif

NSView *mathsynth_au_make_view(AudioUnit unit);
void mathsynth_au_view_gone(void *ctx);

@interface MATHSYNTH_VIEW_CONTAINER : NSView {
@public
    void *ctx;
}
@end

@implementation MATHSYNTH_VIEW_CONTAINER
- (BOOL)isFlipped {
    return YES;
}
- (void)dealloc {
    if (ctx) mathsynth_au_view_gone(ctx);
    [super dealloc];
}
@end

@interface MATHSYNTH_VIEW_FACTORY : NSObject <AUCocoaUIBase>
@end

@implementation MATHSYNTH_VIEW_FACTORY
- (unsigned)interfaceVersion {
    return 0;
}
- (NSString *)description {
    return @"MathSynth";
}
- (NSView *)uiViewForAudioUnit:(AudioUnit)unit withSize:(NSSize)size {
    (void)size;
    return mathsynth_au_make_view(unit);
}
@end

// Returns a +1 container view that calls mathsynth_au_view_gone(ctx) when it
// is deallocated.
NSView *mathsynth_au_container_new(NSRect frame, void *ctx) {
    MATHSYNTH_VIEW_CONTAINER *view = [[MATHSYNTH_VIEW_CONTAINER alloc] initWithFrame:frame];
    view->ctx = ctx;
    return view;
}

NSView *mathsynth_au_autorelease(NSView *view) {
    return [view autorelease];
}
