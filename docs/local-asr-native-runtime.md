# 本地转录原生运行库兼容性

## 社区版转录恢复（2026-11-03）

社区版源代码不包含模型权重，原来的 VAD 资产读取因此失效。共享 VAD 改由 `asr_dependencies.json` 与现有下载队列准备，转录、模型检查和测速复用同一文件；原任务身份、模型版本、字幕和检查点保持不变。详细流程与复测命令见[模型集成](model-integration.md#社区版共享-vad-与按需准备)。

Android 15 真机还复现了 `ModelTaskService` 的 `ForegroundServiceDidNotStartInTimeException`：短下载完成后直接 `stopService()`，可能在服务提升到前台之前结束服务。现在在 `onCreate()` 及时显示前台通知，空闲状态通过同一服务的有序 intent 处理，并用 `stopSelfResult(startId)` 避免旧的空闲请求停止新的识别任务。继续保留原来的通知、暂停操作、唤醒锁释放、服务类型和系统超时处理；没有新增后台引擎或自动重启。平台依据见 [前台服务异常](https://developer.android.com/develop/background-work/services/fgs/troubleshooting)和 [Service.stopSelfResult](https://developer.android.com/reference/android/app/Service#stopSelfResult(int))。

本轮真实 CPU 测试在 Windows x64 与 Android 15 / API 35（23046RP50C）通过：SenseVoice Small、Dolphin Base 经生产队列安装固定权重和 VAD，完成短中文音频识别、时间轴检查、重复识别、取消后的资源释放，以及重建服务后的检查点恢复。Android 额外通过 8 轮快速下载/推理启停，未再发生上述前台服务崩溃。Windows 另通过 VAD 的模型中心真实推理检查。Android 使用独立 profile 包、临时测试数据及维护者本机提供的固定权重，不涉及用户媒体或完整版数据。

上述结果验证这两个模型的 CPU 路径；本轮没有验收其他模型的真实推理、GPU 后端或 iOS/macOS/Linux 实机。全部模型仍共用修复后的依赖准备入口，其他平台仍需对应原生环境检查，不能把通过编译或通用回归当作实机推理。

2026-10-20。适用固定的 `sherpa_onnx` 及五端 companion 1.12.12、`onnxruntime_v2` 1.23.2+2。

## Android：OrtGetApiBase 加载失败

实际 APK 中的依赖关系是：

| 文件 | ELF 符号版本 |
| --- | --- |
| `libsherpa-onnx-c-api.so` | 导入 `OrtGetApiBase@VERS_1.17.1` |
| OCR Maven AAR 的 `libonnxruntime.so` | 导出 `OrtGetApiBase@@VERS_1.23.2` |

原先构建直接移除了 sherpa 自带的 ORT 1.17.1，以共用 OCR 的 ORT 1.23.2。C API 的 `GetApi(17)` 向后兼容不代表 ELF 版本标签相同。Android API 23 起按版本解析符号，因此在打开语音库时就会失败，还未开始读取识别模型。

修复位于 `android/build.gradle` 和 `tool/rebind_sherpa_onnx.dart`：

- 对每个构建变体读取应用实际解析到的 `onnxruntime-android` AAR。
- 在构建目录生成 sherpa 库副本，保留 OCR/对齐使用的新运行库。
- 校验 ELF32/ELF64、CPU 架构、ORT 版本，以及唯一需要重新绑定的导入确实为稳定入口 `OrtGetApiBase`。
- 修改副本中该导入的版本字符串和 ELF 版本哈希，与 AAR 的实际导出一致。机器指令、模型、Dart/C 结构体布局不变，Pub 缓存不变。
- 遇到未知的 sherpa 版本、额外 ORT 导入、缺失导出或不兼容架构时构建失败，需要重新审核，避免静默产生不可运行的安装包。

这里继续保留新 ORT 的另一个原因是：默认普通话 CTC 对齐权重采用 ONNX IR 10，不能通过统一降到 ORT 1.17.1 解决。

回归测试覆盖四种 Android ABI 的真实 companion 二进制、ELF32/64、版本哈希、重复执行、架构不匹配及不支持的导入/版本：

```text
flutter test --no-pub test/sherpa_onnx_linkage_test.dart
flutter build apk --release --target-platform android-arm64
```

测试、分析和发布构建串行执行。测试后发布构建保留默认的依赖/插件准备步骤，使生成的插件注册文件与 release 排除开发依赖的规则一致。

安装修复后的新 APK 才会替换原生库；热重载不能更新 APK 内的 `.so`。此错误不需要重新下载模型。

## 其他平台

| 平台 | 核查与处理 |
| --- | --- |
| Windows | 不使用 Android 的 ELF 版本标签。现有 DirectML 运行库及 sherpa 加载逻辑保留；真实 SenseVoice、Dolphin、Parakeet 识别、分句、取消及 OCR 运行库共存测试通过 |
| Linux x64 | sherpa 依赖 `libonnxruntime.so`，其 SONAME 同名；直接 FFI 使用 `libonnxruntime.so.1.22.0`，SONAME 为 `libonnxruntime.so.1`。保留两套各自匹配的库 |
| Linux ARM64 | 插件原来在此架构也打包 x64 的直接 FFI 运行库。`linux/cmake/onnxruntime_arch.cmake` 改为选择微软官方 aarch64 1.22.0 CPU 发布包，固定 SHA-256、检查 ELF 架构并携带许可；继续保留 sherpa 自带的 ORT |
| macOS | 核对两套库都包含 Intel 和 Apple Silicon slice；sherpa 的依赖名为 `libonnxruntime.1.17.1.dylib`，直接 FFI 使用 `libonnxruntime.1.21.0.dylib`，没有 Android 的同名替换 |
| iOS | 核对 sherpa 是包含自身 ORT 的动态 framework，并提供设备和模拟器 slice；OCR 的 ORT 由独立 CocoaPods 依赖提供。未发现 Android 的删除/替换步骤 |

Linux ARM64 首次配置需要下载约 6.53 MiB 的官方归档，后续复用构建缓存。固定 SHA-256 为 `bb76395092d150b52c7092dc6b8f2fe4d80f0f3bf0416d2f269193e347e24702`。

本次在 Windows 开发机完成 Android 构建/二进制检查、Linux x64/ARM64 的独立 CMake 配置与架构选择检查，以及 Windows 原生推理回归。开发机没有已连接的 Android 设备，也没有可运行的 iOS、macOS、Linux 环境，因此这些平台的完整音频转录真机测试仍需执行。静态依赖核查不能替代真机测试。

相关回归共 80 项通过（6 项链接测试、73 项模型/增强/字幕生命周期测试、1 项真实 Windows ASR/OCR 测试），Dart 静态分析通过。Windows 原生测试使用 `ASR_RUNTIME_ONLY=true`，允许独立验证识别；原混合探针的翻译阶段在当前 Flutter 测试宿主中出现 `llama_model_load_from_file_impl: no backends are loaded`，因此这里不宣称本次验证了翻译模型。该探针的完整模式仍保留。

最终 Android arm64 release APK 构建成功，包内 `OrtGetApiBase` 导入/导出的版本和 ELF 哈希均一致（`VERS_1.23.2` / `0x027bf382`）；两份 sherpa 库的 `.text` 与上游原文件相同。APK v2 签名校验通过。交付文件为 `build/app/outputs/flutter-apk/FluentPlayer-asr-runtime-fix-20261020-arm64.apk`，SHA-256：`913313659e0133e04436a0798f85b721d42c4b298350062d302c57c6cfe50759`。本次本地详细记录保存在 `.artifacts/asr-native-audit/apk-verification.json` 和 `linux-packaging-verification.json`。

上游依据：[Android 原生链接器的符号版本规则](https://android.googlesource.com/platform/bionic/+/master/android-changes-for-ndk-developers.md#symbol-versioning-available-in-api-level-23)、[ORT 1.23.2 的版本标签生成代码](https://github.com/microsoft/onnxruntime/blob/v1.23.2/tools/ci_build/gen_def.py)、[ORT 的 GetApi 接口](https://onnxruntime.ai/docs/api/c/struct_ort_api_base.html)、[微软 ORT 1.22.0 发布](https://github.com/microsoft/onnxruntime/releases/tag/v1.22.0)。
