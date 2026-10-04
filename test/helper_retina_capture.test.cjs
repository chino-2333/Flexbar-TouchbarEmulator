const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const source = fs.readFileSync(
  path.resolve(__dirname, '../src/TouchBarBridgeHelper.m'),
  'utf8',
);

assert.ok(
  source.includes('#import <ScreenCaptureKit/ScreenCaptureKit.h>'),
  'helper must use ScreenCaptureKit for high-resolution window capture',
);
assert.ok(
  source.includes('CGSSetWindowResolutionFn'),
  'helper must use the private WindowServer resolution API to force a 2x backing store',
);
assert.ok(
  source.includes('applyWindowBackingStoreResolutionOverride(self.window);'),
  'helper must apply the 2x backing override to its own window',
);
assert.equal(
  source.includes('copyImageScaledToSize(contentImage'),
  false,
  'helper must not fall back to scaling 1x captures',
);
assert.ok(
  source.includes('TouchBarBridgeBackingWidth = 2190'),
  'helper must normalize capture to fixed Touch Bar backing width',
);
assert.ok(
  source.includes('TouchBarBridgeBackingHeight = 80'),
  'helper must normalize capture to fixed Touch Bar backing height',
);
assert.ok(
  source.includes('configuration.width = TouchBarBridgeBackingWidth;'),
  'helper must request the fixed 2190px capture width from ScreenCaptureKit',
);
assert.ok(
  source.includes('configuration.height = TouchBarBridgeBackingHeight;'),
  'helper must request the fixed 80px capture height from ScreenCaptureKit',
);
assert.ok(
  source.includes('normalizePremultipliedBGRA') && source.includes('pixels[i + 3] = 255;'),
  'helper must restore low-alpha ScreenCaptureKit captures to opaque BGRA frames',
);
assert.ok(
  source.includes('self.touchBarStyle = integerArgument(@"style", self.virtualMode ? 3 : 2);'),
  'helper must expose the Apple XPC touch bar style for diagnostics',
);
assert.ok(
  source.includes('captureSource", @"screencapturekit"') ||
    source.includes('source:@"screencapturekit"'),
  'helper frame-info must report ScreenCaptureKit as the capture source',
);
assert.ok(
  source.includes('DFRTouchBarCreateDisplayStreamFn'),
  'helper must resolve DFRTouchBarCreateDisplayStream for the DFR touch dispatcher activation stream',
);
assert.ok(
  source.includes('CGDisplayStreamStartFn') &&
    source.includes('self.cgDisplayStreamStart(self.dfrDisplayStream)'),
  'helper must start the DFR touch dispatcher activation stream through a runtime-resolved function pointer',
);
assert.ok(
  source.includes('CGDisplayStreamStopFn') &&
    source.includes('self.cgDisplayStreamStop(self.dfrDisplayStream)'),
  'helper must stop the DFR touch dispatcher activation stream through a runtime-resolved function pointer',
);
assert.equal(
  source.includes('postDFRFrame') || source.includes('sendDFRFrame'),
  false,
  'helper must not use the failed third-party DFR direct stream path for frame delivery',
);
assert.ok(
  source.includes('self.targetWidth = integerArgument(@"width", 2170);'),
  'helper default output width must be device pixel width',
);
assert.ok(
  source.includes('self.targetHeight = integerArgument(@"height", 60);'),
  'helper default output height must be device pixel height',
);
assert.ok(
  source.includes('stringArgument(@"capture-source", @"screencapturekit")'),
  'helper default capture source must be the verified high-resolution ScreenCaptureKit path',
);
assert.ok(
  source.includes('self.hideWindow = !flagArgument(@"show-window");'),
  'helper must default to a hidden high-resolution capture window unless --show-window is explicitly requested',
);
assert.ok(
  source.includes('self.hideMode = stringArgument(@"hide-mode", @"orderout");'),
  'helper must default to ordering out the capture window after ScreenCaptureKit binds it',
);
assert.ok(
  source.includes('TouchBarBridge launch args') &&
    source.includes('TouchBarBridge window state'),
  'helper must log launch arguments and final window state for hidden-window diagnostics',
);
assert.ok(
  source.includes('[self.hideMode isEqualToString:@"orderout"]') &&
    source.includes('[self.window orderOut:nil]'),
  'helper must support ordering out the capture window after ScreenCaptureKit binds it',
);
assert.ok(
  source.includes('captureInsetPoints'),
  'helper frame-info must expose point-space inset for debugging',
);

console.log('touchbar helper retina capture tests passed');
