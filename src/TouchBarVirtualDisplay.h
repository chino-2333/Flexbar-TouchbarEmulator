#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

// Private CoreGraphics interfaces. Logical HiDPI mode sizes follow Chromium's
// virtual_display_mac_util.mm. Only the helper owns these session-only displays.
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)rate;
@end
@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic) unsigned int hiDPI;
@property(nonatomic, retain) NSArray *modes;
@end
@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic, retain) dispatch_queue_t queue;
@property(nonatomic, retain) NSString *name;
@property(nonatomic) unsigned int maxPixelsWide, maxPixelsHigh, vendorID, productID, serialNum;
@property(nonatomic) CGSize sizeInMillimeters;
@end
@interface CGVirtualDisplay : NSObject
@property(nonatomic, readonly) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

@interface TouchBarVirtualDisplay : NSObject
@property(nonatomic, strong) CGVirtualDisplay *display;
@property(nonatomic, strong) CGVirtualDisplay *anchor;
@property(nonatomic) BOOL stopped;
- (void)start:(void (^)(NSError *error))completion;
- (BOOL)getHostFrame:(NSRect *)frame;
- (void)stop;
@end

@implementation TouchBarVirtualDisplay
- (CGVirtualDisplay *)createDisplayWithName:(NSString *)name retina:(BOOL)retina product:(unsigned int)product {
    if (!NSClassFromString(@"CGVirtualDisplay")) return nil;
    CGVirtualDisplayDescriptor *descriptor = [CGVirtualDisplayDescriptor new];
    descriptor.queue = dispatch_get_main_queue();
    descriptor.name = name;
    descriptor.vendorID = 0xF17B; descriptor.productID = product; descriptor.serialNum = product;
    descriptor.maxPixelsWide = retina ? 2560 : 1920;
    descriptor.maxPixelsHigh = retina ? 1600 : 1080;
    descriptor.sizeInMillimeters = retina ? CGSizeMake(295,184) : CGSizeMake(480,270);
    CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
    CGVirtualDisplaySettings *settings = [CGVirtualDisplaySettings new];
    settings.hiDPI = retina ? 1 : 0;
    settings.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:retina ? 1280 : 1920
                                                         height:retina ? 800 : 1080 refreshRate:60]];
    return display && [display applySettings:settings] ? display : nil;
}
- (void)start:(void (^)(NSError *))completion {
    // macOS's headless fallback disappears when the first real virtual display
    // arrives. Keep a primary anchor only for that identifiable fallback case.
    CGDirectDisplayID initial = CGMainDisplayID();
    if (NSScreen.screens.count == 1 && CGDisplayVendorNumber(initial) == 0x756e6b6e &&
        CGDisplayModelNumber(initial) == 0x76697274) {
        self.anchor = [self createDisplayWithName:@"FlexBar Headless Desktop" retina:NO product:0x2702];
    }
    self.display = [self createDisplayWithName:@"FlexBar Touch Bar" retina:YES product:0x2701];
    if (!self.display) {
        completion([NSError errorWithDomain:@"TouchBarVirtualDisplay" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Could not create the Touch Bar virtual display"}]);
        return;
    }
    [self waitForDisplay:completion attempts:24];
}
- (void)waitForDisplay:(void (^)(NSError *))completion attempts:(NSInteger)attempts {
    if (self.stopped) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{
        if (self.stopped) return;
        NSScreen *target = nil;
        for (NSScreen *screen in NSScreen.screens) {
            if ([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == self.display.displayID) target = screen;
        }
        if (target && target.backingScaleFactor == 2 && NSScreen.screens.count > 1) {
            // Use the extension layout chosen by WindowServer. Submitting a
            // second display configuration just to add a gap invokes macOS's
            // global fade and can briefly blank every physical monitor. Never
            // rearrange the desktop to repair an unsafe/mirrored placement;
            // wait for it to settle, then fail closed if it stays unsafe.
            NSRect frame;
            if ([self getHostFrame:&frame]) {
                NSLog(@"TouchBarBridge virtual display ready (system placement, no rearrangement) id=%u screen=%@ backingScale=%.1f host=%@ anchor=%u",
                      self.display.displayID, NSStringFromRect(target.frame), target.backingScaleFactor,
                      NSStringFromRect(frame), self.anchor ? self.anchor.displayID : 0);
                completion(nil);
                return;
            }
        }
        if (attempts <= 0) {
            completion([NSError errorWithDomain:@"TouchBarVirtualDisplay" code:2 userInfo:@{NSLocalizedDescriptionKey:@"No isolated 2x Touch Bar virtual screen became available"}]);
            return;
        }
        [self waitForDisplay:completion attempts:attempts - 1];
    });
}
- (BOOL)getHostFrame:(NSRect *)frame {
    if (!self.display || self.stopped || NSScreen.screens.count < 2) return NO;
    NSScreen *target = nil;
    for (NSScreen *screen in NSScreen.screens) {
        if ([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == self.display.displayID) target = screen;
    }
    if (!target || target.backingScaleFactor != 2 || CGDisplayIsMain(self.display.displayID) ||
        CGDisplayIsInMirrorSet(self.display.displayID)) return NO;
    NSRect host = NSMakeRect(NSMinX(target.frame) + 30, NSMinY(target.frame) + 100, 1095, 40);
    if (!NSContainsRect(target.frame, host)) return NO;
    for (NSScreen *screen in NSScreen.screens) {
        if (screen != target && NSIntersectsRect(target.frame, screen.frame)) return NO;
    }
    if (frame) *frame = host;
    return YES;
}
- (void)stop {
    self.stopped = YES;
    self.display = nil;
    self.anchor = nil;
}
@end
