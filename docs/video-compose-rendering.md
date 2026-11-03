# 视频合成：精确烧录、硬件编码与回归验证

本实现保留现有精确/近似烧录、字幕预设、横竖屏样式快照、双语字幕和可切换软字幕工作流。精确模式仍然调用播放页使用的 SubtitleOverlayGroup，字体、换行、描边、阴影和位置不另写一套布局。

## Windows 启动与文件占用

VideoComposeTaskStore 在入队保存时立即冻结任务快照，将所有实例的读写串行化，避免并发操作同一 compose_tasks.json.next / .bak。Windows 共享冲突 32/33 使用有限退避重试，继续保留原有 JSON 格式、路径编码和可读备份恢复策略。文件始终被其他进程独占时仍会记录保存失败，不截断文件强行写入。

Windows/Linux 的探测及桌面编码使用 FFmpegUtils 解析出的打包/系统工具，并直接传递参数启动进程；Windows 合成无需加载 FFprobeKit DLL。macOS 只附带 ffmpeg，探测继续使用 FFprobeKit，避免要求用户额外安装 ffprobe；移动端继续使用 FFmpegKit/FFprobeKit。OCR 已明确选择 Kit 的分支会显式传入该选择，避免共享探测服务随宿主平台改变后端。

每次编码先写入输出目录下独立的 .compose_ 临时目录，并登记为当前任务使用中的资源；成功且文件通过基本有效性检查后才重命名发布。硬件失败、音频回退和旧版参数回退重用临时输出，保留已有成片。发布时也会重试短暂的 Windows 文件占用，不因此重新编码。拒绝输出覆盖源视频。取消会等待本次进程/Kit 会话和清理完成，只取消本任务，避免影响 OCR 等其他会话。

## 精确字幕资源

- 时间线使用字幕起止事件扫描，维护当前活动字幕，避免逐场景扫描整条字幕轨道。保留原输入顺序、重叠字幕以及最近起点的双语配对规则。
- 相同文本场景复用 PNG，缓存键不再受字幕编号影响，并区分不同图像字幕，避免同编号图像被错误复用。缓存命中发生在图像加载之前。
- 一个任务复用同一离屏 Flutter 绘制树；读取 GPU 图像使用异步捕获，并释放中间图像和缩放 Picture。图像字幕无法加载或解码时明确失败，避免把缺失字幕当作成功。
- 保留 DPR 超采样及高质量缩小；在不低于目标分辨率的前提下，额外超采样受约 1600 万像素和单边 8192 的预算限制。大画布还需通过现有资源管理器的内存检查。
- 临时 PNG 写完即关闭，不对每条字幕强制同步磁盘；任务记录和最终字幕清单仍使用持久写入。
- ffconcat 的每一项，包括重复的结束帧，均设置 option framerate 1000，避免 PNG 默认 25 fps 时间基把字幕起止量化到 40 ms。实际字幕切换仍落在源视频帧上；这不把视频编码为 1000 fps。
- 编码采用 VFR 帧同步保留源帧时间；旧版 FFmpeg 不认识 fps_mode 时自动改用 vsync。空白场景、尾部间隔与最后一帧保留在时间线中。

## 各平台的硬件编码

首次真正转码时查询当前执行后端的 -encoders，缓存该后端的结果。只尝试该构建实际包含的平台编码器；被列出仍不代表驱动、权限或分辨率一定可用，执行失败会继续尝试并最终回退 libx264。不在启动时运行编码基准或升级 FFmpeg。

| 平台 | 尝试顺序 |
| --- | --- |
| Windows | NVIDIA NVENC → Intel Quick Sync → AMD AMF → 硬件 Media Foundation → CPU |
| Linux | NVENC → Quick Sync → AMF → 实际存在的 DRM render 节点上的 VAAPI → CPU |
| macOS / iOS | VideoToolbox（禁止隐式软件回退）→ CPU |
| Android | MediaCodec（构建包含时）→ CPU |

编码参数按后端区分：x264 保持 veryfast/CRF 20；NVENC、QSV、AMF、VAAPI 使用各自的质量控制参数；VideoToolbox、MediaCodec、Media Foundation 使用根据输出尺寸和帧率估计的码率。这些后端的质量数值不能横向视作等价，文件大小也可能不同。

字幕布局与 PNG 栅格化在 Flutter 中完成；FFmpeg 的缩放、叠加仍是 CPU 滤镜，硬件编码由显卡/系统媒体编码单元执行。VAAPI 在叠加完成后上传 NV12。没有直接套用 OCR 的 GPU/NPU 推理后端，也没有强开硬件解码而引入滤镜下载、格式不兼容等额外步骤。

线程数来自现有 InferenceResourceSession 的 compilation 许可，结合编码器分配给解码、滤镜和软件编码，并限制字幕 PNG 的解码线程。直接使用执行器且没有资源会话时，默认留出一个逻辑处理器，桌面上限 12、移动端上限 6。仍遵守原有与本地推理排队及资源占用规则。

输出状态显示当前编码器。复制封装继续复制视频与音频；音频不受 MP4 支持时才重试 AAC。显式选择实际视频轨，避免选中附带封面或字幕 PNG；保留用户选择的软字幕及其语言/标题。MP4 使用 faststart 便于播放。

## 验证与复现

普通回归覆盖并发保存、Windows 外部文件占用、备份恢复、跨平台编码器筛选、驱动/权限失败回退、旧版参数、取消隔离、源视频保护和字幕时间线：

    flutter test --no-pub test/video_compose_encoding_test.dart test/video_compose_task_store_test.dart test/video_compose_timeline_test.dart test/video_compose_resource_safety_test.dart test/video_compose_desktop_backend_test.dart

图像回归继续使用 subtitle_preset_precise_export_test、subtitle_playback_export_layout_test、subtitle_font_rendering_test 和 subtitle_multilingual_layout_test，检查播放/导出的像素与多语言换行。

真实桌面 FFmpeg 回归会自行生成素材，执行完整 PNG 烧录和输出解码；逐帧检查 60 fps 视频的字幕起止/间隔，检查 AAC 回退、软字幕、多种特殊字符路径和 VFR 时间戳。独立 CLI 测试环境需要 ffprobe；macOS 正式应用使用 FFprobeKit：

    flutter test --no-pub --dart-define=VIDEO_COMPOSE_NATIVE=true test/video_compose_precise_native_test.dart

可指定随应用打包的 FFmpeg 验证同一组输出参数：

    flutter test --no-pub --dart-define=VIDEO_COMPOSE_NATIVE=true --dart-define=VIDEO_COMPOSE_NATIVE_FFMPEG=D:/path/to/ffmpeg.exe test/video_compose_precise_native_test.dart

Windows 上已实际执行系统 FFmpeg、项目打包的 FFmpeg、libx264 和本机 Intel Arc 的 Quick Sync 编码，验证无 NVIDIA 驱动时继续选择 QSV。Android、iOS、macOS、Linux 的后端选择/回退有自动测试；本轮没有这些系统的实机编码结果。无法把 Windows 上模拟平台策略的测试称作其他系统的原生验证。

时间线测试中 20,000 条字幕生成 39,999 个场景约为数十毫秒，此项不包含字体准备、PNG 生成和视频编码。硬件初始化、视频大小、滤镜负载和驱动都会影响总耗时；短片在本机可能由 CPU 更快，不承诺任意设备或素材固定倍数的加速。

2026-10-27 的命令行对比：Windows、Core Ultra X7 358H / Arc B390、项目打包的 FFmpeg 8.0.1、12 秒 1080p30 动态测试视频、与目标尺寸相同的 RGBA 叠加图片、12 线程预算。每种情况执行两次，以下为中位数，单位为秒：

| 路径 | 输出 1080p | 输出 4K |
| --- | ---: | ---: |
| 修改前 CPU 参数 | 1.449 | 4.612 |
| 当前 CPU 参数 | 1.512 | 4.736 |
| 当前 Quick Sync 参数 | 1.919 | 3.609 |

此处预先指定编码器，时间包含进程初始化、编码、MP4 写入及 faststart，不包含候选编码器筛选或 Flutter 字体/PNG 准备。输出均解码检查为 360 帧、12 秒、H.264 + AAC。CPU 路径保留解码/滤镜各一个线程，将其余预算优先供给 x264；本机没有测出一致的 CPU 编码阶段加速。精确字幕准备的改进来自时间线扫描、场景复用、绘制树复用和减少磁盘同步。原始参数、计时及探测结果保存在 build/compose-validation-20261027/verified-benchmark.json。

本轮定向回归 81 项通过，4 项 Linux 宿主专用检查在 Windows 跳过；静态分析无问题。python tool/verify_model_integration.py 的分析和回归也通过（706 项通过、3 项按条件跳过）；不修改模型目录、模型兼容基线或权重。本轮未执行模型权重的原生推理验证。

Windows Release 构建成功，正式入口为 build/windows/x64/runner/Release/video_player_app.exe。另用 Release/resources/yt_dlp/ffmpeg.exe 执行真实烧录、VFR 及探测/OCR 后端回归，24 项通过。构建与定向回归日志分别保存在 build/compose-validation-20261027/windows-release.log、regression.log、packaged-ffmpeg.log；运行成品需保留整个 Release 目录。

FFmpeg 行为依据：

- [concat 清单、逐文件选项与 image2 帧率](https://github.com/FFmpeg/FFmpeg/blob/n8.0/doc/demuxers.texi)
- [帧同步、流选择和参数作用域](https://github.com/FFmpeg/FFmpeg/blob/n8.0/doc/ffmpeg.texi)
- [MediaCodec 软件帧输入格式](https://github.com/FFmpeg/FFmpeg/blob/n8.0/libavcodec/mediacodecenc.c)
- [VideoToolbox 编码选项](https://github.com/FFmpeg/FFmpeg/blob/n8.0/libavcodec/videotoolboxenc.c)

## 合成队列与成片预览（2026-10-28）

队列支持单项删除、批量勾选/全选删除及清空。共用确认窗口支持主键盘 Enter、小键盘 Enter 与 Esc；是否同时删除成片继续使用原有的记忆设置。输出路径仍可复制，删除失败保留对应记录，Android 外部存储的权限检查继续保留。

管理器在第一次异步等待前移出整批选中的排队任务，并暂停后续任务启动；取消运行任务后，等待素材准备、FFmpeg/渲染器和资源租约退出，再清理输出文件。重叠的删除操作串行执行，批次结束后继续未选中的排队任务。

临时预览在路由完全退出、预览播放器释放后恢复原会话。恢复核对媒体、会话代次、控制器及暂停命令，避免复活已停止/替换的播放，或覆盖预览期间用户明确发出的暂停。原视频仍在初始化时保留原播放意图；连续预览等待前一次释放和恢复，避免丢失意图。加载/报错页也支持返回和 Escape，每个初始化等待后检查退出状态，禁止返回后迟到的自动播放。预览沿用当前横竖屏与系统栏，退出时不会覆盖播放器的全局显示状态。

回归入口：

    flutter test --no-pub test/video_compose_batch_delete_test.dart test/video_compose_queue_dialog_test.dart
    flutter test --no-pub test/playback_page_released_controller_test.dart --plain-name "compose preview"

原生 Windows 验证入口为 scripts/windows_compose_preview_smoke.dart，使用独立临时存储和内存偏好，不打开用户媒体库。通过 SMOKE_MEDIA、SMOKE_REPORT 指定测试视频与报告路径；以 Release 构建该入口后运行，自动覆盖横竖屏、从队列/直接进入、原视频播放/暂停共 8 种组合，检查原控制器仍挂载、预览控制器已释放、进度与意图保留，并保存原生帧及 Flutter 页面截图。此入口不加载正式应用的退出协调器：完成后隐藏窗口，由宿主测试脚本检查报告 PASS/FAIL 并终止自己启动的测试进程，不测试正式应用退出流程。完成验证后必须重新以 lib/main.dart 构建正式 Release。

本轮相关回归 132 项通过，预览专项包含其中 18 项。完整相关套件另发现一项工作区原有的源码文本断言不匹配：media_playback_session_state_test.dart 期待直接调用 player.seek(startPosition)，而现有原生播放器已经改用 _seekNativePlayer 封装；复跑时明确排除此项，未修改该断言或覆盖已有播放器改动。日志保存在 build/compose-queue-regression.log 和 build/compose-queue-verified-regression.log。静态分析日志为 build/compose-queue-analyze.log。Android、iOS、macOS、Linux 本轮没有原生设备验证。

python tool/verify_model_integration.py 通过（706 项通过，3 项按条件跳过），未运行模型权重的原生推理。Windows 原生 8 次预览往返的报告及截图保存在 build/compose-preview-native-report.log、同名 .0.png 至 .7.png；正式构建日志为 build/compose-queue-windows-release.log。
