# 1.1.3 — hidden stream without a virtual display

Accepted behavior: the host is beneath the desktop, with only one logical point
intersecting the leftmost screen. Mission Control/fullscreen overview animations
may reveal it, as demonstrated by the prior marked compositor captures. This is
an accepted tradeoff, not an always-invisible implementation.

The plugin now launches `--hidden-stream --style 3 --mouse-dispatch service`.
The mode enforces a nonactivating 1095×40 point panel, native SCStream capture at
2190×80, and a centered 2170×60 crop. It skips private backing-store/context scale
overrides and repeated layout changes. Stream errors terminate capture, and
SIGTERM/disconnect cleanup cancels outstanding service input. No HID fallback.
The virtual display mode is retained only for explicit diagnostic use.

## Verification on 2026-10-04

- Build and plugin validation passed. Apple XPC remains originally Apple-signed.
- Plugin launch/lifecycle and native-backend unit tests passed; macOS backend
  selector tests confirm 26 and earlier remain native, 27+ uses bridge.
- Real Apple XPC buttons, continuous slider, focus, stationary/moving/held desktop
  mouse, and SIGTERM/disconnect during simultaneous desktop drag passed:
  `/var/folders/hf/194cmdk92ys9jdr8m6cskw_h0000gn/T/touchbar-service-input-CWgZwO`.
- Single-screen and simulated existing mixed-scale multi-screen lifecycle tests
  passed; helper startup/shutdown do not add, move or remove screens:
  `/var/folders/hf/194cmdk92ys9jdr8m6cskw_h0000gn/T/touchbar-lifecycle-Zx4B99`
  and `touchbar-lifecycle-fgNSEB` in the same temporary directory.
- Simulated monitor attachment/removal during a running stream preserved capture
  and actual button callbacks: `touchbar-hidden-hotplug-XicO6n` in the same
  temporary directory. These temporary monitors belong to the test fixture,
  not the plugin.
- Placement geometry covers left, stacked, staggered and mirrored layouts;
  intersections with any screen are at most one logical point wide.
- Production helper fidelity probes on a 1× display passed. 38,700 RGB values
  in the fixed label region match the previous native 2× virtual-screen reference
  exactly, and real button/slider changes update the captured pixels. No display
  topology changes or cursor/button changes occurred during those probes.
  Evidence: TouchbarDesigner `tools/touchbar-macos27-research/results/`
  `production-hidden-1.1.3-button`, `production-hidden-1.1.3-drag`.
  Helper SHA256: `2f25b5895e2a398feaabfd18d6c978a4e2446e68bf3093cb074eed11523d7d4b`.

## Reproduction

Run desktop-affecting integration tests sequentially, with the real mouse released.

```sh
npm run build
node test/plugin_helper_args.test.cjs
node test/helper_retina_capture.test.cjs
node test/helper_touch_event_forwarding.test.cjs
clang -fobjc-arc -framework AppKit test/HiddenPlacement.m -o /tmp/touchbar-hidden-placement-test
/tmp/touchbar-hidden-placement-test
node test/helper_service_input.integration.cjs
node test/helper_lifecycle.integration.cjs
TOUCHBAR_TEST_MULTISCREEN=1 node test/helper_lifecycle.integration.cjs
node test/helper_hidden_hotplug.integration.cjs
npm run plugin:validate
npm run plugin:pack
```

Physical monitor hotplug, sleep/wake, unlock, Stage Manager, Show Desktop and
App Exposé have not been comprehensively validated. Simulated display tests are
not evidence that every physical monitor or visibility transition is covered.

Package SHA256: `c2d173445e283dafa7d46f27a3c1093af5981224eccac93f4b13517fc424887d`.

Public repository release package SHA256: `df0bff53239235e655118bcdc82aefe484c68147622a6d8c6a33ce0c6fda2e48`. The release package
restores the public repository URL and preserves its SDK/software requirements;
helper and runtime bundle bytes are identical to the tested local package.
