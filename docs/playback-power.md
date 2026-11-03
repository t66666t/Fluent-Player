# 播放运行与耗电审计

日期：2026-10-26。本轮以开始工作时的工作区为基线，保留已有未提交修改，重点检查移动端前台播放、后台播放和暂停状态的持续工作，同时检查共享代码对 Windows、iOS、macOS、Linux 的影响。

本报告区分代码审查、自动回归、原生构建和实机运行。减少无用帧、全量遍历或定时扫描可以解释优化方向，不能直接换算成续航提升；尚未完成的实机验证不计为通过。

## 审计范围

检查了播放控制器和原生适配、后台生命周期、播放意图与原生状态同步、位置插值时钟、seek 与倍速、缓冲和播放完成、字幕与歌词、弹幕、氛围背景、键盘保持输入、系统媒体会话、缓存下载及文件租约、网络重连、跨设备同步和配对、播客更新及片尾跳过、缩略图和预览、睡眠定时、模型后台任务与 Android 原生资源锁。

本轮不升级依赖、不调整硬件解码默认设置、不更换本地模型、不修改任务存储格式或重写队列。已有模型 ID、文件身份、断点、字幕输出与用户数据继续沿用原有契约。

收尾阶段用户明确表示“不用管环境光效果了”，因此停止环境光的后续调整、诊断和补充测试，不再补 Windows 新一轮环境光实机验证。保留本轮已完成且经过验证的修改；用户没有要求回退已有修改。

## 八项局部修复

各项的回归和原生验证范围分别记录如下。第八项由 V4/V5 真机诊断追加，已有专项回归及 Android V6 的有限运行验证；不将单次诊断或采样外推为所有媒体和平台均已通过。

| 问题 | 修改 | 必须保留的行为与边界 |
| --- | --- | --- |
| 没有呈现消费者时仍持续请求逐帧位置更新 | 位置和弹幕通知器记录实际订阅数量；有消费者时使用原有 VSync 时间轴，无消费者时停止 Ticker，使用单调时间并保留原有低频位置采样 | 订阅发生在 widget build 时不立即发布新值；重复订阅与通知内移除保持 `ChangeNotifier` 语义；seek、倍率、暂停、缓冲与前后台切换仍遵循原生确认规则；播客停滞外推上限不因订阅变化而重置 |
| 氛围背景在应用隐藏、页面被覆盖、画面完全覆盖背景或暂停后仍重复抓帧和模糊 | 按应用和路由可见性、实际露出的背景以及播放状态管理采样；暂停保留已有图片，仅在 seek、初始化完成或恢复显示等必要边界补采样 | `inactive` 仍可能可见，不据此停掉可见背景；已有图片继续用于暂停与布局；异步捕获使用代次检查，释放后不再补发捕获，替换图片及时释放 |
| 明确为纯音频的中继或 HLS 地址没有音频扩展名，仍创建视频输出 | 创建视频 surface 时复用既有 `knownAudioOnly` 分类，包括显式音频播放标记 | 仅复用原生打开流程已经使用的音频分类，不把普通视频或未知网络媒体改成纯音频；保持原有音频轨选择和视频恢复保护 |
| 系统媒体通知在每次位置快照和边界调度时重复构建全量字幕索引 | 查询播放器已维护的字幕索引，同一份索引用于通知文字和下一个字幕边界 | 保留间隙延续、当前字幕回退、替换与清空、流式追加和变速后的边界调度，不新增第二份长期缓存或改变通知显隐与耳机控制 |
| 后台每 15 秒遍历全部缓存文件及已完成任务目录 | 应用隐藏期间停止全库维护定时器；已隐藏时初始化也不启动；恢复前台沿用即时可用性刷新和网络唤醒，再恢复周期维护 | 活跃下载、进度保存和任务队列不暂停；完成后的即时目录清理、文件监听、缓存获取校验和待删文件租约释放继续执行；显式协调检查仍可调用，已经开始的一次维护正常收尾 |
| 应用失焦或隐藏时丢失 key-up，音量重复调整或临时倍速可能残留 | 生命周期边界结束键盘保持输入；失焦复用原有焦点丢失策略，隐藏后完整清理 | 窗口仍可见但 `inactive` 时停止已开始的保持动作；保留短按 Space 等待 key-up 的原有规则；不暂停后台媒体，不修改稳定播放倍率 |
| 后台恢复播放后，返回前台反而再次暂停 | 真机基线复现后，区分 Flutter 返回路径中的 `paused → hidden`，不把返程误判成离开前台 | 保留真正离开时的自动暂停默认值、跳过 hidden 直接进入 paused 的保护、detached 原意、移动开关及桌面守卫；不是关闭自动暂停设置 |
| Android MediaKit 氛围背景截图仍产生较长原生截图等待，影响控制器位置更新 | 对明确为 SDR、且几何条件安全的 Android 氛围缩略图临时使用软件截图，恢复原有截图选项，并将 96 px 小图编码移出播放控制锁 | 仅影响氛围缩略图；云端封面继续使用原有完整分辨率 JPEG；HDR、色彩信息未知、旋转或其他不安全几何条件回退，保留既有截图与播放兼容路径；V6 未验证整段输出图片尺寸 |

主要代码位于 `lib/services/media_playback_service.dart`、`lib/services/playback_timeline_clock.dart`、`lib/services/listener_aware_value_notifier.dart`、`lib/services/danmaku_presentation_position.dart`、`lib/widgets/ambient_letterbox_layer.dart`、`lib/platform/ambient_frame_thumbnail.dart`、`lib/platform/windows_video_player_media_kit.dart`、`lib/services/system_media_session_service.dart`、`lib/features/media_cache/media_cache_service.dart` 和 `lib/widgets/video_controls_overlay.dart`。

## 保留的策略及理由

- **后台原生播放和资源保护：**保持原有播放意图、控制器所有权、音频焦点、系统媒体会话、视频轨恢复与文件租约。Android 的缓存和模型任务 partial wake lock 服务于实际工作，服务销毁时释放；局域网发现的多播锁已有 Activity 暂停释放路径。本轮不通过删除这些保护来获取表面上的低耗电。
- **Windows 视频纹理保护：**保留禁止应用层原生纹理尺寸调整的既有保护，避免重新引入纹理同步与原生资源竞争。
- **Bilibili 后台视频轨：**仍持有播放页时保留原有视频轨策略，避免重新选轨导致返回前台黑屏或音频时钟回退；离开播放页后的音频优先设置保持原意。20ms 音频缓冲与既有倍速滤镜也没有改动。本轮没有声称消除了后台视频解码的全部能耗。
- **同步与配对轮询：**保留自动进度同步、在线发现、配对状态和重试节奏。这些周期承担用户已开启的跨设备功能，不能统一套用界面不可见即停止的规则。
- **网络取消和恢复：**保留退避与取消检查。部分调用只提供布尔取消条件，短轮询仍承担取消响应；没有等价事件通知时不直接改成长时间等待。
- **播客：**保留活动播放的片尾跳过、在用媒体保护、学习租约、下载进度，以及受设置、间隔和失败退避约束的订阅更新。后台下载、用户保留和已播放清理的业务决定没有改动。
- **睡眠定时与任务进度：**活动睡眠计时承担到点停播，下载和推理的任务内定时器承担取消、进度或租约。本轮没有统一降频，也没有停止用户明确启动的工作。
- **封面、缩略图与预览：**沿用按需加载、缓存淘汰和交互结束后的清理，不添加播放启动时的全库扫描、模型哈希或自动基准测试。

## 自动验证

| 验证层次 | 当前结果 | 证据与限制 |
| --- | --- | --- |
| 最新合并播放功能回归 | 39 文件、490 项中 489 项通过，1 项无关布局断言失败 | `build/power-audit/ambient-final-regressions.log`；失败为播客音乐页横屏工具栏位置，原因及证据见下文。前一轮 38 文件、475 项通过记录为 `android-final-regressions.log`；不同轮次不累计相加，也不将本轮集合记录为全部通过 |
| 模型集成契约检查 | 428 项通过 | `python tool/verify_model_integration.py --output build/power-audit/model-integration`；回归日志 `build/power-audit/model-integration/regression.log`。本轮没有执行原生模型推理 |
| 核心播放与时钟补充回归 | 10 文件、196 项通过 | `build/power-audit/transport-bilibili-final.log`；包括 seek ack、Bilibili 原生推进解除 seek-hold、真实 2 秒 timeout、暂停及缓冲守卫；与最终合并回归重叠，不直接相加 |
| 变更文件静态分析 | 19 文件无问题 | `build/power-audit/final-analysis.log` |
| 返前台生命周期补充检查 | 74 项通过、三文件分析无问题 | `lifecycle-before.log` 先复现两项失败，`lifecycle-after.log`、`lifecycle-analysis.log` 记录最小修复后的结果；均位于 `build/power-audit/` |
| V6 截图与播放设置专项回归 | 50 项通过 | `build/power-audit/ambient-sdr-tests.log`；包括 SDR 守卫、原选项恢复及失败路径，不替代实机兼容验证 |
| V6 集成补充回归及分析 | 5 文件、49 项通过；14 文件静态分析无问题 | `build/power-audit/ambient-v6-integrated-regressions.log`、`final-v6-analysis.log`；与专项及原有集合重叠，不累计，也不覆盖上述无关布局失败 |

针对性测试包含按需订阅、build 中订阅、弹幕单独订阅、最后消费者移除、暂停与倍率、后台订阅、原生主导的播客停滞上限、字幕同长度替换和清空、长字幕查询、氛围背景生命周期和异步释放、后台缓存完成及待删租约、键盘失焦等路径。Widget 测试使用模拟帧和时间，不能替代实际硬件解码、音频输出或整机耗电测量。

本次未通过项为 `test/podcast_playback_test.dart` 的 `podcast notes open separately from the full portrait and landscape transcript`，第 1080 行期待工具栏左上角 `(16, 16)`，当前实际为 `(16, 15.3)`。单项重跑同样失败。当前并行修改的 `music_player_screen.dart` 新增手机横屏间距公式，在 844×390、零安全区时得到 `390 × 0.07 − 12 = 15.3`；HEAD 原实现固定为 16，精确解释该差异。此测试不构造氛围背景或探针，失败与本轮氛围背景 helper/API 无因果关系。本轮没有为使回归变绿而修改他人的布局或测试期望。重跑日志为 `build/power-audit/podcast-notes-retry.log`、`podcast-notes-latest.log`，HEAD 源码和公式对照为 `layout-head-evidence/comparison.json`、`layout-head-evidence/music_player_screen.head.dart`；这些证据是源码对照与当前单项复现，不冒称完整 HEAD 已运行通过。

可重复检查的部分入口：

```powershell
flutter test --no-pub test/playback_timeline_clock_test.dart test/playback_transport_sync_test.dart test/listener_aware_value_notifier_test.dart test/danmaku_presentation_position_test.dart
flutter test --no-pub test/ambient_letterbox_lifecycle_test.dart test/system_media_subtitle_index_test.dart test/media_cache_service_test.dart test/player_volume_keyboard_test.dart test/playback_speed_keyboard_test.dart
python tool/verify_model_integration.py
```

## 原生构建与实机状态

| 平台 | 环境与已完成工作 | 当前验证边界 |
| --- | --- | --- |
| Windows | Windows 11 小米 Book 14 Pro X7 主机；隔离快照 `D:/1spbfq/pwr1` 的前轮修改前后 Release 探针构建及真实播放 A/B 通过；V6 探针另已编译成功 | 前轮正常、暂停、seek、2 倍速、无订阅播放、氛围背景和纯音频中继通过，结果限定当时版本。V6 启动被自动审批策略阻止，未原生运行；未验证正常退出或整机电池放电 |
| Android | USB 设备 `983d4e11`，型号 `23046RP50C`，Android 15；独立 Before/After V2 本地视频基础 A/B 完成，修改版通过，基线复现返回前台误暂停；V6 本地及网络后台 seek、定向媒体暂停/播放、实际息屏 60 秒及唤醒后播放检查通过 | 本地 MP4 使用原有 ExoPlayer 委托路径；按需 Ticker 停止后仍有原生 SurfaceProducer 驱动的帧，不能声称 Android 离页总帧清零。V6 可见截图期间位置采样正常推进，但未验收整段图片尺寸；USB 充电不作为电池放电测量 |
| iOS、macOS、Linux 及其他目标 | 检查共享代码与平台分支，保持已有适配与默认行为 | 当前设备没有完成对应原生构建及实机运行，不声称这些系统已通过 |

最终已在隔离快照恢复正式 `lib/main.dart` 入口，完成 Android ARM64 和 Windows Release 构建。已核对 Android applicationId / 名称为 `com.example.video_player_app` / `Fluent_Player`、依赖锁与工作区一致，且两个平台的生产插件注册均不含 `integration_test`。本轮被测文件与当前工作区的哈希逐项一致，见 `final-source-consistency.json`；独立快照冻结构建输入，工作区其他并行修改继续保留。探针 APK 另存，不作为正式软件分发；正式包没有覆盖安装到用户设备。

| 正式产物 | 路径 | 构建与核对证据 |
| --- | --- | --- |
| 最终 Windows Release | `D:/1spbfq/pwr1/build/windows/x64/runner/Release/video_player_app.exe` | `build/power-audit/windows-production-final-build.log`；正式入口构建通过，运行需要同目录配套文件 |
| 最终 Android ARM64 Release | `D:/1spbfq/pwr1/build/app/outputs/flutter-apk/app-release.apk` | `build/power-audit/android-production-final-build.log`、`android-production-final-package.log`；正式入口构建通过，包身份和 ABI 已核对 |

最终产物及 Windows AOT 哈希、入口、依赖锁和实机验证状态见 `build/power-audit/production-artifacts.json`；前轮记录保存在 `production-artifacts-previous.json`。最终 Android APK SHA-256 为 `B88A20F5D9AB23C914E088ABE11BFE70060A109D0D4EDB6073CCC42F497EDA59`；Windows `data/app.so` 为 `F987D8E1C6947D7CDA9987F9DD0748A469BFEC1E22DA097ABE52E5D03BAA3389`。构建确认编译和打包，实机运行仍以前述对应版本的探针结果为边界，不把正式入口编译成功视为全部功能已经实机验收。

### Windows 原生 A/B

使用同一 180 秒、1080p60 H.264 + AAC 样本，同一 Release 探针和同一窗口设置。每种状态先稳定 2 秒，再采样 8 秒；每版各一次。完整位置、帧数、CPU 和内存样本为 `build/power-audit/windows-before.json`、`windows-after.json`；对照为 `windows-comparison.json`，采样时九个生产文件的哈希保存在 `after-source-hashes.json`，当时与工作区及快照逐项一致。此后新增修复不追溯计入这次 Windows A/B。

| 场景 | 修改前 Flutter 帧数 → 修改后 | 修改前抽帧 → 修改后 | 修改后控制器位置采样推进 |
| --- | ---: | ---: | ---: |
| 可见且有位置订阅 | 967 → 956 | 0 → 0 | 8000 ms |
| 离页且无位置订阅 | 962 → 0 | 0 → 0 | 8000 ms |
| 氛围背景被路由覆盖 | 966 → 0 | 8 → 0 | 8000 ms |
| 暂停并 seek 后稳定的氛围背景 | 9 → 1 | 8 → 0 | 0 ms |
| 可见 2 倍速 | 945 → 961 | 0 → 0 | 15983 ms |

同次采样中，被覆盖背景的进程 CPU 时间由 3594 ms 降至 1938 ms，暂停背景由 1234 ms 降至本次采样计时分辨率下的 0 ms。这是单次进程采样，构建等其他系统负载可能影响结果，不用它推算省电比例或长期统计结论。控制器位置采样推进、暂停位置和 2 倍速检查均通过；无扩展名的 localhost 音频中继初始化成功、位置推进且没有视频输出。

基线比较的是原有 Ticker 和氛围背景策略，基线快照已包含较早完成的纯音频分类修复。因此纯音频一项只是运行验证，不作为该修复的前后性能对比。原始样本缺少音轨的试运行不纳入本表；上述正式采样使用带 AAC 的样本，已核对流信息。

探针进程没有可供 `CloseMainWindow` 关闭的主窗口句柄；采样完成、调用生产 `stop()` 后由启动脚本结束其自己创建的进程。`windows-before-exit.json` 和 `windows-after-exit.json` 均记录 `normalExitValidated=false`、`forcedTermination=true`，不将它算作应用正常退出验收。没有关闭用户正在运行的应用。

V6 Windows 探针已编译成功，见 `build/power-audit/windows-v6-probe-build.log`。随后后台启动命令被自动审批检查以 `blocked by policy` 拒绝，尚未进入原生运行；该阻止不能记为运行通过，也不能据此判定代码运行失败。按用户停止环境光后续工作的指示，不再尝试本轮 Windows 环境光实机测试。

### Android 原生基础 A/B（本地视频，V2）

同一 Android 15 平板上运行独立包 `com.example.video_player_app.power_audit`，沿用 1080p60 H.264 + AAC 本地样本，每个场景稳定 2 秒后采样 8 秒、每版一次。用户手动安装基线，后续修改版安装和运行已完成。原始记录为 `build/power-audit/android-before.json`、`android-after.json`，对照为 `android-comparison.json`，运行日志为 `android-before-run.log`、`android-after-run.log`，修改版源文件记录为 `android-after-v2-source-hashes.json`。

| 场景 | 修改前 Flutter 总帧数 → 修改后 | 修改前 Dart `scheduled` → 修改后 | 修改后控制器位置采样推进 |
| --- | ---: | --- | ---: |
| 可见且有位置订阅 | 488 → 488 | true → true | 7996 ms |
| 离页且无位置订阅 | 484 → 478 | true → false | 8004 ms |
| 背景被路由覆盖 | 484 → 478 | true → false | 8006 ms |
| 暂停并 seek 后稳定 | 0 → 0 | false → false | 0 ms |
| HOME 后恢复后台播放 | 0 → 0 | false → false | 8002 ms |
| 可见 2 倍速 | 488 → 488 | true → true | 16002 ms |

返回前台时，基线的 `androidForegroundRestore.playing=false`，运行日志明确记录 `KNOWN BASELINE FAILURE`，其结果状态为 `known-foreground-pause`；基线经手动恢复后继续完成剩余采样。修改版结果为 `passed`、`knownForegroundPause=false`，返回时保持播放，后续两次控制器位置采样从 33280 ms 推进到 33882 ms。这一修复保持原有 HOME 自动暂停默认值及后台主动恢复路径，没有通过关闭用户设置绕过问题。

Android 的本地 MP4 依照原有 `shouldUsePlatformPlayer` 策略委托 ExoPlayer；修改版诊断为 `playerId=-2`、`managedByMediaKit=false`、1920×1080。离页总帧仍约每秒 60 帧，不能把 484→478 当作有统计意义的整体帧率或耗电下降。应用侧 Ticker 已停止主动排帧，采样前后 Dart `SchedulerBinding.hasScheduledFrame` 均为 false；原生视频纹理仍可触发引擎绘制。这两个计数属于不同层次。

源码解释是：所用 `video_player_android` 2.12.0 的 `VideoPlayerPlugin` 创建 `SurfaceProducer`，`TextureVideoPlayer` 将 ExoPlayer 输出连接到其 Surface；Flutter SDK 的 `FlutterRenderer.ImageReaderSurfaceProducer.onImage` 会调用 `scheduleEngineFrame()`，最终进入 `flutterJNI.scheduleFrame()`，见所用 Flutter 版本的[官方源码](https://github.com/flutter/flutter/blob/c9a6c484230f8b5e408ec57be1ef71dee1e77020/engine/src/flutter/shell/platform/android/io/flutter/embedding/engine/renderer/FlutterRenderer.java#L633)。移除 Dart 视频 widget 或停止 Dart Ticker 并不自动释放仍在播放的原生输出。本轮保持这套资源和播放兼容策略，不声称消除了后台视频解码或 Android 原生纹理的全部工作。

本地委托播放器不支持现有 libmpv 抓帧接口，氛围背景层也会跳过负 player ID，因此该组各场景的抓帧请求本来就是 0→0；它不能证明 Android 氛围背景抓帧优化的前后收益。无扩展名纯音频中继在两版均初始化成功、位置推进且没有视频输出；基线已含纯音频分类修复，这仍只是运行验证，不计为 A/B 收益。

### Android MediaKit 氛围截图诊断（V4/V5）

显式切换到 localhost 网络视频后，探针确认 `managedByMediaKit=true`，可检查真实的 libmpv 截图路径。V4 的 `geometryEligible=true`、返回图片为 96×54，证明 raw 数据转小缩略图的路径实际生效。此前 V3 中记录的第一张 1920 px 图片不能代表整段抓帧始终回退：探针图片尺寸元数据只记录每个 player 的第一张图片，不能据此否定后续缩略图路径。

小图路径生效仍不等于原生截图成本已降低。`android-v4-ambient-quick.json` 中约 4 秒墙钟时间内，控制器缓存位置仅推进 950 ms；`android-v4-raw-timing.json` 中一次 raw 诊断 HTTP 请求耗时 1447 ms。后者是完整请求耗时，不是只计原生截图调用。两项结果表明需要进一步分解截图等待与位置更新延迟，不能仅根据输出尺寸宣布优化成功。

V5 在同一设备上比较默认截图与临时开启 `screenshot-sw=yes` 的 raw 截图调用，得到以下诊断样本：

| 样本 | 默认截图调用 | 软件截图调用 | 验证 |
| --- | ---: | ---: | --- |
| 初次诊断 | 346 ms | 47 ms | raw 数据均为 8,294,400 字节；几何条件满足；前后快照稳定 |
| 重复 1 | 683 ms | 78 ms | 选项恢复为 `no`，raw 大小相同，快照稳定 |
| 重复 2 | 755 ms | 73 ms | 选项恢复为 `no`，raw 大小相同，快照稳定 |
| 重复 3 | 633 ms | 39 ms | 选项恢复为 `no`，raw 大小相同，快照稳定 |

初次诊断也记录了选项从 `no` 临时改为 `yes`、最终恢复 `no`。原始证据为 `build/power-audit/android-v4-ambient-diagnostics.json`、`android-v4-ambient-quick.json`、`android-v4-raw-timing.json`、`android-v5-software-diagnostics.json` 和 `android-v5-software-repeated.json`。这些是截图路径诊断，不是最终第八项修复的完整 A/B，也不能外推听感、唇音同步或实际耗电收益。

mpv 官方说明，默认截图经视频输出渲染器处理，可能因渲染器重新初始化而变慢或影响播放；软件截图采用独立线程中的软件转换，但可能缺少 HDR 等渲染能力。因此第八项将软件截图限制在 Android 明确 SDR、几何条件安全的氛围缩略图，并恢复原选项，其他条件继续回退；云端封面保留原有完整分辨率 JPEG 语义。[mpv `screenshot-sw` 选项](https://mpv.io/manual/stable/#options-screenshot-sw)

该修复同时将小缩略图编码移出播放控制锁，避免与位置、seek、暂停等控制串行等待。V6 网络视频可见采样中，约 4 秒内控制器位置采样推进 4050 ms，完成 4 次截图、返回图片合计 9200 字节。尺寸元数据仍记录冷启动回退的首张 1920×1080 图片，因此不能声称 V6 已实机验证整段均为 96 px 缩略图。按用户最新指示，该部分不再继续诊断或调整；V4/V5 的截图调用耗时诊断与 V6 的有限运行采样分别保留，不混作完整前后对比。

### Android 后台补充验证（V6）

`build/power-audit/android-background-v6-extra.json` 的完整结果为 `status=passed`，操作日志为 `android-background-v6-extra.log`。这轮在独立探针中显式选择允许后台继续播放，仅修改探针内存设置，未改变生产默认值。它补充了 V2 保留 `pausePlaybackWhenAppBackgrounded=true` 默认策略的基础测试。

| 场景 | 实际检查及结果 |
| --- | --- |
| 本地视频后台 seek 后播放 | 3 秒采样控制器位置推进 3092 ms；无 Dart 帧、无截图 |
| MediaKit 网络视频后台 seek 后播放 | 3 秒采样推进 3017 ms；无 Dart 帧、无截图 |
| 指定测试媒体会话的暂停和播放 | 确认目标会话唯一后实际执行；暂停位置稳定，恢复播放后 3 秒采样推进 3084 ms，没有跳过媒体控制检查 |
| 实际息屏后台播放 | 电源状态确认为 `Asleep`，60 秒内位置采样推进 60000 ms，Dart 帧和截图均为 0 |
| 唤醒后继续播放 | 电源状态确认为 `Awake`，随后 3 秒采样推进 3016 ms，Dart 帧和截图均为 0 |

该结果覆盖本次测试样本与设备的后台控制和状态推进，不是耗电量、实际音频听感或所有系统的验收。可见、被覆盖和后台负载属于不同采样场景，不能把息屏无截图解释为可见环境光的图片效果已经全面验证。

## 测量方法与解释

隔离探针为 `scripts/playback_power_probe.dart`，仅在独立源码快照和独立 Android applicationId 中构建使用。它使用 mock preferences、独立播放快照目录和 localhost 控制接口，不加载用户的媒体库、账号或播放队列；不能把此探针入口当成正式应用分发。正式入口构建与探针构建应明确区分。

比较修改前后时应使用同一个媒体样本、播放倍率、窗口或屏幕状态、背景设置和采样时长，分别记录无位置订阅、可见播放、后台播放、暂停、氛围背景和纯音频等负载。帧数、抓帧次数、进程 CPU、内存与控制器位置采样是否持续推进可以帮助确认多余工作及状态更新情况；它们不等同于电池消耗百分比，也不能覆盖整个应用的所有功能。探针现有字段 `nativeMs` 读取的是 `VideoPlayerController.value.position` 缓存，没有直接读取 mpv `time-pos`；位置采样延迟不能单独证明音频或实际解码停顿。

上述 Android V2 基础采样保留移动端原有“切后台自动暂停”默认值。采样脚本先确认 HOME 后生命周期已为 hidden/paused、自动暂停生效且位置稳定，再通过既有播放入口恢复后台播放，最后确认返回前台仍持续推进。这组数据验证后台恢复播放能力，不能单独用于证明“关闭自动暂停设置后，HOME 全程无中断”的配置场景。无订阅场景仅移除视频 widget 和订阅，仍保留 playback page owner，不声称由此关闭了视频解码。计数中的抓帧为请求次数；静音条件下控制器位置采样推进也不等同听感或唇音同步验收。

Flutter 官方建议用真机和 Profile 模式诊断性能，并说明 Debug 和模拟器结果不能代表 Release 表现；本轮以此作为界面性能测量的方法参考，原生行为另以 Release 复核：[Flutter performance profiling](https://docs.flutter.dev/perf/ui-performance)。

Android 官方建议减少不必要的后台唤醒，并按任务性质设置约束、合并适合合并的工作；本轮据此审查后台扫描与用户主动任务的区别，没有把正在播放或正在下载的工作改成仅充电时执行：[Optimize battery use for task scheduling APIs](https://developer.android.com/develop/background-work/background-tasks/optimize-battery)。该页面是后台任务方法参考，不能据此推断项目播放器后端或实机验证结论。
