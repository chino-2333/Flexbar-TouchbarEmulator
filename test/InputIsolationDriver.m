// Test-only independent HID input source and 100 Hz observer. Never linked into
// the plugin. Commands target only the test fixture's desktop window.
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
static void emit(NSDictionary *value) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String); fflush(stdout);
}
int main(){ @autoreleasepool {
    [NSApplication sharedApplication];
    CGEventRef initial=CGEventCreate(NULL); CGPoint original=CGEventGetLocation(initial); CFRelease(initial);
    __block BOOL down=NO;
    __block CGPoint point=original;
    CGEventSourceRef source=CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    CGEventSourceSetUserData(source,0x54455354484944);
    [NSTimer scheduledTimerWithTimeInterval:0.01 repeats:YES block:^(NSTimer *timer){
        CGEventRef e=CGEventCreate(NULL); CGPoint p=CGEventGetLocation(e); CFRelease(e);
        emit(@{@"type":@"state",@"x":@(p.x),@"y":@(p.y),
            @"combined":@(CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState,kCGMouseButtonLeft)),
            @"hid":@(CGEventSourceButtonState(kCGEventSourceStateHIDSystemState,kCGMouseButtonLeft)),
            @"front":@(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier)});
    }];
    NSFileHandle *input=NSFileHandle.fileHandleWithStandardInput;
    NSMutableData *pending=[NSMutableData new];
    input.readabilityHandler=^(NSFileHandle *handle){
        NSData *data=handle.availableData;
        dispatch_async(dispatch_get_main_queue(),^{
            if(!data.length) {
                if(down) { CGEventRef e=CGEventCreateMouseEvent(source,kCGEventLeftMouseUp,point,kCGMouseButtonLeft); CGEventPost(kCGHIDEventTap,e); CFRelease(e); }
                CGWarpMouseCursorPosition(original); exit(0);
            }
            [pending appendData:data];
            NSData *newline=[@"\n" dataUsingEncoding:NSUTF8StringEncoding];
            NSRange line;
            while((line=[pending rangeOfData:newline options:0 range:NSMakeRange(0,pending.length)]).location!=NSNotFound){
                NSDictionary *cmd=[NSJSONSerialization JSONObjectWithData:[pending subdataWithRange:NSMakeRange(0,line.location)] options:0 error:nil];
                [pending replaceBytesInRange:NSMakeRange(0,line.location+1) withBytes:NULL length:0];
                NSString *action=cmd[@"action"];
                if([action isEqual:@"window"]){
                    NSArray *windows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID));
                    for(NSDictionary *w in windows)if([w[(id)kCGWindowOwnerPID] intValue]==[cmd[@"pid"] intValue]){
                        emit(@{@"type":@"window",@"bounds":w[(id)kCGWindowBounds]});break;
                    }
                    continue;
                }
                point=CGPointMake([cmd[@"x"] doubleValue],[cmd[@"y"] doubleValue]);
                CGEventType type=kCGEventMouseMoved;
                if([action isEqual:@"down"]){ type=kCGEventLeftMouseDown;down=YES; }
                if([action isEqual:@"drag"])type=kCGEventLeftMouseDragged;
                if([action isEqual:@"up"]){ type=kCGEventLeftMouseUp;down=NO; }
                CGEventRef e=CGEventCreateMouseEvent(source,type,point,kCGMouseButtonLeft);
                CGEventPost(kCGHIDEventTap,e); CFRelease(e);
            }
        });
    };
    [NSRunLoop.mainRunLoop run];
} }
