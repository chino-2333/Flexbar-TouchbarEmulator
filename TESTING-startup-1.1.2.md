# TouchbarEmulator 1.1.2：移除启动时的屏幕重排

1.1.1 在创建虚拟屏后，无论系统分配的位置是否可用，都会调用 `CGCompleteDisplayConfiguration`，将虚拟屏移到所有屏幕右侧并留下 256 点间隔。该显示配置事务会触发系统的全屏淡出/淡入，是启动时整个显示器黑一下的可疑来源。

1.1.2 直接使用 WindowServer 自动分配的扩展屏位置，不再提交这次排列变更。启动时要求虚拟屏为非主屏、非镜像、2×，且整个虚拟屏不与其他屏幕重叠；不满足时等待布局稳定，最终失败退出，不重排用户桌面。屏幕变化时沿用同样的检查。

不再人为保留 256 点空隙，因此系统可能把虚拟屏放在真实屏幕旁边，用户主动把桌面光标移过边缘时仍可能进入虚拟屏。Touch Bar 的交互继续使用独立服务事件，不移动或抢占桌面鼠标。此版本没有让虚拟显示器常驻，也没有改变 macOS 26 及以前的 native 路径。

## 本机验证

- 构建、插件校验及参数/捕获/事件回归检查通过。
- 在两个预先创建的测试显示器上，启动和停止 helper 后，原有显示器的位置、尺寸、比例、主屏和镜像状态保持一致。两次启动都直接使用系统布局；SIGTERM / WebSocket 断开均清理自身虚拟屏。
- Apple XPC 实际按钮、连续滑块拖动、桌面鼠标静止/移动/同时按下、前台焦点和退出清理的集成测试通过；原生 2×、2170×60 输出仍正常。
- 多屏测试证据：`/var/folders/hf/194cmdk92ys9jdr8m6cskw_h0000gn/T/touchbar-lifecycle-0iicFg`。
- 输入与画面证据：`/var/folders/hf/194cmdk92ys9jdr8m6cskw_h0000gn/T/touchbar-service-input-jZZthM`。

```sh
npm run build
TOUCHBAR_TEST_MULTISCREEN=1 node test/helper_lifecycle.integration.cjs
node test/helper_service_input.integration.cjs
npm run plugin:validate
npm run plugin:pack
```

多屏测试使用受控虚拟显示器，不等同于实体屏目视验证。尚需用户在原来会黑屏的实体显示器上多次进入/离开 Touch Bar 页面，确认黑屏是否消失。虚拟显示器接入/移除仍属于系统显示拓扑变化，不能据此保证所有 GPU、显示器及远程桌面组合完全不闪。

回退包：`backups/2026-10-04-pre-startup-fix/service-input-1.1.1.flexplugin`。
