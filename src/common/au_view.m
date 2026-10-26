// Cocoa view factory for a plugin's Audio Unit. AU hosts find this class by
// name in the plugin bundle and check it conforms to AUCocoaUIBase, which
// needs real Objective-C metadata in the binary, so it lives here rather than
// in Zig. Everything else is forwarded to au.zig. Compiled without ARC, once
// per plugin, with these macros set by the build:
//
//   PLUGIN_VIEW_FACTORY    view factory class name (Metadata.auViewFactoryClass)
//   PLUGIN_VIEW_CONTAINER  container view class name (Metadata.auViewContainerClass)
//   PLUGIN_NAME            the plugin's name as a C string

#import <AppKit/AppKit.h>
#import <AudioToolbox/AUCocoaUIView.h>

#if !defined(PLUGIN_VIEW_FACTORY) || !defined(PLUGIN_VIEW_CONTAINER) || !defined(PLUGIN_NAME)
#error "PLUGIN_VIEW_FACTORY, PLUGIN_VIEW_CONTAINER and PLUGIN_NAME must be defined"
#endif

NSView *plugin_au_make_view(AudioUnit unit);
void plugin_au_view_gone(void *ctx);

@interface PLUGIN_VIEW_CONTAINER : NSView {
@public
    void *ctx;
}
@end

@implementation PLUGIN_VIEW_CONTAINER
- (BOOL)isFlipped {
    return YES;
}
- (void)dealloc {
    if (ctx) plugin_au_view_gone(ctx);
    [super dealloc];
}
@end

@interface PLUGIN_VIEW_FACTORY : NSObject <AUCocoaUIBase>
@end

@implementation PLUGIN_VIEW_FACTORY
- (unsigned)interfaceVersion {
    return 0;
}
- (NSString *)description {
    return @PLUGIN_NAME;
}
- (NSView *)uiViewForAudioUnit:(AudioUnit)unit withSize:(NSSize)size {
    (void)size;
    return plugin_au_make_view(unit);
}
@end

// Returns a +1 container view that calls plugin_au_view_gone(ctx) when it
// is deallocated.
NSView *plugin_au_container_new(NSRect frame, void *ctx) {
    PLUGIN_VIEW_CONTAINER *view = [[PLUGIN_VIEW_CONTAINER alloc] initWithFrame:frame];
    view->ctx = ctx;
    // Hosts that run the plugin out of process (GarageBand, Logic) show the
    // view remotely, which only carries layer contents: without a layer the
    // window stays empty.
    view.wantsLayer = YES;
    return view;
}

NSView *plugin_au_autorelease(NSView *view) {
    return [view autorelease];
}
