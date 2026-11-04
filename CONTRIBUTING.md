# 参与贡献

项目自有应用代码采用 GPL-3.0-or-later。提交贡献时，请确认你有权按此许可提供改动；其他作者的代码、字体、图片与模型必须保留原始版权、许可、来源版本和修改记录。没有要求转让你的版权。

先阅读 [README](README.md) 的构建说明和 [构建与发布指南](docs/releasing.md)，运行 `python tool/prepare_release_assets.py`，再执行 `flutter pub get`。字体和平台运行时由固定来源与校验值准备；不要把 `.artifacts/`、构建目录、账号数据或密钥提交到 Git。

提交前运行 `flutter analyze --no-pub` 和 `flutter test --no-pub`；涉及本地插件时分别分析 `packages/app_network/lib` 与 `packages/ios_ytdlp/lib`。Python 运行时改动先执行 `python tool/prepare_ios_runtime.py --packages-only`，再运行 `python -B -m unittest discover -s test -p '*_test.py'`。涉及原生播放、后台任务和系统权限时，请注明实际验证的平台。

改动说明应写明具体问题、解决后的行为和验证结果。注释说明当前代码的规则与原因；未来方案放到 issue 或文档，不在已实现逻辑旁保留互相矛盾的推演。保留第三方版权头，不能靠删除署名解决授权问题。

媒体库和播放服务较大，发布修复优先保持边界稳定。新增功能沿用既有的状态、任务和存储服务，按需逐步提取模块，避免同时进行大范围结构调整。应用 ID、数据目录与既有签名关系到用户升级，请随改动提供迁移和回归说明。

缺陷、提议与许可材料问题通过 README 中的仓库 Issues 反馈。请使用有权分享的样例，并移除 Cookie、令牌、API 密钥及私人内容。
