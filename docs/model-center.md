# 模型中心

2026-10-31 云端转录：服务管理新增 ElevenLabs、Soniox、AssemblyAI、Deepgram、Google Gemini，使用用户自己的 API Key 直接上传音频。按模型显示语言和附加选项，模型缓存过期后后台刷新，保留当前选择，并允许手动填写新型号。云端转录网络默认跟随设备网络；分段、原字幕与译文复用既有增量流程。腾讯、阿里从新增菜单撤下，旧配置及任务保留。详见[云端转录说明](cloud-transcription.md)及[验证记录](cloud-transcription-tests.md)。

入口：媒体库设置 → 模型中心。普通入口固定打开功能配置，以字幕转录、字幕翻译、字幕输出和设备建议为主；本地模型、服务管理、下载与任务通过首页的三个管理入口进入。返回后保留来源页面的位置与展开状态，旧调用显式传入的页面编号继续映射到对应管理页。

2026-10-29：Zipformer Tiny、Whisper large-v3 Turbo、FireRedASR2 CTC 及其专用 GPU 包已从模型库和新任务选择中下架。未完成下载暂停并保留断点；已安装文件供原冻结任务继续使用，也可从已有下载记录中手动删除。原默认模型下架时改为 SenseVoice，新任务需要先完成安装，不自动下载。Qwen3-ASR 仍支持上下文热词，热词功能与已保存词表保留。

2026-10-29 语音转录页：顶部“模型设置”下方集中显示转录方式、实际接口/模型、识别语言与翻译方式/语言；可直接切换转录方式和识别语言。转录与翻译按钮紧随配置组，后台队列与处理进度放在下方。公益接口显示“服务自动识别”，不提供服务端不支持的语言参数；本地选择按清单列出语言。快捷选择只保存绑定，不自动下载模型或增强组件，未安装时继续由原有模型设置入口准备。

2026-10-31 识别语言统一入口：视频横竖屏、音乐/播客的 AI 转录面板、语音转录队列、模型中心及重新转录确认框共用同一选择器。窄屏批量页把语言放在模型摘要下一行，宽屏并排；语言选择与翻译目标分开，支持大字体和横屏。选择按本地模型 ID 或在线服务类型与模型名保存，重启、切换页面及切换回原模型后恢复；设置导出/导入和试用默认设置也包含这些偏好。旧版全局语言作为未设置模型的兼容回退，超出该模型能力时使用自动识别，日语专用模型直接固定为日语。

语言能力集中在 `asr_language_options.dart`：本地范围来自实际清单与适配器，不复用翻译语种列表。SenseVoice、Qwen3-ASR 会接收手动语言提示；Dolphin、Parakeet v3 自行识别，手动选项只指导后续分词、时间精校与翻译，选择框会说明区别。公益接口自动识别；腾讯云固定语种引擎显示其语种，多语种引擎的选择不自动更换付费引擎。百炼 `fun-asr`、`paraformer-v2` 仅在用户指定受支持语言时发送 `language_hints`，自动模式省略；未知型号保留服务端自动识别。OpenAI 兼容接口发送语言提示，自定义服务器的实际语种范围仍以服务器模型为准。百炼范围依据 [Fun-ASR 文件转录](https://help.aliyun.com/zh/model-studio/fun-asr-recorded-speech-recognition-http-api)和 [Paraformer 文件转录](https://www.alibabacloud.com/help/en/model-studio/paraformer-recorded-speech-recognition-restful-api)，腾讯语种依据[极速版引擎说明](https://cloud.tencent.com/document/api/1093/52097)。

新任务捕获解析后的语言，并以同一语种选择增强依赖；继续/重试沿用任务原有快照，不改写旧任务、ASR 断点或译文。选择语言本身不在播放页、批量页或重新转录框触发下载，缺失组件仍使用原有准备入口。对应检查为 `asr_language_options_test.dart`、`transcription_language_selector_test.dart`、批量布局/实时设置及任务恢复测试；Windows 原生转录并翻译检查也从模型中心的语言选择捕获配置。

支持热词的模型（当前为 Qwen3-ASR）显示紧凑的“热词 / 预设”入口，点击打开独立编辑窗口。每行一个词，最多 100 条、合计 4000 字；按视频身份保存，换视频不会自动继承。已有任务的模型配置和词表保持冻结，继续/重试沿用原词表，重新转录才采用本视频当前词表。旧的全局热词保留为一次性的“原有热词”预设，不自动应用到任何视频；原已开始任务的快照不迁移。识别增强关闭时，编辑窗口明确提示热词暂不参与识别。

预设支持命名、填入、重命名、用当前内容更新与删除；保存预设不会改写视频词表，选择预设填入后点击“应用”保存到当前视频。预设在各视频间共享，只有用户主动套用才复制词表。视频切换时仍打开的编辑窗口绑定其原视频，存储失败保留编辑内容供重试。命名预设保存在 `transcription_hotword_presets_v1`，分视频词表保存在 `transcription_video_hotwords_v1`；设置导出包含命名预设，不包含视频词表与身份。存储/布局/隔离回归入口分别为 `transcription_hotword_store_test.dart`、`ai_transcription_configuration_test.dart`、`transcription_resume_restart_test.dart`，设置 `AI_CONFIGURATION_PREVIEWS=true` 可生成本轮手机、桌面和模拟键盘预览。

功能配置的“字幕输出 → 标点处理”显示当前规则，点击打开选择面板：保留全部标点、去掉语末句号、去掉语末句号和逗号（默认）、去掉语末标点、去掉全部标点。它控制生成文件中的原文与译文，覆盖本地模型、在线及公益转录服务；分句和翻译完成后再清理，不改变识别增强。设置自动保存，新任务开始时冻结；旧的已开始任务保留原文本规则，重新生成采用当前设置。

标点清理不限制语言：所有标点模式依据 Unicode 标点分类，句号模式另外覆盖多个文字系统的 full stop、danda/shad 等句末符号；不增加转录模型自身的语言支持。默认模式保留问号、感叹号、省略号、英文首字母缩写与词中小数点。语末模式保留闭合引号/括号，只处理完整字幕条目末尾；全部标点模式也会去掉词内撇号、连接号、小数点以及藏文音节点等 Unicode 标点。保留文字、组合附标、表情及字幕格式标签，并重映射 UTF-16 词级时间范围。分类与符号名称参考 [Unicode 数据库](https://www.unicode.org/Public/17.0.0/ucd/UnicodeData.txt)。

2026-10-21 新增 `removeTrailingFullStopsAndCommas` 并设为默认，原四种规则的存储名称与行为不变。新规则额外识别 Unicode 17 的 26 个逗号类标点，包含中英文逗号、日文顿号、阿拉伯文逗号及竖排/宽度变体；只去掉字幕末尾的对应符号，句中逗号、数字内部的逗号与小数点保留。只去掉句号时仍可单独选择原选项。没有保存标点选择的配置使用新默认；已经保存的选择（包括旧版默认句号模式）继续保留，已冻结任务续传也不切换规则。

该规则变更的 166 项相关测试通过，覆盖五个选项的响应式选择、26 种逗号、组合标点、UTF-16 词级范围、后台批次交接、本地及在线原文/译文输出、原始翻译上下文和冻结配置续传；7 个改动相关代码文件的静态分析无问题。记录为 `.artifacts/model-center/punctuation-comma-{regression-final,analysis}.log`，本次未重新执行平台构建或原生模型测速。

本次标点设置验证覆盖多文字系统、词级时间伴随文件往返、成对发布、原始翻译上下文、在线转录暂停续传、应用重启与旧任务迁移，以及 320（文字放大 1.3 倍）、360、600、1440 像素下四种规则的实际点击。225 项流程相关回归与后续 86 项设置/界面检查均通过（两组有重叠，9 项在线检查按条件跳过）；针对性静态分析无问题。正式入口 Windows Debug、Android arm64 Debug 构建通过；本轮未进行 Android 真机或 Apple/Linux 构建。记录位于 `.artifacts/model-center/punctuation-{regression,final-tests,analysis,windows-build,android-build}.log`。

标点处理的后续优化保留四种规则及输出字节：语末模式从最后一个字素反向查找；全部标点模式只记录删除区间；词级时间按区间映射，不再为每个字符分配掩码及偏移表。译文直接处理字符串。本地流式只处理新增批次，并直接保留最多两条原始翻译上下文。

在线整份结果由 `SubtitleOutputPreparer` 合并清理、SRT 编码与词级伴随文件编码/哈希。达到 32 条、4096 字符或 128 个词级片段时转入后台 isolate，较大的复核信息也计入阈值；输入解析从 4096 字符起转入后台。字幕对象每 128 条发送一批并等待确认，避免创建线程时一次复制整份对象图。短结果直接处理，避免小任务的线程启动成本。后台不写文件、不发布事件；主任务在返回后检查停止状态，再沿用原文件保存与通知流程。

Windows x64、Dart AOT 的同机样本中，24 对原文/译文（原文含词级时间）的清理中位耗时如下。这里仅比较文本处理，未计模型推理、文件写入及 Flutter 布局，也不代表 Android 平板性能。

| 规则 | 原实现 | 优化后 |
| --- | --- | --- |
| 去掉语末句号 | 0.229 ms | 0.050 ms |
| 去掉全部标点 | 0.395 ms | 0.126 ms |

一万条单轨字幕的同项清理分别由 57.064 / 92.308 ms 降至 10.322 / 28.149 ms。完整后台准备还包括 SRT 与时间数据：仅去句号规则约 64–78 ms，全标点规则约 93–94 ms；主线程在等待期间可继续处理事件。工具为 `tool/subtitle_output_benchmark.dart`，前后记录为 `.artifacts/model-center/punctuation-{before,fast}-benchmark.json`。事件循环计时仅用于观察调度，不代替真实播放帧耗时测试。

本轮优化的 371 项相关回归通过，9 项在线检查按既有条件跳过；其中包含 12,512 组与冻结旧实现的文本及词级范围对照，以及后台编码失败、不可发送对象、停止/移除、恢复后仅一次成功通知和跨 128 条边界的字节一致性检查。旧调度测试按当前资源策略更新，继续检查受限设备不预取、线程预留及 Parakeet 时间格式迁移，未通过放宽文本正确性或取消规则来提速。日志为 `.artifacts/model-center/punctuation-fast-final-regression.log`。16 个文件的静态检查没有错误或警告，本地翻译文件仍有 6 条大括号样式提示，见 `punctuation-fast-final-analysis.log`。正式入口 Windows Debug、Android arm64 Debug 的最终构建均通过，记录分别为 `punctuation-fast-{windows,android}-final-build.log`。Android 最终日志提示当前 ASR 原生源码比 NNAPI 构件新，该可选构件未打包，保留 CPU 回退；重新启用该后端需要重建匹配的 ASR 构件。本轮未进行手机/平板真机性能、Apple/Linux 构建或新的原生模型吞吐测试。

也可从视频横竖屏、音乐/播客的转录面板、语音转录队列顶栏、字幕管理的普通/音乐翻译面板及共享翻译设置直接打开“模型中心”。快捷入口固定打开功能配置，覆盖当前页面，返回后保留输入及任务状态；翻译面板先提交待保存的设置，并继续监听同一个共享设置对象。

服务和模型使用分组选择面板，区分在线服务、转录接口及应用内本地模型；每项显示名称、支持语言、安装状态和下载体积。详细语言说明可在模型详情中查看。Dolphin 单独提示不支持英语，Qwen 的语言标签标为常用语言，避免当成完整覆盖范围。小屏选项允许名称和语言说明换行，并支持搜索与键盘适配。

功能配置中的独立下载按钮按模型 ID 直接打开目标详情，同时开始或继续下载；排队、正在下载和校验中的任务只查看进度，不重复入队。宽度达到 1000 时显示约 420 宽的右侧详情面板，较窄窗口使用完整子页；下载跳转不受模型库搜索、筛选和滚动位置影响。下载与默认选择分开，安装后可明确设为默认转录或翻译。下载状态、暂停、失败和完成会同步到配置及详情；离开页面后由应用级队列继续处理。

## 配置显示与自适应布局

- 本地转录增强、分句和性能参数仅在选择应用内本地转录时出现，自定义接口保留适用的音频语言设置。
- 普通在线翻译显示服务与方向；AI 翻译显示接口及专用设置；应用内本地翻译显示模型、术语及性能设置。Ollama 属于 AI 接口，不显示应用内模型和性能控件。
- 切换服务保留既有本地配置，“当前默认”与“已安装”分别展示。
- 手机使用紧凑单列，进阶设置默认收起。宽度达到 1000 时使用两个独立堆叠的栏目，转录与翻译置顶，最大内容宽度 1280；不再按同行最高卡片高度换行。
- 详情将用途、语言、下载状态及主操作前置，技术信息、文件清单和模型工具按需展开。
- 预览命令继续使用 `--dart-define=MODEL_CENTER_PREVIEWS=true`，新截图保存为 `.artifacts/model-center/redesign-*.png`。

2026-10-21 重设计验收：125 项模型中心、入口导航、转录增强、分句、标点与共享翻译设置回归通过，六个相关文件的静态检查没有问题。覆盖 320（文字放大 1.3 倍）、360、390、600、1000、1440、1920 宽度，以及手机横屏键盘、下载失败重试、重复点击、默认启用、后台进度和返回动画期间的状态更新。已检查首页、详情、模型库、增强、分句及服务编辑截图；手机截图来自 Widget 渲染，本轮未进行真机触控或模型性能验收。

最终 Windows Debug 与 Android arm64 Debug 构建均通过，产物为 `build/windows/x64/runner/Debug/video_player_app.exe` 与 `build/app/outputs/flutter-apk/app-debug.apk`。日志分别为 `.artifacts/model-center/redesign-{regression-final,analysis,windows-build-final,android-build-final}.log`，文件校验与产物记录见 `redesign-verification.json`。本次复用原有下载、推理和持久化逻辑。

## 已接入的能力

字幕转录可选择公益接口、应用内 ONNX 模型、兼容音频转录接口、腾讯云录音文件识别极速版、阿里云百炼异步文件转录。兼容接口必须支持 multipart 音频和 `verbose_json.segments` 或 SRT 时间轴；没有鉴权的本机服务可以留空密钥。腾讯云和百炼仍需要用户自己开通服务并填写密钥。

字幕翻译增加“应用内本地模型”，沿用原有字幕语言、方向、术语、字幕存储和完成通知。已有 AI 接口、Ollama 及其他翻译服务继续可选。本地翻译逐条保留顺序和句级时间轴，校验标签和占位符，不把原文的词级时间直接套用到译文。

本机检查使用语音或翻译样本进行真实推理。付费转录服务的“语音样本检查”上传内置约 11 秒英语音频，可能产生平台用量；模型加载成功不等于服务有额度或识别质量达到要求。

## 首批模型

下表大小为下载文件的近似值，运行内存另计。内存档位是应用的保守起测建议，并非官方最低值或速度保证；设备建议按物理内存和所选音频语言筛选，实际可用内存、系统限制和内容都会影响结果。

| 模型 | 参数 / 格式 | 大小 | 语言与用途 | 起测内存 | 权重许可证 |
| --- | --- | --- | --- | --- | --- |
| [SenseVoice Small](https://huggingface.co/FunAudioLLM/SenseVoiceSmall) | 234M / INT8 ONNX | 228 MiB | 普通话、粤语、英、日、韩；识别与文本规整 | 4 GB | FunASR Model License，见上游模型说明 |
| [Dolphin Base](https://github.com/DataoceanAI/Dolphin) | 100M / INT8 ONNX | 99 MiB | 40 种东方语言；不包含英语，CTC 自动识别语言 | 4 GB | Apache-2.0 |
| [Parakeet TDT v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) | 600M / INT8 ONNX | 639 MiB | 英语等 25 种欧洲语言 | 8 GB | CC-BY-4.0 |
| [Hy-MT2](https://huggingface.co/tencent/Hy-MT2-1.8B) | 1.8B / Q4_K_M GGUF | 1.06 GiB | 专用翻译，支持上下文与术语 | 8 GB | Apache-2.0 |
| [Qwen3 4B](https://huggingface.co/Qwen/Qwen3-4B) | 4B / Q4_K_M GGUF | 2.33 GiB | 通用多语言指令模型，翻译时关闭思考 | 16 GB | Apache-2.0 |

完整文件、固定版本、校验值、语言标签和下载来源保存在 `assets/models/catalog.json`；`tool/refresh_model_catalog.py` 只更新明确审核过的版本，不自动追踪最新权重。Dolphin 的完整语言代码参考[官方列表](https://github.com/DataoceanAI/Dolphin/blob/main/languages.md)。Qwen 卡片只列出常用语言标签，完整覆盖范围见官方模型卡。

另有四个独立增强包：GTCRN 降噪、CT-Transformer 中英标点、英语 Wav2Vec2 CTC、普通话 XLSR-53 CTC。模型中心可按“转录增强”筛选，增强包不能设为主识别/翻译模型；每包提供文件校验、离线导入与真实推理检查。参数、语言、许可与内存边界见[增强模型表](local-asr-quality.md#已固定的增强模型与语言边界)。清单共 10 个模型/增强包。

## 默认本地转录增强

“功能配置 → 本地转录设置 → 识别增强”提供独立持久化设置页，大屏双列、小屏单列。降噪、时间精校、标点、首尾静音修整和声学复核默认开启，可逐项关闭；用户手动关闭后再次进入或选择模型仍保留。混合声道为默认，可改左/右；热词表默认空，现有 Qwen3-ASR 通过上下文提示支持热词，其他可选识别模型不使用热词。当前不提供说话人识别：旧的 Pyannote/CAM++ 不再下载或参与处理，旧任务的相应依赖会忽略；iOS 旧后台下载会暂停，已有权重文件保留。

选择本地模型后按所选语言准备依赖，进入/退出页面不停止下载；处理中等待下载时不占用推理队列。默认自动中英所需增强包约 470 MiB，其他语言仅下载适用部分。所有包固定 SHA-256，提供 Hugging Face 和 HF 镜像，部分提供同一文件的 GitHub 上游直链，沿用下载测速和续传。源可用性取决于用户网络。

时间精校只支持普通话与英语，其他语言保留识别器时间。匹配不足、词表未覆盖或无法安全分窗时回退原始时间轴；字幕列表和编辑页可查看失败原因与声学参考文字。“匹配度”不是识别准确率，参考文字不自动覆盖原文。

五端、四个本地 ASR 模型与已有加速后端共用执行策略。资源足够时，识别实例执行当前块 VAD/ASR，辅助实例交替处理下一块降噪和上一块精校/标点/静音修整。最多两块识别/等待增强/增强，另只允许提前降噪一块；可转移 PCM 避免后续重复降噪，单个原生实例始终只有一个调用。并行余量不足时尽量顺序复用主模型、VAD 和轻量增强；实际需要 CTC 才释放主模型腾出内存。更低内存或选择“节省内存”才按阶段加载和释放。降噪和后处理都未启用时不启动额外推理实例。线程总预算为逻辑处理器一半，移动端最多 4、桌面最多 6，流水线最低 3 线程。“本地识别 CPU 线程上限”配置单个模型的 1–4 个计算线程，不是并发块数；辅助实例最多 2 线程。声学精校默认复用可靠原生时间，也可强制全量精校。完整面板分开展示降噪/识别/增强进度，队列可点开实时详情；还显示计算后端、调度方式、本地已用时间及恢复数量。策略、内存估算和四模型对照见[转录吞吐与流水线](local-asr-quality.md#转录吞吐与流水线)。

识别与派生结果分开断点：只改后处理会复用原始 ASR，只改字幕长度会复用增强结果；降噪、声道、VAD、留白和热词变化重新识别。调度方式不使原始 ASR 断点失效；旧检查点保留自身音频窗口，恢复时不重复全部识别。

ONNX / GGUF 权重在五个平台共用，平台差异由原生运行库处理，无须分别提供五份权重。SenseVoice、Dolphin、Hy-MT2、Qwen3 提供已核对大小和 SHA-256 的 ModelScope 文件，并固定每个文件的提交版本；SenseVoice 是社区副本。五个模型均配置固定版本的 Hugging Face、HF Mirror 和 HF Mirror.net。两个镜像均为第三方服务；HF Mirror 可能重定向海外 CDN，不能凭域名保证国内可达。Parakeet 尚未找到可直接下载同版独立文件的 ModelScope 副本，使用已验证的第三方镜像作为备用来源。也可导入离线目录，按清单中的文件名和大小安装；需要核对内容时可选择“手动校验文件”。

默认“自动测速”通过模型下载的网络设置并行读取各源最多 256 KiB，跟随实际重定向，以包含连接等待的平均速度排序。每个探测最多 5 秒；失败探测保留作末位备用。排名按网络配置、来源组合和模型仓库隔离，缓存 5 分钟；下载成功会提升该源的次序，但不延长测速结果的有效期。探测流量最多为每文件每源 256 KiB（不含协议开销），并不能保证该源始终最快。持续明显降速时会重新测速。不更改用户设置的系统或自定义代理策略。手动选源表示优先使用，失败仍尝试其他来源。模型详情的文件清单可直接打开每个来源链接，下载状态显示当前来源。

## 执行、下载与恢复

- `ModelCenterService` 是应用级服务，页面关闭不会终止下载。队列写入 `model_center.json`，权重放在受存储迁移管理的 `local_models`，断点放在 `model_jobs`。
- 下载连接最多等待 15 秒，无数据最多等待 20 秒。Dart 下载在剩余至少 8 MiB、来源支持精确 Range 和强 ETag 时最多使用 4 条连接，每批最多缓冲四份 2 MiB 分段；按顺序写入连续 `.part` 断点，避免文件空洞被误当作完成。同一文件的分段复用网络连接，网络策略变化时按现有规则轮换连接池，避免每段重新建立连接。来源忽略分段或没有可靠校验标识时退回单连接；模型及模型内文件仍按原队列顺序处理。iOS 系统后台 URLSession 保留系统连接调度，自定义代理走上述 Dart 路径。
- 多源下载连续 20 秒平均不足 16 KiB/s，或低于测速/已观测稳定速度的 20%（参考速度至少 128 KiB/s）时尝试其他来源；自动模式重新测速并优先尝试尚未失败的源。全部来源都慢时，最后回到重新排序的首位继续，避免无限切换。Dart 同源续传使用 ETag / If-Range；跨源不复用其他站点的 ETag，按 Content-Range 和清单长度续传。服务器不支持续传时重新下载。传输完成即安装，不再全文件计算 SHA-256。手动暂停会保留；正常重启可继续原队列。推理中的模型禁止删除，通用缓存清理不会删权重或断点。
- Android、iOS、macOS、Windows、Linux 共用同一规则：下载完成即可使用，恢复下载、离线导入、点击本机检查和开始转录都不自动扫描模型哈希。“本机推理检查”直接加载模型执行短样本；只有主动选择“手动校验文件”才做完整 SHA-256。内置 VAD 和 OCR 也直接复用已有文件。
- 2026-10-20：上述准备流程相关 86 项回归通过，静态分析通过，包含真实 OCR 推理，以及下载完成/重启/离线导入不触发扫描、两个本机检测入口直接调用推理的验证。Android arm64 release 包为 `build/app/outputs/flutter-apk/FluentPlayer-model-ready-20261020-arm64.apk`，构建与签名检查通过，并保留 `OrtGetApiBase` 原生库兼容修复。测试和构建日志位于 `.artifacts/asr-native-audit/model-no-auto-hash-*.log`。
- iOS 的系统网络与直连下载由后台 URLSession 执行，Flutter 被系统挂起时系统仍可下载，重新打开后直接完成安装。自定义代理使用 Dart 下载，进入系统后台后可能暂停。用户强制退出应用及系统取消后台工作均受 iOS 规则限制。权重目录排除 iCloud 备份。
- iOS 下载同样先测速选源，前台监控低速和停滞，切换源时由 URLSession 建立新任务；同源断点由系统维护，跨源不复用系统 resumeData。Flutter 挂起期间的切换时机由系统超时和重新唤醒决定。
- Android 下载和本地推理使用有暂停入口的前台服务；系统超时或用户暂停时停止任务并保留已完成断点。系统强制结束进程后需重新打开应用。
- 本地 ASR、翻译和 OCR 任务共用推理预约；转录任务内部可使用受资源预算限制的双阶段流水线。转录默认 2 个识别 CPU 线程，可选 1–4；翻译单独配置自动加速、线程和批次。本地流式翻译借用同一次预约，在批次边界交接；内存允许时复用已加载的模型，余量不足时按阶段释放。
- ASR 沿用原有媒体获取、FFmpeg 和字幕入库链路。播放器新建本地流式任务每 30 秒准备 PCM WAV，重叠 2 秒；旧检查点沿用已有窗口。其他整份结果调用仍保留原有窗口策略。当前识别时可提前准备下一块，不额外并发提交在线付费任务；退出会清理未领取音频。VAD 保持 512 点输入，仍切成最长约 12 秒语音段；每阶段保存断点，保留重叠去重及可靠原生 token 时间。播放器进度与队列区分音频覆盖量和整体工作进度，加载阶段不伪造百分比。
- 本地转录的“字幕分句”子页默认自然分句：目标 6 秒、中文约 20 字 / 英文等约 80 字符，衔接相邻碎片后按句末、从句与停顿选择边界，减少闪烁短句和孤立尾词。可选短句、标准、原始语音段或自定义；自然重组、标点断句、无可靠词级时间时估算均可单独配置。旧推荐默认值升级，自定义与关闭状态保留。字幕显示分句独立于 12 秒识别音频窗，设置随任务冻结，对新建任务生效。Parakeet 零时长词块不再丢弃，相应原始断点会更新版本以避免读入旧时间数据。算法、局限和调研见[本地转录质量说明](local-asr-quality.md)。
- 本地翻译默认成批处理最多 8 条字幕，长句按长度缩小批次，结合少量前文和术语提示。字幕编号、标签、占位符和有效译文校验通过后保存检查点；批次结束、处理中定期及取消退出时落盘。改变批次、线程和加速方式仍可复用译文，也能读取原先逐句翻译的断点。中断时尚未校验的批次或长句需要重做。
- 已开始任务保存服务、模型版本、语言和线程配置；更改默认设置不改变该任务。更换密钥仍使用同一安全存储条目。没有可用模型时会报错，不会自动把本地任务切到云端。
- 付费平台不做盲目提交重试。百炼保存远端 task ID，网络中断后继续查询；提交响应丢失且尚未保存 ID 时停止并提示先核对平台记录，避免重复计费。恢复记录不保存 API Key。

## 本地字幕增量生成

SenseVoice、Dolphin、Parakeet、Zipformer 现在共用本地增量流水线。只转录时，增强和分句完成的稳定前缀即可显示；选择“转录并翻译”时，整批原文与对应译文完成后一起提交、显示，不先显示缺少译文的原文。自然分句仍等待末尾延续组闭合，不为尽早显示而提前截句。在线转录保留原流程。

首批字幕自动选入播放器；开始任务后手动切换或关闭字幕会停止自动接管，同一任务暂停后续传也保留这一选择。手动重新选择生成中的字幕文件即可继续接收更新。追加通过共享播放服务传递，无需反复解析整个 SRT；视频悬浮字幕、文稿及音乐横竖屏保留播放、阅读和跟随状态。音乐文字选择沿用冻结文稿的交互：新增内容提示可刷新，当前选区和阅读锚点不变。

字幕管理同时显示生成状态、已发布条数、处理位置和文件大小。运行中可“停止并保留进度”，等待当前不可抢占的原生调用和写入收尾后变为“已暂停”；暂停或出错可“继续生成”。续传固定原任务的模型、增强、分句、语言、翻译服务与输出路径。改用新配置应选择“重新生成”，原字幕文件保留。缺少模型或源媒体已经改变时明确报错。

实现、恢复格式、验证命令和性能记录见[本地字幕流式工作流](local-streaming-subtitles.md)。

## 原生依赖与系统

本地主识别模型现支持按模型选择自动／CPU／GPU、同段语音测速、带启动成本的选择及故障回退，并提供按需下载的完整浮点权重。桌面 GPU 在独立工作进程，Android 使用私有进程服务；降噪、VAD、时间精校和标点仍用 CPU。旧任务沿用 CPU，已完成原文和检查点保留。组件、系统限制、构建及真实验证范围见[本地转录硬件加速](asr-acceleration.md)。

最低 iOS 16.4、macOS 14，已按本次需求提高。Apple 使用 `llamadart_llama_cpp_flutter` 的 Swift Package Manager 原生包，项目内开启 SwiftPM；仍使用 CocoaPods 的其他插件保留原来的接入方式。

`llamadart` / Apple companion 固定为 0.15.1。`sherpa_onnx` 及五个平台包固定为 1.12.12，避免其宽松版本范围单独升级原生 ABI。这个版本的 ASR 原生库可使用应用现有的 ONNX Runtime；直接升级到 1.13.8 会要求 ORT API 28，与本工程 Windows OCR 的 DirectML 1.21 冲突并造成进程崩溃。

Windows 保留现有 DirectML DLL；Android 过滤 sherpa 自带的旧 ONNX DLL，仅打包 OCR 的 ONNX Runtime 1.23.2，兼容两个消费者。已检查所用 Android arm64 sherpa ELF 的加载段为 16 KiB 对齐。Android 当前发行配置沿用工程的 arm64 ABI。后续升级运行库必须同时复验 ASR 与 OCR。

## 本地字幕翻译提速

旧实现每条字幕单独生成，固定 2 个 CPU 线程，并显式关闭 GPU。应用内的 AI API 翻译则默认每批 10 条、最多 5 个并发请求。远端还可能使用常驻模型、GPU、连续批处理和提示词缓存，因此两条链路的等待时间差别很大；不能把 API 的速度直接等同于手机 CPU 的推理能力。服务端技术可参考 [vLLM](https://github.com/vllm-project/vllm) 与 [llama-server](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)。

当前优化保留一个推理实例，在任务内复用模型和提示词前缀，按原字幕编号处理 JSON 行。正常批次先快速生成，校验后提交；缺失、重复编号或无效译文只补译相应条目。能确定为格式问题的中文引号、全角逗号、额外样式标签和括号会先恢复，避免为标点再跑模型。缺失的源标签或占位符仍须补译。仅在正常结束且有明确行结束括号时恢复缺失的闭引号；取消或输出达到 token 限制时，不采用这种恢复。

真实模型测试发现，通用模型和专用翻译模型对提示词的反应不同。混元译为中文使用中文指令，Qwen 和其他方向使用明确的英文指令及完整语言名称，批量和单条补译均遵循此规则；单条补译采用短提示词，避免将背景说明翻进当前字幕。结构输出不对重复的 JSON 引号、括号施加重复惩罚。普通批次和首次缩批修复使用快速生成，连续格式失败后才启用约束，Android GPU 约束修复会先切换至 CPU。同一任务中，原文和前文完全相同的片段共用一次推理，字幕顺序、数量和时间轴不变。

| 平台 | 自动模式 | 兼容与设备限制 |
| --- | --- | --- |
| Android | CPU，自动最多 4 个线程 | 可手动尝试 Vulkan；保留运行库的驱动拒绝名单与微批次保护，不强制启用 GPU |
| iOS 16.4+ | 测速后按任务量选择 Metal / CPU | 模拟器保留运行库的 CPU 保护；自动 CPU 最多 4 个线程 |
| macOS 14+ | 测速后按任务量选择 Metal / CPU | 自动 CPU 最多 6 个线程 |
| Windows | 测速后选择 CPU / 独立进程 Vulkan | 播放器进程固定 CPU；GPU 模块只在独立工作进程目录中，加载失败、退出或超时后继续用 CPU；自动 CPU 最多 6 个线程 |
| Linux | 工作进程可用时测速选择 CPU / Vulkan | 与 Windows 共用隔离协议，缺少工作进程时保留 CPU；尚未真机验证；自动 CPU 最多 6 个线程 |

自动线程还受逻辑处理器数量的一半限制，至少 1 个；手动可选 1–8，且不超过可用处理器数量。CPU 是通用处理器，设备覆盖广；GPU 擅长并行矩阵计算，但显存、数据传输、驱动和首次内核编译都会影响收益，小模型不保证 GPU 更快。官方同样建议在真实设备上比较 CPU/GPU，见[性能调优文档](https://llamadart.leehack.com/docs/guides/performance-tuning)与[平台矩阵](https://llamadart.leehack.com/docs/platforms/support-matrix)。

2026-10-20 起，自动模式在有安全 GPU 路径且至少有 8 个待译片段时，使用首批真实字幕预热 CPU/GPU，再分别计时。测速期间禁用提示词前缀复用并固定随机种子，防止重复同一提示词使缓存命中误导结果；正常翻译仍复用前缀。分别记录持续翻译耗时与加载、首次编译的固定开销，再结合本次字幕量估算总耗时，预估差距不足 10% 时使用 CPU。少量字幕在没有历史测速时直接用 CPU，避免为了测速增加等待；“本机测速”可随时主动比较后端，使用内置示例而不改变手动设备偏好。

测速结果按模型版本、系统、架构、处理器数量、语言方向、线程、批次和 GPU 层数缓存 14 天，每个模型最多保留 16 组。更换显卡、驱动或功耗模式后可点“本机测速”刷新。结果是代表样本上的估计，实际耗时还受文本、温度和其他程序占用影响。GPU 译文必须通过与 CPU 相同的编号、目标语言、标签和占位符校验。GPU 失败后保留已完成字幕，自动模式暂不反复探测该配置；用户仍可手动重试。取消测速不会把设备记录为 GPU 故障。

设置参考了 [Jan 的引擎与模型参数组织](https://docs.jan.ai/desktop/local-engine/llama-cpp)以及 [llama.cpp 的设备、线程与批次选项](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)。模型中心保留自动 / CPU / 优先 GPU 与本机测速；进阶设置提供 CPU 线程、GPU 卸载层数和字幕批次。字幕每批条数属于应用层分组，与底层固定的 `n_batch` 不同。Hy、Qwen 分别保存设置，原有全局偏好作为迁移默认值。Android 的本机测速测试当前手动选择的后端并显示总耗时，自动模式仍使用 CPU；其他平台的测速比较 CPU/GPU。字幕任务继续由共享调度器管理。

桌面 GPU 工作进程为纯 Dart AOT 可执行文件，使用私有 stdin/stdout 管道，不监听网络端口。CMake 按 x64 / ARM64 目标架构编译，部署在 `resources/translation/`，与固定 ABI 的原生库一起打包；播放器目录不放 Vulkan 模块。Windows 的 Dart AOT 可执行文件需要与 SDK 主机架构一致，x64 SDK 交叉构建 ARM64 播放器时保留 CPU，不混入 x64 工作进程；原生 ARM64 SDK 构建时可启用对应工作进程。工作进程在连续 90 秒没有输出后终止并回退 CPU，正常长输出不受总时长限制。Windows 清理旧的根目录 Vulkan DLL，防止增量安装重新把驱动加载进播放器。Apple 继续使用原生 Metal，Android 保留 CPU 自动默认及手动 Vulkan 的驱动保护。

字幕进度显示已校验的完成条数、批内已生成条数、生成活动及实际使用的后端。修改默认性能设置不会改变已经冻结的任务配置。模型中心的本机检查会真实翻译两条字幕并显示后端与总耗时。

调研参考还包括 [Subtitle Edit 的批量字幕翻译](https://github.com/SubtitleEdit/subtitleedit/blob/main/docs/features/auto-translate-advanced.md) 和 [Hy-MT2 官方格式翻译说明](https://github.com/Tencent-Hunyuan/Hy-MT2)。官方另有体积更小的 1.25-bit GGUF，但涉及专用 STQ 内核；没有验证当前五平台二进制前，不将其当作 Q4 模型的直接替代。`maxParallelSequences` 主要面向嵌入与真正的多序列工作负载，不会自动让当前单次文本生成变为多句并行。

### 长字幕任务的耗时与失败恢复

1900 条字幕不能从 24 条短字幕的结果得到准确承诺。在 2026-10-20 的同机 GPU 样本中，Hy / Qwen 的 24 条总时间分别为 6.033 / 12.562 秒；直接按条数线性外推为约 478 / 994 秒。由于一项任务只加载一次模型，扣除每轮样本中 1.187 / 2.216 秒加载时间后再外推，约为 385 / 821 秒。这只是相同平均字幕长度、无补译、无争抢资源时的估计，尚未进行真实 1900 条语料的性能测量。每任务模型常驻只能节约数秒，无法独自消除几分钟的生成时间。

长任务现在会继续处理后续字幕，再集中补译经两次单条尝试仍不合格的片段。最终仍缺少译文时，明确报告已完成数与未完成字幕编号，保留有效断点，不把原文冒充译文、也不生成错误的“全部完成”结果。重试同一个任务仅处理缺失部分。连续三批完全没有有效译文则提前停止，避免模型始终输出无效内容却消耗整个长任务的时间。GPU 进程故障仍回退 CPU；可抛出的 CPU 推理异常每任务最多重载一次，取消、文件系统错误与格式校验失败不触发 CPU 重载。该机制无法恢复操作系统直接终止主进程的情况。

在 `model_jobs/translation-<任务摘要>.diagnostic.json` 保存最后一次运行的阶段、完成数、当前字幕编号、异常分类、GPU 子进程退出码（若可用）、恢复事件和耗时指标。记录不包含字幕原文、提示词、译文或原始异常消息。诊断写入失败不会覆盖翻译本身的异常。转录后本地翻译失败的任务提示现在展示安全分类及未完成数量，不再只显示“翻译未成功”。现有 1900 条故障注入回归使用模拟推理，验证流程与断点恢复，不代表真实模型吞吐或语义质量。用户旧版本的失败原因没有历史记录，不能仅凭“同时操作电脑”判断为 CPU 或 GPU 问题。

`tool/local_translation_format_benchmark.dart` 使用同一已打包 GPU worker、同一 24 条短字幕、两种格式交错运行两轮，评估减少输出包装的可行性。增加明确字幕边界后的 JSON / `编号|译文` 对比：Qwen 的生成词元由 275 降至 223–225，三批稳态时间由 8.65–8.67 秒降至 7.10–7.15 秒；Hy 却只有 17/24 条符合编号及目标文字检查。因此该实验格式没有启用为产品默认，不能把实验吞吐当成已交付提速，也不能把格式校验当作语义质量评测。两次实验报告为 `.artifacts/model-center/translation-framing{,-bounded}-20261020.json`。

本轮最终 100 项相关回归通过，9 项已有在线检查按条件跳过；Hy / Qwen 两项真实模型回归通过，静态分析通过。Windows Release 构建成功，按安装清单复制的独立包为 `.artifacts/model-center/windows-translation-long-task/`；播放器根目录没有 Vulkan 模块，子进程目录有匹配模块。本轮没有新增跨平台原生依赖，其他系统的真机长任务仍需分别验证。记录见 `.artifacts/model-center/translation-long-task-{final-regression,runtime,analysis,final-build,package-verification}-20261020.*`。

进一步值得评测的方向：真正共享模型权重的多序列解码、专用小型翻译模型、与主模型匹配的推测解码，以及按平台选择原生加速后端。[llama.cpp server](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md) 提供并行解码与 continuous batching；现有 `LlamaEngine.create` 单序列接口不能仅通过 `Future.wait` 自动获得同等效果。[Bergamot](https://github.com/browsermt/bergamot-translator) 是面向消费设备的 Marian NMT 引擎；[CTranslate2](https://opennmt.net/CTranslate2/parallel.html) 提供共享权重的并行处理，但其[预编译 GPU 后端](https://opennmt.net/CTranslate2/hardware_support.html) 面向 NVIDIA CUDA，不能作为所有设备的唯一实现。腾讯低比特 GGUF 依赖 [STQ 内核](https://github.com/Tencent-Hunyuan/Hy-MT2#llama_cpp)，也不能只换权重就假设现有各平台运行库兼容。上述方向均未作为本轮产品功能启用。

## 验证与复现

2026-10-20 的验证使用真实 Windows 桌面 runner、AOT Release 及随包工作进程，未设置 `LLAMADART_NATIVE_LIB_DIR`。在静音循环播放 H.264 视频的同时，每轮将相同的 24 条英文字幕译成简体中文，关闭译文断点复用，包含模型加载、推理、校验和保存时间。设备为 Intel Core Ultra X7 358H（16 个逻辑处理器）和 Intel Arc B390。

| 模型 | CPU 模式 | 测速后的自动模式 | 首次自动模式（含测速） |
| --- | --- | --- | --- |
| Hy-MT2-1.8B Q4_K_M | 11.045 秒 | 6.033 秒，Vulkan | 15.419 秒 |
| Qwen3-4B Q4_K_M | 24.881 秒 | 12.562 秒，Vulkan | 32.613 秒 |

后续自动任务直接复用测速，不再次跑 CPU/GPU 比较；首轮测速存在明确成本，不能把首次运行时间当成持续吞吐。独立的手动 GPU 轮次分别为 6.902 / 12.498 秒。本机两模型的持续翻译约快 1.8 / 2.0 倍，不能推算为所有设备的加速比。

两模型各覆盖首次自动、手动 CPU、手动 GPU、缓存自动以及真实 GPU 工作进程退出后继续翻译，共 10 轮、240 条字幕。主动退出发生在首批保存之后，两轮均由 CPU 完成剩余字幕，队列和模型租约释放；每个模型另验证 GPU 生成中取消及随后重新创建任务，取消释放耗时分别为 249 / 598 毫秒。播放器进程所有轮次均未加载 `ggml-vulkan.dll` / `igvk64.dll`，视频最后仍在正常播放。报告位于 `.artifacts/model-center/windows-translation-20261020.json`；打包模块分别在测试包根目录与 `resources/translation/` 验证。

相关回归累计覆盖 71 个独立用例，包括 69 项策略、存储、设置与界面用例及 2 项真实模型中英双向、标签、占位符、换行与原生取消测试；静态分析无问题。界面检查覆盖 320（文字放大 1.3 倍）、360、600、1440 像素，并实际操作设备、GPU 层数、线程和批次选择。Android arm64 Debug 构建通过；当前没有 Android、iOS、macOS、Linux 真机性能结果，不将 Windows 的速度或稳定性外推到这些设备。

当前 Windows 正式包输出到 `.artifacts/model-center/windows-translation-production/`，入口为 `video_player_app.exe`，没有覆盖旧程序目录。八项核心 llama 原生库在正式包、工作进程和验证包中的 SHA-256 一致；包内 Vulkan 仅位于工作进程目录，工作进程 PE 架构为 x64，见 `translation-20261020-production-verification.json`。Windows ARM64 交叉编译的 CPU 保护分支单独通过 CMake 检查，记录在 `translation-20261020-arm64-guard.log`，不等同于 ARM64 真机验证。常规 `flutter build windows` / `flutter build linux` 会由 CMake 自动生成并打包可用架构的工作进程。

以下保留 2026-10-19 的早期 CPU 提速与驱动故障记录，解释为何采用进程隔离。早期独立测试使用真实 Hy-MT2-1.8B Q4_K_M、同样的 24 条字幕：

| 配置 | 总耗时 | 相对原实现吞吐 |
| --- | --- | --- |
| 原实现，逐条、CPU 2 线程 | 23.346 秒 | 1.00 倍 |
| 新实现，批量、CPU 2 线程 | 19.092 秒 | 1.22 倍 |
| 新实现，批量、自动 CPU 预算（本机 6 线程） | 10.143 秒 | 2.30 倍 |
| 旧试验配置，批量、Vulkan（进程内路径已停用） | 5.625 秒 | 4.15 倍 |

这组样本来自 `flutter_tester`，均为 3 次批量生成、0 次补译。它们只代表独立测试进程中的吞吐，不能证明正式桌面程序的 GPU 稳定性。结果保存在 `.artifacts/model-center/translation-{baseline,final-cpu2,final-cpu,final-auto}.json`，包含输入、输出、进度时间以及前填充、解码、采样计时。数字受设备、模型、语言、文本长度及缓存状态影响，不能推算成所有设备的相同加速比。

2026-10-19 的实际 Windows Release 程序连续三次在 Intel Vulkan 驱动 `igvk64.dll` 32.0.101.8359 内发生 `0xc0000005`，Windows Application Error 1000 记录了同一模块与偏移 `0xa866d8`。这说明此前测试未覆盖正式桌面程序中的驱动故障。修复在进入原生库前强制 `ComputeDevice.cpu`，而不只是将 GPU 层数设为零；旧的 GPU 偏好也受到保护，设置页停用 Windows GPU 选项。Release 检查还发现旧构建目录残留的 `ggml-vulkan.dll` 可能在 CPU 推理时被运行库探测，因此 CPU 资源配置之外，CMake 安装步骤也会清理该过期 DLL；若旧应用仍锁住它，构建会报错，不输出一个误报成功的混合包。重新开放 GPU 之前需要进程隔离与实际驱动验证。上游也有 [Intel Vulkan 设备丢失报告](https://github.com/ggml-org/llama.cpp/issues/22034)，但不能据此认定同一修复适用于本机驱动。

2026-10-19 的 CPU 闪退修复另用真实 Windows 桌面 runner、AOT Release 和打包 DLL 验证，未设置 `LLAMADART_NATIVE_LIB_DIR`。静音循环播放本地 H.264 视频的同时，混元与 Qwen 各运行自动、CPU、历史 GPU 偏好三种设置，共六轮、144 条字幕，均完成并通过校验；取消后继续创建新任务也通过。六轮实际后端均为 CPU、GPU 层数为零，`GetModuleHandleW` 确认没有加载 `ggml-vulkan.dll` 或 `igvk64.dll`。混元每轮 24 条约 9.35–9.46 秒，Qwen 约 22.40–24.23 秒；两模型取消后分别约 193 / 483 毫秒释放推理队列和模型租约。视频在检查结束时仍正常播放。该结果只代表本机样本。

检查入口为 `tool/local_translation_desktop_smoke.dart`，使用 `TRANSLATION_SMOKE_ROOT`、`TRANSLATION_SMOKE_OUTPUT` 和可选 `TRANSLATION_SMOKE_VIDEO` 三个编译参数。原始证据位于 `.artifacts/model-center/windows-release-translation-smoke.json`；本次 73 项回归通过、12 项按条件跳过，静态分析通过。正式修复包位于 `.artifacts/model-center/windows-fixed-release/`，其十项核心原生库的哈希与测试包一致，包内无 Vulkan 后端；记录见 `windows-fixed-release-verification.json`。旧正式程序运行时无法覆盖其 EXE，因此该包输出到独立目录，需关闭旧程序后启动新包。iOS、macOS、Linux 与 Android 的真机稳定性尚未在本次验证。

此前独立进程中的混元与 Qwen 测试还覆盖了 HTML / ASS 标签、占位符、换行、术语、中英双向翻译及生成中的取消；两模型取消后释放队列约 0.3–0.6 秒。此类样本验证格式与链路，不替代大规模翻译质量评测。Windows、Android arm64 调试构建通过，APK 内确认存在 Vulkan 和唯一 ONNX Runtime，二者 ELF LOAD 段均为 16 KiB 对齐。布局覆盖 320（文字放大 1.3 倍）、360、600、1440 像素，包括性能设置的实际选择操作。

前一轮提速改造的 143 项相关回归测试通过，9 项按已有条件跳过；静态分析无问题。自动化测试覆盖批次编号、局部补译、取消续传、性能设置持久化、旧断点迁移（包括旧线程预算变更）、付费转录远端任务续查及五个平台的后端配置策略。复核日志位于 `.artifacts/model-center/translation-{analyze,final-regression,runtime-check,windows-build,android-build}.log`。

复现翻译基准（权重已下载时）：

```powershell
$env:LLAMADART_NATIVE_LIB_DIR = (Join-Path (Get-Location) 'build/native_assets/windows')
flutter test test/local_translation_benchmark_test.dart `
  --dart-define=TRANSLATION_BENCHMARK_ROOT=<绝对模型目录> `
  --dart-define=BENCHMARK_THREADS=0 --dart-define=BENCHMARK_ACCELERATION=auto
flutter test test/local_translation_runtime_test.dart `
  --dart-define=TRANSLATION_RUNTIME_ROOT=<绝对模型目录>
```

`BENCHMARK_ACCELERATION=cpu` 单独测 CPU，`BENCHMARK_THREADS=2` 固定线程，`BENCHMARK_BATCH_SIZE` 调批次，`BENCHMARK_MODEL=qwen3-4b-q4` 改模型。基准测试不会在普通测试中自动下载或运行大模型。

可选真实模型验证会下载约 4.5 GB 权重到忽略目录 `.artifacts/model-center/native`：

```powershell
python tool/download_model_smoke_assets.py --ids sensevoice-small-int8 dolphin-base-int8 parakeet-v3-int8 hy-mt2-1.8b-q4 qwen3-4b-q4
$env:LLAMADART_NATIVE_LIB_DIR = (Join-Path (Get-Location) 'build/native_assets/windows')
flutter test test/model_runtime_native_test.dart `
  --dart-define=MODEL_RUNTIME_ROOT=<绝对模型目录> `
  --dart-define=SHERPA_DLL=<Pub缓存中的sherpa-onnx-c-api.dll绝对路径> `
  --dart-define=ORT_DLL=<本工程windows/runtime/onnxruntime.dll绝对路径>
```

该测试验证真实 VAD、三种 ASR、取消、两种 GGUF 翻译，以及加载 ASR 后 OCR 仍有 DirectML / CPU provider。测试输出每个模型的加载与样本推理总耗时，不作为质量排名或跨设备基准。`LLAMADART_NATIVE_LIB_DIR` 用于 Flutter 测试，避免开发机的 Dart JIT 缓存与 Flutter 测试原生库目录不同；打包应用使用应用目录内的原生库。

生成页面预览：`flutter test test/model_center_test.dart --dart-define=MODEL_CENTER_PREVIEWS=true`，输出到 `.artifacts/model-center/`。

尚需有相应环境的实际验证：iOS / macOS 的 Xcode 构建与设备后台恢复、Linux 构建、Android 真机长时间处理与后台限制，以及用户自有付费账号的真实服务调用。本机没有这些设备或账号，模拟响应测试不能替代它们。现有 Apple 构建工作流可用于编译验证。

2026-10-20 的流式任务调度调整按阶段驻留内存决定本地识别、增强和翻译的并行与复用，修复重叠区后缀/前缀重复及同一说话人的时间交叠；旧任务续传冻结组装版本。实现、实模型对照和适用边界见 [本地字幕流式工作流](local-streaming-subtitles.md)。

## 参考与素材

用户提供的 `FLUTTER_LOCAL_ASR.md` 作为音频准备、VAD、原生推理、字幕链路分析参考；实际接口与行为以本工程代码及已核实的官方资料为准。

- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)：跨平台离线 ASR、VAD 和 Flutter 接入；模型来源参考 [SenseVoice](https://k2-fsa.github.io/sherpa/onnx/sense-voice/pretrained.html)、[Dolphin](https://k2-fsa.github.io/sherpa/onnx/Dolphin/pretrained.html)。
- [llamadart](https://github.com/leehack/llamadart)：GGUF Flutter 运行库与取消、线程配置；底层使用 [llama.cpp](https://github.com/ggml-org/llama.cpp)。
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp)：跨平台本地转录项目与公开 JFK 样本来源；[Buzz](https://github.com/chidiwilliams/buzz)、[Vibe](https://github.com/thewh1teagle/vibe) 可作为本地转录产品流程参考，未复制其代码。
- [腾讯云极速版接口](https://cloud.tencent.com/document/product/1093/52097)、[百炼临时上传](https://www.alibabacloud.com/help/en/model-studio/get-temporary-file-url)：鉴权、上传和任务协议来源。
- 内置 VAD 使用 [Silero VAD](https://github.com/snakers4/silero-vad) 模型，完整 MIT 许可放在 `assets/models/asr/NOTICE.txt`。
- 英语检查音频是 whisper.cpp 的 JFK 片段，原始文件版本 `b0a11594aec50892a02cd8d129eee2dfe93a8bb8`；SHA-256 为 `59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e`。中文检查音频为本应用编写的测试句，通过 Windows Huihui 系统语音生成；SHA-256 为 `1688bc98d470c40f9fc38a0875b39b32ead054e3fa8aafc4759737bdb640bd03`。
