const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const source = fs.readFileSync(
  path.resolve(__dirname, '../src/TouchBarBridgeHelper.m'),
  'utf8',
);

assert.ok(
  source.includes('touchBarLogicalPointFromPayload(payload,') &&
    source.includes('CGFloat captureWidthPoints = 1085.0;') &&
    source.includes('CGFloat captureInsetX = 5.0;'),
  'helper must map incoming touch coordinates with fixed Apple Touch Bar logical dimensions instead of mutable remoteView bounds',
);
assert.ok(
  source.includes('TouchBarBridge mouse payload') &&
    source.includes('TouchBarBridge CGEvent mouse posted'),
  'helper must log received mouse payloads and posted CGEvent diagnostics',
);

assert.ok(
  source.includes('CGEventPostToPid(getpid(), event);'),
  'helper must dispatch bridge touch through a CGEvent targeted at the hosted Apple XPC remote view',
);
assert.ok(
  source.includes('CGEventPostToPid(getpid(), moveEvent);') &&
    source.includes('kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent'),
  'helper must post mouse-moved/down/up events with the helper window number so ViewBridge can route them',
);
assert.ok(
  source.includes('self.window.ignoresMouseEvents = NO;') &&
    source.includes('self.window.ignoresMouseEvents = YES;'),
  'helper must temporarily allow hidden window mouse events while posting the CGEvent sequence',
);
assert.ok(
  source.includes('@"type": @"mouse-dispatched"'),
  'helper must send a mouse-dispatched diagnostic message back to FlexDesigner after dispatching touch events',
);


const handleTextMatch = source.match(/- \(void\)handleTextMessage:\(NSString \*\)text \{([\s\S]*?)\n\}/);
assert.ok(handleTextMatch, 'helper must keep a handleTextMessage method');
assert.match(
  handleTextMatch[1],
  /dispatch_async\(dispatch_get_main_queue\(\), \^\{\s*\[self postMousePayload:payload\];\s*\}\);/,
  'helper must dispatch WebSocket touch payloads to the main queue before touching AppKit',
);

assert.ok(
  source.includes('[self.remoteView mouseDown:event]') &&
    source.includes('[self.window sendEvent:event]'),
  'helper may keep direct NSRemoteView/AppKit dispatchers only as explicit diagnostics modes',
);

console.log('touchbar helper touch event forwarding tests passed');
