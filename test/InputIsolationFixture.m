#import <AppKit/AppKit.h>
@interface InputFixtureView : NSView <NSTouchBarDelegate>
@property NSButton *button;
@property NSUInteger presses;
@end
@implementation InputFixtureView
- (BOOL)acceptsFirstResponder { return YES; }
- (NSTouchBar *)makeTouchBar {
    NSTouchBar *bar=[NSTouchBar new]; bar.delegate=self;
    bar.defaultItemIdentifiers=@[@"isolation.button",@"isolation.slider"]; return bar;
}
- (NSTouchBarItem *)touchBar:(NSTouchBar *)bar makeItemForIdentifier:(NSString *)identifier {
    NSCustomTouchBarItem *item=[[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];
    if([identifier hasSuffix:@"button"]) {
        self.button=[NSButton buttonWithTitle:@"TARGET OFF" target:self action:@selector(press:)];
        self.button.bezelColor=NSColor.systemBlueColor; item.view=self.button;
    } else {
        NSSlider *slider=[NSSlider sliderWithValue:25 minValue:0 maxValue:100 target:self action:@selector(slide:)];
        slider.continuous=YES; [slider.widthAnchor constraintEqualToConstant:300].active=YES; item.view=slider;
    }
    return item;
}
- (void)press:(id)sender {
    self.presses++; self.button.title=self.presses%2?@"TARGET ON":@"TARGET OFF";
    NSLog(@"ISOLATION_BUTTON %lu active=%d",self.presses,NSApp.active);
}
- (void)slide:(NSSlider *)sender { NSLog(@"ISOLATION_SLIDER %.3f active=%d",sender.doubleValue,NSApp.active); }
- (void)mouseDown:(NSEvent *)event { NSLog(@"ISOLATION_DESKTOP_DOWN %.1f %.1f",event.locationInWindow.x,event.locationInWindow.y); }
- (void)mouseDragged:(NSEvent *)event { NSLog(@"ISOLATION_DESKTOP_DRAG %.1f %.1f",event.locationInWindow.x,event.locationInWindow.y); }
- (void)mouseUp:(NSEvent *)event { NSLog(@"ISOLATION_DESKTOP_UP %.1f %.1f",event.locationInWindow.x,event.locationInWindow.y); }
@end
@interface FixtureDelegate : NSObject <NSApplicationDelegate>
@property NSWindow *window;
@end
@implementation FixtureDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(400,400,440,120) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    self.window.title=@"Touch Bar input isolation test";
    self.window.contentView=[[InputFixtureView alloc] initWithFrame:self.window.contentView.bounds];
    [self.window makeKeyAndOrderFront:nil]; [self.window makeFirstResponder:self.window.contentView];
    [NSApp activateIgnoringOtherApps:YES];
    NSLog(@"ISOLATION_READY window=%ld",self.window.windowNumber);
}
@end
int main(){ @autoreleasepool {
    NSApplication *app=NSApplication.sharedApplication;
    FixtureDelegate *delegate=[FixtureDelegate new]; app.delegate=delegate; [app run];
} }
