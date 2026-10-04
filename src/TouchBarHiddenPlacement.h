// Keep exactly one logical point on the leftmost screen for native 2x rendering.
// Coordinates are AppKit screen coordinates, including negative screen origins.
#import <AppKit/AppKit.h>
static NSRect TouchBarHiddenEdgeFrame(NSArray<NSValue *> *frames, NSSize hostSize) {
    NSRect edge = frames.count ? frames.firstObject.rectValue : NSMakeRect(0, 0, 1920, 1080);
    for (NSValue *value in frames) {
        NSRect candidate = value.rectValue;
        if (NSMinX(candidate) < NSMinX(edge) ||
            (NSMinX(candidate) == NSMinX(edge) && NSMinY(candidate) < NSMinY(edge))) edge = candidate;
    }
    return NSMakeRect(NSMinX(edge) - hostSize.width + 1.0,
                      NSMinY(edge) + MIN(100.0, MAX(0.0, edge.size.height - hostSize.height)),
                      hostSize.width, hostSize.height);
}
