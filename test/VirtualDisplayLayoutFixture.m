// Controlled pre-existing multi-monitor environment for the lifecycle test.
// No placement transaction: use WindowServer's normal extension layout.
#import "../src/TouchBarVirtualDisplay.h"
#import <signal.h>

int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    NSMutableArray *displays = [NSMutableArray new];
    for (unsigned int i = 0; i < 2; i++) {
        CGVirtualDisplayDescriptor *descriptor = [CGVirtualDisplayDescriptor new];
        descriptor.queue = dispatch_get_main_queue();
        descriptor.name = [NSString stringWithFormat:@"Touch Bar Test Existing Monitor %u", i + 1];
        descriptor.vendorID = 0x54455354;
        descriptor.productID = descriptor.serialNum = 0x5100 + i;
        descriptor.maxPixelsWide = i ? 2560 : 1920;
        descriptor.maxPixelsHigh = i ? 1600 : 1080;
        descriptor.sizeInMillimeters = CGSizeMake(480, 270);
        CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
        CGVirtualDisplaySettings *settings = [CGVirtualDisplaySettings new];
        settings.hiDPI = i;
        settings.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:i ? 1280 : 1920
                                                                             height:i ? 800 : 1080 refreshRate:60]];
        if (!display || ![display applySettings:settings]) return 1;
        [displays addObject:display];
    }
    signal(SIGTERM, SIG_IGN);
    dispatch_source_t termination = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(termination, ^{
        [displays removeAllObjects];
        [NSApp terminate:nil];
    });
    dispatch_resume(termination);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NSUInteger found = 0;
        for (NSScreen *screen in NSScreen.screens) {
            CGDirectDisplayID ident = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
            if (CGDisplayVendorNumber(ident) == 0x54455354) found++;
        }
        if (found != 2) exit(2);
        puts("LAYOUT_READY"); fflush(stdout);
    });
    [NSApp run];
} return 0; }
