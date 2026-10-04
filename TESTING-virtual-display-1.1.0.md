# TouchbarEmulator 1.1.0 虚拟屏测试版

安装包：`com.chino.touchbaremulator.flexplugin`。在 FlexDesigner 中导入并覆盖同 UUID 的旧插件，再进入带 TouchbarEmulator 按键的页面。主程序需要包含 macOS 27 bridge 后端；本机已安装的 FlexDesigner 中检测到了对应 bridge 触摸链路。本次没有修改或替换主程序。

macOS 27 bridge 模式默认使用 2× 虚拟显示器和非激活面板，原生捕获 2190×80 后裁剪输出 2170×60。系统显示器列表中会出现 `FlexBar Touch Bar`，停止 helper 后移除。没有实体显示器的环境另创建临时 `FlexBar Headless Desktop`；普通实体屏配置不需要该 anchor。

模拟器改为 style 3，与旧 native 模块一致，显示 Esc，并修复 style 2 中画面与触摸不对位的问题。测试按钮现在使用图片中真实坐标 x=270，滑块用图片坐标 x=550 → 850，实际回调为 25% → 78%；不再使用研究阶段的经验偏移。

已验证：

- 原生 2× backing 和 2170×60 输出；按钮点击、连续滑块拖动。
- 源应用操作前后保持前台；模拟器位于主测试屏之外。
- 同一配置的重复 alive 不反复创建屏幕；旧进程 exit 不覆盖新进程状态。
- 按住触摸时 SIGTERM 或 WebSocket 断开：松开鼠标、恢复光标、销毁虚拟屏。
- helper Developer ID 签名、内嵌 Apple XPC 原签名、FlexCLI 验证和打包。
- 从最终 `.flexplugin` 解包后再次运行，真实按钮回调通过。

测试环境是 macOS 27.2（26B5091g）arm64、双虚拟屏。实体屏、实际 FlexBar、其他应用和睡眠唤醒由本轮用户测试继续确认。FPS 配置为 60，但逐帧截图链路的实际输出受系统负载限制，不保证稳定 60 FPS。

当前输入借用系统鼠标，触摸期间光标可能短暂移开，松手后恢复。持续 10 秒没有后续触摸消息会释放遗失的按下状态。若画面正常但不能触摸，查看日志 `postEventAccess`；为对应的 FlexDesigner/helper 开启系统辅助功能输入授权后重新进入页面。本测试版不会自行更改系统隐私权限。

建议检查：

1. 启动后实体桌面是否出现模拟器窗口，画面是否清晰且尺寸正确。
2. 左侧按钮、右侧 Control Strip、滑块是否准确对应触摸位置。
3. 操作期间源应用是否保持前台，松手后鼠标是否恢复。
4. 离开 Touch Bar 页面后，虚拟显示器是否消失。

旧可见窗口版的回退安装包保留在 `backups/2026-09-30-pre-virtual/visible-window.flexplugin`。
