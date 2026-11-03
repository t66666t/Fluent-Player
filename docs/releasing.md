# 开源版构建与发布

此目录是独立社区项目。完整版的 GitHub Release 上传工作流和下载器打包脚本不适用于这里；此项目没有自动发布任务。

1. 安装与 pubspec.lock 相容的 Flutter SDK、Python 及目标平台构建工具。
2. 执行 flutter pub get，然后执行 python tool/verify_community_project.py。
3. 运行 README 和 docs/community-verification.md 中记录的检查。
4. 按 docs/model-integration.md 准备需要的原生组件。权重仍通过现有模型中心按需取得，不放进源码仓库。
5. Windows 额外运行 python tool/prepare_release_assets.py --platform windows，准备独立媒体工具及 ONNX Runtime；此脚本不获取下载器。
6. 分别使用 flutter build windows、flutter build apk、flutter build macos、flutter build ios 或 flutter build linux。各平台需要对应主机、SDK 和签名；Windows 主机上的 Dart 测试不能代替这些构建及安装验收。
7. Android 使用本项目自己的 applicationId 与签名；不要复制完整版密钥，也不要尝试覆盖安装完整版。
8. 分发安装包前，按 docs/release-materials.md 提供实际使用组件的许可、匹配源码与构建材料。核实后手动发布，不上传 build 缓存、权重、用户文件或密钥。
