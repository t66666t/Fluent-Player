# 云端转录验证记录

核对及执行环境：2026-10-31，Windows 宿主，项目现有 Flutter / Dart、FFmpeg 和原生运行库；没有五家真实厂商账号及可用收费 Key。本文明确区分契约、本机网络和厂商在线转录。

## 官方依据

| 厂家 | 文档与适配点 |
| --- | --- |
| ElevenLabs | [文件转录参数与响应](https://elevenlabs.io/docs/api-reference/speech-to-text/convert)、[语言及文件限制](https://elevenlabs.io/docs/overview/capabilities/speech-to-text)、[删除 transcript](https://elevenlabs.io/docs/api-reference/speech-to-text/delete)；词 / 字符数组的可选字段同时核对官方 [Python 类型定义](https://github.com/elevenlabs/elevenlabs-python/blob/main/src/elevenlabs/types/speech_to_text_word_response_model.py) |
| Soniox | [模型清单](https://docs.soniox.com/api-reference/stt/get_models)、[文件转录](https://docs.soniox.com/stt/async/async-transcription)、[上下文](https://docs.soniox.com/stt/concepts/context)、[时间戳](https://docs.soniox.com/stt/concepts/timestamps)；只选异步文件模型，按毫秒处理 token |
| AssemblyAI | [上传文件](https://www.assemblyai.com/docs/api-reference/files/upload)、[创建转录](https://www.assemblyai.com/docs/api-reference/transcripts/submit)、[语言支持](https://www.assemblyai.com/docs/pre-recorded-audio/supported-languages)、[模型选择](https://www.assemblyai.com/docs/pre-recorded-audio/select-the-speech-model)；显式 `speech_models`，不增加未选模型的自动回退 |
| Deepgram | [文件转录](https://developers.deepgram.com/reference/speech-to-text/listen-pre-recorded)、[模型枚举](https://developers.deepgram.com/reference/manage/models/list)、[多语识别](https://developers.deepgram.com/docs/multilingual-code-switching)、[术语参数和总 token 限制](https://developers.deepgram.com/docs/keyterm)、[语言检测与自动更换型号的关系](https://developers.deepgram.com/docs/language-detection)；未知型号不假定支持多语，也不启用隐式模型回退 |
| Google | [Transcribe 参数、功能互斥与 `word_info` 样例](https://ai.google.dev/gemini-api/docs/transcribe)、[Files API](https://ai.google.dev/gemini-api/docs/files)、[Interactions 的提交 / 查询 / 删除](https://ai.google.dev/api/interactions-api)、[Models API](https://ai.google.dev/api/models) |

内置模型 ID 以本次核对版本为准，服务仍可能改变模型权限、配额、别名或协议。后续刷新只发现同协议的新型号，不会自动改变用户选择。模型接口没有列出某个专用型号，不代表它不存在；也不能仅凭名字或列表查询成功判定字幕支持和付费权限。

## 验证方法与边界

新增测试使用本机真实 HTTP 服务检查上传字节和请求编码，而不是只检查组装前的对象。响应为按官方约定独立构造的小型样例，包括未知字段；这些测试不属于厂商在线识别。

- 五家契约：鉴权、multipart 和二进制、重复热词参数、模型和语言参数、Google Files 会话与 Interactions、秒 / 毫秒 / Duration、Unicode、子词、字符时间、声音事件、空输入、全文无时间轴、未知结构和安全错误消息。
- 模型更新：新增型号、Google 分页、实时模型过滤、缺失元数据、24 小时缓存过期、列表失败、手动模型 ID、账号缓存隔离及冻结任务。旧服务 JSON 不新增云端字段。
- 本机网络：设备代理与自定义代理、HTTP / HTTPS CONNECT、证书拒绝、连续三次请求复用一个连接、线路切换保持在途提交、取消隔离、代理失败不直连、发送超时与处理等待分离。
- 分段：虚拟长媒体的 10 分钟与更严格上限、文件大小边界、必要转码 / 拆分、重叠计入长度、乱序完成立即保存、连续发布、真实词边界去重、静音及原时间偏移、错误后的断点恢复和临时文件所有权。
- 生产流程：实际 `ModelTranscriptionRunner` 使用本机服务中断后恢复原任务；`TranscriptionManager` 接入原增量字幕和本地翻译流程，暂停后沿用冻结配置。真实 FFmpeg 转码输出另用 ffprobe 检查 MP3 / 16 kHz / 单声道 / 64 kbps，生产准备流程只做一次源信息探测。

另用真实 FFmpeg 构造“三秒视频、音轨延迟两秒开始”的文件，检查转码后的 PCM：前 1.7 秒接近静音，2.2–2.8 秒保留测试声。修复前普通提取仅得到约一秒音频，修复后保留完整三秒时钟；这些检查只在开发验证中解码，不增加生产输出扫描。

实际执行命令、结果及日志在本记录末尾登记。`test/fixtures/local_model_compatibility.json` 保留原基线，未重新生成。

## 厂商在线验证状态

| 厂家 | 契约及本机服务 | 厂商在线转录 |
| --- | --- | --- |
| ElevenLabs | 使用真实本机 HTTP 请求验证 | 未实测，无真实账号 / Key |
| Soniox | 使用真实本机 HTTP 请求验证，包括恢复原任务 | 未实测，无真实账号 / Key |
| AssemblyAI | 使用真实本机 HTTP 请求验证，包括恢复原任务 | 未实测，无真实账号 / Key |
| Deepgram | 使用真实本机 HTTP 请求验证 | 未实测，无真实账号 / Key |
| Google | 使用真实本机 HTTP 请求验证，核对官方 Duration 时间注释 | 未实测，无真实账号 / Key |

因此不能声称已验证真实语音识别质量、五家付费账号开通情况、各地区外网线路或所有平台的代理实现。真实账号的最后一步是由用户手动执行样本检查，再用代表性的中 / 英 / 混合语言及长媒体验证费用和质量。没有自动发送收费样本，没有下载模型或运行库来补齐验证。

## 本次执行记录（Windows）

| 检查 | 实际结果 | 本机日志 |
| --- | --- | --- |
| 受影响代码与模型集成静态分析 | 107 个分析条目，无问题 | `.artifacts/cloud-asr/completed/analysis.log` |
| 完整 Flutter 兼容回归 | 1017 项通过，3 项跳过 | `.artifacts/cloud-asr/completed/regression.log` |
| 本机网络及既有网络回归分组 | 42 项通过；包含 HTTP / TLS、HTTP / HTTPS / SOCKS5 代理、复用和线路切换 | `.artifacts/cloud-asr/network-regression.log` |
| 云端任务与真实音频准备分组 | 4 项通过；含 MP3 参数、源信息仅探测一次、两秒音轨延迟、暂停恢复与翻译 | `.artifacts/cloud-asr/audio-preparation.log` |
| 既有 Windows 本地 ASR / 翻译原生回归 | 7 项通过；使用已经准备好的模型权重和原生运行库，实际执行识别与转录翻译流程 | `.artifacts/cloud-asr/final/native.log`、`native-results.json` |

完整检查入口为 `python tool/verify_model_integration.py --output .artifacts/cloud-asr/completed`；原生检查另执行 `python tool/verify_model_integration.py --native --output .artifacts/cloud-asr/final`。分组检查与完整回归存在重叠，不把各行数量相加作为测试总数。

`test/fixtures/local_model_compatibility.json` 与修改前基线逐字节一致，SHA-256 为 `43d6d5b1f223131a50db1693ee7ae632e254835834e17146d5041857e82bd2e0`。本次没有替换本地模型、权重或运行库。

以上原生结果仅适用于本机 Windows；Android、iOS、macOS、Linux 的原生设备流程没有因此获得实测结论。五家厂商的在线语音识别仍全部为“未实测”。
