# 社区版分离验证记录

日期：2026-11-03。验证主机：Windows x64。

## 已完成

- 使用现有缓存执行 flutter pub get --offline；唯一移除的 Flutter 依赖为 ios_ytdlp，没有升级其余依赖。
- python tool/verify_community_project.py：通过。检查下载器/嗅探实现与原生入口、应用/数据身份、条件导入、字体文件及三份原有模型契约文件。
- dart analyze --format machine --no-fatal-warnings lib：没有编译错误。仍有 125 项 unused_field/unused_element 警告及 44 项信息提示，主要来自停用功能的兼容层；不把此结果称为零诊断。
- 下列 5 个 Flutter 测试文件，共 45 项通过，单进程运行；其中实际引入 main.dart 编译应用的 Dart 依赖图。

```sh
flutter test --no-pub --concurrency=1 --reporter expanded test/community_media_boundary_test.dart test/library_persistence_recovery_test.dart test/video_compose_encoding_test.dart test/subtitle_position_controller_test.dart test/model_integration_test.dart
```

覆盖：下载接口拒绝执行与安全生命周期、本地路径允许/远程素材拒绝、轻量字体兼容、媒体库保存恢复、字幕拖动、合成编码选择与失败回退、模型清单及原有任务/续传契约。

## 验证范围

没有构建或安装五个平台的完整应用，未连接真实付费账号或执行网站下载；合成测试使用受控命令执行器，不能作为真实设备编码、播放速度或 GPU 可用性的证明。

未下载或复制模型权重，未进行真实模型推理，未测试原生 ASR/OCR 扩展或测量应用运行内存。安装包需要的原生输入须在对应构建主机准备。

这是独立源码工程，没有配置远程 Git 地址，没有发布 GitHub 仓库或安装包；也没有完成完整版的闭源依赖替换。
