#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>

// The simulator's service window is distinct from its host window. Address it
// directly: forwarding a host-targeted event through NSRemoteView drops input.
// Window-local event routing fields are private, as is CGEventSetWindowLocation.
// See https://github.com/tmc/apple/blob/main/x/skylight/mouse.go for field names.
@interface TouchBarServiceInput : NSObject
@property(nonatomic, readonly) BOOL available;
@property(nonatomic, readonly) BOOL pressed;
@property(nonatomic, readonly) pid_t targetPID;
@property(nonatomic, readonly) CGWindowID targetWindow;
- (BOOL)beginAt:(CGPoint)point servicePID:(pid_t)pid hostBounds:(CGRect)bounds;
- (BOOL)continueAt:(CGPoint)point down:(BOOL)down;
- (void)cancel;
@end

@implementation TouchBarServiceInput {
    void (*_setWindowLocation)(CGEventRef, CGPoint);
    CGEventSourceRef _source;
    CGRect _bounds;
    CGPoint _lastPoint;
    int64_t _sequence;
}
- (instancetype)init {
    if ((self = [super init])) {
        static void *sky;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LOCAL | RTLD_NOW); });
        if (sky) _setWindowLocation = dlsym(sky, "CGEventSetWindowLocation");
        // Private event state prevents synthetic presses changing the shared
        // session/HID button state used by the user's physical mouse.
        _source = CGEventSourceCreate(kCGEventSourceStatePrivate);
        if (_source) CGEventSourceSetUserData(_source, 0x464C455854424152);
    }
    return self;
}
- (void)dealloc { if (_source) CFRelease(_source); }
- (BOOL)available { return _source && _setWindowLocation; }
- (BOOL)beginAt:(CGPoint)point servicePID:(pid_t)pid hostBounds:(CGRect)bounds {
    if (!self.available || pid <= 0 || _pressed) return NO;
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
    CGWindowID match = kCGNullWindowID;
    CGRect matchedBounds = CGRectZero;
    for (NSDictionary *window in windows) {
        if ([window[(id)kCGWindowOwnerPID] intValue] != pid) continue;
        CGRect candidate;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(id)kCGWindowBounds], &candidate)) continue;
        if (fabs(candidate.origin.x-bounds.origin.x) > 2 || fabs(candidate.origin.y-bounds.origin.y) > 2 ||
            fabs(candidate.size.width-bounds.size.width) > 2 || fabs(candidate.size.height-bounds.size.height) > 2) continue;
        // Never guess between multiple windows, or target another app by name.
        if (match != kCGNullWindowID) return NO;
        match = [window[(id)kCGWindowNumber] unsignedIntValue];
        matchedBounds = candidate;
    }
    if (!match) return NO;
    _targetPID = pid; _targetWindow = match; _bounds = matchedBounds;
    _sequence++;
    if (![self postType:kCGEventLeftMouseDown at:point]) return NO;
    _pressed = YES;
    return YES;
}
- (BOOL)continueAt:(CGPoint)point down:(BOOL)down {
    if (!_pressed) return NO;
    if (![self postType:down ? kCGEventLeftMouseDragged : kCGEventLeftMouseUp at:point]) return NO;
    _pressed = down;
    return YES;
}
- (BOOL)postType:(CGEventType)type at:(CGPoint)point {
    if (!self.available || !_targetWindow || _targetPID <= 0 || !isfinite(point.x) || !isfinite(point.y)) return NO;
    CGPoint local = CGPointMake(fmax(0, fmin(_bounds.size.width-0.5, point.x)),
                               fmax(0, fmin(_bounds.size.height-0.5, point.y)));
    CGPoint global = CGPointMake(_bounds.origin.x+local.x, _bounds.origin.y+local.y);
    CGEventRef event = CGEventCreateMouseEvent(_source, type, global, kCGMouseButtonLeft);
    if (!event) return NO;
    CGEventSetFlags(event, 0);
    _setWindowLocation(event, local);
    CGEventSetIntegerValueField(event, (CGEventField)51, _targetWindow);
    CGEventSetIntegerValueField(event, (CGEventField)58, _sequence);
    CGEventSetIntegerValueField(event, kCGMouseEventWindowUnderMousePointer, _targetWindow);
    CGEventSetIntegerValueField(event, kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent, _targetWindow);
    CGEventSetIntegerValueField(event, kCGEventTargetUnixProcessID, _targetPID);
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, 1);
    CGEventSetIntegerValueField(event, kCGMouseEventSubtype, 3);
    CGEventPostToPid(_targetPID, event);
    CFRelease(event);
    _lastPoint = local;
    return YES;
}
- (void)cancel {
    if (_pressed) [self postType:kCGEventLeftMouseUp at:_lastPoint];
    _pressed = NO; _targetWindow = kCGNullWindowID; _targetPID = 0;
}
@end
