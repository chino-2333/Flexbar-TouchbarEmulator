#!/usr/bin/env node
'use strict';

const childProcess = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const rootDir = path.resolve(__dirname, '..');
const pluginDir = path.join(rootDir, 'com.chino.touchbaremulator.plugin');
const appPath = path.join(pluginDir, 'resources', 'TouchBarBridgeHelper.app');
const helperSource = path.join(rootDir, 'src', 'TouchBarBridgeHelper.m');
const helperExecutable = path.join(appPath, 'Contents', 'MacOS', 'TouchBarBridgeHelper');
const xpcBundleId = 'com.apple.dt.Xcode.TouchBarSimulatorService';
const xpcTarget = path.join(appPath, 'Contents', 'XPCServices', `${xpcBundleId}.xpc`);

function run(command, args, options = {}) {
  const result = childProcess.spawnSync(command, args, {
    encoding: 'utf8',
    stdio: options.stdio || 'pipe',
    ...options,
  });
  if (result.status !== 0) {
    const details = [result.stdout, result.stderr].filter(Boolean).join('\n');
    throw new Error(`${command} ${args.join(' ')} failed with ${result.status}\n${details}`);
  }
  return typeof result.stdout === 'string' ? result.stdout.trim() : '';
}

function findXcodeService() {
  const explicit = process.env.TOUCHBAR_SERVICE_XPC;
  if (explicit && fs.existsSync(explicit)) {
    return explicit;
  }

  const candidates = [
    '/Users/aspen/Downloads/Xcode-beta.app',
    '/Applications/Xcode-beta.app',
    '/Applications/Xcode.app',
  ];

  try {
    const developerDir = run('/usr/bin/xcode-select', ['-p']);
    if (developerDir.endsWith('/Contents/Developer')) {
      candidates.unshift(developerDir.slice(0, -'/Contents/Developer'.length));
    }
  } catch {
    // Keep using static candidates.
  }

  for (const app of candidates) {
    for (const serviceName of ['IDETouchBarSimulatorService.xpc', `${xpcBundleId}.xpc`]) {
    const service = path.join(
      app,
      'Contents',
      'Frameworks',
      'IDEKit.framework',
      'Versions',
      'A',
      'XPCServices',
      serviceName,
    );
    if (fs.existsSync(service)) {
      return service;
    }
    }
  }

  throw new Error('Could not find IDETouchBarSimulatorService.xpc. Set TOUCHBAR_SERVICE_XPC to the original Apple-signed XPC path.');
}

function plist() {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>TouchBarBridgeHelper</string>
  <key>CFBundleIdentifier</key>
  <string>com.chino.touchbaremulator.bridge.helper</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>TouchBarBridgeHelper</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSBackgroundOnly</key>
  <false/>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
`;
}

function build() {
  const servicePath = findXcodeService();
  fs.rmSync(appPath, { recursive: true, force: true });
  fs.mkdirSync(path.join(appPath, 'Contents', 'MacOS'), { recursive: true });
  fs.mkdirSync(path.join(appPath, 'Contents', 'XPCServices'), { recursive: true });
  fs.writeFileSync(path.join(appPath, 'Contents', 'Info.plist'), plist(), 'utf8');
  fs.cpSync(servicePath, xpcTarget, {
    recursive: true,
    preserveTimestamps: true,
  });

  run('clang', [
    '-x', 'objective-c',
    '-fobjc-arc',
    '-DSERVICE_BUNDLE_ID="com.apple.dt.Xcode.TouchBarSimulatorService"',
    '-DSERVICE_VIEW_CONTROLLER_CLASS="IDETouchBarSimulatorViewService"',
    '-F/System/Library/PrivateFrameworks',
    '-framework', 'AppKit',
    '-framework', 'ViewBridge',
    '-framework', 'CoreGraphics',
    '-framework', 'Foundation',
    '-framework', 'CoreMedia',
    '-framework', 'CoreVideo',
    '-framework', 'IOSurface',
    '-framework', 'QuartzCore',
    '-framework', 'ScreenCaptureKit',
    '-o', helperExecutable,
    helperSource,
  ]);

  const identity = process.env.CODESIGN_IDENTITY || 'Developer ID Application: yihan tong (HFL796UK5D)';
  run('/usr/bin/codesign', [
    '--force',
    '--options', 'runtime',
    '--timestamp',
    '--sign', identity,
    appPath,
  ], { stdio: 'inherit' });

  run('/usr/bin/codesign', ['--verify', '--strict', xpcTarget]);
  const verify = run('/usr/bin/codesign', ['-dv', xpcTarget], { stdio: 'pipe' });
  console.log(`Built ${appPath}`);
  console.log(`Embedded original service: ${servicePath}`);
  if (verify) {
    console.log(verify);
  }
}

try {
  build();
} catch (error) {
  console.error(error && error.stack ? error.stack : String(error));
  process.exit(1);
}
