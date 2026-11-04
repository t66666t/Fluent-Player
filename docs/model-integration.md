# 本地模型接入

云端文件转录的五家适配、模型发现及验证入口见[云端转录说明](cloud-transcription.md)。它们沿用本文的转录、翻译、字幕与任务兼容边界，不替换本地权重、运行库或兼容性基线。

目标：以后用户指定一个新模型，维护者或 GPT 能找到固定的接入位置，复用现有的转录、转录并翻译及 OCR 流程，并用同一套检查验证兼容性。本文对应当前实现，不代表任意 ONNX/GGUF 都能直接运行。

## 最小接入步骤

1. 阅读目标模型的官方模型卡、推理示例、许可证和导出说明，核对语言、输入输出、时间戳、词表、运行库要求及实际内存需求。区分权重更新、模型卡修改和新架构发布。字幕任务必须有可靠时间轴；仅返回整段文字的模型需要另行适配时间对齐。
2. 检查是否满足下表已有适配器的完整约定。相同后缀或相同架构名称不能代替这一步。新架构先实现加载和结果转换，再登记清单。
3. 在 `assets/models/catalog.json` 添加独立 ID，固定完整 revision、文件名、大小、SHA-256、下载源、语言、许可及内存建议。新版本也使用新 ID；保留现有条目的 ID、revision 和权重。这样继续使用现有下载和版本目录即可并存，无须迁移用户大文件。
4. 复用现有选择、下载、导入、增强、资源调度、分句、字幕输出和翻译入口。确认是否需要增强/加速依赖，避免把主模型的语言支持误当成对齐器或标点模型的支持。
5. 运行下面的检查入口，再用新模型在目标平台执行真实短样本及任务取消/恢复。记录质量、时间轴、耗时、内存和已验证平台；有改善证据后再讨论推荐或默认值。

维护接入口时，不应顺带替换已有权重、升级原生依赖或增加用户操作步骤。

## 当前接入口

| 内容 | 文件及职责 |
| --- | --- |
| 主模型、增强、加速包 | `assets/models/catalog.json`；`tool/refresh_model_catalog.py` 及对应增强/加速目录脚本维护固定来源 |
| OCR 组件及组合 | `assets/models/ocr_catalog.json`；`tool/refresh_ocr_catalog.py` |
| OCR 可选 GPU 加载 | `ocr_accelerator_contract.dart` 按组件 ID 登记已适配导出；`ocr_native_accelerator.dart` 和 `native/ocr/` 加载 MNN/QNN，原 ONNX CPU 路径保留 |
| 适配器约定 | `lib/features/model_center/model_adapters.dart`：已实现架构、必需文件、热词、时间戳格式、翻译提示词选择 |
| ASR 加载配置 | `local_asr_model_adapter.dart`：生成 sherpa 配置；`local_asr_worker.dart` 保留原生所有者、流式循环、VAD、增强和取消 |
| 转录流程 | `model_transcription.dart`：音频准备、断点、稳定批次及有界流水线；新模型应输出当前 `SubtitleItem`/词级时间结构 |
| OCR 流式输出与恢复 | `ocr_subtitle_stream.dart` 适配现有 `streaming_subtitle_store.dart`；`subtitle_stream_source.dart` 将 OCR 与转录接入同一播放/字幕列表入口，按区域保存完成段与待确认尾部 |
| 翻译提示词与推理 | `local_translation_batch.dart`、`local_subtitle_translator.dart`、`translation_inference.dart`、`tool/translation_worker.dart` |
| 下载、安装及使用保护 | `model_center_service.dart`：沿用现有队列、来源、导入、收据和租约 |
| 开发期清单校验 | `tool/model_integration_contract.dart`：ID、固定版本、导出文件、加速包及 OCR 组件引用 |

同族新条目复用现有 `engine`；只有经过验证的新加载方式才增加新的引擎注册。适配器文件不是动态插件执行入口。

## 已实现的转录约定

| engine | CPU 导出文件 | 识别方式及特殊约定 |
| --- | --- | --- |
| `sensevoice` | `model.int8.onnx`、`tokens.txt` | OfflineSenseVoice；语言和 ITN 沿用当前配置 |
| `dolphin` | `model.int8.onnx`、`tokens.txt` | OfflineDolphin；当前 Base 不支持英语；新方言/提示词/流式变体需要逐项核对 |
| `parakeet` | `encoder.int8.onnx`、`decoder.int8.onnx`、`joiner.int8.onnx`、`tokens.txt` | 离线 `nemo_transducer`；TDT 时间格式为 `tdt-frame-groups-v2` |
| `zipformer` | 上述三模型及 `tokens.txt`、`bpe.vocab` | 当前 Tiny 导出必须使用流式识别器，即使输入是文件；`cjkchar+bpe`，支持当前热词路径 |
| `whisper` | `turbo-encoder.int8.onnx`、`turbo-decoder.int8.onnx`、`turbo-tokens.txt` | large-v3 Turbo；元数据选择 128-bin 特征；自动语言传空串，始终 `task=transcribe`；翻译沿用文字翻译流程 |
| `firered2` | `model.int8.onnx`、`tokens.txt` | FireRedASR2 encoder + CTC，独立原生 CPU 加载器；校验专用 CMVN、INT64 长度、4 倍下采样和 `ctc-40ms-v1` 时间；不是 AED/LLM 加载器 |
| `parakeet-ja` | `parakeet-tdt-0.6b-ja-q8_0.gguf` | 日本語 Hybrid TDT/CTC，固定日语、CPU CTC 解码及原生 80 ms token 时间；独立 CrispASR helper/移动库，不能交给 sherpa 或文本翻译加载器 |

新增模型、跨平台组件及验证方法见 [高性能转录模型补充](asr-models-2026.md)。

加载配置仍使用当前固定文件名和原生默认值。导出布局不匹配时，应显式转换/适配并验证，不能只改名假定兼容。当前 CPU 输入为 16 kHz、单声道、16-bit PCM。

GPU 包沿用 `<主模型ID>-gpu`，单独固定权重和版本；SenseVoice/Dolphin 使用 `model.onnx`，Parakeet/Zipformer 使用 FP32 encoder/decoder/joiner，Zipformer 另需 BPE。Parakeet 的外部权重文件也必须列入清单。加速器的原生分支在 `native/asr/asr_accelerator.cpp`；增加 CPU 架构不代表 GPU 自动支持，不能复制无效加速包。保持当前 CPU 回退和资源预算。

## 任务和新旧版本

2026-10-29 按产品要求下架 Zipformer Tiny、Whisper large-v3 Turbo、FireRedASR2 CTC 及各自的 GPU 包。清单以 `retired: true` 保留固定文件身份，`loadModelCatalog()` 和模型中心的可选列表不再返回它们；只在 `includeRetired: true` 或服务的旧任务兼容查询中可见。禁止重新选择或发起下载，未完成下载暂停并保留连续断点，iOS 按原 identity/文件键暂停后台任务。已安装模型仍可被冻结的原任务租用，权重、字幕、任务 JSON 和续传指纹不变；缺少权重的旧任务明确提示重新创建。下架模型原为默认时，新任务绑定 SenseVoice，不触发下载、不切换到在线服务。Qwen3-ASR 仍支持上下文热词，热词设置保留。

- 用户通过现有模型选择页选择新条目。默认选择只影响之后捕获的任务；任务保留原模型的 `artifactIdentity`，增强/加速组件也保留各自身份。
- 识别语言的选项和提示能力在 `asr_language_options.dart` 集中解析，本地语种以清单和实际适配器为准。`ModelCenterService.selectAsrLanguage` 按模型保存可选的 `asrLanguagePreferences`，未设置时兼容旧 `language`；不支持的旧值回退自动，单语模型固定语种。页面、增强准备和测速都读取有效语言；`transcriptionConfiguration` 将它冻结为现有 `ModelServiceProfile.language`，不为旧任务重算、不更改任务格式或兼容性基线。新增模型需要核对自动识别、原生语言提示及后处理偏好的差别，而非仅把语言名加入通用列表。
- 支持热词的架构以 `localAsrAdapters[engine].supportsHotwords` 登记。新任务不继承旧全局热词；`TranscriptionManager` 在首次捕获配置时按同一媒体身份读取 `TranscriptionHotwordStore`，将词表写入现有 `ModelJobSpec.asrEnhancements` 快照。继续/重试不重新读取词表，显式重新转录才重新捕获；预设只负责用户主动填入，不是跨视频默认配置。保持既有 JSON/检查点格式，不改写已冻结任务。
- `ModelCenterService.transcriptionConfiguration` 为新 ID 的 Parakeet 冻结 `asrTokenTiming`；原 Parakeet ID 已有相同时间标记，旧任务不新增字段，旧 JSON 和全部续传指纹保持兼容。自行构建新模型的 `ModelJobSpec` 时也要使用 `asrTokenTimingOverride(model.id, model.engine)`；正常生产流程优先使用已有 capture 方法。
- 仅修改线程/翻译设置不应使原始 ASR 断点失效。使用旧任务恢复时不能重新捕获当前默认模型，不能去掉模型身份检查，也不能合并不同模型的结果。
- 已使用模型受租约保护；不要自动删除旧模型或共享组件。旧版下架/停用属于单独变更，需要明确迁移与恢复策略。

## 翻译和 OCR

翻译已注册 `hy-mt`、`qwen3`。当前实现加载文件清单中的第一份 GGUF，清单校验要求唯一 GGUF 且位于首位。单条与批量提示词在统一入口选择，保留现有文字、术语截取、标签/占位符校验和批次编号。

当前翻译上下文为 4096；温度、top-p 等参数与结构化输出行为沿用已有实现。接入新模型要核对模板、思考开关、采样和语法约束是否适用。需要新参数时应按模型显式接入，并同时验证进程内 CPU 与桌面翻译 worker；不要全局替换已有模型参数。GGUF 语音模型不能直接交给文本翻译引擎。

OCR 继续沿用检测/识别组件组合。新版读取 `inference.onnx`、`inference.yml`，识别器要求 CTCLabelDecode，配置控制字典、输入尺寸和预处理。新解码方式需要适配，不能只登记文件。Tiny 识别组合已经迁移到 Small，但 Tiny 检测器仍由英/韩/拉丁语专用组合共用；保留 `migrateRetiredOcrTrack` 和现有旧版兼容预处理。

OCR 的 MNN 3.6.1 和 Android QNN 组件独立于原 ORT。维护者使用 `python tool/build_ocr_acceleration.py --platform <平台>` 显式构建，Android 还需 `--ndk <NDK目录>`；Apple/Linux 需要对应主机。构建固定源码、AAR 及哈希，`verify_ocr_artifact.py` 检查源码与产物匹配。Android 和 Windows 已提供本轮构建的预编译组件，其他平台缺少可选组件时保留原 CPU/CoreML。修改原生适配器后必须重建相应组件，不能手改清单绕过检查。模型/驱动的真实推理与 CPU 对照仍不可省略；详细路线、复测开关与未验证平台见 [OCR 优化记录](ocr-upgrade.md)。

### 转录与翻译的硬件路线（2026-10-27）

加速能力按模型导出、运行库、平台和实际驱动联合判断，不能把 OCR 的 QNN/NPU 支持直接套到 GGUF 翻译或所有 ONNX 语音模型。原模型 ID、权重、CPU 默认参数、任务和断点约定保持不变。

| 模型 | Android | Windows | Linux / macOS / iOS |
| --- | --- | --- | --- |
| SenseVoice Small、Dolphin Base、Zipformer Tiny | 原 NNAPI；新增独立 MNN Vulkan / OpenCL，使用已有 FP32 GPU 包 | 原 DirectML / 可选 CUDA；新增 MNN Vulkan / OpenCL | Linux 可构建 MNN Vulkan / OpenCL；macOS 可构建 MNN Metal，保留原 CoreML；iOS 保留原有静态 ORT / CoreML 路径 |
| Parakeet TDT v3 | 保留原 ORT / NNAPI 兼容性检测及 CPU 回退 | 保留原 DirectML / 可选 CUDA | 保留原 ORT / CoreML 适配；本轮未登记 MNN |
| HY-MT2 1.8B、Qwen3 4B 的现有 Q4_K_M GGUF | 新增 OpenCL，保留 Vulkan | 新增 CUDA，保留 Vulkan；无匹配设备时回退 | Linux CUDA / Vulkan；macOS 新增独立 Metal helper；iOS 沿用运行库的 Metal 及模拟器保护 |

上述路线不代表每台设备都能卸载全部算子。Parakeet 的 TDT 状态、动态形状及大于 2 GB 的外部权重需要另行适配；没有把它交给通用 MNN 转换器。现有 GGUF 也没有变成 NPU 模型：llamadart 的 Android LiteRT-LM NPU 路线需要独立 `.litertlm` 导出与加载器，本轮未替换权重或添加未经验证的导出。

四个增强模型（标点、GTCRN 降噪、英/中文 CTC 对齐）仍走现有 CPU 适配器和线程预算，没有将其固定的量化导出或流状态模型标记为已适配 GPU。它们与主转录模型的执行接口不同，后续加速需要分别验证加载器及时间轴/流状态约定；参见 [sherpa 标点示例](https://k2-fsa.github.io/sherpa/onnx/c-api/html/punctuation.html)、[GTCRN 官方实现](https://github.com/Xiaobin-Rong/gtcrn)及 [Wav2Vec2 模型卡](https://huggingface.co/facebook/wav2vec2-base-960h)。

ASR 的新适配器在 `native/asr_mnn/`，复用固定的 MNN 3.6.1（`d407447ed56c4121a11ccbd266dc184ca1ead0c2`），独立于 OCR 及应用原 ORT。`mnn_session.h` 只替换登记模型的神经网络执行，保留 sherpa 1.12.12 的前端、词表、解码、热词、流状态和时间轴；跨库结果复制进 ASR 自身的 ORT 分配器。GPU 所有者线程固定，转换缓存按权重身份/版本加锁复用，程序缓存另含后端与驱动标识。必须观察实际 GPU 算子，只有 CPU 分区的运行不算硬件加速。

维护者按顺序显式构建，不在应用启动时转换或下载运行库：

```text
python tool/build_asr_mnn.py --platform windows --arch x64
python tool/build_asr_accelerator.py --platform windows --arch x64
python tool/build_asr_mnn.py --platform android --ndk <NDK目录>
python tool/build_asr_accelerator.py --platform android --ndk <NDK目录>
python tool/verify_asr_artifact.py native/asr/prebuilt/windows-x64 --platform windows --arch x64
python tool/verify_asr_artifact.py native/asr/prebuilt/android/arm64-v8a --platform android --arch arm64
```

缺少匹配的源码收据、ABI 或依赖时保持 CPU。Android 预编译为 arm64-v8a，两个新增原生库检查 16 KB 页面对齐；Windows 当前提供 x64。Linux/macOS 需在对应主机构建；macOS 构建阶段会打包并签署匹配架构的 ASR 与翻译 helper，缺少组件/架构时不运行错误的可执行文件。iOS 没有新增可动态加载的 MNN 组件。

翻译运行库仍为 llamadart 0.15.1 / llamadart-native `v0.7.0-1`。`pubspec.yaml` 仅补齐同一固定包的 CUDA/OpenCL 模块。Android GPU 推理通过不导出的 `:translation_gpu` 服务，桌面通过独立 helper；Windows/Linux 的 GPU 模块及 CUDA 依赖只放在 helper 目录。Android APK 不携带替代厂商驱动的 `libOpenCL.so`。两端都验证实际后端及 GPU 层数，一个驱动失败后以新进程尝试下一条兼容路线，再回退 CPU；超时、取消和进程退出释放资源租约，暂时内存压力不永久标记 GPU 故障。iOS 仍使用原来的进程内 Metal，无法从 Windows 验证其运行稳定性。

GPU 路线位于模型中心原有翻译高级设置中，沿用自动 / CPU / GPU；新路线默认自动，旧任务 JSON 不增加默认字段。用户可按系统选 CUDA、Vulkan、OpenCL 或 Metal；换路线后的性能记录独立，避免套用其他后端的结果。不会增加启动测速。Android 的 `microBatchSize=0` 保留上游对 Mali subgroup 与长提示词/语法约束的防护，不强制覆盖其策略。

官方依据：

- [llamadart 平台矩阵](https://llamadart.leehack.com/docs/platforms/support-matrix)、[后端选择](https://llamadart.leehack.com/docs/guides/backend-selection)、[固定原生运行库](https://github.com/leehack/llamadart-native)。
- [llama.cpp OpenCL 文档](https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/OPENCL.md)明确列出 Snapdragon 8 Elite / Adreno 830 和 Q4_K 支持；实际手机的系统驱动仍须验证，不能保证全部安卓设备支持 OpenCL。
- [HY-MT2](https://github.com/Tencent-Hunyuan/Hy-MT2)、[Qwen3 llama.cpp 部署](https://github.com/QwenLM/Qwen3/blob/main/docs/source/run_locally/llama.cpp.md)、[SenseVoice](https://github.com/QwenAudio/SenseVoice)、[Dolphin](https://github.com/DataoceanAI/Dolphin)、[sherpa-onnx](https://k2-fsa.github.io/sherpa/onnx/)、[Parakeet TDT v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)。
- [MNN 3.6.1](https://github.com/alibaba/MNN/releases/tag/3.6.1)、[ORT QNN 限制](https://onnxruntime.ai/docs/execution-providers/QNN-ExecutionProvider.html)。模型官方示例与后端功能说明不能代替当前导出的真实推理检查。

本轮验证收据在 `.artifacts/am26/`：Windows 上三种 ASR 各自的 Vulkan/OpenCL 共六种组合通过重复推理、CPU/FP32 文本对照、热词/时间信息和适用的退出恢复/取消检查。实际 GPU 算子计数分别为 SenseVoice 3037、Dolphin 529、Zipformer Vulkan 1317 / OpenCL 1325。两个 GGUF 均通过发布版 Vulkan helper 的双向翻译、标签/占位符保留、术语、取消；另验证 helper 被终止后可重新加载和取消生成。本机无可供验证的 NVIDIA 设备，因此 CUDA 仅验证模块打包与不可用时继续 Vulkan，未宣称 CUDA 推理通过。Android 原生编译不等于真机推理；目前没有安卓、Apple 或 Linux 实机验证。

Windows x64 与 Android arm64 Release 均构建通过，发布包检查包含 CUDA/Vulkan 私有依赖闭包、ASR 制品匹配、Android 16 KB 对齐、四个私有服务及两个 Dart 后台入口，并确认原 CPU ORT 未替换。Android 测试包仅在隔离目录使用开发签名，项目发布签名配置未改。Parakeet DirectML 连续测试中观察到偶发 80 ms 的词边界变化，单独运行也有完全一致的结果；当前 FP32 encoder 元数据为 `subsampling_factor=8`、特征帧移 10 ms。原生回归对这一条路线显式检查词边界偏差不超过一帧，文字、句子边界及其余元数据仍要求完全相同，并记录实测最大偏差。应用没有取整、重写或掩盖这些时间戳；其他模型和 CPU 路线仍检查重复结果完全一致。

最终 `verify_model_integration.py --native --output .artifacts/am26/model-integration-final` 通过静态分析（无问题）、614 项回归与两项真实 Windows 原生集成检查。原有四个 ASR 模型的 DirectML 完整流程复测通过，记录在 `asr-original-native-bounded.log`；Parakeet 本次最大词边界偏差为 80000 µs。原模型清单、依赖锁文件及 `test/fixtures/local_model_compatibility.json` 保持不变。

## 验证入口

### 社区版共享 VAD 与按需准备

`assets/models/asr_dependencies.json` 单独登记 `silero-vad-16k`，由 `loadModelCatalog()` 合并到同一模型清单。其文件大小、SHA-256 与原内置 Silero VAD 完全相同；不把权重提交到源码仓库，也不再从不存在的 `assets/models/asr/silero_vad.onnx` 读取。主模型中心下载组合包含该依赖，即使关闭可选增强也需要语音检测。已安装组合可以离线转录，也可通过原离线导入入口准备依赖。

`captureTranscription()` 只冻结已登记且未下架的模型及设置，不再要求提前安装。执行时 `prepareAsrModels()` 通过原下载队列准备冻结的主模型、增强组件和 VAD，再进入推理资源调度；本地翻译使用相同的 `prepareModel()`。进度显示模型名称、下载状态、百分比和字节数。暂停/失败结束当前等待，重试沿用原模型身份和下载断点。取消转录立即停止等待，应用级共享下载继续保留，仍可在模型中心暂停；不会取消其他任务正在使用的下载。

旧社区版已经释放到自己数据目录的 VAD 在首次使用时按固定大小和哈希检查并导入，保留原文件，不读取完整版目录。下载后的 VAD 与主模型一样受使用租约保护。任务 JSON、已有模型清单和兼容性基线不变。

回归入口包括 `test/local_asr_preparation_test.dart`。可复现的真实 CPU 推理检查：

```text
python tool/download_model_smoke_assets.py --output .artifacts/local-asr-repair --ids sensevoice-small-int8 dolphin-base-int8
flutter test --no-pub --dart-define=LOCAL_ASR_MODEL_ROOT=.artifacts/local-asr-repair test/local_asr_native_smoke_test.dart
```

该 Windows 检查会把已准备的文件流送入生产下载队列，再执行真实 VAD/ASR、重复识别、取消与进程内服务重建后的检查点恢复。Android 真机入口是 `integration_test/local_asr_transcription_test.dart`，使用 `LOCAL_ASR_FIXTURE_BASE` 指定维护者提供的同版本权重服务器；用独立 profile 包执行，测试目录与用户数据分离。它不证明所有模型、GPU 后端或其他系统的推理均已通过。

### 模型下载策略

模型中心最多同时下载 3 个模型，每个大文件最多 8 路 HTTP Range 请求。分段上限为 2 MiB，小文件按剩余大小缩小分段；请求完成即补位，不必等待前面的慢分段写入，最多同时保留 16 段（32 MiB，与原 4 × 8 MiB 相同的内容预算）。磁盘仍只保存连续 `.part` 前缀，沿用原来的 URL / ETag 续传信息；没有 Range 或强 ETag 的来源回退单流。暂停单个模型不影响其他模型，退出时等待全部传输关闭并保存原队列状态。

2026-11-04：每个分段独立按 5 秒窗口监测速度；连续两个窗口低于已观测分段速度的 20%（阈值最低 16 KiB/s、最高 1 MiB/s）时，保留该段已收到的内容，用原来源、原网络策略的新连接续传剩余范围，继续核对强 ETag、Content-Range 和长度。其余健康连接保持运行。每段最多重连 2 次；若稳定慢速仍有数据，最后一次允许继续，避免无限重连。无数据超时、临时连接错误或正文截断也在预算内续传；文件身份不一致立即拒绝。断点格式、模型 ID、权重及任务快照不变。

自动选源在用户开始下载时采样，最大 4 MiB / 8 秒；足够大的样本按正文持续吞吐排序，避免将低连接延迟误判为大文件速度。低速必须连续两个 20 秒窗口才触发切源，相对低速阈值封顶 256 KiB/s，避免多模型共享带宽后误切源；无数据超时仍及时处理。切源使用已经测得的备用顺序，不再每次中断下载重测全部来源。手动选源、手动测速和网络变化后的缓存隔离保留。

下载与测速均使用网络中心的 `modelDownloads` 策略。直连使用原生连接，系统 / 自定义代理沿用网络中心并按目标地址复用隧道；统一网络设置仍生效，不因代理较慢擅自绕开用户指定路线。iOS 非自定义代理继续使用原后台下载实现，Dart 分段改进适用于其他路径；iOS 真机后台行为需单独验证。

实现参考 [Ollama 的并发分段下载](https://github.com/ollama/ollama/blob/main/server/download.go) 与 [Hugging Face 的并发模型文件下载](https://huggingface.co/docs/huggingface_hub/en/guides/download)。本项目保留现有多源、文件身份及断点格式，没有引入额外下载器或模型运行库。

```text
python tool/verify_model_integration.py
```

默认执行相关静态分析及模型、下载、任务、转录/翻译、OCR 回归，不访问下载源、不安装权重、不改变应用设置。开发环境需要已有 Flutter 依赖，脚本使用 `--no-pub`。日志保存在 `.artifacts/model-integration/`；目录可用 `--output` 指定。

Windows 已准备好权重时执行：

```text
python tool/verify_model_integration.py --native --model-root .artifacts/model-center/native
```

权重目录按 `<model-root>/<模型ID>/<文件名>` 组织。脚本先检查清单中所有转录/翻译主模型的文件和大小，缺失时失败并给出路径，不自动下载。原生库默认使用 `build/native_assets/windows`，可用 `--native-lib-dir` 指定已准备的同版本库；仅给本次检查的子进程设置 `LLAMADART_NATIVE_LIB_DIR`，沿用项目既有 Flutter 测试方法，避免 JIT 缓存和 Flutter 原生目录不一致，不修改应用目录或全局环境。

随后执行真实 ASR、重复识别，以及生产转录 runner → 两个现有 GGUF 翻译 → 断点恢复；报告在 `native-results.json`。这只验证当前 Windows 运行库，不能替代 Android/iOS/macOS/Linux 的实机检查。其他语言或不同架构也需要对应的代表性样本。

如果改动涉及 OCR、GPU、降噪、时间精校或平台原生库，还需运行对应现有原生测试，如 `ocr_native_models_test.dart`、`asr_workflow_native_test.dart`、`asr_acceleration_native_test.dart`，按文件内的开关和样本目录执行。不要用跳过的测试充当已验证。

`test/fixtures/local_model_compatibility.json` 在本次生产代码调整前采集，固定已有模型文件身份、OCR 组合和旧任务的序列化/指纹哈希。添加条目允许通过；直接改写现有权重或任务身份会失败。不要重新生成快照来掩盖回归。

## 兼容边界

保持现有下载完成即可使用、完整哈希由用户手动触发的规则；检查工具不能引入启动时的模型扫描。真实检查只在明确调用时执行。保持现有入口、设置、后台下载、分句、标点、词级时间、成对字幕保存和播放期间的资源策略。

原生版本仍由 `pubspec.yaml` 和各平台构建固定：当前 sherpa 为 1.12.12、llamadart 为 0.15.1。新模型需要新版运行库时，应将升级及相关平台回归作为明确工作项，不能把库更新夹带在清单修改中。

Qwen3 FP16 和日韩共享增强的固定版本、接入、许可与验证状态见 [Qwen 接入记录](qwen-asr-integration.md)。

Qwen 的 CPU 流水线与英文字幕后续优化见 [CPU 与英文时间精校](qwen-asr-cpu-optimization.md)。新任务统一通过 `currentAsrTextProcessingVersion` 冻结处理版本及依赖；v2 英文优先使用已准备的原英文 CTC，对齐失败仍保留原始时间。模型选择页、增强准备和任务快照须使用同一版本；旧任务按冻结版本解析。
