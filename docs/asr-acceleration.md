# 本地转录硬件加速

四个现有主识别模型共用 `AsrAcceleratedDecoder`：SenseVoice、Dolphin、Parakeet、Zipformer Tiny。默认按模型保存“自动测速选择”，也可选择 CPU 或 GPU／硬件加速。降噪、VAD、CTC 时间精校、标点、静音修整及字幕分句继续使用原有 CPU 流水线。

模型中心 → 本地转录设置 → 性能，提供本机测速、重新测速、清除记录和可选 GPU 权重下载。下载入口先显示体积；开始转录和测速不会自动下载额外权重，也不新增全模型哈希扫描。已有“本机推理检查”和手动校验文件入口保留。

## 选择与回退

- 手动 CPU 不启动加速工作进程，不探测 GPU。旧任务未保存加速偏好时继续使用 CPU。
- 没有有效记录且短于 60 秒的任务先用 CPU。长任务等待至少 3 秒的语音段，使用同段最多 12 秒音频、同语言与解码配置、相同线程预算，分别预热一次、测量三次并取中位数。显式本机测速使用内置真实中／英文样本。
- 测速包含 PCM 文件传输、推理及结果解析；另存启动开销，包括加载、编译和执行后端验证。根据实际 VAD 语音占比、片段次数、任务长度和模型重复加载次数估算耗时，预计优势超过 10% 才自动选 GPU。GPU 每段都有传输／派发成本，不能把长 tensor 的吞吐直接套到大量短句上。成功记录允许约 20% 的片段长度差（至少半秒、至多两秒）；差异较大时保守用 CPU，不因换了一段音频重复测速。测速中的有效 CPU 结果可以复用。
- 验证 ORT profiling 中目标 execution provider 确实执行了计算；全 CPU 的静默回退不能成为 GPU 成功记录。检查文字、语言、token、时间戳和 duration 的结构；自动测速还拒绝与 CPU 原文差异过大的结果。文字比较用于拒绝异常，不能作为准确率评测。
- 记录包含模型／权重版本、原生组件与 ORT、系统、架构、设备／驱动、语言、线程、热词和流水线配置，14 天失效，每个模型最多保存 16 组。重测绕过旧记录，不修改手动偏好。
- 加速进程启动、能力检查、加载和运行失败，以及所有候选均不支持时，另存可在启动 GPU 之前匹配的失败记录。后续任务直接沿用 CPU，不再反复等待初始化并显示“GPU 不可用”。记录随应用重启保留，14 天后失效；更新系统、应用／组件或已安装权重会使记录失效，“重新测速”绕过它且验证成功后移除，“清除测速记录”也会清除它。Android 只读取安装包／组件元信息，iOS 只读取包版本／可执行文件元信息；不启动原生加速服务、不扫描模型文件。桌面使用组件大小／修改时间，单独更新驱动后可主动重新测速。
- 当前内存预算不足／未知时直接用 CPU，不记为硬件故障，下个任务只重新检查内存预算。取消不会写入失败记录，也不会触发 CPU 重跑。
- 手动 GPU 跳过速度比较，仍做能力、内存、实际执行后端和结果检查。初次初始化可以从不兼容的 INT8 尝试已安装的浮点包；实际识别成功后若再出错，当次任务直接停用 GPU。
- 初始化、显存、推理、无效结果、超时和子进程退出都会先释放加速器，再由 CPU 重做尚未提交的语音段。已完成字幕及原始／派生检查点保留。取消只结束任务，不触发 CPU 重跑。

`ModelJobSpec` 冻结偏好和允许使用的额外权重身份；旧任务的序列化和识别断点保持兼容。后端偏好变化不会废弃已提交原文，每个新提交的字幕保留 `SubtitleAsrInfo.backend` 和 `weights`，可从识别信息查看。任务进度显示实际后端及回退原因。

## 原生隔离与系统范围

| 系统 | 后端与隔离 | 不满足条件时 |
| --- | --- | --- |
| Windows | 独立 `resources/asr/asr_worker.exe`，私有 ORT DirectML 1.21.0 与 DirectML 1.15.4；检查 DX12 硬件适配器与实际图执行 | 主进程原有 CPU 路径 |
| Linux | 独立 `resources/asr/asr_worker`，匹配架构的 CUDA ORT 与 NVIDIA 驱动；其他 GPU 不假冒 CUDA | CPU |
| macOS | 签名的 `Contents/Helpers/asr/asr_worker`，CoreML；安装时检查组件版本和架构 | CPU |
| Android | API 29+、实际 GPU／加速器驱动、NNAPI；私有 `:asr_accel` 绑定服务，通过只读文件描述符传 PCM，避免 Binder 大音频传输 | 保持 API 24 最低版本及原 CPU 支持 |
| iOS | 使用与 OCR 共用的 ORT 1.23.0；统一静态 sherpa 组件替换原插件，而不额外嵌入 ORT；组合必须写入安装包签名覆盖的真机验证列表 | CPU |

NNAPI 使用 `NNAPI_FLAG_CPU_DISABLED`，设备类型只接受官方 `DEVICE_GPU`／`DEVICE_ACCELERATOR`。NNAPI 已弃用，存在 Android 10+ 并不代表该设备有可用加速器。CoreML／NNAPI 显示“GPU/NPU · 后端名称”，不宣称整个流水线都在 GPU 上。

桌面加速进程退出不影响播放器中的 CPU 库。Android 不在播放器进程加载加速 JNI；服务退出、连接失效和超时都会让 Dart 层回到 CPU。iOS 无法隔离 GPU 致命崩溃，进入已验证原生组合前先保存运行标记；下次启动发现未清除标记，会停用该组合并用 CPU 恢复。

iOS 的 `FluentValidatedAsrGpuCombinations` 默认空。每项需要精确的 `modelIdentity`、`weightsIdentity`、`hardware`、`osMajor` 和原生 `runtime`；未经真机验证不得添加。现有最低 iOS 16.4／macOS 14 不变。缺少组件的安装包正常保留 CPU。

## 可选权重

完整清单、文件大小和 SHA-256 固定在 `assets/models/catalog.json`，由 `tool/refresh_asr_gpu_catalog.py` 从固定官方导出修订生成。浮点包有自己的词表、BPE 和外置权重文件，不借用其他版本的模型附件。

| 主模型 | 可选完整包字节数 | 浮点导出修订 |
| --- | ---: | --- |
| SenseVoice Small | 937,933,072 | `2365baeacb507f821a0c8120fcee3d484dba7a07` |
| Dolphin Base | 317,252,150 | `819b6e48f032e58d7800dd1e0550411352f22d1a` |
| Parakeet v3 | 2,549,800,429 | `1a468a35cbba69418f126de829e75261dea4a4e4` |
| Zipformer zh/en Tiny | 115,256,102 | `e2382758de9a0219b4efe682b95af30b399db3b8` |

Parakeet 包包含约 2.44 GB 的 `encoder.weights`；ORT 加载内存中的 encoder 图时也设置外置权重目录。Zipformer 继续使用在线识别器、独立 stream、原缓存状态、尾音刷新和原始热词短语，不能当作普通离线 encoder 加载。

额外包沿用模型中心下载、暂停／恢复、校验、离线导入、存储迁移、租约和移除机制。任务只租用已安装且与冻结版本相符的包；没有包时仍可检查原 INT8，失败后使用 CPU。

## 构建

固定 `sherpa_onnx` 及五个平台 companion 为 1.12.12。构建脚本只修改校验下载后的生成副本，禁止修改 Pub cache 或全局升级 OCR 的 ORT。组件 manifest 绑定源码和每个原生文件的 SHA-256；构建与打包时检查，转录时不重复扫描权重。

```text
python tool/build_asr_accelerator.py --platform windows --arch x64
python tool/build_asr_accelerator.py --platform android --arch arm64 --ndk <NDK-28.2>
python tool/build_asr_accelerator.py --platform linux --arch x64 --ort-root <matching-cuda-ort>
python tool/build_asr_accelerator.py --platform macos --arch universal2 --ort-root <matching-coreml-ort>
```

非 Windows 运行库根目录提供对应架构的 `include/` 与 `lib/`；Linux CUDA 运行组件单独留在 helper 目录，不能替换播放器中的 CPU 运行库。Android 使用 OCR 已有的 1.23.2 AAR，原生库以 API 24 构建、运行到 API 29 才加载，链接段使用 16 KiB 对齐。

iOS 在 Apple 主机分别生成 device 和 simulator 静态归档，合并时排除 ORT，并检查归档没有定义 `OrtGetApiBase`：

```text
python tool/build_asr_accelerator.py --platform ios --arch arm64 --ort-root <existing-ort-1.23.0>
python tool/build_asr_accelerator.py --platform ios --ios-simulator --arch universal2 --ort-root <existing-ort-1.23.0>
python tool/assemble_ios_asr.py
cd ios && pod install
```

Pod 安装只把生成的 sherpa 插件符号链接指向校验过的统一归档，不修改缓存中的插件。静态归档与 OCR 的 `onnxruntime-objc/c 1.23.0` 一起链接，随主程序签名；缺少／陈旧归档保留原 CPU 插件和空验证列表。macOS helper 与其 dylib 在应用构建中签名。

## 验证与性能证据

本机 Windows x64 的真实模型、进程故障与取消测试见 `test/asr_acceleration_native_test.dart`；完整识别／增强流水线见 `test/asr_pipeline_native_test.dart`。这些测试必须显式启用 Dart define，普通测试不会自动下载数 GB 权重或启动 GPU。开发下载与独立 native smoke 工具分别为 `download_asr_gpu_smoke_assets.py`、`asr_accelerator_smoke.py`。

逐模型的冷启动、稳定分段识别、同段三次中位数和结果原文记录在 `.artifacts/asr-gpu/native-runtime/verification.json`。完整流水线另记 `.artifacts/model-center/asr-throughput-pipeline-gpu.json`，避免把主模型 kernel 的提速当作整条流水线提速。

2026-10-20 Windows x64／DirectML 1.15.4 实测如下。冷启动指新建识别器／加速进程，未清空系统文件缓存；含首次执行验证，GPU 也包含不兼容 INT8 尝试的成本。稳定识别复用同一会话，含 VAD、传输和字幕结果组装，未启用额外增强。

| 模型／样本 | CPU 冷启动 | GPU 冷启动 | CPU 稳定识别 | GPU 稳定识别 |
| --- | ---: | ---: | ---: | ---: |
| SenseVoice／11 秒英文 | 2.67 秒 | 16.42 秒 | 0.28 秒 | 0.94 秒 |
| Dolphin／6.72 秒中文 | 0.89 秒 | 4.77 秒 | 0.16 秒 | 0.19 秒 |
| Parakeet／11 秒英文 | 4.82 秒 | 11.59 秒 | 0.49 秒 | 1.41 秒 |
| Zipformer／6.72 秒中文 | 1.59 秒 | 7.46 秒 | 0.19 秒 | 0.69 秒 |

默认增强的 Parakeet 双阶段流水线连续处理四段 11 秒样本：CPU **9.47 秒**、GPU **19.30 秒**。GPU 的若干长 tensor kernel 虽然更快，模型加载和短句派发仍可能使完整流水线变慢；修正后的实际 VAD 测速在该场景选择 CPU。单段三次中位数及当次选择另记 `.artifacts/asr-gpu/native-runtime/calibration.json`，不与整条流水线耗时混用。

本次最终校验共 142 项通过，另有 5 项原生包完整性／架构拒绝检查通过；四模型 Windows GPU 真实执行、中文模型／缓存目录、Parakeet 外置权重与时间、Zipformer 流式／热词、GPU 工作进程退出后的 CPU 接续、加载中取消、CPU 增强和真实 OCR 已检查。GPU 并行计算的 TDT 词块边界可能有 80 毫秒帧级变化；流水线测试保留文字、字幕范围和时间顺序检查，并将同一词块边界偏差限定在两个帧以内，不要求浮点输出逐位一致。

INT8 与浮点权重的文字允许有量化差异。Zipformer 的样本已单独与同一浮点导出的 CPU 结果比较，核对流式状态和时间轴；自动模式仍保守拒绝与现有 CPU 原文差异过大的组合。

Apple／Linux 的构建、签名和真机 GPU 检查不能由 Windows 结果替代；Android 交叉编译与 APK 打包也不能替代 NNAPI 真机检查。未验证或不可用的组合继续使用 CPU，不宣称五端 GPU 已全部实测。

发布验证：Windows Release 构建通过，主进程 OCR ORT 与原文件完全一致，ASR／翻译工作进程均保留在各自私有目录；构建前登记的 10,391 个数据文件构建后未变化。Android arm64 Release 构建通过，APK 中 44 个原生库的 ELF 加载段和未压缩 ZIP 入口均为 16 KiB 对齐，只含一份 ORT，并保留独立服务及 JNI 方法名。`adb devices` 当前没有连接设备，因此本次不宣称 NNAPI 已通过真机验证。iOS、macOS、Linux 未在对应主机执行构建与签名验证。

可运行产物：`.artifacts/asr-gpu/windows-production/video_player_app.exe`（整个目录一起保留）与 `.artifacts/asr-gpu/app-release.apk`。最终日志为 `final-verification.log`、`pipeline-native.log`、`build-windows-app.log`、`build-android-apk.log` 和 `analysis.log`；原生包检查结果为 `windows-package.json`、`android-package.json`。

重复探测修复的增量验证：133 项回归通过（`cache-fix-regression.log`），模型中心及相关测试静态分析通过（`cache-fix-analysis.log`）。新增用例覆盖进程启动／能力检查／无硬件／加载／识别失败后跨任务直接使用 CPU、失败持久化到重启、记录到期／安装更新／权重变化／主动重测／清除后的恢复，以及临时内存不足和取消不写入故障记录。大幅不同长度的 VAD 片段使用 CPU，不再反复重新测速。

修复版 Android Release 构建、APK 签名及 16 KiB ZIP 对齐检查通过；产物为 `.artifacts/asr-gpu/cache-fix/app-release.apk`，SHA-256 为 `2e2bb1518b7d63ab53ebd23f992b34a39c35ea34d22025ea7dca221a4e635249`。构建日志为 `cache-fix-build-android.log`，签名／对齐日志保存在 `cache-fix/`。本次未连接手机真机；Apple 安装元信息桥接未在 Apple 主机编译验证。

官方依据：[DirectML](https://onnxruntime.ai/docs/execution-providers/DirectML-ExecutionProvider.html)、[CoreML](https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html)、[NNAPI](https://onnxruntime.ai/docs/execution-providers/NNAPI-ExecutionProvider.html)、[CUDA](https://onnxruntime.ai/docs/execution-providers/CUDA-ExecutionProvider.html)、[Android NNAPI 弃用说明](https://developer.android.com/ndk/guides/neuralnetworks)、[固定 sherpa 源码](https://github.com/k2-fsa/sherpa-onnx/tree/v1.12.12)。
