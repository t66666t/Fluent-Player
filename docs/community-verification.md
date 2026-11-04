# 社区版本地媒体验证记录

日期：2026-11-03。验证主机：Windows x64。

## 当前范围

社区版现专注本地视频、音频、字幕与学习，主界面仅保留“继续学习／文件夹／最近添加”。官方/网页播放器、浏览器、网盘和播客联网入口已经退出。旧入口设置回到本地页面，旧远程播放和任务不能恢复，不自动跳转浏览器。

“批量字幕导入”使用仓库现有的 `BatchImportScreen`，已恢复侧栏、导入菜单、更多菜单和媒体库 `M` 快捷键；文件夹上下文保留。没有从外部项目复制实现。

本地播放器、字幕、转录/OCR、翻译、AI 学习、本地合成/导出和设备同步保留。历史来源信息不赋予联网获取权限，也不应阻止已有本地文件的正常操作。模型目录、模型身份、默认项及兼容性基线未修改。

## 验证方式

- 源码边界：`python tool/verify_community_project.py` 检查本地执行与恢复入口、停用下载器、退役网页依赖、批量字幕入口、社区版身份和三份模型契约哈希。
- Flutter 模拟/文件测试：验证本地导航、菜单、不同屏幕和文字缩放、键盘/输入法、旧设置迁移、剪贴板不监听、远程处理拒绝、本地进度/字幕、文件导入和导出。平台策略测试不是对应平台真机验收。
- 模型集成：`python tool/verify_model_integration.py`，使用现有模型/任务/检查点/字幕/OCR 回归；不下载权重或执行新的原生推理。
- 正常主入口构建：Android arm64 Debug、Windows x64 Debug。构建不等于真机播放、推理或发布版验证；不安装、卸载、推送或发布。

## 最终检查结果

- `python tool/verify_community_project.py`：通过。三份模型契约文件与现有兼容性基线保持一致。
- `python tool/verify_model_integration.py`：专项分析无问题，回归 **1228 项通过、3 项跳过**。日志：`.artifacts/model-integration/analysis.log`、`regression.log`。包括本地转录、获授权云服务、任务恢复、OCR、逐词字幕、合成资源占用与本地来源导出。
- 全量 `lib` 静态分析：**0 个编译错误、129 个警告、44 个信息提示**；未使用的历史兼容成员等诊断保留，不称为零诊断。日志：`.artifacts/local-only-analysis.log`。
- 本地播放/导航/恢复/引导/目录/持久化/合成/字幕位置组合：**117 项通过**，日志：`.artifacts/local-media-regression.log`。
- 搜索/输入法/网络设置/根页面滑动与预热：**103 项通过**；设置/操作菜单/帮助/硬件键盘：**97 项通过、1 项既有跳过**；历史来源的本地列表/卡片/文件操作/字幕入口/导出界面：**71 项通过**。这些分组与模型回归有交集，不相加为总数。
- 导出计划和往返：**21 项通过**；额外 ZIP/运行时/来源组合：**15 项通过**，包含该 Windows 主机真实 FFmpeg 的 MP4/MKV/MKA 与 SRT/ASS 重封装。日志：`.artifacts/local-only-export-final.log`、`local-only-export-run.log`。这不代表其他设备编码或 GPU 能力实测。
- 播客拒绝执行、兼容解析、本地 iOS 导入布局与混合转录：**57 项通过**。Android SAF、本地路径及音频封面专项也通过。它们是本机模拟/文件测试，不是 Apple/Android 真机验收。
- Android arm64 正常 `main.dart` Debug 构建通过。APK 只读身份预检确认 `com.example.video_player_app.community`；包内 58 份 arm64 原生库，未发现 WebView 库、包或资源。可选 ASR NNAPI 组件缺失的既有提示仍存在，保留 CPU 路径；未把它列为加速推理通过。日志：`.artifacts/local-only-android-main-debug-build.log`、`local-only-android-apk-audit.json`。
- Windows x64 正常 `main.dart` Debug 构建通过（152.1 秒）；最终 Debug 目录没有 WebView DLL/资源，重新生成的 Debug/Release 运行时清单及安装清单均无 WebView 项。日志：`.artifacts/local-only-windows-main-debug-build.log`、`local-only-windows-output-audit.json`。本轮只验证 Debug 构建，没有宣称 Release 构建通过。

原生构建仅用于本机审阅，没有安装、卸载、自动推送或发布。当前源码依赖图与五个平台插件注册表均无 WebView；未编译的历史第三方 Windows 补丁仍保留其许可和修改记录。

## 退役记录与发布边界

此前文档中的官方播放器/WebView/RSS 成功记录属于已移除的功能，不作为当前支持项。退役清单与替代测试见 [本地版功能退役清单](community-local-only-retirement.json)。纯解析器、历史数据类型和未参与编译的第三方 Windows 插件补丁可保留为兼容源码；它们不能重新启用媒体获取。

本轮没有下载或替换模型权重，也没有验证新的原生模型推理。Apple 平台、Linux 和物理设备上的播放效果需在对应环境继续验证。分发原生二进制前仍按 [发布材料](release-materials.md) 准备实际构建对应的许可证、源码、补丁和配置，Debug 构建通过不表示分发材料已齐备。
