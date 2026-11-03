# Qwen3-ASR 与日韩共享增强（FP16）

后续的 CPU 调度与 v2 英文时间精校改进见 [CPU 与字幕优化记录](qwen-asr-cpu-optimization.md)；下文 v1 内容为首批接入记录，已有冻结任务继续兼容。

本轮新增独立架构和原生加载器，沿用模型中心的下载、导入、增强组件准备、转录及转录并翻译入口。未改默认模型、原有权重、运行库版本及旧任务身份；未接入 Galgame 微调版。

## 登记模型

| ID | 固定文件体积 | 建议设备内存 |
| --- | ---: | ---: |
| `qwen3-asr-0.6b-f16` | 1,882,037,824 字节 | 16 GB |
| `qwen3-asr-1.7b-f16` | 4,704,800,576 字节 | 24 GB |
| `asr-qwen3-aligner-0.6b-f16` | 1,841,707,200 字节 | 与主模型交替加载；建议 8 GB 以上 |
| `asr-language-id-voxlingua107-f16` | 42,838,944 字节 | CPU 按需使用 |

完整固定 revision、SHA-256 和来源见 `assets/models/catalog.json`、`tool/prepare_qwen_asr_models.py`。ASR 支持 30 种语言，共享对齐支持中英日韩等 11 种语言。CPU / GPU 共用同一个 FP16 文件，没有重复 GPU 权重包。文件体积不能直接当作运行内存。

权重均为 Apache-2.0。运行时固定 CrispASR `34a8e436192de19d3e5a872437edfe3fd26ce8c4`、其 GGML 子模块 `e2ae679a563014f46c546ce6c6448e8601e4dea6`（MIT）；使用其底层 mel、编码、KV 解码和对齐，未调用空的高层 `transcribe`。原有 sherpa、llamadart 保持原版本。

分词为 Lindera 6.2.0（MIT），嵌入固定 IPADIC（NAIST / ICOT）和 ko-dic（Apache-2.0）。构建后校验词典 SHA-256，用户不需要 Python、Rust、WSL 或 CUDA Toolkit。应用及原生发布目录附完整许可和通知：`assets/licenses/Qwen-ASR-ThirdPartyNotices.txt`、组件目录内 `licenses/`。没有打包 soynlp 或移植其实现；开发期官方参考环境与应用发布物分开。新增组件没有引入 LGPL 义务；应用原本的其他组件和整体许可仍按原项目声明处理。

## 接入顺序与兼容

### 下载内容与共享组件

Qwen 主模型只负责识别文字；独立的共享精校模型用于补充字幕时间戳。开启声学时间精校时需要该组件，关闭后沿用语音段时间。自动语言模式还会按任务冻结音频语言识别组件；降噪和标点依赖仍按现有开关计算。

Qwen 的下载入口和选择器在缺少文件时先展示原有模型详情页，页首列出主模型、各共享组件的用途 / 状态 / 大小、完整组合大小及未安装文件总量，点击“下载模型及增强组件”后才一起加入现有队列。详情页可直接关闭可选的声学时间精校，调整只影响新任务及本次组合。两档 Qwen 复用相同组件 ID；已安装或正在下载的共享文件不重复排队，暂停 / 继续覆盖当前组合中未完成的组件。

此处捆绑的是下载计划，文件仍独立保存、单独续传，避免两档各附一份大精校权重。已有任务仍按其冻结依赖准备组件，旧任务、断点及版本身份不变。

### 转录处理

沿用：音频准备 / VAD → ASR → 逐段语言判定 → 分词和必要对齐 → 原字幕整理 → 稳定批次 → 原翻译。

- 手动语言优先；自动模式结合模型语言标签、假名 / 韩文字母及邻近信息。纯汉字、拉丁字母不会直接被猜成中文或英文。信息不足时使用音频语言识别，阈值 0.8；短语音结合邻近片段，仍不确定则保留原有时间和复核信息。旧模型的现代自动语言任务同样冻结 LID 依赖，语言确定后沿用原中英文 CTC 路径；低于阈值不强行分配。
- 日韩分词供所有支持这两种语言的原模型使用。按原文 grapheme 建立 NFC、UTF-8、UTF-16 映射；保留韩语空格、标点和连续外语词，不改写识别原文。分词边界只约束已有可靠的声学切点，不按字数估算词时间。
- 原模型可靠词时间继续使用；需要精校的日韩用共享对齐，原模型中英文继续使用原 CTC 对齐器。Qwen 在其对齐器支持的语言上使用 Qwen 对齐。
- 对齐原始时间倒序、越界或跨长静音时回退；拒绝上游的倒序插值修补。原模型已有时间仍保留；没有可靠词时间的 Qwen 片段保留 VAD 句级时间。
- 原生单段上限 25 秒，VAD 语音段限制 23.5 秒以容纳边界上下文，首批原生 batch 为 1。复用容量 2 的有界队列和资源预算，低内存时交替释放识别、对齐和翻译所有者。调度可在语言未知时预测冻结依赖的最大预算；实际加载前先单独判定语言，再只准入本批选中的对齐器。语言仍未知时保留原时间，不加载无关语言的精校模型；批次内切换 CTC / Qwen 对齐器前释放上一种对齐权重。核显与主内存共用预算。
- 新任务捕获 `asrTextProcessingVersion: 1`，仅改变增强指纹；旧任务缺省保持旧行为。按任务冻结组件身份，保留原始识别断点和已完成译文。
- Windows / Linux 使用独立 helper 和私有依赖目录；移动端使用独立原生所有者及 GGML 符号前缀。Android 运行于私有服务；Apple 队列在原生安全边界完成销毁后才确认释放。
- GPU 要有实际执行算子的证据；失败时重新建立 CPU 所有者。现有“本机测速”入口支持 Qwen 同权重 CPU / GPU 对照及缓存；不会启动下载或自动启动测速。

## 验证数据与限制

官方参考固定为 Qwen3-ASR Python 源码 `7c6daf77a2421100f5fb066495372c00129d39ff`；官方权重 revision：0.6B `5eb144179a02acc5e5ba31e748d22b0cf3e303b0`、1.7B `7278e1e70fe206f11671096ffdd38061171dd6e5`、对齐器 `c7cbfc2048c462b0d63a45797104fc9db3ad62b7`。开发参考使用 CPU FP16、greedy、最多 512 新 token。

固定 FLEURS dev revision `70bb2e84b976b7e960aa89f1c648e09c59f894dd`（CC-BY-4.0）：日语 20 段、韩语 20 段、中英文各 4 段，另有日韩各 1 段确定性 12 dB 合成背景音乐，共 50 段。含数字和人名；不代替大规模或母语人工评测。

| 模型 | 日语 CER（20 段） | 韩语 CER（20 段） | 相对官方参考 |
| --- | ---: | ---: | --- |
| 0.6B FP16 | 8.13% | 8.06% | Windows CPU / Vulkan 均 0 个百分点劣化 |
| 1.7B FP16 | 4.11% | 7.26% | Windows CPU / Vulkan 均 0 个百分点劣化 |

CER 使用 NFKC、小写并去除标点、符号和空白后计算；中文和英文对照也没有劣化。各档各后端均完成 50 段，没有相对官方新增整句漏识别或循环输出。数字书写差异也会计入 CER，不能把该小样本当作通用准确率或模型排行榜。

手动指定日韩语言、热词上下文、日韩与英文拼接的 8 个附加案例均与官方规范化结果一致。这仅证明导出与原生解码的一致性；官方本身可能漏掉拼接音频中的外语，不能承诺混合语言完整识别。两档 ASR 的 mel 形状均为 128 × 200，最大绝对误差 0.0000689，平均 0.000000754。

相同分词单元的 50 段对齐对照：CPU / Vulkan 各有 21 段通过原生时间次序检查，29 段因原始时间次序异常触发保守回退。通过原生检查的结果相对官方最大差异为 CPU 80 ms、Vulkan 0 ms；应用还会进一步检查越界、跨静音和原文映射，因此这 21 段不等于全部已采用词级结果。对齐器两端 mel 特征形状相同，最大绝对误差约 0.000219，平均约 0.00000269。**该固定对齐导出在此样本集的回退率较高，不能承诺所有日韩字幕完成词级精校；识别文本仍保留。**

## 本机实测

Windows，Ultra X7 358H / 约 32 GB / Arc B390，6 个推理线程，11.1 秒日语音频，持续速度取 3 次中位数；GPU 路径已记录实际 Vulkan 算子。

| 模型 / 后端 | 新进程首结果 | 持续转录耗时 | 实时倍速 | 峰值 RSS | 峰值私有提交 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 0.6B / CPU | 4.33 s | 2.86 s | 3.88× | 2.07 GiB | 5.18 GiB |
| 0.6B / Vulkan | 4.22 s | 1.23 s | 9.03× | 3.56 GiB | 5.24 GiB |
| 1.7B / CPU | 8.38 s | 7.23 s | 1.53× | 4.63 GiB | 10.68 GiB |
| 1.7B / Vulkan | 9.78 s | 2.31 s | 4.80× | 8.81 GiB | 10.73 GiB |

首结果包含进程启动、加载和第一次解码，未清空系统文件缓存。内存为原生 ASR helper 的采样峰值，不含播放器、翻译或整个系统；RSS 与私有提交是不同指标，不应相加，也不能视为独显显存要求。核显共享系统内存。速度取决于音频、文本长度、驱动及线程数，不能线性承诺长文件总耗时。

后台同时执行 720p H.264 D3D11VA 30 fps 实时解码时，1.7B CPU / Vulkan 的持续耗时分别为 7.34 / 2.23 秒。该检查无窗口和音频输出，不能代替播放器界面流畅度实测；播放与资源交接的既有回归另行运行。

日韩词典按需初始化；本机冷分词约日语 42 ms、韩语 250 ms，热分词均不足 0.1 ms。两种词典加载后 helper RSS 约 49 MiB，资源预算预留 160 MiB。分词本身不需要 GPU。

真实故障注入验证：让 GPU DLL 在加载时退出进程，CPU ASR 和 CPU LID 仍正常；Dart GPU 解码器检测故障后新建 CPU 所有者并完成识别。中文权重路径、PCM 路径及 helper 安装路径均已检查。

原始质量、对齐、提示词、性能及工作流报告保存在 `.artifacts/qwen-integration/`，其中 `quality/summary.json`、`prompt-parity.json`、`audio-feature-parity.json`、`performance.json`、`performance-contention.json`、`driver-fault.json` 可复核上述数据。构建收据位于 `native/qwen_asr/prebuilt/<平台>-<架构>/manifest.json`。

## 验收记录（2026-10-29）

下载提示追加修复：模型详情先展示下载组合，一键准备共享组件，并允许关闭可选精校；5 项针对性检查及全部 728 项回归通过（3 项既有跳过），63 个静态分析目标无问题。320 像素 / 1.3 倍字体和桌面预览检查通过，组合暂停 / 继续、已安装及在途组件去重、依赖与任务一致性均已覆盖。日志在 `.artifacts/qwen-download-disclosure/`。

运行中的播放器锁住了原 Release 目录的 WebView DLL，故没有关闭播放器或替换其正在使用的文件。修复版使用仅对子进程生效的 Flutter 配置构建到 `.artifacts/qwen-download-release/windows/x64/runner/Release/`（517.5 秒），该目录的原生组件收据、随包模型清单及许可校验通过。退出旧版后从修复版的完整目录运行；原全局 Flutter 配置未修改。

- `python tool/verify_model_integration.py --native --output .artifacts/qwen-integration/verification-delivery`：静态分析通过，723 项回归通过（3 项既有跳过），6 项 Windows 真实推理工作流通过。
- 真实工作流包含原有全部 ASR 家族、新增两档 Qwen、原模型共用日韩增强、取消 / 新所有者恢复、低内存串行、日语转录后接两种现有本地翻译模型，以及恢复时不重复推理。
- 最后补齐手动语言覆盖模型标签的预算规则后，`verification-preflight/` 再次通过 61 个分析目标与全部 723 项回归。旧任务的语言规则未修改。
- 另行执行 GPU helper 加载崩溃的真实 Dart CPU 回退测试，通过；Rust 的 3 项原文 / Unicode / 韩语空格测试通过。
- Windows x64、Android arm64 的来源及文件收据校验通过；Android ELF 16 KB 对齐及导出符号隔离通过，Release Kotlin 编译通过。各目标是否做过实际推理见下表。
- 最终 `flutter build windows --release --no-pub` 通过（105.2 秒）；应用位于 `build/windows/x64/runner/Release/`，保留整个目录运行。发布目录原生组件再次通过收据校验，随包目录清单、许可资产与源文件逐字节一致。
- `test/fixtures/local_model_compatibility.json`、`pubspec.yaml`、`pubspec.lock` 与本轮修改前的副本逐字节一致；未用重新生成基线的方式通过兼容性回归。

## 平台构建

| 目标 | 路线 | 本轮状态 |
| --- | --- | --- |
| Windows x64 | CPU / Vulkan；可构建 CUDA | 本机 CPU / Vulkan 真实识别、LID、对齐和转录并翻译；无 NVIDIA 实机，未验证 CUDA 推理 |
| Windows ARM64 | CPU / Vulkan 源码构建目标 | Rust 静态库构建通过；本机未安装 MSVC ARM64 C++ 工具链，完整构建及推理未验证 |
| Android arm64 | CPU / Vulkan | 原生构建、16 KB ELF 对齐、导出符号隔离及 Release Kotlin 编译通过；没有真机推理验证 |
| macOS | CPU / Metal | 提供独立 helper、私有依赖、打包及签名路径；需对应 Apple 主机构建及推理验证 |
| iOS | CPU / Metal | 提供静态库、XCFramework、Pod 和 Swift 所有者桥接；需 Apple 主机及真机验证 |
| Linux | CPU / Vulkan / CUDA | 提供相同 CMake helper 和私有依赖安装路径；需对应主机构建及推理验证 |

```text
python tool/build_qwen_asr.py --platform windows --backend cpu
python tool/build_qwen_asr.py --platform windows --backend vulkan --cmake-arg=-DCMAKE_PREFIX_PATH=<VulkanSDK>
python tool/build_qwen_asr.py --platform windows --backend cuda --runtime-dir <CUDA可再分发DLL目录>
python tool/build_qwen_asr.py --platform android --arch arm64 --backend cpu --ndk <NDK目录>
python tool/build_qwen_asr.py --platform macos --arch arm64 --backend metal
python tool/build_qwen_asr.py --platform linux --arch x64 --backend vulkan
python tool/build_qwen_asr.py --platform ios --arch arm64 --backend metal
python tool/build_qwen_asr.py --platform ios --arch arm64 --backend metal --ios-simulator
python tool/package_qwen_ios.py
python tool/verify_qwen_ios.py
python tool/verify_qwen_artifact.py native/qwen_asr/prebuilt/windows-x64 --platform windows --arch x64
python tool/verify_model_integration.py --native --output .artifacts/qwen-integration/verification-final
```

维护者需 Rust 1.88+、CMake、对应 C++ 工具链及后端 SDK。Android 跨编译 Vulkan 还需要主机 C++ 编译器 / glslc、SPIRV-Headers 的包路径和 NDK 的 Vulkan 导入库；不要把 Windows 的 Vulkan 导入库交给 Android。Android API 24 通过实例动态解析 Vulkan 1.1 查询，驱动不支持时走 CPU。GPU / Metal 编译通过不等于对应设备已验证。

运行 `prepare_qwen_asr_models.py`、`prepare_qwen_reference.py`、`prepare_qwen_quality_samples.py` 是维护者明确执行的下载步骤；应用不会调用这些工具。质量检查使用 `check_qwen_quality.py`、`check_qwen_alignment.py`、`check_qwen_prompts.py`，本机原生性能使用 `benchmark_qwen_native.py`。所有检查都保留 `test/fixtures/local_model_compatibility.json` 作为原基线。
