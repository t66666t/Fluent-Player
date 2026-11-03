# 桌面系统媒体控制

入口：**媒体库设置 → 桌面媒体控制**。

## 用户行为

| 能力 | Windows | macOS | Linux |
| --- | --- | --- | --- |
| 系统媒体面板、标题、封面、播放状态 | SMTC，默认开启 | Now Playing，默认开启 | MPRIS，默认开启；显示由桌面环境决定 |
| 键盘/耳机媒体键 | 系统分配给当前媒体会话 | Remote Command Center | GNOME/KDE 等桌面环境经 MPRIS 路由 |
| 鼠标悬停任务栏图标后的播放按钮 | 上一项、快退、播放/暂停、快进、下一项、播放模式，默认开启 | 不模拟 Windows 任务栏；使用系统媒体控件 | 不模拟 Windows 任务栏；使用桌面媒体控件 |
| 应用自己的全局组合键 | RegisterHotKey，可选 | Carbon 热键，可选 | 在系统键盘设置中绑定媒体操作 |

全局组合键默认关闭，开启后默认是：

- `Ctrl + Alt + Space`：播放/暂停。
- `Ctrl + Alt + ←`：上一项。
- `Ctrl + Alt + →`：下一项。

如果其他程序占用了其中的按键，可以切换为 `Ctrl + Alt + Shift` 加相同按键。三条注册全部成功才启用，避免只启用一部分而没有说明。修改组合、关闭开关、停止播放会话或退出应用会释放注册。没有当前媒体时不注册组合键；暂停时保留会话以便恢复。

这与键盘上的专用媒体键不同：系统媒体键由操作系统在多个媒体应用间选择目标；本应用注册的组合键专门控制 Fluent Player。开启后，即使在其他应用的文本框内按下这组组合键也会控制播放。普通字母、空格和方向键继续遵守原有应用内输入保护。

Windows 系统媒体面板的位置和样式由系统版本决定，不是传统的右下角 Toast 通知。任务栏预览显示运行中的窗口以及下方六个按钮，不将窗口内容替换成专辑封面。应用退出后不额外运行后台常驻进程。

任务栏快退/快进沿用 `doubleTapSeekSeconds`；若开启字幕跳转且当前有字幕，则沿用手机媒体通知的上一条/下一条字幕逻辑及字幕偏移。鼠标悬停提示显示当前跳转秒数或字幕跳转。连续点击沿用现有累积与边界保护；切源加载中禁用快退/快进。播放模式按钮按现有顺序循环：顺序播放 → 随机播放 → 单集循环 → 顺序播放，图标和提示随模式更新，不改变独立的“列表末尾回到第一项”设置。

播放模式图标与软件内按钮共用 `PlaybackModeIconPainter`，统一路径、圆角线宽和箭头形状。Windows 初始化时接收这套图标生成的 32×32 BGRA 像素并创建 HICON，移除原生端另一套手绘模式图标；每个进程仅生成一次。像素对照回归覆盖三种模式。

系统媒体会话声明快退、快进能力，并同步 `ShuffleEnabled` 和 `AutoRepeatMode`，接收系统的随机/循环模式请求。单集循环映射为 Track，列表回到开头映射为 List，其余为 None。Windows 自己决定当前面板展示哪些按钮，不能把任务栏的六个自定义按钮原样塞进系统卡片；有些 Windows 版本仍只显示上一项、播放/暂停、下一项。新增操作在任务栏预览中可以直接使用。

应用身份统一为 `io.github.t66666t.FluentPlayer`：在窗口创建前设置进程 AppUserModelID，注册当前用户的显示名称/图标，并为直接运行版建立开始菜单快捷方式；已有安装版快捷方式只补齐身份，不重定向其启动目标。安装器快捷方式使用同一 ID。此注册无需管理员权限。应用名称显示为 Fluent Player，应用图标与媒体封面分别提供，避免把媒体标题当成应用身份。

Windows 版本资源的 `CompanyName=com.example`、`ProductName=Fluent_Player` 是历史存储身份，必须保持稳定。`path_provider_windows` 和偏好插件据此定位 `%APPDATA%/com.example/Fluent_Player`，其中保存用户选择的数据根和 `storage/layout.json`。可见名称由 `FileDescription=Fluent Player` 和上述 AppUserModelID 的注册提供；修改显示名不能改动 ProductName。Release 保护脚本会在构建前后检查此约束，原生检查入口为 `integration_test/windows_storage_identity_test.dart`。

桌面媒体封面优先使用当前条目的本地封面，也可通过现有 `MediaArtworkRepository` 加载网络封面/在线卡片封面，复用下载缓存和请求策略。统一导出最长边 512 像素的 PNG；Windows 将图片读入独立内存流，避免 file URI、源图片格式和缓存文件生命周期造成空白。没有可用媒体封面时使用应用图标兜底；缺失封面在 30 秒后允许重试，不阻塞播放命令。停止、切源、退出期间过期的异步结果不会写回当前会话。临时图片有数量上限，退出时清理。

## 与现有播放逻辑的关系

`DesktopMediaSessionService` 绑定现有 `MediaPlaybackService` 和 `PlaylistManager`。没有新增播放器、播放列表或历史存储。

- 三种入口最终调用同一播放服务的 `resume()`、`pause()`、`playNext()` 和 `playPrevious()`。
- 快退/快进复用 `handleExternalDoubleTapSeek()`；播放模式复用 `PlaylistManager.cyclePlaybackMode()` / `setPlaybackMode()`。系统列表循环请求更新现有 `playlistWrapToFirst`，不另建播放规则。
- 上一项/下一项使用服务的 `hasPlayablePrevious` / `hasPlayableNext`，保留现有排序、循环、随机、云盘分页队列和不可播放项处理。任务栏/系统面板按真实队列能力启用或禁用按钮。
- 切换媒体期间重复的系统上下集命令直接忽略，不在缓慢的网络加载后连续跳多集。播放/暂停意图立即传入原会话，不排在切源后面；上下集的自动播放规则沿用当前设置。
- 按钮依据播放意图展示，加载期间不会将“暂停”错误切成“播放”。标题、封面、停止和队列变化随当前会话更新。位置发布最多每秒一次，不创建逐帧后台 UI 刷新。
- 单独开关系统媒体面板、任务栏按钮、全局组合键；关闭任一开关不停止音频，其他入口仍按其开关工作。
- 桌面和移动端分开适配，Android/iOS 的音频焦点、耳机去重、通知显示策略不迁移到桌面。现有“移动端切后台暂停”等规则不扩大到 Windows。
- Linux 还通过 MPRIS 将音量和倍速写入原播放服务。外部 URI 打开和系统进度拖动没有开放；Linux 正确声明 `CanSeek=false`。

## 原生实现

Windows 将 SMTC 的后台回调投递到窗口线程，再通过 MethodChannel 调用 Dart；任务栏和 WM_HOTKEY 也走同一通道。热键使用 `MOD_NOREPEAT`，注册失败回滚整组并返回错误。窗口销毁前释放注册和会话。Explorer 重新创建任务栏按钮时重新注册缩略图工具栏。

macOS 的媒体信息通过 `MPNowPlayingInfoCenter` 发布，媒体命令由 `MPRemoteCommandCenter` 传回；可选组合键通过 Carbon 注册，不使用监听所有文字输入的全局键盘钩子。窗口释放时注销命令目标和热键。

Linux 通过会话 D-Bus 导出 MPRIS 对象，以进程后缀避免多个实例抢同一个服务名。停止会话/关闭系统媒体面板时不再持有可发现的媒体服务名；退出时注销对象。不会为了组合键安装 X11 钩子或绕过 Wayland 的安全边界。

参考：[Microsoft SMTC](https://learn.microsoft.com/en-us/windows/uwp/audio-video-camera/system-media-transport-controls)、[Win32 SMTC 窗口互操作](https://learn.microsoft.com/en-us/windows/win32/api/systemmediatransportcontrolsinterop/nf-systemmediatransportcontrolsinterop-isystemmediatransportcontrolsinterop-getforwindow)、[任务栏缩略图工具栏](https://learn.microsoft.com/en-us/windows/win32/shell/taskbar-extensions#thumbnail-toolbars)、[RegisterHotKey](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerhotkey)、[Apple Remote Command Center](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter)、[MPRIS](https://specifications.freedesktop.org/mpris/latest/Player_Interface.html)。

设计参考音乐软件的“系统媒体会话 + 独立快捷键帮助”习惯，保留本软件现有的 P/N/G 等页面键。可对照 [Spotify 快捷键说明](https://support.spotify.com/ee-en/article/keyboard-shortcuts/)；它不意味着本项目复制了 Spotify 的系统实现。

## 验证入口与边界

- `flutter test test/desktop_media_session_test.dart`：元数据、播放意图、独立开关、持久化、上下集重复抑制、忙碌期间暂停、队列边界、停止/释放与设置布局。
- `flutter test test/desktop_media_artwork_test.dart`：默认封面、PNG 转换、文件 URI/中文路径、损坏图片、晚生成封面与网络封面缓存复用。
- `tool/verify_desktop_media_windows.ps1`：真实 Windows SMTC 创建、元数据及 Playing/Paused 状态；真实 RegisterHotKey 占用检测、回滚和释放；最小化窗口的 native message 分发、任务栏点击分发与队列边界保护。使用测试窗口和 MethodChannel 测试接收器，不注入键盘输入、不修改用户媒体库。
- `flutter test integration_test/desktop_media_windows_test.dart -d windows`：临时静音 WAV 文件和内存设置，验证最小化后的 Windows native message → MethodChannel → 实际播放服务及原生播放器，覆盖播放/暂停、上下曲、任务栏按钮与停止后注销。此测试使用原生消息，并不声称模拟了真人按键或鼠标悬停的视觉效果。
- 原有移动媒体会话、队列、播放时间线和输入快捷键回归继续运行。

前次三按钮版本的本机结果（Windows 11 x64，系统版本 10.0.26200.9711，Windows SDK 10.0.26100.0；本次新增功能的结果见下一节）：

- 完整 Windows Debug 应用构建成功；集成测试后已重新生成普通应用入口的构建。
- 原生验证脚本通过，覆盖真实 SMTC 属性、实际系统热键注册、第二条按键冲突时整组回滚、最小化消息分发与释放。
- Windows 真实本地音频集成测试通过，覆盖最小化暂停/恢复、下一项、任务栏上一项、停止后注销。首次测试发现发布正在进行时 `refreshNow()` 提前返回；已修复为等待最新快照排空，并增加单元回归。
- 本轮桌面媒体、移动媒体会话、输入与播放策略的定向回归通过；此前运行的播放队列、播放时间线与媒体库布局回归也通过。
- 新增注册设置的导出覆盖检查通过。整个设置导出审计另有已有失败：`services/ocr_compute_service.dart` 的持久化所有者未在现有审计清单登记；该文件在任务开始前已存在于未提交改动中，本次不改写这项独立工作。

macOS/Linux 适配代码需要在相应主机编译并验证；Windows 上的 Dart 测试和跨平台策略检查不能代替这些设备检查。系统外观、任务栏视觉、蓝牙耳机路由以及与其他媒体应用竞争需要交互验收。

### 本次六按钮与身份/封面修复验证

- Dart 定向回归共 74 项通过，静态分析无问题。覆盖跳转参数、字幕偏移、加载期保护、现有三种播放模式及系统随机/循环请求；媒体封面测试验证共享缓存只下载一次。
- Windows 原生验证覆盖六个按钮的命令映射、不可跳转保护、SMTC 随机/循环属性，以及实际可打开的图片内存流。通过系统媒体客户端读取真实会话的 AppUserModelID、标题和图片，并发起随机/循环模式请求，验证请求经过 Windows 回调到达 Dart 通道。
- 身份测试使用独立测试 ID，在真实 Shell 中解析应用 ID 和显示名称，检查进程 ID、快捷方式 ID 与注册图标，结束后清理测试专用注册和快捷方式。
- 当前工作区完整 Windows 应用/集成测试构建被另一项 Qwen ASR 改动的预编译来源校验阻断：`Qwen component needs rebuilding: native/qwen_asr/CMakeLists.txt`。本次未绕过校验或改写模型组件；此前完整构建结果不代表这次新增代码已完成全应用构建验证。
- 按用户要求，本次不进行 computer use 交互验收。系统面板的具体按钮布局仍以 Windows 实际展示为准。
