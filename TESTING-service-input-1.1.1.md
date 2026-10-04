# TouchbarEmulator 1.1.1：不占用系统鼠标的触摸输入

安装 `com.chino.touchbaremulator.flexplugin`，覆盖同 UUID 旧插件，重新进入 Touch Bar 页面。

仍使用虚拟显示器进行原生 2× 捕获，输出 2170×60。默认输入改为 `--mouse-dispatch service`：通过宿主的 `serviceProcessIdentifier` 确定 Apple XPC PID，匹配该服务自己的窗口及坐标，再用私有状态的 CGEvent 定向投递。此前向宿主窗口投递的实验不能转发到服务，并不意味着向服务窗口直接投递也无效。

该路径不移动、隐藏或恢复系统光标，不向全局 HID 队列发送事件。正常松手、超时、断连、退出和屏幕变化都只向服务发送释放事件；找不到唯一的服务窗口、缺少接口或权限时拒绝触摸，没有抢占鼠标的自动回退。旧 HID 模式仅保留为显式命令行诊断模式，插件不会选择它。

## 自动验证

在本机 macOS 27.2（26B5091g）、Apple Silicon 上，使用原签名 Apple XPC 验证：

- 独立测试应用的按钮每次点击只触发一次，连续滑块拖动有效，源应用保持前台。
- 100 Hz 观察系统光标及 combined/HID 左键状态；Touch Bar 操作期间静止光标不移动、全局左键不被按下。
- 用独立进程在测试窗口中模拟桌面 HID 拖动，与 Touch Bar 同时操作：桌面鼠标可以保持按下和移动，Touch Bar 松手不会释放桌面鼠标或拉回光标。
- 两种拖动同时进行时 SIGTERM / WebSocket 断开，桌面拖动仍保持；退出移除自有虚拟屏。
- 画面仍为原生 2×、2170×60；helper 和 Apple XPC 签名校验通过。

最终安装包解包复测通过，包 SHA256：`bdb35170593bd7206e5b6b85777282b5b5db26890ec3cf651fc07e3614f5833b`。本机证据目录：`/var/folders/hf/194cmdk92ys9jdr8m6cskw_h0000gn/T/touchbar-service-input-J7tyyD`。初次生产构建使用 Xcode-beta 的 Apple XPC，最终包使用 `/Applications/Xcode.app` 的 Apple XPC，两者均通过完整输入隔离测试，均保留 Apple 原签名。

```sh
node test/plugin_helper_args.test.cjs
node test/helper_service_input.integration.cjs
node test/helper_lifecycle.integration.cjs
```

`helper_service_input.integration.cjs` 自行编译隔离测试应用和观测工具，创建临时虚拟屏，只在它自己的桌面窗口内产生测试鼠标事件。请测试时不要同时手动移动鼠标；测试工具退出会释放它自己产生的按下并恢复测试前位置。观测日志保存在输出的临时目录。可通过 `TOUCHBAR_BRIDGE_HELPER` 指定从安装包解出的 helper 复测。

## 请用真实设备检查

1. 鼠标停在实体屏上，连续点击、拖动 FlexBar Touch Bar；指针应保持原位。
2. 鼠标拖动一个窗口或画图时，另一只手操作 Touch Bar 滑块；鼠标不应中断或跳位。
3. 同时使用鼠标和 Touch Bar 后松手、离开页面，再检查鼠标正常。
4. 检查常用应用的按钮、长按、弹出条及 Control Strip。任意第三方控件、真实多屏、系统升级后的兼容性仍需覆盖。

该实现仍依赖私有窗口路由接口，不能保证未来 macOS 版本不变。虚拟屏在系统显示器列表中出现的行为与 1.1.0 相同。辅助功能事件投递授权仍需保留。

本机回退包：`backups/2026-10-02-pre-service-input/virtual-hid-1.1.0.flexplugin`。该旧版会借用系统鼠标。
