#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];
    NSMutableArray *displays = [NSMutableArray new];
    for (NSScreen *screen in NSScreen.screens) {
        CGDirectDisplayID ident = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        CGRect bounds = CGDisplayBounds(ident);
        [displays addObject:@{@"id":@(ident),@"vendor":@(CGDisplayVendorNumber(ident)),
            @"model":@(CGDisplayModelNumber(ident)),@"scale":@(screen.backingScaleFactor),
            @"x":@(bounds.origin.x),@"y":@(bounds.origin.y),
            @"pixelsWide":@(CGDisplayPixelsWide(ident)),@"pixelsHigh":@(CGDisplayPixelsHigh(ident)),
            @"mirrored":@(CGDisplayIsInMirrorSet(ident)),
            @"main":@(CGDisplayIsMain(ident)),@"width":@(screen.frame.size.width),@"height":@(screen.frame.size.height)}];
    }
    CGEventRef event = CGEventCreate(NULL); CGPoint point = CGEventGetLocation(event); CFRelease(event);
    NSDictionary *result = @{@"displays":displays,@"cursor":@[@(point.x),@(point.y)],
        @"leftDown":@(CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState,kCGMouseButtonLeft))};
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
} }
