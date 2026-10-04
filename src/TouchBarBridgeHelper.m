#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <unistd.h>
#import <signal.h>
#import "TouchBarVirtualDisplay.h"
#import "TouchBarServiceInput.h"
#import "TouchBarHiddenPlacement.h"
#import <CoreVideo/CoreVideo.h>

#ifndef SERVICE_BUNDLE_ID
#define SERVICE_BUNDLE_ID "com.apple.dt.Xcode.TouchBarSimulatorService"
#endif

#ifndef SERVICE_VIEW_CONTROLLER_CLASS
#define SERVICE_VIEW_CONTROLLER_CLASS "IDETouchBarSimulatorViewService"
#endif

static NSString *const FrameMagic = @"TBFR";
static const size_t TouchBarBridgeBackingWidth = 2190;
static const size_t TouchBarBridgeBackingHeight = 80;
static BOOL TouchBarBridgeDebugTouchBarButtonEnabled = NO;

typedef int (*CGSMainConnectionIDFn)(void);
typedef CGError (*CGSSetWindowResolutionFn)(int cid, uint32_t windowID, double resolution);
typedef void *(*DFRTouchBarSimulatorCreateFn)(int64_t version, void *options);
typedef void (*DFRTouchBarSimulatorInvalidateFn)(void *simulator);
typedef void (*DFRTouchBarSimulatorPostEventWithMouseActivityFn)(void *simulator, CGEventType event, NSPoint point);
typedef void *(*DFRTouchBarSimulatorGetTouchBarFn)(void *simulator);
typedef void (^DFRDisplayUpdateCallback)(CGDisplayStreamFrameStatus status, uint64_t displayTime, IOSurfaceRef surface, CGDisplayStreamUpdateRef update);
typedef CGDisplayStreamRef (*DFRTouchBarCreateDisplayStreamFn)(void *touchBar, size_t flags, dispatch_queue_t queue, DFRDisplayUpdateCallback callback);
typedef CGError (*CGDisplayStreamStartFn)(CGDisplayStreamRef displayStream);
typedef CGError (*CGDisplayStreamStopFn)(CGDisplayStreamRef displayStream);

static BOOL hasPostEventAccess(void) {
    if (@available(macOS 10.15, *)) {
        return CGPreflightPostEventAccess();
    }
    return YES;
}

@protocol TouchBarBridgeServiceProtocol
- (void)enableTouchBar;
- (void)enableTouchBarWithStyle:(NSInteger)style;
- (void)disableTouchBar;
@end

@interface NSRemoteViewControllerParameters : NSObject
@property(copy) NSString *serviceViewControllerClassName;
@property(copy) NSString *serviceBundleIdentifier;
@end

@interface NSRemoteViewController : NSViewController
+ (void)requestViewController:(NSRemoteViewControllerParameters *)configuration connectionHandler:(void (^)(NSRemoteViewController *viewController, NSError *error))handler;
- (id)serviceViewControllerProxy;
@end

@interface TouchBarBridgeRemoteViewController : NSRemoteViewController
@end

@implementation TouchBarBridgeRemoteViewController

- (NSXPCInterface *)serviceViewControllerInterface {
    return [NSXPCInterface interfaceWithProtocol:@protocol(TouchBarBridgeServiceProtocol)];
}

- (void)enableTouchBarWithStyle:(NSInteger)style {
    [[self serviceViewControllerProxy] enableTouchBarWithStyle:style];
}

- (void)disableTouchBar {
    [[self serviceViewControllerProxy] disableTouchBar];
}

@end

static NSTouchBarItemIdentifier const TouchBarBridgeItemIdentifier = @"com.chino.touchbaremulator.bridge.item";

@interface TouchBarBridgeContentView : NSView <NSTouchBarDelegate>
@property(nonatomic, strong) NSButton *debugTouchBarButton;
@property(nonatomic) BOOL debugTouchBarButtonOn;
@end

@implementation TouchBarBridgeContentView

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (NSTouchBar *)makeTouchBar {
    NSTouchBar *touchBar = [[NSTouchBar alloc] init];
    touchBar.delegate = self;
    touchBar.defaultItemIdentifiers = TouchBarBridgeDebugTouchBarButtonEnabled ? @[ TouchBarBridgeItemIdentifier ] : @[];
    return touchBar;
}

- (NSTouchBarItem *)touchBar:(NSTouchBar *)touchBar makeItemForIdentifier:(NSTouchBarItemIdentifier)identifier {
    (void)touchBar;
    if (![identifier isEqualToString:TouchBarBridgeItemIdentifier]) {
        return nil;
    }
    NSCustomTouchBarItem *item = [[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];
    self.debugTouchBarButton = [NSButton buttonWithTitle:@"TOUCH OFF"
                                                  target:self
                                                  action:@selector(debugTouchBarButtonPressed:)];
    self.debugTouchBarButton.bezelColor = NSColor.systemBlueColor;
    item.view = self.debugTouchBarButton;
    return item;
}

- (void)debugTouchBarButtonPressed:(id)sender {
    (void)sender;
    self.debugTouchBarButtonOn = !self.debugTouchBarButtonOn;
    self.debugTouchBarButton.title = self.debugTouchBarButtonOn ? @"TOUCH ON" : @"TOUCH OFF";
    NSLog(@"TouchBarBridge debug touchbar button pressed state=%d", self.debugTouchBarButtonOn);
}

@end

@interface TouchBarBridgeWindow : NSPanel
@end

@implementation TouchBarBridgeWindow

- (BOOL)canBecomeKeyWindow {
    return ![NSProcessInfo.processInfo.arguments containsObject:@"--virtual-display"] && ![NSProcessInfo.processInfo.arguments containsObject:@"--hidden-stream"];
}

- (BOOL)canBecomeMainWindow {
    return ![NSProcessInfo.processInfo.arguments containsObject:@"--virtual-display"] && ![NSProcessInfo.processInfo.arguments containsObject:@"--hidden-stream"];
}

- (NSRect)constrainFrameRect:(NSRect)frameRect toScreen:(NSScreen *)screen {
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--virtual-display"] || [NSProcessInfo.processInfo.arguments containsObject:@"--hidden-stream"]) return frameRect;
    return [super constrainFrameRect:frameRect toScreen:screen];
}

- (void)sendEvent:(NSEvent *)event {
    NSEventType type = event.type;
    if (type == NSEventTypeLeftMouseDown ||
        type == NSEventTypeLeftMouseDragged ||
        type == NSEventTypeLeftMouseUp ||
        type == NSEventTypeMouseMoved) {
        NSLog(@"TouchBarBridge host window sendEvent type=%ld location=%.2f,%.2f windowNumber=%ld hasCGEvent=%d",
              (long)type,
              event.locationInWindow.x,
              event.locationInWindow.y,
              (long)event.windowNumber,
              event.CGEvent != NULL);
    }
    [super sendEvent:event];
}

@end

@interface TouchBarBridgeMouseEvent : NSEvent
- (instancetype)initWithType:(NSEventType)type
                    location:(NSPoint)location
                   timestamp:(NSTimeInterval)timestamp
                      window:(NSWindow *)window
                 eventNumber:(NSInteger)eventNumber
                     cgEvent:(CGEventRef)cgEvent;
@end

@implementation TouchBarBridgeMouseEvent {
    NSEventType _bridgeType;
    NSPoint _bridgeLocation;
    NSTimeInterval _bridgeTimestamp;
    __weak NSWindow *_bridgeWindow;
    NSInteger _bridgeWindowNumber;
    NSInteger _bridgeEventNumber;
    CGEventRef _bridgeCGEvent;
}

- (instancetype)initWithType:(NSEventType)type
                    location:(NSPoint)location
                   timestamp:(NSTimeInterval)timestamp
                      window:(NSWindow *)window
                 eventNumber:(NSInteger)eventNumber
                     cgEvent:(CGEventRef)cgEvent {
    self = [super init];
    if (self) {
        _bridgeType = type;
        _bridgeLocation = location;
        _bridgeTimestamp = timestamp;
        _bridgeWindow = window;
        _bridgeWindowNumber = window.windowNumber;
        _bridgeEventNumber = eventNumber;
        _bridgeCGEvent = cgEvent ? (CGEventRef)CFRetain(cgEvent) : NULL;
    }
    return self;
}

- (void)dealloc {
    if (_bridgeCGEvent) {
        CFRelease(_bridgeCGEvent);
    }
}

- (NSEventType)type { return _bridgeType; }
- (NSPoint)locationInWindow { return _bridgeLocation; }
- (NSUInteger)modifierFlags { return 0; }
- (NSTimeInterval)timestamp { return _bridgeTimestamp; }
- (NSInteger)windowNumber { return _bridgeWindowNumber; }
- (NSWindow *)window { return _bridgeWindow; }
- (NSInteger)eventNumber { return _bridgeEventNumber; }
- (NSInteger)clickCount { return 1; }
- (NSInteger)buttonNumber { return 0; }
- (float)pressure { return _bridgeType == NSEventTypeLeftMouseUp ? 0.0f : 1.0f; }
- (CGEventRef)CGEvent { return _bridgeCGEvent; }

@end

static void normalizePremultipliedBGRA(NSMutableData *bgra) {
    uint8_t *pixels = bgra.mutableBytes;
    NSUInteger length = bgra.length;
    for (NSUInteger i = 0; i + 3 < length; i += 4) {
        uint8_t alpha = pixels[i + 3];
        if (alpha > 0 && alpha < 255) {
            pixels[i + 0] = (uint8_t)MIN(255, ((NSUInteger)pixels[i + 0] * 255 + alpha / 2) / alpha);
            pixels[i + 1] = (uint8_t)MIN(255, ((NSUInteger)pixels[i + 1] * 255 + alpha / 2) / alpha);
            pixels[i + 2] = (uint8_t)MIN(255, ((NSUInteger)pixels[i + 2] * 255 + alpha / 2) / alpha);
        }
        pixels[i + 3] = 255;
    }
}

static NSMutableData *createBGRADataFromImage(CGImageRef image) {
    size_t width = CGImageGetWidth(image);
    size_t height = CGImageGetHeight(image);
    size_t stride = width * 4;
    NSMutableData *bgra = [NSMutableData dataWithLength:height * stride];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(bgra.mutableBytes,
                                                 width,
                                                 height,
                                                 8,
                                                 stride,
                                                 colorSpace,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(colorSpace);
    if (!context) {
        return nil;
    }

    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context);
    normalizePremultipliedBGRA(bgra);
    return bgra;
}

static CGFloat effectiveScreenScale(void) {
    NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    CGFloat scale = screen ? screen.backingScaleFactor : 1.0;
    return (isfinite(scale) && scale > 0.0) ? scale : 1.0;
}

static NSSize touchBarHostPointSizeForScale(CGFloat scale) {
    CGFloat safeScale = (isfinite(scale) && scale > 0.0) ? scale : 1.0;
    return NSMakeSize((CGFloat)TouchBarBridgeBackingWidth / safeScale,
                      (CGFloat)TouchBarBridgeBackingHeight / safeScale);
}

static NSRect hiddenWindowFrame(NSSize hostSize) {
    NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    NSRect screenFrame = screen ? screen.frame : NSMakeRect(0, 0, hostSize.width, hostSize.height);
    return NSMakeRect(screenFrame.origin.x,
                      screenFrame.origin.y,
                      hostSize.width,
                      hostSize.height);
}

static NSRect offscreenWindowFrame(NSSize hostSize) {
    NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    NSRect screenFrame = screen ? screen.frame : NSMakeRect(0, 0, hostSize.width, hostSize.height);
    return NSMakeRect(NSMaxX(screenFrame) + 100.0,
                      screenFrame.origin.y,
                      hostSize.width,
                      hostSize.height);
}

static NSRect backgroundWindowFrame(NSSize hostSize) {
    return NSMakeRect(100.0, 100.0, hostSize.width, hostSize.height);
}

static NSRect edgeWindowFrame(NSSize hostSize) {
    NSMutableArray<NSValue *> *frames = [NSMutableArray new];
    for (NSScreen *screen in NSScreen.screens) [frames addObject:[NSValue valueWithRect:screen.frame]];
    return TouchBarHiddenEdgeFrame(frames, hostSize);
}

static BOOL isTransparentInteractiveHideMode(NSString *hideMode) {
    return [hideMode isEqualToString:@"transparent-interactive"];
}

static BOOL isTransparentFrontInteractiveHideMode(NSString *hideMode) {
    return [hideMode isEqualToString:@"transparent-front-interactive"];
}

static CGFloat clampCGFloat(CGFloat value, CGFloat minValue, CGFloat maxValue) {
    return MIN(MAX(value, minValue), maxValue);
}

static NSPoint touchBarLogicalPointFromPayload(NSDictionary *payload,
                                               CGFloat sourceWidth,
                                               CGFloat sourceHeight,
                                               NSInteger targetWidth,
                                               NSInteger targetHeight,
                                               NSSize remoteBoundsSize) {
    CGFloat rawX = [payload[@"x"] doubleValue];
    CGFloat rawY = [payload[@"y"] doubleValue];
    CGFloat fullWidth = (CGFloat)TouchBarBridgeBackingWidth;
    CGFloat fullHeight = (CGFloat)TouchBarBridgeBackingHeight;
    CGFloat cropWidth = MIN((CGFloat)targetWidth, fullWidth);
    CGFloat cropHeight = MIN((CGFloat)targetHeight, fullHeight);
    CGFloat insetX = MAX(0.0, (fullWidth - cropWidth) / 2.0);
    CGFloat insetY = MAX(0.0, (fullHeight - cropHeight) / 2.0);
    CGFloat boundsWidth = remoteBoundsSize.width > 0.0 ? remoteBoundsSize.width : 1095.0;
    CGFloat boundsHeight = remoteBoundsSize.height > 0.0 ? remoteBoundsSize.height : 40.0;
    CGFloat logicalScaleX = fullWidth > 0.0 ? boundsWidth / fullWidth : 0.5;
    CGFloat logicalScaleY = fullHeight > 0.0 ? boundsHeight / fullHeight : 0.5;
    CGFloat safeSourceWidth = sourceWidth > 0.0 ? sourceWidth : cropWidth;
    CGFloat safeSourceHeight = sourceHeight > 0.0 ? sourceHeight : cropHeight;
    CGFloat x = (insetX + (rawX / safeSourceWidth * cropWidth)) * logicalScaleX;
    CGFloat y = (insetY + (rawY / safeSourceHeight * cropHeight)) * logicalScaleY;
    return NSMakePoint(clampCGFloat(x, 0.0, boundsWidth), clampCGFloat(y, 0.0, boundsHeight));
}

static void applyWindowBackingStoreResolutionOverride(NSWindow *window) {
    if (!window || window.windowNumber <= 0) {
        return;
    }
    void *coreGraphics = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY);
    CGSMainConnectionIDFn mainConnectionID = coreGraphics ? (CGSMainConnectionIDFn)dlsym(coreGraphics, "CGSMainConnectionID") : NULL;
    CGSSetWindowResolutionFn setWindowResolution = coreGraphics ? (CGSSetWindowResolutionFn)dlsym(coreGraphics, "CGSSetWindowResolution") : NULL;
    int cid = mainConnectionID ? mainConnectionID() : 0;
    uint32_t windowID = (uint32_t)window.windowNumber;
    if (setWindowResolution) {
        setWindowResolution(cid, windowID, 2.0);
    }
}

static CGImageRef copyCenteredCropImage(CGImageRef image, NSInteger targetWidth, NSInteger targetHeight) {
    if (!image || targetWidth <= 0 || targetHeight <= 0) {
        return NULL;
    }

    CGFloat imageWidth = (CGFloat)CGImageGetWidth(image);
    CGFloat imageHeight = (CGFloat)CGImageGetHeight(image);
    CGFloat cropWidth = MIN((CGFloat)targetWidth, imageWidth);
    CGFloat cropHeight = MIN((CGFloat)targetHeight, imageHeight);
    CGRect cropRect = CGRectMake(floor(MAX(0.0, (imageWidth - cropWidth) / 2.0)),
                                 floor(MAX(0.0, (imageHeight - cropHeight) / 2.0)),
                                 cropWidth,
                                 cropHeight);
    if (CGRectEqualToRect(cropRect, CGRectMake(0, 0, imageWidth, imageHeight))) {
        return CGImageRetain(image);
    }
    return CGImageCreateWithImageInRect(image, cropRect);
}

static CGImageRef copyWindowServerImage(CGWindowID windowID) {
    if (windowID == 0) {
        return NULL;
    }
    typedef CGImageRef (*CGWindowListCreateImageFn)(CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption);
    void *coreGraphics = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY);
    CGWindowListCreateImageFn createImage = coreGraphics ? (CGWindowListCreateImageFn)dlsym(coreGraphics, "CGWindowListCreateImage") : NULL;
    if (!createImage) {
        return NULL;
    }
    return createImage(CGRectNull,
                       kCGWindowListOptionIncludingWindow,
                       windowID,
                       kCGWindowImageBoundsIgnoreFraming);
}

static NSString *writeCGImagePNG(CGImageRef image, NSString *directory, NSString *name) {
    if (!image || directory.length == 0 || name.length == 0) {
        return @"";
    }
    NSString *path = [directory stringByAppendingPathComponent:name];
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [png writeToFile:path atomically:YES];
    return path;
}

static NSNumber *unsignedIntegerSelectorValue(id object, SEL selector);
static id objectSelectorValue(id object, SEL selector);

static CGImageRef copyRemoteViewSnapshot(NSView *view, double *scaleOut) {
    if (!view) {
        return NULL;
    }
    double snapshotScale = 0.0;
    CGImageRef image = NULL;
    if ([view respondsToSelector:@selector(_snapshot:)]) {
        @try {
            image = ((CGImageRef (*)(id, SEL, double *))objc_msgSend)(view, @selector(_snapshot:), &snapshotScale);
        } @catch (__unused NSException *exception) {
            image = NULL;
        }
    }
    if (!image && [view respondsToSelector:@selector(snapshot)]) {
        @try {
            image = ((CGImageRef (*)(id, SEL))objc_msgSend)(view, @selector(snapshot));
        } @catch (__unused NSException *exception) {
            image = NULL;
        }
    }
    if (scaleOut) {
        *scaleOut = snapshotScale;
    }
    return image ? CGImageCreateCopy(image) : NULL;
}

static void requestRemoteViewSnapshotFiles(NSView *view, NSString *directory, NSString *label) {
    if (!view || directory.length == 0 || label.length == 0) {
        return;
    }
    if ([view respondsToSelector:@selector(snapshot:)]) {
        @try {
            void (^snapshotBlock)(CGImageRef) = ^(CGImageRef image) {
                if (image) {
                    writeCGImagePNG(image,
                                    directory,
                                    [NSString stringWithFormat:@"%@-remote-snapshot-async.png", label]);
                }
            };
            ((void (*)(id, SEL, id))objc_msgSend)(view, @selector(snapshot:), snapshotBlock);
        } @catch (__unused NSException *exception) {
        }
    }
    if ([view respondsToSelector:@selector(_snapshotWithScale:)]) {
        @try {
            void (^snapshotWithScaleBlock)(CGImageRef, double) = ^(CGImageRef image, double scale) {
                (void)scale;
                if (image) {
                    writeCGImagePNG(image,
                                    directory,
                                    [NSString stringWithFormat:@"%@-remote-snapshot-with-scale-async.png", label]);
                }
            };
            ((void (*)(id, SEL, id))objc_msgSend)(view, @selector(_snapshotWithScale:), snapshotWithScaleBlock);
        } @catch (__unused NSException *exception) {
        }
    }
}

static NSArray<NSDictionary *> *writeRenderServerCaptureProbes(CALayer *layer,
                                                               NSString *directory,
                                                               NSString *label,
                                                               NSInteger targetWidth,
                                                               NSInteger targetHeight) {
    if (!layer || directory.length == 0 || label.length == 0) {
        return @[];
    }
    if (![layer respondsToSelector:@selector(_copyRenderLayer:layerFlags:commitFlags:)]) {
        return @[];
    }

    void *quartzCore = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY);
    typedef CGImageRef (*CARenderServerCaptureLayerFn)(uint32_t, uint32_t, void *, uint32_t, uint32_t, uint32_t);
    typedef void (*CARenderReleaseFn)(void *);
    CARenderServerCaptureLayerFn captureLayer = quartzCore ? (CARenderServerCaptureLayerFn)dlsym(quartzCore, "CARenderServerCaptureLayer") : NULL;
    CARenderReleaseFn renderRelease = quartzCore ? (CARenderReleaseFn)dlsym(quartzCore, "CARenderRelease") : NULL;
    if (!captureLayer) {
        return @[];
    }

    uint32_t commitFlags = 0;
    void *renderLayer = NULL;
    @try {
        renderLayer = ((void *(*)(id, SEL, void *, uint32_t, uint32_t *))objc_msgSend)(layer,
                                                                                       @selector(_copyRenderLayer:layerFlags:commitFlags:),
                                                                                       NULL,
                                                                                       0,
                                                                                       &commitFlags);
    } @catch (__unused NSException *exception) {
        renderLayer = NULL;
    }
    if (!renderLayer) {
        return @[];
    }

    NSMutableArray<NSDictionary *> *results = [NSMutableArray array];
    NSMutableOrderedSet<NSNumber *> *contextIds = [NSMutableOrderedSet orderedSet];
    NSNumber *remoteContextId = unsignedIntegerSelectorValue(layer, @selector(contextId));
    if (remoteContextId) {
        [contextIds addObject:remoteContextId];
    }
    id localContext = objectSelectorValue(layer, @selector(context));
    NSNumber *localContextId = unsignedIntegerSelectorValue(localContext, @selector(contextId));
    if (localContextId) {
        [contextIds addObject:localContextId];
    }
    [contextIds addObject:@0];

    for (NSNumber *contextIdNumber in contextIds) {
        uint32_t contextId = contextIdNumber.unsignedIntValue;
        CGImageRef image = NULL;
        @try {
            image = captureLayer(0,
                                 contextId,
                                 renderLayer,
                                 (uint32_t)TouchBarBridgeBackingWidth,
                                 (uint32_t)TouchBarBridgeBackingHeight,
                                 0);
        } @catch (__unused NSException *exception) {
            image = NULL;
        }
        NSMutableDictionary *entry = [@{
            @"contextId": @(contextId),
            @"image": image ? @[ @(CGImageGetWidth(image)), @(CGImageGetHeight(image)) ] : @[],
        } mutableCopy];
        if (image) {
            NSString *name = [NSString stringWithFormat:@"%@-render-server-capture-%u-full.png", label, contextId];
            NSString *path = writeCGImagePNG(image, directory, name);
            if (path.length > 0) {
                entry[@"png"] = path;
            }
            CGImageRef cropped = copyCenteredCropImage(image, targetWidth, targetHeight);
            if (cropped) {
                NSString *croppedName = [NSString stringWithFormat:@"%@-render-server-capture-%u-cropped.png", label, contextId];
                NSString *croppedPath = writeCGImagePNG(cropped, directory, croppedName);
                if (croppedPath.length > 0) {
                    entry[@"croppedPng"] = croppedPath;
                    entry[@"croppedImage"] = @[ @(CGImageGetWidth(cropped)), @(CGImageGetHeight(cropped)) ];
                }
                CGImageRelease(cropped);
            }
            CGImageRelease(image);
        }
        [results addObject:entry];
    }

    if (renderRelease) {
        renderRelease(renderLayer);
    }
    return results;
}

static NSURL *argumentURL(void) {
    NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
    for (NSUInteger i = 0; i + 1 < arguments.count; i += 1) {
        if ([arguments[i] isEqualToString:@"--url"]) {
            return [NSURL URLWithString:arguments[i + 1]];
        }
    }
    NSString *envURL = NSProcessInfo.processInfo.environment[@"TOUCHBAR_BRIDGE_URL"];
    return envURL.length > 0 ? [NSURL URLWithString:envURL] : nil;
}

static NSInteger integerArgument(NSString *name, NSInteger fallback) {
    NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
    NSString *flag = [NSString stringWithFormat:@"--%@", name];
    for (NSUInteger i = 0; i + 1 < arguments.count; i += 1) {
        if ([arguments[i] isEqualToString:flag]) {
            return arguments[i + 1].integerValue;
        }
    }
    return fallback;
}

static double doubleArgument(NSString *name, double fallback) {
    NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
    NSString *flag = [NSString stringWithFormat:@"--%@", name];
    for (NSUInteger i = 0; i + 1 < arguments.count; i += 1) {
        if ([arguments[i] isEqualToString:flag]) {
            return arguments[i + 1].doubleValue;
        }
    }
    return fallback;
}

static NSString *stringArgument(NSString *name, NSString *fallback) {
    NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
    NSString *flag = [NSString stringWithFormat:@"--%@", name];
    for (NSUInteger i = 0; i + 1 < arguments.count; i += 1) {
        if ([arguments[i] isEqualToString:flag]) {
            return arguments[i + 1];
        }
    }
    return fallback;
}

static BOOL flagArgument(NSString *name) {
    NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
    NSString *flag = [NSString stringWithFormat:@"--%@", name];
    return [arguments containsObject:flag];
}

static NSArray<NSNumber *> *rectArray(CGRect rect) {
    return @[ @(rect.origin.x), @(rect.origin.y), @(rect.size.width), @(rect.size.height) ];
}

static NSString *pointerString(const void *pointer) {
    return [NSString stringWithFormat:@"%p", pointer];
}

static BOOL cgWindowTopLeftBoundsForWindowNumber(NSInteger windowNumber, CGRect *boundsOut) {
    if (windowNumber <= 0 || !boundsOut) {
        return NO;
    }
    CFArrayRef windowInfo = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, (CGWindowID)windowNumber);
    if (!windowInfo) {
        return NO;
    }
    NSArray *windows = CFBridgingRelease(windowInfo);
    NSDictionary *window = windows.firstObject;
    NSDictionary *bounds = [window isKindOfClass:NSDictionary.class] ? window[(id)kCGWindowBounds] : nil;
    if (![bounds isKindOfClass:NSDictionary.class]) {
        return NO;
    }
    CGRect rect = CGRectNull;
    if (!CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)bounds, &rect) || CGRectIsNull(rect)) {
        return NO;
    }
    *boundsOut = rect;
    return YES;
}

static CGPoint cgEventPointForWindowPoint(NSWindow *window, NSPoint windowPoint) {
    NSPoint screenPoint = [window convertPointToScreen:windowPoint];
    // Quartz Y is relative to the primary display, not the window's display.
    NSScreen *screen = NSScreen.screens.firstObject;
    NSRect screenFrame = screen ? screen.frame : NSMakeRect(0, 0, 0, 0);
    return CGPointMake(screenPoint.x, NSMaxY(screenFrame) - screenPoint.y);
}

static NSString *truncatedDescription(id object) {
    if (!object) {
        return @"";
    }
    NSString *description = [object description] ?: @"";
    if (description.length > 500) {
        return [[description substringToIndex:500] stringByAppendingString:@"..."];
    }
    return description;
}

static NSArray<NSString *> *matchingMethodNamesForClass(Class cls, NSArray<NSString *> *needles, NSUInteger maxDepth) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    Class current = cls;
    for (NSUInteger depth = 0; current && depth < maxDepth; depth += 1, current = class_getSuperclass(current)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(current, &count);
        for (unsigned int i = 0; i < count; i += 1) {
            SEL selector = method_getName(methods[i]);
            NSString *name = NSStringFromSelector(selector) ?: @"";
            NSString *lowercase = name.lowercaseString;
            BOOL matched = NO;
            for (NSString *needle in needles) {
                if ([lowercase containsString:needle.lowercaseString]) {
                    matched = YES;
                    break;
                }
            }
            if (matched) {
                const char *typeEncoding = method_getTypeEncoding(methods[i]);
                [names addObject:[NSString stringWithFormat:@"%@: %@ :: %s",
                                                            NSStringFromClass(current),
                                                            name,
                                                            typeEncoding ?: ""]];
            }
        }
        free(methods);
    }
    return names;
}

static NSNumber *unsignedIntegerSelectorValue(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) {
        return nil;
    }
    @try {
        NSUInteger value = ((NSUInteger (*)(id, SEL))objc_msgSend)(object, selector);
        return @(value);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSNumber *boolSelectorValue(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) {
        return nil;
    }
    @try {
        BOOL value = ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
        return @(value);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSNumber *doubleSelectorValue(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) {
        return nil;
    }
    @try {
        double value = ((double (*)(id, SEL))objc_msgSend)(object, selector);
        return @(value);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id objectSelectorValue(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) {
        return nil;
    }
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSDictionary *describeSurface(IOSurfaceRef surface) {
    if (!surface) {
        return nil;
    }
    return @{
        @"width": @(IOSurfaceGetWidth(surface)),
        @"height": @(IOSurfaceGetHeight(surface)),
        @"stride": @(IOSurfaceGetBytesPerRow(surface)),
        @"pixelFormat": @(IOSurfaceGetPixelFormat(surface)),
    };
}

typedef IOSurfaceRef (*CAIOSurfaceGetIOSurfaceFn)(void *surface);
static NSDictionary *describeRenderContextById(NSUInteger contextId);
static NSDictionary *describeHostingToken(id hostingToken);

static NSDictionary *describeLayerContents(id contents) {
    if (!contents) {
        return @{};
    }

    NSMutableDictionary *info = [@{
        @"class": NSStringFromClass([contents class]) ?: @"",
        @"description": truncatedDescription(contents),
    } mutableCopy];

    NSString *className = info[@"class"];
    if ([className containsString:@"IOSurface"]) {
        IOSurfaceRef surface = (__bridge IOSurfaceRef)contents;
        NSDictionary *surfaceInfo = describeSurface(surface);
        if (surfaceInfo) {
            info[@"iosurface"] = surfaceInfo;
        }
    }

    if ([className containsString:@"CAIOSurface"]) {
        void *quartzCore = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY);
        CAIOSurfaceGetIOSurfaceFn getIOSurface = quartzCore ? (CAIOSurfaceGetIOSurfaceFn)dlsym(quartzCore, "CAIOSurfaceGetIOSurface") : NULL;
        if (getIOSurface) {
            IOSurfaceRef surface = getIOSurface((__bridge void *)contents);
            NSDictionary *surfaceInfo = describeSurface(surface);
            if (surfaceInfo) {
                info[@"caiosurface"] = surfaceInfo;
            }
        }
    }
    return info;
}

static NSDictionary *describeLayer(CALayer *layer, NSUInteger depth) {
    if (!layer) {
        return @{};
    }

    NSMutableDictionary *info = [@{
        @"class": NSStringFromClass(layer.class) ?: @"",
        @"pointer": pointerString((__bridge const void *)layer),
        @"bounds": rectArray(layer.bounds),
        @"frame": rectArray(layer.frame),
        @"position": @[ @(layer.position.x), @(layer.position.y) ],
        @"contentsScale": @(layer.contentsScale),
        @"contentsGravity": layer.contentsGravity ?: @"",
        @"hidden": @(layer.hidden),
        @"opacity": @(layer.opacity),
        @"masksToBounds": @(layer.masksToBounds),
        @"sublayerCount": @(layer.sublayers.count),
    } mutableCopy];

    NSDictionary *contentsInfo = describeLayerContents(layer.contents);
    if (contentsInfo.count > 0) {
        info[@"contents"] = contentsInfo;
    }

    NSNumber *contextId = unsignedIntegerSelectorValue(layer, @selector(contextId));
    if (contextId) {
        info[@"contextId"] = contextId;
        info[@"renderContext"] = describeRenderContextById(contextId.unsignedIntegerValue);
    }
    NSNumber *resizesHostedContext = boolSelectorValue(layer, @selector(resizesHostedContext));
    if (resizesHostedContext) {
        info[@"resizesHostedContext"] = resizesHostedContext;
    }
    id layerContext = objectSelectorValue(layer, @selector(context));
    if (layerContext) {
        info[@"context"] = @{
            @"class": NSStringFromClass([layerContext class]) ?: @"",
            @"pointer": pointerString((__bridge const void *)layerContext),
            @"description": truncatedDescription(layerContext),
            @"contextId": unsignedIntegerSelectorValue(layerContext, @selector(contextId)) ?: @0,
            @"valid": boolSelectorValue(layerContext, @selector(valid)) ?: @NO,
        };
    }

    if (depth > 0 && layer.sublayers.count > 0) {
        NSMutableArray *children = [NSMutableArray array];
        for (CALayer *child in layer.sublayers) {
            [children addObject:describeLayer(child, depth - 1)];
        }
        info[@"sublayers"] = children;
    }
    return info;
}

static NSDictionary *describeCAContextForId(NSUInteger contextId) {
    Class contextClass = NSClassFromString(@"CAContext");
    if (!contextClass || ![contextClass respondsToSelector:@selector(contextWithId:)]) {
        return @{};
    }

    id context = nil;
    @try {
        context = ((id (*)(id, SEL, unsigned int))objc_msgSend)(contextClass, @selector(contextWithId:), (unsigned int)contextId);
    } @catch (__unused NSException *exception) {
        context = nil;
    }
    if (!context) {
        return @{ @"contextId": @(contextId), @"available": @NO };
    }

    NSMutableDictionary *info = [@{
        @"contextId": @(contextId),
        @"available": @YES,
        @"class": NSStringFromClass([context class]) ?: @"",
        @"pointer": pointerString((__bridge const void *)context),
        @"description": truncatedDescription(context),
        @"valid": boolSelectorValue(context, @selector(valid)) ?: @NO,
        @"displayId": unsignedIntegerSelectorValue(context, @selector(displayId)) ?: @0,
        @"displayNumber": unsignedIntegerSelectorValue(context, @selector(displayNumber)) ?: @0,
    } mutableCopy];

    id layer = objectSelectorValue(context, @selector(layer));
    if ([layer isKindOfClass:CALayer.class]) {
        info[@"layer"] = describeLayer(layer, 2);
    }
    id payload = objectSelectorValue(context, @selector(payload));
    if (payload) {
        info[@"payload"] = @{
            @"class": NSStringFromClass([payload class]) ?: @"",
            @"description": truncatedDescription(payload),
        };
    }
    id hostingToken = objectSelectorValue(context, @selector(hostingToken));
    if (hostingToken) {
        info[@"hostingToken"] = @{
            @"class": NSStringFromClass([hostingToken class]) ?: @"",
            @"description": truncatedDescription(hostingToken),
        };
    }
    id options = objectSelectorValue(context, @selector(options));
    if (options) {
        info[@"options"] = @{
            @"class": NSStringFromClass([options class]) ?: @"",
            @"description": truncatedDescription(options),
        };
    }
    return info;
}

static NSDictionary *describeCAContextObject(id context, NSString *label) {
    if (!context) {
        return @{ @"label": label ?: @"", @"available": @NO };
    }
    NSMutableDictionary *info = [@{
        @"label": label ?: @"",
        @"available": @YES,
        @"class": NSStringFromClass([context class]) ?: @"",
        @"pointer": pointerString((__bridge const void *)context),
        @"description": truncatedDescription(context),
        @"contextId": unsignedIntegerSelectorValue(context, @selector(contextId)) ?: @0,
        @"valid": boolSelectorValue(context, @selector(valid)) ?: @NO,
        @"displayId": unsignedIntegerSelectorValue(context, @selector(displayId)) ?: @0,
        @"displayNumber": unsignedIntegerSelectorValue(context, @selector(displayNumber)) ?: @0,
        @"defaultContentsScale": doubleSelectorValue(context, @selector(NS_defaultContentsScale)) ?: @0,
    } mutableCopy];
    id layer = objectSelectorValue(context, @selector(layer));
    if ([layer isKindOfClass:CALayer.class]) {
        info[@"layer"] = describeLayer(layer, 3);
    }
    id options = objectSelectorValue(context, @selector(options));
    if (options) {
        info[@"options"] = @{
            @"class": NSStringFromClass([options class]) ?: @"",
            @"description": truncatedDescription(options),
        };
    }
    id hostingToken = objectSelectorValue(context, @selector(hostingToken));
    if (hostingToken) {
        info[@"hostingToken"] = describeHostingToken(hostingToken);
    }
    return info;
}

static id quartzCoreConstantObject(const char *symbol) {
    void *quartzCore = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY);
    void *address = quartzCore ? dlsym(quartzCore, symbol) : NULL;
    if (!address) {
        return nil;
    }
    return (__bridge id)(*(void **)address);
}

static NSDictionary *describePixelDoublingRemoteContextForLayer(CALayer *layer) {
    id hostingToken = objectSelectorValue(layer, @selector(hostingToken));
    Class contextClass = NSClassFromString(@"CAContext");
    if (!hostingToken || !contextClass || ![contextClass respondsToSelector:@selector(remoteContextWithOptions:)]) {
        return @{ @"available": @NO };
    }
    id clientIDTokenKey = quartzCoreConstantObject("kCAContextClientIDToken");
    id pixelDoublingKey = quartzCoreConstantObject("kCAContextEnablePixelDoubling");
    if (!clientIDTokenKey || !pixelDoublingKey) {
        return @{
            @"available": @NO,
            @"hasClientIDTokenKey": @(clientIDTokenKey != nil),
            @"hasPixelDoublingKey": @(pixelDoublingKey != nil),
        };
    }
    NSDictionary *options = @{
        clientIDTokenKey: hostingToken,
        pixelDoublingKey: @YES,
    };
    id context = nil;
    @try {
        context = ((id (*)(id, SEL, id))objc_msgSend)(contextClass, @selector(remoteContextWithOptions:), options);
    } @catch (__unused NSException *exception) {
        context = nil;
    }
    return describeCAContextObject(context, @"pixelDoublingRemoteContext");
}

typedef void *(*CARenderContextByIdFn)(uint32_t contextId);

static NSDictionary *describeHostingToken(id hostingToken) {
    if (!hostingToken) {
        return @{};
    }
    NSMutableDictionary *info = [@{
        @"class": NSStringFromClass([hostingToken class]) ?: @"",
        @"description": truncatedDescription(hostingToken),
        @"pid": unsignedIntegerSelectorValue(hostingToken, @selector(pid)) ?: @0,
        @"authoritative": boolSelectorValue(hostingToken, @selector(isAuthoritative)) ?: @NO,
    } mutableCopy];
    id xpcRepresentation = objectSelectorValue(hostingToken, @selector(createXPCRepresentation));
    if (xpcRepresentation) {
        info[@"xpcRepresentation"] = @{
            @"class": NSStringFromClass([xpcRepresentation class]) ?: @"",
            @"description": truncatedDescription(xpcRepresentation),
        };
    }
    return info;
}

static NSDictionary *describeRenderContextById(NSUInteger contextId) {
    void *quartzCore = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY);
    CARenderContextByIdFn renderContextById = quartzCore ? (CARenderContextByIdFn)dlsym(quartzCore, "CARenderContextById") : NULL;
    if (!renderContextById) {
        return @{ @"contextId": @(contextId), @"available": @NO };
    }
    void *renderContext = NULL;
    @try {
        renderContext = renderContextById((uint32_t)contextId);
    } @catch (__unused NSException *exception) {
        renderContext = NULL;
    }
    return @{
        @"contextId": @(contextId),
        @"available": @(renderContext != NULL),
        @"pointer": pointerString(renderContext),
    };
}

static NSArray *describeAllLayerHosts(void) {
    Class layerHostClass = NSClassFromString(@"CALayerHost");
    if (!layerHostClass || ![layerHostClass respondsToSelector:@selector(allLayerHosts)]) {
        return @[];
    }
    id allHosts = objectSelectorValue(layerHostClass, @selector(allLayerHosts));
    if (![allHosts respondsToSelector:@selector(countByEnumeratingWithState:objects:count:)]) {
        return @[];
    }
    NSMutableArray *hosts = [NSMutableArray array];
    for (CALayer *host in allHosts) {
        NSMutableDictionary *entry = [describeLayer(host, 1) mutableCopy];
        NSNumber *contextId = entry[@"contextId"];
        if (contextId) {
            entry[@"caContext"] = describeCAContextForId(contextId.unsignedIntegerValue);
            entry[@"renderContext"] = describeRenderContextById(contextId.unsignedIntegerValue);
        }
        id hostingToken = objectSelectorValue(host, @selector(hostingToken));
        if (hostingToken) {
            entry[@"hostingToken"] = describeHostingToken(hostingToken);
        }
        [hosts addObject:entry];
    }
    return hosts;
}

static NSString *writeLayerRenderProbe(CALayer *layer, NSString *directory, NSString *name) {
    if (!layer || directory.length == 0) {
        return @"";
    }
    NSInteger width = MAX(1, (NSInteger)ceil(layer.bounds.size.width * 2.0));
    NSInteger height = MAX(1, (NSInteger)ceil(layer.bounds.size.height * 2.0));
    NSMutableData *bgra = [NSMutableData dataWithLength:width * height * 4];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(bgra.mutableBytes,
                                                 width,
                                                 height,
                                                 8,
                                                 width * 4,
                                                 colorSpace,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(colorSpace);
    if (!context) {
        return @"";
    }
    CGContextScaleCTM(context, 2.0, 2.0);
    [layer renderInContext:context];
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (!image) {
        return @"";
    }
    NSString *path = [directory stringByAppendingPathComponent:name];
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [png writeToFile:path atomically:YES];
    CGImageRelease(image);
    return path;
}

@interface TouchBarBridgeDelegate : NSObject <NSApplicationDelegate, NSURLSessionWebSocketDelegate, SCStreamOutput, SCStreamDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) TouchBarVirtualDisplay *virtualDisplay;
@property(nonatomic, strong) TouchBarServiceInput *serviceInput;
@property(nonatomic) BOOL virtualMode;
@property(nonatomic) BOOL hiddenStreamMode;
@property(nonatomic, strong) SCStream *captureStream;
@property(nonatomic) BOOL shuttingDown;
@property(nonatomic) NSTimeInterval lastMousePayloadTime;
@property(nonatomic) CGPoint lastHIDPoint;
@property(nonatomic) NSUInteger mouseSequence;
@property(nonatomic, strong) NSTimer *watchdog;
@property(nonatomic, strong) dispatch_source_t terminationSource;
@property(nonatomic, strong) dispatch_source_t interruptSource;
@property(nonatomic) pid_t originalParent;
- (void)releaseVirtualMouse;
- (void)startBridge;
@property(nonatomic, strong) TouchBarBridgeRemoteViewController *remote;
@property(nonatomic, strong) NSView *remoteView;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionWebSocketTask *webSocket;
@property(nonatomic, strong) NSTimer *frameTimer;
@property(nonatomic, strong) SCContentFilter *screenCaptureFilter;
@property(nonatomic, strong) SCStreamConfiguration *screenCaptureConfiguration;
@property(nonatomic) NSInteger targetWidth;
@property(nonatomic) NSInteger targetHeight;
@property(nonatomic) NSInteger fps;
@property(nonatomic) NSInteger touchBarStyle;
@property(nonatomic) NSInteger syntheticMouseEventNumber;
@property(nonatomic) BOOL mouseDown;
@property(nonatomic) BOOL sentFrameInfo;
@property(nonatomic) BOOL screenCaptureInFlight;
@property(nonatomic) BOOL sentScreenCaptureError;
@property(nonatomic) BOOL scaleRemoteView;
@property(nonatomic) BOOL hideWindow;
@property(nonatomic) BOOL surfaceDump;
@property(nonatomic) BOOL useWindowServerCapture;
@property(nonatomic) BOOL activateHidden;
@property(nonatomic) BOOL hidHitTestActive;
@property(nonatomic) NSWindowLevel hidHitTestOriginalLevel;
@property(nonatomic) CGFloat hidHitTestOriginalAlpha;
@property(nonatomic) BOOL hidHitTestOriginalIgnoresMouseEvents;
@property(nonatomic) CGFloat hidHitTestAlpha;
@property(nonatomic) BOOL hidHasOriginalCursorPoint;
@property(nonatomic) CGPoint hidOriginalCursorPoint;
@property(nonatomic) CGFloat hostScaleOverride;
@property(nonatomic) CGFloat lastLayoutScale;
@property(nonatomic) NSSize lastLayoutHostSize;
@property(nonatomic) void *dfrFramework;
@property(nonatomic) void *dfrSimulator;
@property(nonatomic) CGDisplayStreamRef dfrDisplayStream;
@property(nonatomic) CGDisplayStreamStartFn cgDisplayStreamStart;
@property(nonatomic) CGDisplayStreamStopFn cgDisplayStreamStop;
@property(nonatomic) DFRTouchBarSimulatorInvalidateFn dfrInvalidate;
@property(nonatomic) DFRTouchBarSimulatorPostEventWithMouseActivityFn dfrPostMouseActivity;
@property(nonatomic, copy) NSString *hideMode;
@property(nonatomic, copy) NSString *mouseDispatchMode;
@property(nonatomic, copy) NSString *surfaceDumpDir;
@end

@implementation TouchBarBridgeDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.hiddenStreamMode = flagArgument(@"hidden-stream");
    self.virtualMode = !self.hiddenStreamMode && flagArgument(@"virtual-display");
    self.originalParent = getppid();
    signal(SIGTERM, SIG_IGN);
    signal(SIGINT, SIG_IGN);
    self.terminationSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
    self.interruptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.terminationSource, ^{ [weakSelf releaseVirtualMouse]; [NSApp terminate:nil]; });
    dispatch_source_set_event_handler(self.interruptSource, ^{ [weakSelf releaseVirtualMouse]; [NSApp terminate:nil]; });
    dispatch_resume(self.terminationSource);
    dispatch_resume(self.interruptSource);
    self.watchdog = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        typeof(self) owner = weakSelf;
        if (!owner) return;
        if (getppid() != owner.originalParent) { [NSApp terminate:nil]; return; }
        if ((owner.virtualMode || owner.hiddenStreamMode) && owner.mouseDown && NSProcessInfo.processInfo.systemUptime - owner.lastMousePayloadTime > 10.0) {
            NSLog(@"TouchBarBridge releasing stale touch after missing up event");
            [owner releaseVirtualMouse];
        }
    }];
    if (self.virtualMode) {
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        self.virtualDisplay = [TouchBarVirtualDisplay new];
        [self.virtualDisplay start:^(NSError *error) {
            if (error) { NSLog(@"TouchBarBridge virtual display failed: %@",error); [NSApp terminate:nil]; return; }
            [self startBridge];
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(virtualScreensChanged:)
                                                        name:NSApplicationDidChangeScreenParametersNotification object:nil];
        }];
    } else {
        [self startBridge];
        if (self.hiddenStreamMode) [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(hiddenScreensChanged:)
            name:NSApplicationDidChangeScreenParametersNotification object:nil];
    }
}

- (void)startBridge {
    NSURL *url = argumentURL();
    if (!url) {
        NSLog(@"Missing --url");
        [NSApp terminate:nil];
        return;
    }

    self.targetWidth = integerArgument(@"width", 2170);
    self.targetHeight = integerArgument(@"height", 60);
    self.fps = MAX(1, integerArgument(@"fps", 60));
    self.touchBarStyle = integerArgument(@"style", self.virtualMode ? 3 : 2);
    self.scaleRemoteView = integerArgument(@"scale-remote", 0) != 0;
    self.hideWindow = !flagArgument(@"show-window");
    if (flagArgument(@"hide-window")) {
        self.hideWindow = YES;
    }
    if (self.virtualMode) self.hideWindow = NO; // Window is visible only on the isolated virtual screen.
    self.surfaceDump = flagArgument(@"surface-dump");
    NSString *captureSource = stringArgument(@"capture-source", @"screencapturekit");
    self.useWindowServerCapture = [captureSource isEqualToString:@"cgwindow"];
    self.activateHidden = flagArgument(@"activate-hidden");
    self.hostScaleOverride = (CGFloat)doubleArgument(@"host-scale", self.virtualMode ? 2.0 : 0.0);
    self.hideMode = stringArgument(@"hide-mode", @"orderout");
    self.mouseDispatchMode = stringArgument(@"mouse-dispatch", self.virtualMode ? @"service" : @"dfr");
    self.hidHitTestAlpha = MAX(0.0, MIN(1.0, (CGFloat)doubleArgument(@"hid-hit-test-alpha", 0.01)));
    NSString *windowLevel = stringArgument(@"window-level", @"");
    self.surfaceDumpDir = stringArgument(@"surface-dump-dir", @"/private/tmp/flexdesigner-touchbar-surface-dump");
    if (self.hiddenStreamMode) {
        self.hideWindow = YES;
        self.hideMode = @"edge";
        self.hostScaleOverride = 2.0;
        self.touchBarStyle = 3;
        self.mouseDispatchMode = @"service";
        self.useWindowServerCapture = NO;
        self.scaleRemoteView = NO;
        self.activateHidden = NO;
    }
    TouchBarBridgeDebugTouchBarButtonEnabled = flagArgument(@"debug-touchbar-button");
    NSLog(@"TouchBarBridge launch args=%@ target=%ldx%ld fps=%ld style=%ld hideWindow=%d hideMode=%@ mouseDispatch=%@ captureSource=%@ scaleRemote=%d hostScale=%.2f activateHidden=%d debugTouchBarButton=%d hidHitTestAlpha=%.3f",
          NSProcessInfo.processInfo.arguments,
          (long)self.targetWidth,
          (long)self.targetHeight,
          (long)self.fps,
          (long)self.touchBarStyle,
          self.hideWindow,
          self.hideMode,
          self.mouseDispatchMode,
          captureSource,
          self.scaleRemoteView,
          self.hostScaleOverride,
          self.activateHidden,
          TouchBarBridgeDebugTouchBarButtonEnabled,
          self.hidHitTestAlpha);

    BOOL transparentInteractiveHide = isTransparentInteractiveHideMode(self.hideMode);
    BOOL transparentFrontInteractiveHide = isTransparentFrontInteractiveHideMode(self.hideMode);
    if (self.hideWindow && !transparentInteractiveHide && !transparentFrontInteractiveHide) {
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    }

    CGFloat initialScale = self.hostScaleOverride > 0.0 ? self.hostScaleOverride : effectiveScreenScale();
    NSSize initialHostSize = touchBarHostPointSizeForScale(initialScale);
    NSRect windowRect = NSMakeRect(100.0, 100.0, initialHostSize.width, initialHostSize.height);
    if (self.hideWindow) {
        if ([self.hideMode isEqualToString:@"offscreen"]) {
            windowRect = offscreenWindowFrame(initialHostSize);
        } else if ([self.hideMode isEqualToString:@"background"] ||
                   [self.hideMode isEqualToString:@"underdesktop"] ||
                   [self.hideMode isEqualToString:@"transparent"] ||
                   transparentInteractiveHide ||
                   transparentFrontInteractiveHide) {
            windowRect = backgroundWindowFrame(initialHostSize);
        } else if ([self.hideMode isEqualToString:@"edge"]) {
            windowRect = edgeWindowFrame(initialHostSize);
        } else {
            windowRect = hiddenWindowFrame(initialHostSize);
        }
    }
    if (self.virtualMode && ![self.virtualDisplay getHostFrame:&windowRect]) {
        NSLog(@"TouchBarBridge refusing to show simulator on a non-virtual screen"); [NSApp terminate:nil]; return;
    }
    self.window = [[TouchBarBridgeWindow alloc] initWithContentRect:windowRect
                                                          styleMask:(NSWindowStyleMaskBorderless | ((self.virtualMode || self.hiddenStreamMode) ? NSWindowStyleMaskNonactivatingPanel : 0))
                                                            backing:NSBackingStoreBuffered
                                                              defer:NO];
    ((NSPanel *)self.window).hidesOnDeactivate = NO;
    if (self.virtualMode) {
        ((NSPanel *)self.window).becomesKeyOnlyIfNeeded = YES;
        self.window.collectionBehavior = NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle | NSWindowCollectionBehaviorFullScreenNone;
    }
    self.window.backgroundColor = NSColor.blackColor;
    self.window.opaque = YES;
    self.window.hasShadow = NO;
    self.window.movableByWindowBackground = NO;
    if (!self.virtualMode && !self.hiddenStreamMode) applyWindowBackingStoreResolutionOverride(self.window);
    if (self.hideWindow) {
        self.window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                         NSWindowCollectionBehaviorStationary |
                                         NSWindowCollectionBehaviorIgnoresCycle;
        self.window.ignoresMouseEvents = self.hiddenStreamMode ? NO : !transparentFrontInteractiveHide;
        if (![self.hideMode isEqualToString:@"offscreen"] &&
            ![self.hideMode isEqualToString:@"transparent"] &&
            !transparentInteractiveHide &&
            !transparentFrontInteractiveHide &&
            ![self.hideMode isEqualToString:@"edge"]) {
            self.window.level = (NSWindowLevel)(CGWindowLevelForKey(kCGDesktopWindowLevelKey) - 1);
        }
        if ([self.hideMode isEqualToString:@"transparent"] || transparentInteractiveHide || transparentFrontInteractiveHide) {
            self.window.alphaValue = transparentInteractiveHide ? 0.01 : 0.05;
            if (transparentFrontInteractiveHide) {
                self.window.alphaValue = MAX(0.01, self.hidHitTestAlpha);
            }
        }
    }
    if ([windowLevel isEqualToString:@"floating"]) {
        self.window.level = (NSWindowLevel)CGWindowLevelForKey(kCGFloatingWindowLevelKey);
    } else if ([windowLevel isEqualToString:@"status"]) {
        self.window.level = (NSWindowLevel)CGWindowLevelForKey(kCGStatusWindowLevelKey);
    }

    if (self.hiddenStreamMode) self.window.level = CGWindowLevelForKey(kCGDesktopWindowLevelKey) - 1;

    TouchBarBridgeContentView *contentView = [[TouchBarBridgeContentView alloc] initWithFrame:self.window.contentView.bounds];
    contentView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    contentView.wantsLayer = YES;
    contentView.layer.backgroundColor = NSColor.blackColor.CGColor;
    self.window.contentView = contentView;
    self.window.initialFirstResponder = contentView;
    if (self.hideWindow) {
        [self.window orderFrontRegardless];
        if (self.activateHidden) {
            [self.window makeKeyWindow];
            [self.window makeMainWindow];
            [self.window makeFirstResponder:contentView];
            [NSApp activateIgnoringOtherApps:YES];
        }
        if ([self.hideMode isEqualToString:@"background"] ||
            [self.hideMode isEqualToString:@"underdesktop"] ||
            [self.hideMode isEqualToString:@"transparent"] ||
            transparentInteractiveHide ||
            [self.hideMode isEqualToString:@"edge"]) {
            [self.window orderBack:nil];
        }
    } else if (self.virtualMode) {
        [self.window orderFrontRegardless];
    } else {
        [self.window makeKeyAndOrderFront:nil];
        [self.window makeMainWindow];
        [self.window makeFirstResponder:contentView];
        [NSApp activateIgnoringOtherApps:YES];
    }
    NSLog(@"TouchBarBridge window state hidden=%d visible=%d frame=%@ level=%ld alpha=%.3f ignoresMouse=%d collectionBehavior=%llu windowNumber=%ld activationPolicy=%ld",
          self.hideWindow,
          self.window.visible,
          NSStringFromRect(self.window.frame),
          (long)self.window.level,
          self.window.alphaValue,
          self.window.ignoresMouseEvents,
          (unsigned long long)self.window.collectionBehavior,
          (long)self.window.windowNumber,
          (long)NSApp.activationPolicy);
    self.session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration delegate:self delegateQueue:nil];
    self.webSocket = [self.session webSocketTaskWithURL:url];
    [self.webSocket resume];
    [self receiveWebSocketMessage];

    NSRemoteViewControllerParameters *configuration = [[NSClassFromString(@"NSRemoteViewControllerParameters") alloc] init];
    configuration.serviceViewControllerClassName = @SERVICE_VIEW_CONTROLLER_CLASS;
    configuration.serviceBundleIdentifier = @SERVICE_BUNDLE_ID;

    [TouchBarBridgeRemoteViewController requestViewController:configuration connectionHandler:^(NSRemoteViewController *viewController, NSError *error) {
        if (error || !viewController) {
            [self sendJSON:@{ @"type": @"error", @"message": error.localizedDescription ?: @"view service unavailable" }];
            [NSApp terminate:nil];
            return;
        }

        self.remote = (TouchBarBridgeRemoteViewController *)viewController;
        self.remoteView = viewController.view;
        NSArray<NSString *> *remoteViewEventMethods = matchingMethodNamesForClass(self.remoteView.class,
                                                                                  @[ @"mouse", @"event", @"remote", @"send", @"forward" ],
                                                                                  8);
        id serviceMarshal = nil;
        NSArray<NSString *> *serviceMarshalMethods = @[];
        if ([self.remoteView respondsToSelector:@selector(serviceMarshalForRemoteViewWindow:)]) {
            serviceMarshal = ((id (*)(id, SEL, id))objc_msgSend)(self.remoteView,
                                                                  @selector(serviceMarshalForRemoteViewWindow:),
                                                                  self.window);
            if (serviceMarshal) {
                serviceMarshalMethods = matchingMethodNamesForClass([serviceMarshal class],
                                                                    @[ @"mouse", @"event", @"remote", @"send", @"window", @"service" ],
                                                                    8);
            }
        }
        NSLog(@"TouchBarBridge remote view diagnostics class=%@ superclass=%@ eventMethods=%@",
              NSStringFromClass(self.remoteView.class),
              NSStringFromClass(class_getSuperclass(self.remoteView.class)),
              remoteViewEventMethods);
        [self sendJSON:@{
            @"type": @"remote-view-diagnostics",
            @"class": NSStringFromClass(self.remoteView.class) ?: @"",
            @"superclass": NSStringFromClass(class_getSuperclass(self.remoteView.class)) ?: @"",
            @"eventMethods": remoteViewEventMethods,
            @"serviceMarshalClass": serviceMarshal ? NSStringFromClass([serviceMarshal class]) : @"",
            @"serviceMarshalDescription": truncatedDescription(serviceMarshal),
            @"serviceMarshalMethods": serviceMarshalMethods,
        }];
        self.remoteView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self.window.contentView addSubview:self.remoteView];
        [self applyTargetLayout];
        id attachedServiceMarshal = nil;
        NSArray<NSString *> *attachedServiceMarshalMethods = @[];
        if ([self.remoteView respondsToSelector:@selector(serviceMarshalForRemoteViewWindow:)]) {
            attachedServiceMarshal = ((id (*)(id, SEL, id))objc_msgSend)(self.remoteView,
                                                                          @selector(serviceMarshalForRemoteViewWindow:),
                                                                          self.window);
            if (attachedServiceMarshal) {
                attachedServiceMarshalMethods = matchingMethodNamesForClass([attachedServiceMarshal class],
                                                                            @[ @"mouse", @"event", @"remote", @"send", @"window", @"service" ],
                                                                            8);
            }
        }
        NSLog(@"TouchBarBridge attached service marshal class=%@ description=%@ methods=%@",
              attachedServiceMarshal ? NSStringFromClass([attachedServiceMarshal class]) : @"",
              truncatedDescription(attachedServiceMarshal),
              attachedServiceMarshalMethods);
        [self sendJSON:@{
            @"type": @"attached-service-marshal-diagnostics",
            @"serviceMarshalClass": attachedServiceMarshal ? NSStringFromClass([attachedServiceMarshal class]) : @"",
            @"serviceMarshalDescription": truncatedDescription(attachedServiceMarshal),
            @"serviceMarshalMethods": attachedServiceMarshalMethods,
        }];

        [self.remote enableTouchBarWithStyle:self.touchBarStyle];
        [self setupMouseDispatcher];
        [self applyFunctionRowContextScale];
        [self setupScreenCapture];
        if (self.surfaceDump) {
            [self scheduleSurfaceDump];
        }
        [self sendJSON:@{
            @"type": @"ready",
            @"width": @(self.targetWidth),
            @"height": @(self.targetHeight),
            @"fps": @(self.fps),
        }];
        [self startFrameTimer];
    }];
}

- (void)setupMouseDispatcher {
    if ([self.mouseDispatchMode isEqualToString:@"service"]) {
        self.serviceInput = [TouchBarServiceInput new];
        BOOL available = self.serviceInput.available && [self.remote respondsToSelector:@selector(serviceProcessIdentifier)] && hasPostEventAccess();
        [self sendJSON:@{@"type": available ? @"mouse-dispatch-ready" : @"mouse-dispatch-error",
                        @"dispatcher": @"service", @"available": @(available),
                        @"message": available ? @"Direct service-window input; no global mouse events" : @"Service input unavailable; no HID fallback"}];
        return;
    }
    NSUInteger mouseEventMask = NSEventMaskLeftMouseDown |
                                NSEventMaskLeftMouseDragged |
                                NSEventMaskLeftMouseUp |
                                NSEventMaskMouseMoved;
    if ([self.mouseDispatchMode isEqualToString:@"appkit"] ||
        [self.mouseDispatchMode isEqualToString:@"appkit-nsevent"] ||
        [self.mouseDispatchMode isEqualToString:@"appkit-monitor"] ||
        [self.mouseDispatchMode isEqualToString:@"remoteview"] ||
        [self.mouseDispatchMode isEqualToString:@"remoteview-nsevent"] ||
        [self.mouseDispatchMode isEqualToString:@"sendremote"] ||
        [self.mouseDispatchMode isEqualToString:@"sendremote-nsevent"] ||
        [self.mouseDispatchMode isEqualToString:@"postapp"] ||
        [self.mouseDispatchMode isEqualToString:@"nsapp"] ||
        [self.mouseDispatchMode isEqualToString:@"serviceleft"] ||
        [self.mouseDispatchMode isEqualToString:@"fakeclick"]) {
        NSLog(@"TouchBarBridge mouse dispatcher using %@ remote-view event forwarding mode", self.mouseDispatchMode);
        if ([self.remoteView respondsToSelector:@selector(_setServiceWindowEventMask:)]) {
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(self.remoteView,
                                                          @selector(_setServiceWindowEventMask:),
                                                          mouseEventMask);
            NSLog(@"TouchBarBridge remote view service event mask set mask=%llu", (unsigned long long)mouseEventMask);
        }
        if ([self.mouseDispatchMode isEqualToString:@"appkit-monitor"]) {
            if ([self.remoteView respondsToSelector:@selector(setTrustsServiceKeyEvents:)]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(self.remoteView,
                                                        @selector(setTrustsServiceKeyEvents:),
                                                        YES);
                NSLog(@"TouchBarBridge remote view trusts service key events enabled");
            }
            if ([self.remoteView respondsToSelector:@selector(maintainProcessNotificationEventMonitor:)]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(self.remoteView,
                                                        @selector(maintainProcessNotificationEventMonitor:),
                                                        YES);
                NSLog(@"TouchBarBridge remote view process notification monitor enabled");
            }
            if ([self.remoteView respondsToSelector:@selector(maintainWindowEventMonitor:)]) {
                ((void (*)(id, SEL, uint32_t))objc_msgSend)(self.remoteView,
                                                            @selector(maintainWindowEventMonitor:),
                                                            (uint32_t)self.window.windowNumber);
                NSLog(@"TouchBarBridge remote view window event monitor enabled windowNumber=%ld",
                      (long)self.window.windowNumber);
            }
        }
        [self sendJSON:@{ @"type": @"mouse-dispatch-ready", @"dispatcher": self.mouseDispatchMode }];
        return;
    }
    if ([self.mouseDispatchMode isEqualToString:@"none"]) {
        NSLog(@"TouchBarBridge mouse dispatcher disabled");
        [self sendJSON:@{ @"type": @"mouse-dispatch-ready", @"dispatcher": @"none" }];
        return;
    }
    if ([self.mouseDispatchMode isEqualToString:@"cgevent"] ||
        [self.mouseDispatchMode isEqualToString:@"hid"]) {
        if ([self.remoteView respondsToSelector:@selector(_setServiceWindowEventMask:)]) {
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(self.remoteView,
                                                          @selector(_setServiceWindowEventMask:),
                                                          mouseEventMask);
            NSLog(@"TouchBarBridge remote view service event mask set for %@ mask=%llu",
                  self.mouseDispatchMode,
                  (unsigned long long)mouseEventMask);
        }
        BOOL postEventAccess = hasPostEventAccess();
        NSLog(@"TouchBarBridge mouse dispatcher using %@ mode pid=%d postEventAccess=%d",
              self.mouseDispatchMode,
              getpid(),
              postEventAccess);
        [self sendJSON:@{
            @"type": @"mouse-dispatch-ready",
            @"dispatcher": self.mouseDispatchMode,
            @"pid": @(getpid()),
            @"postEventAccess": @(postEventAccess),
        }];
        return;
    }

    self.dfrFramework = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY);
    if (!self.dfrFramework) {
        const char *error = dlerror();
        NSString *message = error ? [NSString stringWithUTF8String:error] : @"DFRFoundation dlopen failed";
        NSLog(@"TouchBarBridge DFR mouse dispatcher unavailable: %@", message);
        [self sendJSON:@{ @"type": @"mouse-dispatch-error", @"dispatcher": self.mouseDispatchMode ?: @"dfr", @"message": message }];
        return;
    }

    DFRTouchBarSimulatorCreateFn create = (DFRTouchBarSimulatorCreateFn)dlsym(self.dfrFramework, "DFRTouchBarSimulatorCreate");
    DFRTouchBarSimulatorGetTouchBarFn getTouchBar = (DFRTouchBarSimulatorGetTouchBarFn)dlsym(self.dfrFramework, "DFRTouchBarSimulatorGetTouchBar");
    DFRTouchBarCreateDisplayStreamFn createDisplayStream = (DFRTouchBarCreateDisplayStreamFn)dlsym(self.dfrFramework, "DFRTouchBarCreateDisplayStream");
    self.dfrInvalidate = (DFRTouchBarSimulatorInvalidateFn)dlsym(self.dfrFramework, "DFRTouchBarSimulatorInvalidate");
    self.dfrPostMouseActivity = (DFRTouchBarSimulatorPostEventWithMouseActivityFn)dlsym(self.dfrFramework, "DFRTouchBarSimulatorPostEventWithMouseActivity");
    self.cgDisplayStreamStart = (CGDisplayStreamStartFn)dlsym(RTLD_DEFAULT, "CGDisplayStreamStart");
    self.cgDisplayStreamStop = (CGDisplayStreamStopFn)dlsym(RTLD_DEFAULT, "CGDisplayStreamStop");
    if (!create || !getTouchBar || !createDisplayStream || !self.dfrPostMouseActivity || !self.cgDisplayStreamStart || !self.cgDisplayStreamStop) {
        NSLog(@"TouchBarBridge DFR mouse dispatcher missing symbols create=%p getTouchBar=%p createDisplayStream=%p post=%p invalidate=%p streamStart=%p streamStop=%p",
              create,
              getTouchBar,
              createDisplayStream,
              self.dfrPostMouseActivity,
              self.dfrInvalidate,
              self.cgDisplayStreamStart,
              self.cgDisplayStreamStop);
        [self sendJSON:@{
            @"type": @"mouse-dispatch-error",
            @"dispatcher": self.mouseDispatchMode ?: @"dfr",
            @"message": @"DFRFoundation mouse symbols unavailable",
            @"hasCreate": @(create != NULL),
            @"hasGetTouchBar": @(getTouchBar != NULL),
            @"hasCreateDisplayStream": @(createDisplayStream != NULL),
            @"hasPostMouse": @(self.dfrPostMouseActivity != NULL),
            @"hasInvalidate": @(self.dfrInvalidate != NULL),
            @"hasStreamStart": @(self.cgDisplayStreamStart != NULL),
            @"hasStreamStop": @(self.cgDisplayStreamStop != NULL),
        }];
        return;
    }

    self.dfrSimulator = create((int64_t)self.touchBarStyle, NULL);
    if (!self.dfrSimulator) {
        NSLog(@"TouchBarBridge DFR mouse dispatcher create failed style=%ld", (long)self.touchBarStyle);
        [self sendJSON:@{
            @"type": @"mouse-dispatch-error",
            @"dispatcher": self.mouseDispatchMode ?: @"dfr",
            @"message": @"DFRTouchBarSimulatorCreate failed",
            @"style": @(self.touchBarStyle),
        }];
        return;
    }

    void *touchBar = getTouchBar(self.dfrSimulator);
    if (!touchBar) {
        NSLog(@"TouchBarBridge DFR mouse dispatcher get touchbar failed simulator=%p style=%ld",
              self.dfrSimulator,
              (long)self.touchBarStyle);
        [self sendJSON:@{
            @"type": @"mouse-dispatch-error",
            @"dispatcher": self.mouseDispatchMode ?: @"dfr",
            @"message": @"DFRTouchBarSimulatorGetTouchBar failed",
            @"style": @(self.touchBarStyle),
            @"simulator": pointerString(self.dfrSimulator),
        }];
        return;
    }

    __block NSUInteger activationFrameCount = 0;
    DFRDisplayUpdateCallback activationCallback = ^(CGDisplayStreamFrameStatus status,
                                                    uint64_t displayTime,
                                                    IOSurfaceRef surface,
                                                    CGDisplayStreamUpdateRef update) {
        (void)update;
        activationFrameCount++;
        if (activationFrameCount <= 3) {
            size_t surfaceWidth = surface ? IOSurfaceGetWidth(surface) : 0;
            size_t surfaceHeight = surface ? IOSurfaceGetHeight(surface) : 0;
            NSLog(@"TouchBarBridge DFR activation stream frame status=%d displayTime=%llu surface=%zux%zu count=%lu",
                  (int)status,
                  (unsigned long long)displayTime,
                  surfaceWidth,
                  surfaceHeight,
                  (unsigned long)activationFrameCount);
        }
    };
    self.dfrDisplayStream = createDisplayStream(touchBar, 0, dispatch_get_main_queue(), activationCallback);
    CGError streamStart = self.dfrDisplayStream ? self.cgDisplayStreamStart(self.dfrDisplayStream) : kCGErrorFailure;
    if (!self.dfrDisplayStream || streamStart != kCGErrorSuccess) {
        NSLog(@"TouchBarBridge DFR mouse dispatcher display stream failed touchBar=%p stream=%p start=%d style=%ld",
              touchBar,
              self.dfrDisplayStream,
              streamStart,
              (long)self.touchBarStyle);
        [self sendJSON:@{
            @"type": @"mouse-dispatch-error",
            @"dispatcher": @"dfr",
            @"message": @"DFRTouchBarCreateDisplayStream failed",
            @"style": @(self.touchBarStyle),
            @"simulator": pointerString(self.dfrSimulator),
            @"touchBar": pointerString(touchBar),
            @"stream": pointerString(self.dfrDisplayStream),
            @"streamStart": @(streamStart),
        }];
        return;
    }

    NSLog(@"TouchBarBridge DFR mouse dispatcher ready simulator=%p touchBar=%p stream=%p streamStart=%d style=%ld",
          self.dfrSimulator,
          touchBar,
          self.dfrDisplayStream,
          streamStart,
          (long)self.touchBarStyle);
    [self sendJSON:@{
        @"type": @"mouse-dispatch-ready",
        @"dispatcher": @"dfr",
        @"style": @(self.touchBarStyle),
        @"simulator": pointerString(self.dfrSimulator),
        @"touchBar": pointerString(touchBar),
        @"stream": pointerString(self.dfrDisplayStream),
        @"streamStart": @(streamStart),
    }];
}

- (void)scheduleSurfaceDump {
    [[NSFileManager defaultManager] createDirectoryAtPath:self.surfaceDumpDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:NO block:^(NSTimer *timer) {
        (void)timer;
        [self sendSurfaceDumpWithLabel:@"surface-dump-1s"];
    }];
    [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:NO block:^(NSTimer *timer) {
        (void)timer;
        [self sendSurfaceDumpWithLabel:@"surface-dump-3s"];
    }];
}

- (void)sendSurfaceDumpWithLabel:(NSString *)label {
    CGWindowID windowID = (CGWindowID)self.window.windowNumber;
    Class contextClass = NSClassFromString(@"CAContext");
    id functionRowContext = objectSelectorValue(contextClass, @selector(NS_functionRowContext));
    id currentContext = objectSelectorValue(contextClass, @selector(currentContext));
    NSMutableDictionary *payload = [@{
        @"type": @"surface-dump",
        @"label": label,
        @"dumpDir": self.surfaceDumpDir ?: @"",
        @"windowID": @(windowID),
        @"arguments": NSProcessInfo.processInfo.arguments ?: @[],
        @"effectiveScreenScale": @(effectiveScreenScale()),
        @"windowBackingScaleFactor": @(self.window.backingScaleFactor),
        @"hostScaleOverride": @(self.hostScaleOverride),
        @"lastLayoutScale": @(self.lastLayoutScale),
        @"lastLayoutHostSize": @[ @(self.lastLayoutHostSize.width), @(self.lastLayoutHostSize.height) ],
        @"windowFrame": rectArray(self.window.frame),
        @"contentBounds": rectArray(self.window.contentView.bounds),
        @"remoteViewClass": NSStringFromClass(self.remoteView.class) ?: @"",
        @"remoteFrame": rectArray(self.remoteView.frame),
        @"remoteBounds": rectArray(self.remoteView.bounds),
        @"remoteLayer": describeLayer(self.remoteView.layer, 4),
        @"contentLayer": describeLayer(self.window.contentView.layer, 3),
        @"allLayerHosts": describeAllLayerHosts(),
        @"functionRowContext": describeCAContextObject(functionRowContext, @"NS_functionRowContext"),
        @"currentCAContext": describeCAContextObject(currentContext, @"currentContext"),
        @"pixelDoublingRemoteContext": describePixelDoublingRemoteContextForLayer(self.remoteView.layer),
    } mutableCopy];

    NSString *remoteLayerPath = writeLayerRenderProbe(self.remoteView.layer,
                                                      self.surfaceDumpDir,
                                                      [NSString stringWithFormat:@"%@-remote-layer-render.png", label]);
    if (remoteLayerPath.length > 0) {
        payload[@"remoteLayerRenderPng"] = remoteLayerPath;
    }
    NSString *contentLayerPath = writeLayerRenderProbe(self.window.contentView.layer,
                                                       self.surfaceDumpDir,
                                                       [NSString stringWithFormat:@"%@-content-layer-render.png", label]);
    if (contentLayerPath.length > 0) {
        payload[@"contentLayerRenderPng"] = contentLayerPath;
    }

    CGImageRef windowImage = copyWindowServerImage(windowID);
    if (windowImage) {
        payload[@"windowServerFullImage"] = @[ @(CGImageGetWidth(windowImage)), @(CGImageGetHeight(windowImage)) ];
        NSString *fullPath = writeCGImagePNG(windowImage,
                                             self.surfaceDumpDir,
                                             [NSString stringWithFormat:@"%@-cgwindow-full.png", label]);
        if (fullPath.length > 0) {
            payload[@"windowServerFullPng"] = fullPath;
        }
        CGImageRef cropped = copyCenteredCropImage(windowImage, self.targetWidth, self.targetHeight);
        if (cropped) {
            payload[@"windowServerCroppedImage"] = @[ @(CGImageGetWidth(cropped)), @(CGImageGetHeight(cropped)) ];
            NSString *croppedPath = writeCGImagePNG(cropped,
                                                    self.surfaceDumpDir,
                                                    [NSString stringWithFormat:@"%@-cgwindow-cropped.png", label]);
            if (croppedPath.length > 0) {
                payload[@"windowServerCroppedPng"] = croppedPath;
            }
            CGImageRelease(cropped);
        }
        CGImageRelease(windowImage);
    }

    double remoteSnapshotScale = 0.0;
    CGImageRef remoteSnapshot = copyRemoteViewSnapshot(self.remoteView, &remoteSnapshotScale);
    if (remoteSnapshot) {
        payload[@"remoteSnapshotScale"] = @(remoteSnapshotScale);
        payload[@"remoteSnapshotImage"] = @[ @(CGImageGetWidth(remoteSnapshot)), @(CGImageGetHeight(remoteSnapshot)) ];
        NSString *snapshotPath = writeCGImagePNG(remoteSnapshot,
                                                 self.surfaceDumpDir,
                                                 [NSString stringWithFormat:@"%@-remote-snapshot-full.png", label]);
        if (snapshotPath.length > 0) {
            payload[@"remoteSnapshotPng"] = snapshotPath;
        }
        CGImageRef cropped = copyCenteredCropImage(remoteSnapshot, self.targetWidth, self.targetHeight);
        if (cropped) {
            payload[@"remoteSnapshotCroppedImage"] = @[ @(CGImageGetWidth(cropped)), @(CGImageGetHeight(cropped)) ];
            NSString *croppedPath = writeCGImagePNG(cropped,
                                                    self.surfaceDumpDir,
                                                    [NSString stringWithFormat:@"%@-remote-snapshot-cropped.png", label]);
            if (croppedPath.length > 0) {
                payload[@"remoteSnapshotCroppedPng"] = croppedPath;
            }
            CGImageRelease(cropped);
        }
        CGImageRelease(remoteSnapshot);
    }
    requestRemoteViewSnapshotFiles(self.remoteView, self.surfaceDumpDir, label);
    NSArray<NSDictionary *> *renderServerCaptures = writeRenderServerCaptureProbes(self.remoteView.layer,
                                                                                   self.surfaceDumpDir,
                                                                                   label,
                                                                                   self.targetWidth,
                                                                                   self.targetHeight);
    if (renderServerCaptures.count > 0) {
        payload[@"renderServerCaptures"] = renderServerCaptures;
    }

    NSString *jsonPath = [self.surfaceDumpDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", label]];
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingPrettyPrinted error:nil];
    [jsonData writeToFile:jsonPath atomically:YES];
    payload[@"jsonPath"] = jsonPath;
    [self sendJSON:payload];
}

- (void)setupScreenCapture {
    if (self.useWindowServerCapture) {
        [self sendJSON:@{
            @"type": @"capture-ready",
            @"source": @"cgwindow",
            @"width": @(self.targetWidth),
            @"height": @(self.targetHeight),
            @"windowID": @((CGWindowID)self.window.windowNumber),
        }];
        return;
    }

    if (@available(macOS 14.4, *)) {
        [SCShareableContent getCurrentProcessShareableContentWithCompletionHandler:^(SCShareableContent *shareableContent, NSError *error) {
            if (error || !shareableContent) {
                [self sendJSON:@{ @"type": @"error", @"message": error.localizedDescription ?: @"ScreenCaptureKit content unavailable" }];
                return;
            }

            CGWindowID windowID = (CGWindowID)self.window.windowNumber;
            SCWindow *captureWindow = nil;
            for (SCWindow *window in shareableContent.windows) {
                if (window.windowID == windowID) {
                    captureWindow = window;
                    break;
                }
            }
            if (!captureWindow) {
                [self sendJSON:@{ @"type": @"error", @"message": @"ScreenCaptureKit helper window unavailable" }];
                return;
            }

            SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:captureWindow];
            SCStreamConfiguration *configuration = [[SCStreamConfiguration alloc] init];
            configuration.width = TouchBarBridgeBackingWidth;
            configuration.height = TouchBarBridgeBackingHeight;
            configuration.scalesToFit = YES;
            if (@available(macOS 14.0, *)) {
                configuration.preservesAspectRatio = NO;
                configuration.captureResolution = SCCaptureResolutionBest;
            }
            configuration.showsCursor = NO;
            configuration.capturesAudio = NO;
            configuration.minimumFrameInterval = CMTimeMake(1, (int32_t)MAX(1, self.fps));

            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.shuttingDown) return;
                self.screenCaptureFilter = filter;
                self.screenCaptureConfiguration = configuration;
                if (self.hiddenStreamMode) {
                    configuration.pixelFormat = kCVPixelFormatType_32BGRA;
                    self.captureStream = [[SCStream alloc] initWithFilter:filter configuration:configuration delegate:self];
                    NSError *outputError = nil;
                    if (![self.captureStream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:dispatch_get_main_queue() error:&outputError]) {
                        [self failCaptureStream:outputError]; return;
                    }
                    [self.captureStream startCaptureWithCompletionHandler:^(NSError *streamError) {
                        if (streamError) dispatch_async(dispatch_get_main_queue(), ^{ [self failCaptureStream:streamError]; });
                    }];
                }
                if (self.hideWindow && [self.hideMode isEqualToString:@"orderout"]) {
                    [self.window orderOut:nil];
                    NSLog(@"TouchBarBridge window ordered out after ScreenCaptureKit filter setup visible=%d windowNumber=%ld",
                          self.window.visible,
                          (long)self.window.windowNumber);
                }
                [self sendJSON:@{
                    @"type": @"capture-ready",
                    @"source": @"screencapturekit",
                    @"width": @(TouchBarBridgeBackingWidth),
                    @"height": @(TouchBarBridgeBackingHeight),
                    @"windowID": @(windowID),
                }];
            });
        }];
    } else {
        [self sendJSON:@{ @"type": @"error", @"message": @"ScreenCaptureKit requires macOS 14.4 or newer" }];
    }
}

- (void)applyTargetLayout {
    CGFloat backingScale = self.hostScaleOverride > 0.0 ? self.hostScaleOverride : (self.window.backingScaleFactor > 0.0 ? self.window.backingScaleFactor : effectiveScreenScale());
    NSSize hostSize = touchBarHostPointSizeForScale(backingScale);
    self.lastLayoutScale = backingScale;
    self.lastLayoutHostSize = hostSize;
    NSRect windowFrame = self.window.frame;
    if (self.hideWindow) {
        if ([self.hideMode isEqualToString:@"offscreen"]) {
            windowFrame = offscreenWindowFrame(hostSize);
        } else if ([self.hideMode isEqualToString:@"background"] ||
                   [self.hideMode isEqualToString:@"underdesktop"] ||
                   [self.hideMode isEqualToString:@"transparent"] ||
                   isTransparentInteractiveHideMode(self.hideMode) ||
                   isTransparentFrontInteractiveHideMode(self.hideMode)) {
            windowFrame = backgroundWindowFrame(hostSize);
        } else if ([self.hideMode isEqualToString:@"edge"]) {
            windowFrame = edgeWindowFrame(hostSize);
        } else {
            windowFrame = hiddenWindowFrame(hostSize);
        }
    }
    if (self.virtualMode && ![self.virtualDisplay getHostFrame:&windowFrame]) {
        [self.window orderOut:nil]; [self releaseVirtualMouse]; [NSApp terminate:nil]; return;
    }
    [self.window setFrame:NSMakeRect(windowFrame.origin.x,
                                     windowFrame.origin.y,
                                     hostSize.width,
                                     hostSize.height)
                  display:YES];
    [self.window setContentSize:hostSize];
    if (!self.virtualMode && !self.hiddenStreamMode) applyWindowBackingStoreResolutionOverride(self.window);
    self.window.contentView.frame = NSMakeRect(0, 0, hostSize.width, hostSize.height);
    self.window.contentView.layer.contentsScale = backingScale;
    if (self.scaleRemoteView) {
        NSSize naturalSize = touchBarHostPointSizeForScale(backingScale);
        self.remoteView.frame = NSMakeRect(0, 0, naturalSize.width, naturalSize.height);
        self.remoteView.bounds = NSMakeRect(0, 0, naturalSize.width, naturalSize.height);
        [self.remoteView setFrameSize:naturalSize];
        self.remoteView.wantsLayer = YES;
        self.remoteView.layer.contentsScale = backingScale;
        self.remoteView.layer.anchorPoint = CGPointZero;
        self.remoteView.layer.position = CGPointZero;
        self.remoteView.layer.transform = CATransform3DMakeScale(hostSize.width / naturalSize.width,
                                                                 hostSize.height / naturalSize.height,
                                                                 1.0);
    } else {
        self.remoteView.frame = self.window.contentView.bounds;
        self.remoteView.bounds = NSMakeRect(0, 0, hostSize.width, hostSize.height);
        [self.remoteView setFrameSize:hostSize];
        self.remoteView.wantsLayer = YES;
        self.remoteView.layer.contentsScale = backingScale;
    }
    [self.window.contentView setNeedsDisplay:YES];
    [self.remoteView setNeedsDisplay:YES];
    [self applyRemoteLayerCaptureScale];
    [self applyFunctionRowContextScale];
}

- (void)applyFunctionRowContextScale {
    if (self.virtualMode || self.hiddenStreamMode) return;
    Class contextClass = NSClassFromString(@"CAContext");
    id functionRowContext = objectSelectorValue(contextClass, @selector(NS_functionRowContext));
    if (functionRowContext && [functionRowContext respondsToSelector:@selector(NS_setDefaultContentsScale:)]) {
        ((void (*)(id, SEL, double))objc_msgSend)(functionRowContext, @selector(NS_setDefaultContentsScale:), 2.0);
    }
}

- (void)applyRemoteLayerCaptureScale {
    if (self.virtualMode || self.hiddenStreamMode) return;
    if (!self.remoteView.layer) {
        return;
    }
    CGFloat widthScale = self.remoteView.bounds.size.width > 0.0 ? (CGFloat)TouchBarBridgeBackingWidth / self.remoteView.bounds.size.width : 2.0;
    CGFloat heightScale = self.remoteView.bounds.size.height > 0.0 ? (CGFloat)TouchBarBridgeBackingHeight / self.remoteView.bounds.size.height : 2.0;
    CGFloat captureScale = MAX(1.0, MIN(widthScale, heightScale));
    self.window.contentView.layer.contentsScale = captureScale;
    self.remoteView.layer.contentsScale = captureScale;

    if ([self.remoteView.layer respondsToSelector:@selector(setResizesHostedContext:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(self.remoteView.layer, @selector(setResizesHostedContext:), YES);
    }
    [self setContextDefaultContentsScale:self.window.contentView.layer scale:captureScale];
    [self setContextDefaultContentsScale:self.remoteView.layer scale:captureScale];
}

- (void)setContextDefaultContentsScale:(CALayer *)layer scale:(CGFloat)scale {
    id context = objectSelectorValue(layer, @selector(context));
    if (context && [context respondsToSelector:@selector(NS_setDefaultContentsScale:)]) {
        ((void (*)(id, SEL, double))objc_msgSend)(context, @selector(NS_setDefaultContentsScale:), (double)scale);
    }
}

- (void)failCaptureStream:(NSError *)error {
    if (self.shuttingDown) return;
    NSLog(@"TouchBarBridge hidden capture failed: %@", error);
    [self sendJSON:@{@"type": @"error", @"message": error.localizedDescription ?: @"Hidden capture stream failed"}];
    [NSApp terminate:nil];
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{ [self failCaptureStream:error]; });
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (stream != self.captureStream || type != SCStreamOutputTypeScreen || self.shuttingDown) return;
    NSArray *attachments = (__bridge NSArray *)CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    NSNumber *status = attachments.firstObject[SCStreamFrameInfoStatus];
    if (!status || status.integerValue != SCFrameStatusComplete) return;
    CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixels) return;
    CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
    CGColorSpaceRef colors = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pixels), CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels), 8, CVPixelBufferGetBytesPerRow(pixels), colors, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGImageRef image = context ? CGBitmapContextCreateImage(context) : NULL;
    if (image) { [self handleCapturedImage:image source:@"screencapturekit"]; CGImageRelease(image); }
    if (context) CGContextRelease(context);
    CGColorSpaceRelease(colors);
    CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
}

- (void)hiddenScreensChanged:(NSNotification *)notification {
    if (!self.hiddenStreamMode || self.shuttingDown) return;
    [self releaseVirtualMouse];
    // Follow the union's outer edge; do not move or configure any display.
    if (!NSScreen.screens.count) { [NSApp terminate:nil]; return; }
    [self applyTargetLayout];
    self.sentFrameInfo = NO;
}

- (void)startFrameTimer {
    // SCStream delivers changed content; no repeated screenshots/layout writes.
    if (self.hiddenStreamMode) return;
    NSTimeInterval interval = 1.0 / (double)self.fps;
    self.frameTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                      repeats:YES
                                                        block:^(NSTimer *timer) {
        (void)timer;
        [self captureAndSendFrame];
    }];
}

- (void)captureAndSendFrame {
    if (!self.webSocket || !self.remoteView || self.screenCaptureInFlight) {
        return;
    }
    if (!self.useWindowServerCapture && (!self.screenCaptureFilter || !self.screenCaptureConfiguration)) {
        return;
    }
    if (self.virtualMode) {
        NSRect frame;
        if (![self.virtualDisplay getHostFrame:&frame] || !NSEqualRects(frame,self.window.frame)) {
            [self virtualScreensChanged:nil]; return;
        }
    } else {
        [self applyTargetLayout];
    }
    self.screenCaptureInFlight = YES;
    if (self.useWindowServerCapture) {
        CGImageRef captureImage = copyWindowServerImage((CGWindowID)self.window.windowNumber);
        if (!captureImage) {
            self.screenCaptureInFlight = NO;
            if (!self.sentScreenCaptureError) {
                self.sentScreenCaptureError = YES;
                [self sendJSON:@{ @"type": @"error", @"message": @"CGWindow frame unavailable" }];
            }
            return;
        }
        [self handleCapturedImage:captureImage source:@"cgwindow"];
        CGImageRelease(captureImage);
        self.screenCaptureInFlight = NO;
        return;
    }
    [SCScreenshotManager captureImageWithFilter:self.screenCaptureFilter configuration:self.screenCaptureConfiguration completionHandler:^(CGImageRef captureImage, NSError *error) {
        if (captureImage) CGImageRetain(captureImage);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.screenCaptureInFlight = NO;
            if (self.shuttingDown) { if (captureImage) CGImageRelease(captureImage); return; }
            if (error || !captureImage) {
                if (!self.sentScreenCaptureError) {
                    self.sentScreenCaptureError = YES;
                    [self sendJSON:@{ @"type": @"error", @"message": error.localizedDescription ?: @"ScreenCaptureKit frame unavailable" }];
                }
            } else {
                [self handleCapturedImage:captureImage source:@"screencapturekit"];
            }
            if (captureImage) CGImageRelease(captureImage);
        });
    }];
}

- (void)handleCapturedImage:(CGImageRef)captureImage source:(NSString *)source {
    @autoreleasepool {
        CGImageRef image = copyCenteredCropImage(captureImage, self.targetWidth, self.targetHeight);
        if (!image) {
            return;
        }
        NSMutableData *bgra = createBGRADataFromImage(image);
        size_t width = CGImageGetWidth(image);
        size_t height = CGImageGetHeight(image);
        size_t stride = width * 4;
        if (!self.sentFrameInfo) {
            NSRect windowFrame = self.window.frame;
            NSRect contentBounds = self.window.contentView.bounds;
            NSRect remoteFrame = self.remoteView.frame;
            NSRect remoteBounds = self.remoteView.bounds;
            NSRect backingRemoteFrame = [self.window convertRectToBacking:[self.remoteView convertRect:self.remoteView.bounds toView:nil]];
            CGFloat normalizedImageWidth = source && [source isEqualToString:@"screencapturekit"] ? (CGFloat)TouchBarBridgeBackingWidth : (CGFloat)CGImageGetWidth(captureImage);
            CGFloat normalizedImageHeight = source && [source isEqualToString:@"screencapturekit"] ? (CGFloat)TouchBarBridgeBackingHeight : (CGFloat)CGImageGetHeight(captureImage);
            CGFloat captureInsetX = MAX(0.0, (normalizedImageWidth - (CGFloat)width) / 2.0);
            CGFloat captureInsetY = MAX(0.0, (normalizedImageHeight - (CGFloat)height) / 2.0);
            CGFloat captureScaleX = contentBounds.size.width > 0 ? normalizedImageWidth / contentBounds.size.width : 1.0;
            CGFloat captureScaleY = contentBounds.size.height > 0 ? normalizedImageHeight / contentBounds.size.height : 1.0;
            [self sendJSON:@{
                @"type": @"frame-info",
                @"windowFrame": @[ @(windowFrame.origin.x), @(windowFrame.origin.y), @(windowFrame.size.width), @(windowFrame.size.height) ],
                @"contentBounds": @[ @(contentBounds.origin.x), @(contentBounds.origin.y), @(contentBounds.size.width), @(contentBounds.size.height) ],
                @"remoteFrame": @[ @(remoteFrame.origin.x), @(remoteFrame.origin.y), @(remoteFrame.size.width), @(remoteFrame.size.height) ],
                @"remoteBounds": @[ @(remoteBounds.origin.x), @(remoteBounds.origin.y), @(remoteBounds.size.width), @(remoteBounds.size.height) ],
                @"backingRemoteFrame": @[ @(backingRemoteFrame.origin.x), @(backingRemoteFrame.origin.y), @(backingRemoteFrame.size.width), @(backingRemoteFrame.size.height) ],
                @"fullImage": @[ @(CGImageGetWidth(captureImage)), @(CGImageGetHeight(captureImage)) ],
                @"normalizedImage": @[ @(normalizedImageWidth), @(normalizedImageHeight) ],
                @"croppedImage": @[ @(width), @(height) ],
                @"captureSource": source ?: @"unknown",
                @"captureInset": @[ @(captureInsetX), @(captureInsetY) ],
                @"captureInsetPoints": @[ @(captureInsetX / captureScaleX), @(captureInsetY / captureScaleY) ],
                @"captureScale": @[ @(captureScaleX), @(captureScaleY) ],
                @"effectiveScreenScale": @(effectiveScreenScale()),
                @"windowBackingScaleFactor": @(self.window.backingScaleFactor),
                @"hostScaleOverride": @(self.hostScaleOverride),
                @"layoutScale": @(self.lastLayoutScale),
                @"layoutHostSize": @[ @(self.lastLayoutHostSize.width), @(self.lastLayoutHostSize.height) ],
            }];
            self.sentFrameInfo = YES;
        }
        CGImageRelease(image);
        if (!bgra) {
            return;
        }

        NSMutableData *packet = [NSMutableData dataWithLength:16 + bgra.length];
        uint8_t *bytes = packet.mutableBytes;
        memcpy(bytes, FrameMagic.UTF8String, 4);
        uint32_t headerWidth = (uint32_t)width;
        uint32_t headerHeight = (uint32_t)height;
        uint32_t headerStride = (uint32_t)stride;
        memcpy(bytes + 4, &headerWidth, sizeof(headerWidth));
        memcpy(bytes + 8, &headerHeight, sizeof(headerHeight));
        memcpy(bytes + 12, &headerStride, sizeof(headerStride));
        memcpy(bytes + 16, bgra.bytes, bgra.length);

        NSURLSessionWebSocketMessage *message = [[NSURLSessionWebSocketMessage alloc] initWithData:packet];
        [self.webSocket sendMessage:message completionHandler:^(NSError *error) {
            if (error) {
                NSLog(@"Frame send failed: %@", error);
            }
        }];
    }
}

- (void)sendJSON:(NSDictionary *)payload {
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSURLSessionWebSocketMessage *message = [[NSURLSessionWebSocketMessage alloc] initWithString:json ?: @"{}"];
    [self.webSocket sendMessage:message completionHandler:^(NSError *error) {
        if (error) {
            NSLog(@"JSON send failed: %@", error);
        }
    }];
}

- (void)receiveWebSocketMessage {
    [self.webSocket receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
            return;
        }
        if (message.type == NSURLSessionWebSocketMessageTypeString) {
            [self handleTextMessage:message.string];
        }
        [self receiveWebSocketMessage];
    }];
}

- (void)handleTextMessage:(NSString *)text {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![payload isKindOfClass:NSDictionary.class]) {
        NSLog(@"TouchBarBridge ignored invalid text message: %@", text);
        return;
    }

    NSString *type = payload[@"type"];
    if ([type isEqualToString:@"mouse"]) {
        NSLog(@"TouchBarBridge mouse payload raw=%@", payload);
    } else {
        NSLog(@"TouchBarBridge text message type=%@ payload=%@", type, payload);
    }
    if ([type isEqualToString:@"stop"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSApp terminate:nil];
        });
        return;
    }
    if ([type isEqualToString:@"mouse"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self postMousePayload:payload];
        });
        return;
    }
}

- (void)postMousePayload:(NSDictionary *)payload {
    if (!self.remoteView || self.shuttingDown) {
        NSLog(@"TouchBarBridge mouse ignored: remoteView is nil payload=%@", payload);
        return;
    }
    CGFloat sourceWidth = [payload[@"width"] doubleValue] ?: (CGFloat)self.targetWidth;
    CGFloat sourceHeight = [payload[@"height"] doubleValue] ?: (CGFloat)self.targetHeight;
    NSPoint stableLogicalPoint = touchBarLogicalPointFromPayload(payload,
                                                                 sourceWidth,
                                                                 sourceHeight,
                                                                 self.targetWidth,
                                                                 self.targetHeight,
                                                                 self.remoteView.bounds.size);
    NSRect backingRemoteFrame = [self.window convertRectToBacking:[self.remoteView convertRect:self.remoteView.bounds toView:nil]];
    CGFloat scaleX = self.remoteView.bounds.size.width > 0 ? backingRemoteFrame.size.width / self.remoteView.bounds.size.width : 2.0;
    CGFloat scaleY = self.remoteView.bounds.size.height > 0 ? backingRemoteFrame.size.height / self.remoteView.bounds.size.height : 2.0;
    CGFloat captureWidthPoints = 1085.0;
    CGFloat captureHeightPoints = 30.0;
    CGFloat captureInsetX = 5.0;
    CGFloat captureInsetY = 5.0;
    CGFloat x = stableLogicalPoint.x;
    CGFloat y = stableLogicalPoint.y;
    BOOL down = [payload[@"down"] boolValue];
    if (self.hiddenStreamMode) {
        if (!isfinite([payload[@"x"] doubleValue]) || !isfinite([payload[@"y"] doubleValue])) return;
        if (!down && !self.mouseDown) return;
        self.lastMousePayloadTime = NSProcessInfo.processInfo.systemUptime;
    }
    if (self.virtualMode) {
        if (!isfinite([payload[@"x"] doubleValue]) || !isfinite([payload[@"y"] doubleValue])) return;
        if (!down && !self.mouseDown) return;
        NSRect frame;
        if (![self.virtualDisplay getHostFrame:&frame] || !NSEqualRects(frame, self.window.frame)) { [self releaseVirtualMouse]; return; }
        self.lastMousePayloadTime = NSProcessInfo.processInfo.systemUptime;
    }
    if ([self.mouseDispatchMode isEqualToString:@"none"]) {
        NSLog(@"TouchBarBridge mouse ignored: dispatcher disabled payload=%@", payload);
        [self sendJSON:@{
            @"type": @"mouse-ignored",
            @"dispatcher": @"none",
            @"reason": @"dispatcher-disabled",
            @"input": @[@([payload[@"x"] doubleValue]), @([payload[@"y"] doubleValue])],
            @"source": @[@(sourceWidth), @(sourceHeight)],
            @"down": @(down),
        }];
        return;
    }
    if ([self.mouseDispatchMode isEqualToString:@"service"]) {
        NSPoint local = [self.remoteView convertPoint:NSMakePoint(x,y) toView:nil];
        CGPoint topLeft = cgEventPointForWindowPoint(self.window, NSMakePoint(0,self.window.contentView.bounds.size.height));
        CGRect bounds = CGRectMake(topLeft.x,topLeft.y,self.window.contentView.bounds.size.width,self.window.contentView.bounds.size.height);
        CGPoint point = CGPointMake(local.x,bounds.size.height-local.y);
        pid_t pid = [self.remote respondsToSelector:@selector(serviceProcessIdentifier)]
            ? ((pid_t(*)(id,SEL))objc_msgSend)(self.remote,@selector(serviceProcessIdentifier)) : 0;
        if (self.serviceInput.pressed && pid != self.serviceInput.targetPID) { [self releaseVirtualMouse]; return; }
        BOOL sent = NO;
        if (hasPostEventAccess()) {
            sent = self.serviceInput.pressed ? [self.serviceInput continueAt:point down:down]
                : (down && [self.serviceInput beginAt:point servicePID:pid hostBounds:bounds]);
        }
        self.mouseDown = self.serviceInput.pressed;
        if (!sent) [self releaseVirtualMouse];
        [self sendJSON:@{@"type":sent ? @"mouse-dispatched" : @"mouse-dispatch-error", @"dispatcher":@"service",
                        @"down":@(down), @"servicePID":@(pid), @"serviceWindow":@(self.serviceInput.targetWindow)}];
        return;
    }
    if ([self.mouseDispatchMode isEqualToString:@"cgevent"] ||
        [self.mouseDispatchMode isEqualToString:@"hid"]) {
        [self postCGEventMousePayload:payload sourceWidth:sourceWidth sourceHeight:sourceHeight appKitX:x appKitY:y down:down];
        return;
    }
    if (![self.mouseDispatchMode isEqualToString:@"appkit"] &&
        ![self.mouseDispatchMode isEqualToString:@"appkit-nsevent"] &&
        ![self.mouseDispatchMode isEqualToString:@"appkit-monitor"] &&
        ![self.mouseDispatchMode isEqualToString:@"remoteview"] &&
        ![self.mouseDispatchMode isEqualToString:@"remoteview-nsevent"] &&
        ![self.mouseDispatchMode isEqualToString:@"sendremote"] &&
        ![self.mouseDispatchMode isEqualToString:@"sendremote-nsevent"] &&
        ![self.mouseDispatchMode isEqualToString:@"postapp"] &&
        ![self.mouseDispatchMode isEqualToString:@"nsapp"] &&
        ![self.mouseDispatchMode isEqualToString:@"serviceleft"] &&
        ![self.mouseDispatchMode isEqualToString:@"fakeclick"]) {
        [self postDFRMousePayload:payload sourceWidth:sourceWidth sourceHeight:sourceHeight down:down];
        return;
    }
    if (self.hideWindow && [self.hideMode isEqualToString:@"orderout"] && !self.window.visible) {
        [self.window orderFrontRegardless];
        [self.window makeFirstResponder:self.remoteView ?: self.window.contentView];
        [self.window displayIfNeeded];
        NSLog(@"TouchBarBridge mouse deferred until ordered hidden window is visible=%d windowNumber=%ld",
              self.window.visible,
              (long)self.window.windowNumber);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self postMousePayload:payload];
        });
        return;
    }

    NSEventType eventType;
    CGEventType cgEventType;
    if (down && !self.mouseDown) {
        eventType = NSEventTypeLeftMouseDown;
        cgEventType = kCGEventLeftMouseDown;
    } else if (down) {
        eventType = NSEventTypeLeftMouseDragged;
        cgEventType = kCGEventLeftMouseDragged;
    } else {
        eventType = NSEventTypeLeftMouseUp;
        cgEventType = kCGEventLeftMouseUp;
    }
    self.mouseDown = down;

    NSPoint windowPoint = [self.remoteView convertPoint:NSMakePoint(x, y) toView:nil];
    NSString *eventTypeName = @"leftMouseUp";
    if (eventType == NSEventTypeLeftMouseDown) {
        eventTypeName = @"leftMouseDown";
    } else if (eventType == NSEventTypeLeftMouseDragged) {
        eventTypeName = @"leftMouseDragged";
    }
    NSLog(@"TouchBarBridge mouse mapped source=%.1fx%.1f input=(%.1f,%.1f) down=%d event=%@ remoteBounds=%@ backingRemote=%@ capturePoints=%.2fx%.2f captureInset=%.2f,%.2f appKitPoint=%.2f,%.2f windowPoint=%.2f,%.2f windowNumber=%ld ignoresMouse=%d",
          sourceWidth,
          sourceHeight,
          [payload[@"x"] doubleValue],
          [payload[@"y"] doubleValue],
          down,
          eventTypeName,
          NSStringFromRect(self.remoteView.bounds),
          NSStringFromRect(backingRemoteFrame),
          captureWidthPoints,
          captureHeightPoints,
          captureInsetX,
          captureInsetY,
          x,
          y,
          windowPoint.x,
          windowPoint.y,
          (long)self.window.windowNumber,
          self.window.ignoresMouseEvents);
    NSPoint screenPoint = [self.window convertPointToScreen:windowPoint];
    NSScreen *eventScreen = self.window.screen ?: NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    NSRect screenFrame = eventScreen ? eventScreen.frame : NSMakeRect(0, 0, 0, 0);
    CGPoint quartzPoint = CGPointMake(screenPoint.x, NSMaxY(screenFrame) - screenPoint.y);
    NSInteger eventNumber = ++self.syntheticMouseEventNumber;
    CGEventRef cgEvent = CGEventCreateMouseEvent(NULL, cgEventType, quartzPoint, kCGMouseButtonLeft);
    if (cgEvent) {
        CGEventSetIntegerValueField(cgEvent, kCGMouseEventNumber, eventNumber);
        CGEventSetIntegerValueField(cgEvent, kCGMouseEventClickState, 1);
        CGEventSetIntegerValueField(cgEvent, kCGMouseEventWindowUnderMousePointer, self.window.windowNumber);
        CGEventSetIntegerValueField(cgEvent, kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent, self.window.windowNumber);
    }
    BOOL useStandardNSEvent = [self.mouseDispatchMode hasSuffix:@"-nsevent"];
    NSEvent *event = (cgEvent && !useStandardNSEvent)
        ? [[TouchBarBridgeMouseEvent alloc] initWithType:eventType
                                                location:windowPoint
                                               timestamp:NSProcessInfo.processInfo.systemUptime
                                                  window:self.window
                                            eventNumber:eventNumber
                                                 cgEvent:cgEvent]
        : [NSEvent mouseEventWithType:eventType
                              location:windowPoint
                         modifierFlags:0
                             timestamp:NSProcessInfo.processInfo.systemUptime
                          windowNumber:self.window.windowNumber
                               context:nil
                           eventNumber:eventNumber
                            clickCount:1
                              pressure:down ? 1.0 : 0.0];
    BOOL ignoresMouseEvents = self.window.ignoresMouseEvents;
    self.window.ignoresMouseEvents = NO;
    if ([self.mouseDispatchMode isEqualToString:@"fakeclick"] &&
        [self.remoteView respondsToSelector:@selector(_sendWindowFakeClick:why:)]) {
        @try {
            id mouseAssociation = nil;
            if ([self.remoteView respondsToSelector:@selector(_associateMouseAndMouseCursorPosition:)]) {
                mouseAssociation = ((id (*)(id, SEL, BOOL))objc_msgSend)(self.remoteView,
                                                                          @selector(_associateMouseAndMouseCursorPosition:),
                                                                          NO);
            }
            const char *reason = "TouchBarBridgeHelper";
            ((void (*)(id, SEL, NSInteger, const char *))objc_msgSend)(self.remoteView,
                                                                       @selector(_sendWindowFakeClick:why:),
                                                                       1,
                                                                       reason);
            NSLog(@"TouchBarBridge fakeclick sent association=%@", truncatedDescription(mouseAssociation));
        } @catch (NSException *exception) {
            NSLog(@"TouchBarBridge fakeclick failed exception=%@ reason=%@", exception.name, exception.reason);
            [self sendJSON:@{
                @"type": @"mouse-dispatch-error",
                @"dispatcher": @"fakeclick-cgevent",
                @"exception": exception.name ?: @"",
                @"reason": exception.reason ?: @"",
            }];
        }
    } else if ([self.mouseDispatchMode isEqualToString:@"sendremote"] ||
               [self.mouseDispatchMode isEqualToString:@"sendremote-nsevent"]) {
        ((void (*)(id, SEL, id))objc_msgSend)(self.remoteView,
                                              @selector(sendEvent:),
                                              event);
    } else if ([self.mouseDispatchMode isEqualToString:@"postapp"]) {
        [NSApp postEvent:event atStart:NO];
    } else if ([self.mouseDispatchMode isEqualToString:@"nsapp"]) {
        [NSApp sendEvent:event];
    } else if ([self.mouseDispatchMode isEqualToString:@"serviceleft"]) {
        if (eventType == NSEventTypeLeftMouseDown &&
            [self.remoteView respondsToSelector:@selector(_serviceViewReceivedLeftMouseDown:)]) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(self.remoteView,
                                                         @selector(_serviceViewReceivedLeftMouseDown:),
                                                         event.eventNumber);
            NSLog(@"TouchBarBridge serviceleft notified left mouse down eventNumber=%ld",
                  (long)event.eventNumber);
        }
        [self.window sendEvent:event];
    } else if ([self.mouseDispatchMode isEqualToString:@"remoteview"] ||
               [self.mouseDispatchMode isEqualToString:@"remoteview-nsevent"]) {
        if (eventType == NSEventTypeLeftMouseDown) {
            [self.remoteView mouseDown:event];
        } else if (eventType == NSEventTypeLeftMouseDragged) {
            [self.remoteView mouseDragged:event];
        } else {
            [self.remoteView mouseUp:event];
        }
    } else {
        [self.window sendEvent:event];
    }
    if (cgEvent) {
        CFRelease(cgEvent);
    }
    self.window.ignoresMouseEvents = ignoresMouseEvents;
    [self sendJSON:@{
        @"type": @"mouse-dispatched",
        @"event": eventTypeName,
        @"dispatcher": [self.mouseDispatchMode isEqualToString:@"fakeclick"] ? @"fakeclick-cgevent" : ([self.mouseDispatchMode isEqualToString:@"remoteview"] ? @"remoteview-cgevent" : ([self.mouseDispatchMode isEqualToString:@"sendremote"] ? @"sendremote-cgevent" : ([self.mouseDispatchMode isEqualToString:@"postapp"] ? @"postapp-cgevent" : ([self.mouseDispatchMode isEqualToString:@"nsapp"] ? @"nsapp-cgevent" : ([self.mouseDispatchMode isEqualToString:@"serviceleft"] ? @"serviceleft-cgevent" : @"appkit-cgevent"))))),
        @"input": @[@([payload[@"x"] doubleValue]), @([payload[@"y"] doubleValue])],
        @"source": @[@(sourceWidth), @(sourceHeight)],
        @"down": @(down),
        @"appKitPoint": @[@(x), @(y)],
        @"windowPoint": @[@(windowPoint.x), @(windowPoint.y)],
        @"eventLocationInWindow": @[@(event.locationInWindow.x), @(event.locationInWindow.y)],
        @"eventNumber": @(event.eventNumber),
        @"screenPoint": @[@(screenPoint.x), @(screenPoint.y)],
        @"quartzPoint": @[@(quartzPoint.x), @(quartzPoint.y)],
        @"hasCGEvent": @(event.CGEvent != NULL),
        @"windowNumber": @((long)self.window.windowNumber),
        @"hideMode": self.hideMode ?: @"",
        @"windowVisible": @(self.window.visible),
        @"windowAlpha": @(self.window.alphaValue)
    }];
    if (self.hideWindow && [self.hideMode isEqualToString:@"orderout"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.window.visible) {
                [self.window orderOut:nil];
                NSLog(@"TouchBarBridge mouse ordered hidden window back out visible=%d windowNumber=%ld",
                      self.window.visible,
                      (long)self.window.windowNumber);
            }
        });
    }
    NSLog(@"TouchBarBridge mouse dispatched event=%@ restoredIgnoresMouse=%d", eventTypeName, self.window.ignoresMouseEvents);
}

- (void)postDFRMousePayload:(NSDictionary *)payload sourceWidth:(CGFloat)sourceWidth sourceHeight:(CGFloat)sourceHeight down:(BOOL)down {
    double rawX = [payload[@"x"] doubleValue];
    double rawY = [payload[@"y"] doubleValue];
    double dfrX = rawX * 0.5;
    double dfrY = rawY * 0.5;
    CGEventType dfrEvent = down ? kCGEventLeftMouseDown : kCGEventLeftMouseUp;
    self.mouseDown = down;

    if (!self.dfrSimulator || !self.dfrPostMouseActivity) {
        NSLog(@"TouchBarBridge DFR mouse ignored: dispatcher not ready simulator=%p post=%p payload=%@",
              self.dfrSimulator,
              self.dfrPostMouseActivity,
              payload);
        [self sendJSON:@{
            @"type": @"mouse-ignored",
            @"dispatcher": @"dfr",
            @"reason": @"dispatcher-not-ready",
            @"input": @[@(rawX), @(rawY)],
            @"source": @[@(sourceWidth), @(sourceHeight)],
            @"down": @(down),
            @"hideMode": self.hideMode ?: @"",
            @"windowVisible": @(self.window.visible),
        }];
        return;
    }

    NSLog(@"TouchBarBridge DFR mouse mapped source=%.1fx%.1f input=(%.1f,%.1f) down=%d event=%ld dfrPoint=%.2f,%.2f simulator=%p windowVisible=%d hideMode=%@",
          sourceWidth,
          sourceHeight,
          rawX,
          rawY,
          down,
          (long)dfrEvent,
          dfrX,
          dfrY,
          self.dfrSimulator,
          self.window.visible,
          self.hideMode);
    self.dfrPostMouseActivity(self.dfrSimulator, dfrEvent, NSMakePoint(dfrX, dfrY));
    [self sendJSON:@{
        @"type": @"mouse-dispatched",
        @"dispatcher": @"dfr",
        @"event": down ? @"down" : @"up",
        @"dfrEvent": @(dfrEvent),
        @"input": @[@(rawX), @(rawY)],
        @"source": @[@(sourceWidth), @(sourceHeight)],
        @"down": @(down),
        @"dfrPoint": @[@(dfrX), @(dfrY)],
        @"hideMode": self.hideMode ?: @"",
        @"windowVisible": @(self.window.visible),
        @"windowAlpha": @(self.window.alphaValue),
    }];
}

- (void)postCGEventMousePayload:(NSDictionary *)payload
                     sourceWidth:(CGFloat)sourceWidth
                    sourceHeight:(CGFloat)sourceHeight
                         appKitX:(CGFloat)appKitX
                         appKitY:(CGFloat)appKitY
                            down:(BOOL)down {
    NSEventType appKitEventType;
    CGEventType cgEventType;
    if (down && !self.mouseDown) {
        appKitEventType = NSEventTypeLeftMouseDown;
        cgEventType = kCGEventLeftMouseDown;
    } else if (down) {
        appKitEventType = NSEventTypeLeftMouseDragged;
        cgEventType = kCGEventLeftMouseDragged;
    } else {
        appKitEventType = NSEventTypeLeftMouseUp;
        cgEventType = kCGEventLeftMouseUp;
    }
    if (down && !self.mouseDown) self.mouseSequence++;
    self.mouseDown = down;

    BOOL usesHID = [self.mouseDispatchMode isEqualToString:@"hid"];
    BOOL transparentInteractiveHide = isTransparentInteractiveHideMode(self.hideMode);
    BOOL shouldPrepareTransparentHIDWindow = usesHID &&
                                             self.hideWindow &&
                                             transparentInteractiveHide;
    if (shouldPrepareTransparentHIDWindow && down && !self.hidHitTestActive) {
        self.hidHitTestActive = YES;
        self.hidHitTestOriginalLevel = self.window.level;
        self.hidHitTestOriginalAlpha = self.window.alphaValue;
        self.hidHitTestOriginalIgnoresMouseEvents = self.window.ignoresMouseEvents;
        self.window.ignoresMouseEvents = NO;
        self.window.alphaValue = MAX(self.window.alphaValue, self.hidHitTestAlpha);
        [self.window orderFrontRegardless];
        [self.window makeKeyWindow];
        [self.window makeMainWindow];
        [self.window makeFirstResponder:self.remoteView ?: self.window.contentView];
        [NSApp activateIgnoringOtherApps:YES];
        [self.window displayIfNeeded];
        NSLog(@"TouchBarBridge transparent HID hit-test begin level=%ld alpha=%.3f targetAlpha=%.3f windowNumber=%ld",
              (long)self.window.level,
              self.window.alphaValue,
              self.hidHitTestAlpha,
              (long)self.window.windowNumber);
        usleep(120 * 1000);
    }

    NSPoint windowPoint = [self.remoteView convertPoint:NSMakePoint(appKitX, appKitY) toView:nil];
    NSPoint screenPoint = [self.window convertPointToScreen:windowPoint];
    CGPoint quartzPoint = cgEventPointForWindowPoint(self.window, windowPoint);
    self.lastHIDPoint = quartzPoint;

    CGEventRef event = CGEventCreateMouseEvent(NULL, cgEventType, quartzPoint, kCGMouseButtonLeft);
    if (!event) {
        NSLog(@"TouchBarBridge CGEvent mouse ignored: failed to create event payload=%@", payload);
        [self sendJSON:@{
            @"type": @"mouse-ignored",
            @"dispatcher": @"cgevent",
            @"reason": @"create-event-failed",
        }];
        return;
    }
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, 1);
    CGEventSetIntegerValueField(event, kCGMouseEventWindowUnderMousePointer, self.window.windowNumber);
    CGEventSetIntegerValueField(event, kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent, self.window.windowNumber);
    if (self.hideWindow) {
        self.window.ignoresMouseEvents = NO;
    }
    if (usesHID) {
        if (cgEventType == kCGEventLeftMouseDown) {
            // A second gesture may begin before the previous delayed restore.
            // Preserve the original desktop position across that short gap.
            if (!self.hidHasOriginalCursorPoint) {
                CGEventRef currentMouseEvent = CGEventCreate(NULL);
                if (currentMouseEvent) {
                    self.hidOriginalCursorPoint = CGEventGetLocation(currentMouseEvent);
                    self.hidHasOriginalCursorPoint = YES;
                    CFRelease(currentMouseEvent);
                }
            }
            CGAssociateMouseAndMouseCursorPosition(true);
            CGWarpMouseCursorPosition(quartzPoint);
            // CGWarpMouseCursorPosition already uses global coordinates, including virtual screens.
            CGEventRef movedMouseEvent = CGEventCreate(NULL);
            if (movedMouseEvent) {
                CGPoint movedPoint = CGEventGetLocation(movedMouseEvent);
                NSLog(@"TouchBarBridge HID cursor positioned target=%.2f,%.2f actual=%.2f,%.2f",
                      quartzPoint.x,
                      quartzPoint.y,
                      movedPoint.x,
                      movedPoint.y);
                CFRelease(movedMouseEvent);
            }
            usleep(20 * 1000);
            CGEventRef moveEvent = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, quartzPoint, kCGMouseButtonLeft);
            if (moveEvent) {
                CGEventSetIntegerValueField(moveEvent, kCGMouseEventWindowUnderMousePointer, self.window.windowNumber);
                CGEventSetIntegerValueField(moveEvent, kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent, self.window.windowNumber);
                CGEventPost(kCGHIDEventTap, moveEvent);
                CFRelease(moveEvent);
                usleep(30 * 1000);
            }
        }
        CGEventPost(kCGHIDEventTap, event);
        if (cgEventType == kCGEventLeftMouseUp && self.hidHasOriginalCursorPoint) {
            CGPoint restorePoint = self.hidOriginalCursorPoint;
            NSUInteger sequence = self.mouseSequence;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.04 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!self.mouseDown && self.mouseSequence == sequence && self.hidHasOriginalCursorPoint) {
                    CGWarpMouseCursorPosition(restorePoint);
                    self.hidHasOriginalCursorPoint = NO;
                }
            });
        }
    } else {
        if (cgEventType == kCGEventLeftMouseDown) {
            CGEventRef moveEvent = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, quartzPoint, kCGMouseButtonLeft);
            if (moveEvent) {
                CGEventSetIntegerValueField(moveEvent, kCGMouseEventWindowUnderMousePointer, self.window.windowNumber);
                CGEventSetIntegerValueField(moveEvent, kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent, self.window.windowNumber);
                CGEventPostToPid(getpid(), moveEvent);
                CFRelease(moveEvent);
                usleep(30 * 1000);
            }
        }
        CGEventPostToPid(getpid(), event);
    }
    CFRelease(event);
    if (shouldPrepareTransparentHIDWindow && !down && self.hidHitTestActive) {
        NSWindowLevel restoreLevel = self.hidHitTestOriginalLevel;
        CGFloat restoreAlpha = self.hidHitTestOriginalAlpha;
        BOOL restoreIgnores = self.hidHitTestOriginalIgnoresMouseEvents;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self.window.level = restoreLevel;
            self.window.alphaValue = restoreAlpha;
            self.window.ignoresMouseEvents = restoreIgnores;
            if ([self.hideMode isEqualToString:@"background"] ||
                [self.hideMode isEqualToString:@"underdesktop"] ||
                isTransparentInteractiveHideMode(self.hideMode) ||
                [self.hideMode isEqualToString:@"edge"]) {
                [self.window orderBack:nil];
            }
            self.hidHitTestActive = NO;
            NSLog(@"TouchBarBridge transparent HID hit-test restored level=%ld alpha=%.3f ignoresMouse=%d windowNumber=%ld",
                  (long)self.window.level,
                  self.window.alphaValue,
                  self.window.ignoresMouseEvents,
                  (long)self.window.windowNumber);
        });
    } else if (self.hideWindow && !down && !isTransparentFrontInteractiveHideMode(self.hideMode)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self.window.ignoresMouseEvents = YES;
        });
    }

    NSString *eventTypeName = @"leftMouseUp";
    if (appKitEventType == NSEventTypeLeftMouseDown) {
        eventTypeName = @"leftMouseDown";
    } else if (appKitEventType == NSEventTypeLeftMouseDragged) {
        eventTypeName = @"leftMouseDragged";
    }
    NSLog(@"TouchBarBridge CGEvent mouse posted source=%.1fx%.1f input=(%.1f,%.1f) down=%d event=%@ appKitPoint=%.2f,%.2f windowPoint=%.2f,%.2f screenPoint=%.2f,%.2f quartzPoint=%.2f,%.2f windowNumber=%ld visible=%d",
          sourceWidth,
          sourceHeight,
          [payload[@"x"] doubleValue],
          [payload[@"y"] doubleValue],
          down,
          eventTypeName,
          appKitX,
          appKitY,
          windowPoint.x,
          windowPoint.y,
          screenPoint.x,
          screenPoint.y,
          quartzPoint.x,
          quartzPoint.y,
          (long)self.window.windowNumber,
          self.window.visible);
    BOOL postEventAccess = hasPostEventAccess();
    [self sendJSON:@{
        @"type": @"mouse-dispatched",
        @"dispatcher": self.mouseDispatchMode ?: @"cgevent",
        @"event": eventTypeName,
        @"input": @[@([payload[@"x"] doubleValue]), @([payload[@"y"] doubleValue])],
        @"source": @[@(sourceWidth), @(sourceHeight)],
        @"down": @(down),
        @"appKitPoint": @[@(appKitX), @(appKitY)],
        @"windowPoint": @[@(windowPoint.x), @(windowPoint.y)],
        @"screenPoint": @[@(screenPoint.x), @(screenPoint.y)],
        @"quartzPoint": @[@(quartzPoint.x), @(quartzPoint.y)],
        @"windowNumber": @((long)self.window.windowNumber),
        @"hideMode": self.hideMode ?: @"",
        @"windowVisible": @(self.window.visible),
        @"windowAlpha": @(self.window.alphaValue),
        @"postEventAccess": @(postEventAccess),
        @"hidHitTestActive": @(self.hidHitTestActive),
    }];
}

- (void)releaseVirtualMouse {
    if ([self.mouseDispatchMode isEqualToString:@"service"]) {
        [self.serviceInput cancel];
        self.mouseDown = NO;
        return;
    }
    if (!self.virtualMode) return;
    if (self.mouseDown) {
        CGEventRef up = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, self.lastHIDPoint, kCGMouseButtonLeft);
        if (up) { CGEventPost(kCGHIDEventTap,up); CFRelease(up); }
        self.mouseDown = NO;
    }
    if (self.hidHasOriginalCursorPoint) {
        CGWarpMouseCursorPosition(self.hidOriginalCursorPoint);
        self.hidHasOriginalCursorPoint = NO;
    }
}

- (void)virtualScreensChanged:(NSNotification *)notification {
    (void)notification;
    if (!self.virtualMode || self.shuttingDown) return;
    [self.window orderOut:nil];
    [self releaseVirtualMouse];
    NSRect frame;
    if (![self.virtualDisplay getHostFrame:&frame]) {
        NSLog(@"TouchBarBridge virtual screen lost; terminating without a visible fallback");
        [NSApp terminate:nil]; return;
    }
    [self.window setFrame:frame display:YES];
    [self.window orderFrontRegardless];
    self.sentFrameInfo = NO;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    self.shuttingDown = YES;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self releaseVirtualMouse];
    [self.window orderOut:nil];
    [self.watchdog invalidate];
    [self.frameTimer invalidate];
    [self.captureStream stopCaptureWithCompletionHandler:^(NSError *error) {}];
    self.captureStream = nil;
    if (self.dfrDisplayStream) {
        if (self.cgDisplayStreamStop) {
            self.cgDisplayStreamStop(self.dfrDisplayStream);
        }
        CFRelease(self.dfrDisplayStream);
        self.dfrDisplayStream = NULL;
    }
    if (self.dfrSimulator && self.dfrInvalidate) {
        self.dfrInvalidate(self.dfrSimulator);
        self.dfrSimulator = NULL;
    }
    if (self.remote) {
        [self.remote disableTouchBar];
    }
    [self.webSocket cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
    [self.virtualDisplay stop];
}

@end

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        TouchBarBridgeDelegate *delegate = [[TouchBarBridgeDelegate alloc] init];
        app.delegate = delegate;
        [app run];
        return 0;
    }
}
