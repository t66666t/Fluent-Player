# Windows 原生播放崩溃回归修复（2026-09-11）

## 结论与处置

本轮性能优化已撤回。之前通过组件测试和 Release 构建，不能证明原生播放稳定；用户随后报告进入媒体、关闭字幕侧栏时闪退。

Windows Application 日志记录 20:11:49、20:12:21、20:12:41 三次 `video_player_app.exe` 崩溃，故障模块 `flutter_windows.dll`，异常码 `0xc0000409`。日志证明原生进程终止，尚不能单独确定引擎内部故障位置。

最可疑的新增路径是根据 Flutter 布局调用 `VideoController.setSize`。当前 media_kit_video 1.3.1 的 Windows `VideoOutput::SetSize` 仅向原生线程池投递任务；其 Resize 会注销旧纹理并更换 D3D/ANGLE 共享资源。因此 Dart 层等待方法返回、串行调用，不能保证旧纹理已经不被 Flutter GPU 提交使用。

处置：

- 移除视口上报、延迟合并尺寸更新及对应生命周期逻辑。
- 撤回上一轮自定义桌面转场与侧栏尺寸动画，恢复原有实现。
- Windows 额外禁用应用层自适应原生纹理尺寸调整。让 media_kit 按视频源管理输出，窗口及字幕侧栏变化只影响 Flutter 显示布局，不调用原生 setSize。
- Android 保持原本不调整原生纹理的行为；其他平台恢复本轮优化之前的行为。macOS/Linux 尚未实机验证。
- 保留遍历播放器 Map 时使用 keys.toList 的安全清理修正。
- 保留用户在此轮之前及期间的其他未提交修改。

代价：Windows 小窗口也可能保留源分辨率纹理，优先稳定性。没有声称本修复提高帧率。

## 验证

`test/video_playback_performance_settings_test.dart` 新增 Windows 不允许应用层纹理调整的回归断言。

定向回归测试 25 项通过；涉及的应用文件、测试和原生测试入口静态分析通过。

`scripts/windows_native_playback_smoke.dart` 是独立原生测试入口，不读写媒体库：真实解码视频并挂载 Flutter 纹理，重复路由进入/返回、侧栏展开/收起、操作系统窗口尺寸变化及控制器释放。它检查首帧、播放时钟和错误状态，并逐阶段写入报告；原生闪退会导致报告缺少 PASS。

运行示例（先准备本地视频）：

```powershell
flutter run -d windows --release -t scripts/windows_native_playback_smoke.dart --dart-define=SMOKE_MEDIA=D:/path/sample.mp4 --dart-define=SMOKE_REPORT=D:/path/report.txt
```

注意：构建这个测试入口会将 Release 目录中的 app 改成测试程序。交付前必须重新执行 `flutter build windows --release -t lib/main.dart`，确保最终产物是正式应用。

原生冒烟测试也不能替代用户的全部素材、实际业务页和显卡组合测试。

测试入口第一次执行完成 24 次尺寸变化后，在第二个控制器初始化时超时。检查依赖源码发现 VideoController 创建等待 post-frame，而独立测试首页处于静止状态，没有业务加载动画请求新帧。测试入口已在初始化期间请求帧，随后必须重新完整执行；该超时不能记为原生回归测试通过。

修正测试入口后，20:26:15–20:26:49 在本机 Windows Release 进程完整通过：1080p60 H.264 合成视频，6 次路由进入/返回、72 次侧栏与窗口尺寸变化、3 次原生控制器创建/释放。每轮检查首帧与播放时钟。结果见 `build/native-regression/report.txt`，最终记录为 PASS；测试进程正常退出，未重现闪退。

原生测试后已成功执行 `flutter build windows --release -t lib/main.dart`（110 秒），Release 目录已恢复为正式应用入口。构建日志：`build/native-regression/production-build.log`。

## 桌面侧栏过渡（2026-09-12）

Windows、macOS、Linux 横屏播放页共用 `DesktopPlayerSidebar`：

- 将分隔条与侧栏纳入同一个 240 ms 宽度动画，关闭字幕栏时不再先移除分隔条而令视频宽度跳变。
- 每个面板按目标宽度布局，外层裁剪区域变化，避免侧栏内容在动画每帧重新布局；关闭期间保留内容完成淡出。
- 字幕侧栏首次打开后保留元素状态，并继续接收字幕和可见性更新。隐藏时禁止输入、焦点、语义和子动画，原有 isVisible 守卫停止自动跟随工作。
- 功能侧栏淡出后释放；以面板类型维持唯一元素，支持动画未结束时快速来回切换。
- 播放器使用稳定的布局 key。拖动尺寸直接跟手；全屏/窗口视口尺寸改变时直接适配新约束，避免叠加一次滞后的宽度动画。
- 桌面不再构造未使用的旧版侧栏树。Windows 禁止应用层原生纹理 setSize 的保护保持有效。

新增真实 widget 测试覆盖左右侧栏、按 8.333 ms 步长检查收起宽度连续性、动画期间内容布局次数、快速中断、字幕与播放器元素保留、隐藏 ticker、功能栏释放、拖动及全屏视口适配。连同已有侧栏、字幕视口、播放器所有权、控制条及性能策略回归，共 52 项通过。涉及代码静态分析无问题。

本轮遵守用户要求，没有操控桌面或启动原生窗口验证；widget 测试的模拟时间步长不是实际 120 FPS 测量。macOS/Linux 尚无原生验证。正式入口构建日志为 `build/sidebar-transition-release.log`。
