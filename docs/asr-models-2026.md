# 高性能本地转录模型补充

2026-10-27：新增两个主模型及其独立 FP32 包，沿用模型中心、下载/导入、资源调度、转录、增强、字幕分句、成对字幕保存和转录并翻译入口。原有四个 ASR、两个 GGUF、默认值、排队任务与兼容性基线不变。没有升级原生运行库，也不在启动时下载、哈希或测速。

## 模型和版本

| 独立 ID | 固定导出 revision | 定位 |
| --- | --- | --- |
| `whisper-large-v3-turbo-int8` | `2ca6ff69fc878651b770880507669577ac41c2ff` | 809M 参数，多语言通用；导出实际包含中英日韩、粤语等 100 个语言标签。Turbo 是 2024 年 large-v3 的解码器裁剪版本，不宣称为 2026 年发布的架构。 |
| `firered-asr2-ctc-int8` | `423be1acfdc5d8aaa5a485fb6263fe4ea8570b06` | 2026-02 的中文、英文和二十多种中文方言/口音导出。专门实现 encoder + CTC 加载器，不是完整 AED/LLM 模型，不引用它们的质量榜单作为本导出的效果。 |

Whisper CPU 文件约 1.04 GB，FireRed2 CPU 约 776 MB。对应 `<ID>-gpu` 包约 3.24 GB / 2.94 GB，包含匹配词表；建议 16 GB 以上内存的高性能设备起测。文件体积不等于运行内存或显存。原自动模式根据任务、资源及既有本机测速记录选择后端，不能保证短音频用 GPU 更快。

Whisper GPU 的 `turbo-encoder.weights` 和 FireRed2 GPU 的 `model.weights` 超过 2 GB，均单独固定大小、SHA-256 和来源。Whisper GPU 使用同一导出 revision，FireRed2 FP32 revision 为 `5816c6e906b01242cb707fd989967a8db8b2a556`。完整 CPU/GPU 文件角色集中在 `model_adapters.dart`；缺少外部权重时清单验证失败，不能只安装小 ONNX 图或随意改名。

## 加载、时间轴和翻译

Whisper 使用 sherpa 1.12.12 已有架构，模型元数据选取 128-bin Whisper 特征。Windows 的公共 CPU 接口不能读取中文模型目录，因此只对这个新模型改用已有私有 worker 的 CPU 加载器，复用其 Unicode 文件校验/读取修复和进程取消；其他平台保留公共 CPU 接口。自动语言传空串，始终 `task=transcribe`；它不使用语音模型内仅向英文翻译的任务。所有目标语言继续交给现有 HY-MT2 / Qwen3 文字翻译、批次标签、术语及断点机制。

Whisper 的字幕边界使用现有 VAD 与分句流程；中英可选已有 CTC 精校器获得词级时间。日/韩等未适配精校器的语言保留语音片段时间，不伪造词级对齐。两种新模型不支持热词加权，沿用现有能力提示，不用术语替换识别原文。

实测发现 Qwen3 4B 会将一个韩语长句原样返回为中文翻译。补充了目标中文时的韩文句子校验，既有重试轮次对 Qwen3 使用明确的中文修复提示词；首次提示词、采样参数、已完成翻译、批次协议和检查点不变。HY-MT2 不使用这条 Qwen 专用修复提示词。真实日/韩样本均通过两种 GGUF，详见 `translation-languages-fixed.json`。

FireRed2 的 `native/asr/firered_ctc.h` 校验 `fire-red-asr-2-ctc` 元数据、80 维 CMVN、词表、FP32 特征、INT64 长度、输出布局和 4 倍下采样。前端复用固定 sherpa 的 16 kHz Kaldi 特征，使用 16-bit 幅度、`high_freq=0`、`snip_edges=true`、无 dither，然后应用导出的 CMVN。CTC 使用 blank=0，时间起点按 10 ms × 4 计算；新任务冻结 `ctc-40ms-v1`。没有将新模型交给旧 AED 或通用后缀加载器。

公共 Dart/C ABI 不变。`native_asr_cpu_decoder.dart` 通过现有私有 worker/服务执行新架构，并复用资源预算和 PCM 协议。CPU/GPU 切换等待前一所有者释放；线程变化、精校、内存回收、取消和退出均释放会话。PCM 与会话临时目录分别拥有，取消时不会因父目录清理覆盖真正的取消结果。新头文件纳入各平台源码收据和构建 ID；Whisper 两个 ORT 会话使用独立 profile 前缀。

## 平台边界

| 平台 | CPU | GPU |
| --- | --- | --- |
| Windows x64 | 两种 INT8 均使用随包附带的私有 worker；验证中文模型目录与进程取消 | 两种 FP32 均已在 Intel Arc B390 上真实验证 DirectML；必须记录实际 GPU 算子，失败回到各自 INT8 |
| Android arm64 | 新私有组件已交叉编译并验证 ABI / 16 KB 对齐 | 沿用 NNAPI 探测、进程隔离及回退；未做安卓真机推理 |
| Linux / macOS | 源码已接入现有 worker 构建，需在对应主机构建匹配组件 | 保留可用运行库中的 CUDA / CoreML；未做实机推理 |
| iOS | 需在 Apple 主机重新构建/组装现有统一静态库；新 CTC CPU 分支不受 CoreML 白名单限制 | 原签名组合验证及故障保护保留，未增加未验证的白名单项 |

这两种新架构没有登记到未经适配的 MNN Vulkan/OpenCL/Metal 转换器。CUDA 也没有在本机推理验证。缺少可用硬件或浮点包时保留 INT8 CPU；FireRed2 的 CPU 本身需要匹配的新原生组件，不能把缺少组件冒充为推理通过。

## 开发验证

先运行 `python tool/verify_model_integration.py`；准备好主模型后运行既有 `--native` 入口。额外检查如下，均不自动下载权重或修改应用设置：

```text
python tool/test_asr_artifact.py
flutter test --no-pub test/new_asr_models_test.dart
flutter test --no-pub --concurrency=1 --dart-define=ASR_ACCEL_NATIVE=true --dart-define=ASR_ACCEL_MODEL=whisper-large-v3-turbo-int8 test/asr_acceleration_native_test.dart
flutter test --no-pub --concurrency=1 --dart-define=ASR_ACCEL_NATIVE=true --dart-define=ASR_ACCEL_MODEL=firered-asr2-ctc-int8 test/asr_acceleration_native_test.dart
flutter test --no-pub --concurrency=1 --dart-define=NEW_ASR_NATIVE=true test/new_asr_models_native_test.dart
flutter test --no-pub --concurrency=1 --dart-define=NEW_ASR_NATIVE=true --dart-define=NEW_ASR_GPU=true test/new_asr_models_native_test.dart
```

主模型在 `.artifacts/model-center/native/<ID>`，GPU 包在 `.artifacts/asr-gpu/models/<ID>-gpu`，增强模型在 `.artifacts/model-center/enhancements/<ID>`。GGUF 原生检查需按主文档配置同版本 `LLAMADART_NATIVE_LIB_DIR`。可用 `NEW_ASR_SAMPLES` 指向含 `zh/en/ja/ko/yue.wav` 的 16 kHz PCM 目录，扩展语言检查；`NEW_ASR_REPORT` 指定报告位置，默认 `.artifacts/model-integration/new-asr-native.json`。

额外测试覆盖重复识别、CPU/GPU 字幕与权重元数据、硬件进程故障回退、取消加载、默认增强、低内存/流水线、两种真实 GGUF 翻译及已完成断点复用。语言样本及具体收据保存在 `.artifacts/new-asr-20261027/`。自然语音短片段上仍观察到错词，尤其 FireRed2 CTC 的英文；识别可用和重复结果稳定不等于完整质量基准，更不等于所有语言和硬件都已通过。

本轮最终收据：Core Ultra X7 358H、32 GB、Intel Arc B390、Windows x64。独立构建目录中的 `verify_model_integration.py --native` 通过静态分析（无问题）、704 项回归（另有 3 项原有跳过）与 2 项真实原生集成检查；新增 4 项原生检查全部通过，覆盖 7 组模型/语言识别、两项模型的 CPU 取消/重载、8 种 CPU 完整流程组合及日/韩通过两种 GGUF 翻译。另有 8 种真实 GPU 完整流程组合通过；新 Whisper 的最终 CPU/DirectML、故障回退与取消复测通过。两个新模型均通过中文权重目录和临时文件清理检查。

Windows Release 已重新构建并检查实际包内的模型目录、原生组件及源码收据，确认播放器原 CPU ORT 未替换。原先 14 条模型记录逐项相同，兼容性 fixture 未改。`validation-summary.json` 汇总结果；`isolated-validation/`、`completed-new-models.json`、`native-additions-gpu.json`、`unicode-final.json`、`completed-whisper-gpu.log` 和 `release-bundle-check.json` 保存具体证据。独立测试目录用于避开同时工作时的 Flutter 原生构建缓存冲突，没有改变全局 Flutter 设置。Windows ARM64、Linux、Apple 仍需要对应主机和匹配组件验证；Android 仅完成本轮原生编译及 ABI/16 KB 检查。

## 官方依据

- [Whisper Turbo 模型卡](https://huggingface.co/openai/whisper-large-v3-turbo)与[固定 ONNX 导出](https://huggingface.co/csukuangfj/sherpa-onnx-whisper-turbo/tree/2ca6ff69fc878651b770880507669577ac41c2ff)，原始权重 MIT。
- [FireRedASR2 项目](https://github.com/FireRedTeam/FireRedASR2S)、[原始模型卡](https://huggingface.co/FireRedTeam/FireRedASR2-AED)与[CTC 导出说明](https://k2-fsa.github.io/sherpa/onnx/FireRedAsr/pretrained.html)，原始权重 Apache-2.0。

## 2026-10-31 日语手机实测接入

本轮只公开新增 `parakeet-ja-0.6b-q8`：NVIDIA `parakeet-tdt_ctc-0.6b-ja` 的固定 cstr GGUF Q8 导出，673,554,880 字节，CC BY 4.0（署名、说明转换/修改、保留许可，可商用）。基座不是 2026 年新训练模型；GGUF 更新时间不能当成基座发布日期。未加入 Galgame 微调版或新的 Whisper ASR。Cohere 2B Q8 已完成开发对照，但该动画上更慢且漏句较多，因此不进入用户可选清单；比较用定义在 `test/support/cohere_candidate.dart`。

实现复用已固定的 CrispASR `34a8e436192de19d3e5a872437edfe3fd26ce8c4` / ggml `e2ae679a563014f46c546ce6c6448e8601e4dea6`，不升级原 sherpa、llamadart。`native/parakeet_ja/` 仅构建本架构需要的音频前端、加载器和 Parakeet 解码。桌面为私有依赖 helper，Android 为独立 `:parakeet_ja` 服务；移动库隔离 GGML 和共享 C++ 命名空间，Android 基线 ARMv8-A、16 KB 页面对齐。只启用真实验证过的 CPU 路线，不宣称核显/NPU/GPU 加速。

默认流程：现有音频准备 → VAD / 最长 7.5 秒声学分段 → 日语 CTC → 原生 token 时间与共享 Lindera 日语词边界 → 原字幕整理 / 容量 2 的有界稳定批次 → 原翻译交接。发现至少 1.5 秒的原生 token 空档时，最多在声学停顿处拆成两个不重叠窗口重识别一次；不读取 OCR 作为识别提示。无有效词时间时保留句时间，不按字数插值。新模型的时间格式是 `parakeet-ja-ctc-80ms-gap-recovery-v1`，既有模型及旧任务的时间版本、文件、指纹保持不变。

该日语专用模型在“自动”设置下也冻结日语；界面显示日语，保留其他模型的全局语言偏好。新任务默认保留原音（此视频的 GTCRN 对识别有损伤），使用原生时间，因而只需下载主权重；日语词典随原生共享组件内嵌。现有增强页仍能手动启用降噪（GTCRN）或“每条字幕都做声学精校”（共享 Qwen 对齐器）；下载组合、任务快照与实际入口使用同一依赖计算。降噪开关对新模型单独保存，其他模型的全局偏好不改动。所有旧任务继续使用冻结配置。

实测音频为用户提供的 `BV1ajb3zGEi3` / `cid=31607492065` 第一部分，16 kHz 单声道、632.349 秒。以下均经过生产 `ModelTranscriptionRunner`，含音频块准备、分词、字幕整理、稳定批次和首次模型加载，CPU 请求 4 线程，未包含联网取视频耗时；系统文件缓存未清空，不能称冷启动基准。

| 平台与配置 | 完整转录耗时 | 原生 ASR 进程峰值 RSS | 输出 / 恢复 |
| --- | ---: | ---: | --- |
| Windows x64 / Ultra X7 358H / 原音（新默认） | 89.422 秒 | 0.781 GiB | 通过稳定批次与无新增推理的断点恢复 |
| 小米 24122RKC7C / Android 17 arm64 / 原音（新默认） | 119.279 秒 | 0.949 GiB | 130 条字幕，44 次稳定批次，取消后新所有者及恢复通过 |
| Windows 同设备 / 开启 GTCRN | 111.998 秒 | 0.779 GiB | 转录、稳定批次与恢复通过 |
| Android 同设备 / 开启 GTCRN | 146.169 秒 | 同次观测上界 0.949 GiB | 166 条字幕与恢复通过，但文字错误增多 |

Android 多进程采样 RSS 同时求和峰值约 1.52 GiB；共享页会重复计数，不等于独占物理内存。准入保留约 2 GiB 的保守主模型工作集预算，仍按系统当前可用内存判断，不把存储扩展当物理 RAM。

质量证据：上一轮 21 项固定 FLEURS 日语 dev 对照包含 20 项原始朗读和 1 项合成伴奏派生，并非 21 段独立原始朗读。该混合组原生 Q8 CTC（无降噪、无 VAD/字幕后处理）字符错误率 CER 10.36%，UniDic 读音归一 CER 7.14%；20 项原始朗读单独统计为 10.43%。这些是固定切分下的参考，不代表动画准确率；下文另有实际软件分段入口的配对实验。用户选中的 OCR 有错字、重复字幕且未人工校订：同一 30–180 秒窗口，旧 Qwen 0.6B 自动语言流程相对 OCR 的字符/读音 CER 为 56.15% / 51.08%，新 Parakeet 原音 Windows 为 37.09% / 28.52%、手机为 37.30% / 28.70%。全视频新模型手机相对 OCR 为 42.64% / 33.71%，开 GTCRN 为 53.52% / 44.44%。这些是**相对未经校订 OCR 的误差**，不能换算成绝对准确率，也没有证明全球最强。仍有动画童声、人名和词语误识别。

收据：`.artifacts/cohere-integration/` 的 `windows-parakeet-full-raw/pipeline.json`、`android-parakeet-report.json`、`*-memory.json`、`parakeet-fleurs-quality.json`、`quality-final-*.json`、`phone-preservation.json`。手机通过现有导入 API 登记权重，另存一条原音转录字幕及词时间伴随文件；没有替换 OCR、选中字幕、默认模型、任务或译文。任务 JSON 保持字节一致，媒体库差异仅为播放活动时间字段。

维护者显式构建/验证：

```text
python tool/build_parakeet_ja.py --platform windows --arch x64
python tool/build_parakeet_ja.py --platform android --arch arm64 --ndk <NDK目录>
python tool/verify_parakeet_ja_artifact.py native/parakeet_ja/prebuilt/windows-x64 --platform windows --arch x64
python tool/verify_parakeet_ja_artifact.py native/parakeet_ja/prebuilt/android-arm64 --platform android --arch arm64
python tool/verify_model_integration.py --native
```

Windows x64 与 Android arm64 已真实推理；Windows ARM64、Linux、macOS、iOS 尚未实测。Linux 复用私有 helper 安装，Apple 需对应主机构建：macOS 使用 `bundle_japanese_asr_macos.sh` 打包签名，iOS 分别构建设备 / `--ios-simulator` 静态库，再运行 `package_japanese_asr_ios.py --component parakeet_ja` 生成并验证 XCFramework；Podfile 仅接入有收据的组件。未验证的平台不能标记推理通过。没有直接执行官方 NeMo 对照推理，Q8/F16 等价性不能以成功加载替代验证。

官方模型、转换与许可依据：[NVIDIA 模型卡](https://huggingface.co/nvidia/parakeet-tdt_ctc-0.6b-ja)、[固定 GGUF 导出](https://huggingface.co/cstr/parakeet-tdt-0.6b-ja-GGUF/tree/d9e3ba65a6579796389ea89e5939509ed257f972)、[FLEURS](https://huggingface.co/datasets/google/fleurs)、[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)。完整声明见 `assets/licenses/Japanese-ASR-ThirdPartyNotices.txt`；探针音频保存来源、转换及哈希，不含用户的视频音频。

最终验证：`verification-final-catalog/` 中静态分析无问题，856 项主回归通过（3 项原有跳过），7 项 Windows 原生检查通过，包含新日语模型接两种现有本地中文翻译和无新增推理恢复。真实手机输出的 130 条字幕词时间另查 UTF-16 原文范围、正时长及句时间范围，零越界。Windows 中文程序/依赖、权重与音频路径真实识别通过。Windows 与 Android 正常 `lib/main.dart` Profile 包构建完成；Windows 包内私有 helper 再次真实识别通过，Android 校对清单、许可及原生可加载 ELF 段（AGP 去除调试符号会改变整文件哈希）后原位安装，正常启动无错误。保留用户选择的 OCR、默认模型、语言及待处理任务。

额外设置导出/试用检查 43 项通过、1 项审计失败：现有 `experimental_layout`、`home_search_preferences`、`ocr_compute_service`、`experimental_home_frame`、`media_library_search_prompt` 五个其他未提交模块未列入原持久化所有者审计表；它不涉及本轮模型设置，未顺带修改这些模块或放宽审计。日志为 `settings-regression-final.log`。本轮新模型降噪选项的导出检查通过。`test/fixtures/local_model_compatibility.json` 的 SHA-256 保持 `43d6d5b1f223131a50db1693ee7ae632e254835834e17146d5041857e82bd2e0`。可查看的音频、两平台字幕、词时间及构建/质量收据汇总在 `.artifacts/japanese-asr-results-20261031/`。

## 2026-10-31 Windows 处理步骤配对实验

本轮应用户要求仅在 Windows CPU 执行，不连接手机做测试。保持当前 Q8 权重、CTC 解码器与生产处理代码。新增显式维护工具 `tool/japanese_asr_ablation.py` 和有开关的 `test/japanese_asr_ablation_native_test.dart`，复用真实 GTCRN、Silero、Parakeet、Lindera、共享对齐器和生产转录 runner。没有新增应用启动测速、下载或任务设置。

固定 20 条独立 FLEURS 日语 dev 原始朗读，再分别添加不含语音的合成宽带噪声（整体 RMS 定义的 10 dB SNR）和合成伴奏（12 dB），合计 60 条配对场景；另测同一动画 30–180 秒窗口和 10 秒静音。原始文件和处理后文件保存哈希。固定切分对照前后使用完全相同的范围，以隔离降噪波形的影响；另一组遵循软件实际顺序，降噪后重新 VAD。还对同一个 GTCRN 导出做了分窗与整段调用比较，保留实例重复处理的输出采样差异为零。

当前流程前端参数：Silero 阈值 0.5、最短静音 150 ms、最短语音 180 ms、最大检测段 8 秒、严格 512 采样步进；再用现有声学规则限制到 7.5 秒，前后最多补 160 ms，并受相邻片段中点约束。格式准备是 16 kHz 单声道 PCM16，不额外使用 loudnorm、压缩或高低通；这是匹配 ASR 输入格式。以下 CER 使用 NFKC、去空白与标点，越低越好，数字或汉字/假名写法差异仍计错。

| 相同 20 条原始朗读的处理方式 | CER |
| --- | ---: |
| 固定秒数切分，无 VAD | 10.14% |
| VAD，不补边 | 4.40% |
| VAD + 最多 160 ms 补边，保留原音（当前默认） | 3.35% |
| VAD + 补边 + GTCRN | 4.11% |

20 条原始朗读通过真实 `LocalAsrWorker` 逐段复核，与独立原生对照文字一致，故 3.35% 不是仅按扩展名加载成功得出的结论。严格字符全文一致为 8/20；例如仍有“帰国後→企画後”“価値→かし”的错词，也有“車椅子→車いす”这类书写差异。因此不宣称逐句无误，更不外推为动画的准确率。

| 每类 20 条，均使用 VAD 与补边 | 原音 CER | 降噪 CER | 改善 / 变差 / 持平的段数 |
| --- | ---: | ---: | ---: |
| 原始朗读 | 3.35% | 4.11% | 1 / 5 / 14 |
| 合成宽带噪声 10 dB | 4.59% | 4.98% | 6 / 7 / 7 |
| 合成伴奏 12 dB | 3.16% | 3.92% | 2 / 7 / 11 |

不能把这些均值解释成降噪在所有环境必然有害：三组配对 bootstrap 95% 区间均包含零。实验支持“目前没有稳定增益证据，不默认开启”，不能覆盖严重噪声或所有真实音乐。固定切分下合成伴奏组有轻微平均改善（10.05%→9.86%），也说明波形变化与 VAD 边界变化应分开看。

冻结动画同一份已识别的 36 段原文后，只切换后处理：默认、关闭修边、关闭标点、关闭日韩分词层、每条强制精校，识别文字和最终自然分句后的文字改动均为零。默认实际给 36 段附加了日语词边界；中英文标点器没有为日语加载；静音修边仅改变 16 段显示时间。强制精校使用真实共享权重运行 42.46 秒，18 段保留 aligned 词时间，18 段回退，原文不变；所有词时间与 UTF-16 原文范围检查零越界。精校测试初次指向缺失的开发目录，已纠正并重跑，测试新增了实际精校成功断言，未把初次回退计为成功。没有独立词时间真值，不声称强制精校必然比原生时间更准。

再次经过生产 runner 的完整 632.349 秒动画：原音 82.783 秒、GTCRN 87.541 秒；相对未经校订 OCR 的字符差异率为 42.41% / 53.44%。这不能叫真实准确率。150 秒流水线与节省内存串行的全部字幕 JSON 一致；流水线的 6 个稳定批次与最终字幕逐项一致，断点恢复没有新增推理。45 秒强制精校路径真实执行并保留了 5 条采用标记。两种现有本地中文翻译也再次真实运行并通过恢复复用。

默认方案维持原音、VAD 与补边、日语分词/自然分句、原生词时间优先及有界流水线，不默认 GTCRN，也不每条都强制精校。所有最终结果和源码收据在 `.artifacts/japanese-processing-ablation-20261031/`；`report.html` 可看表格、听配对音频，`summary.json` 含区间与逐项流程结果。复现命令：`python tool/japanese_asr_ablation.py --stage all`；须已有本地权重与样本，不自动下载。最终中央入口静态分析无问题，963 项相关回归通过，另 3 项原有跳过；本轮硬件实验通过上述显式入口执行，中央默认命令本身未启用 `--native`。
