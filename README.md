# Fluent Player Community（独立开源版）

此项目从完整版独立分出，采用 GPL-3.0-or-later。这里是单独维护的 Flutter 项目，不依赖私有项目路径或 Git 历史。

## 功能范围

社区版专注**本地媒体播放与学习**，沿用现有播放器和媒体库布局。

- 本地视频、音频、媒体库、播放进度、横竖屏播放和快捷键。
- 字幕/文稿、笔记、转录、OCR、翻译和 AI 学习。
- “批量字幕导入”已恢复，可从侧栏、导入菜单或更多菜单进入，批量选择媒体及对应字幕；从文件夹打开时保留导入目标。
- 本地文件合成、导出、分享、打开文件位置和设备同步。

主界面只保留“继续学习／文件夹／最近添加”。哔哩哔哩、YouTube、网页在线播放、内置浏览器、网盘和播客订阅入口已退出社区版；不监听或识别网站剪贴板链接。旧在线播放及下载任务不会自动恢复，也不会自动跳转浏览器。已有本地文件、字幕、笔记、进度和历史来源信息保留，本机文件按普通本地媒体使用。

网站媒体直链提取、抖音下载、yt-dlp、网页嗅探与 AES 密钥提取保持移除。模型/字体资源获取、用户配置的获授权转录/翻译/AI 服务、更新检查和用户启用的设备同步继续保留；未确认服务授权的预设“公益 ASR”停用。详见 [隐私与联网说明](PRIVACY.md)。帮助及 AI 回复中的参考链接仅在用户主动点击时交给系统查看，不作为媒体播放入口。

优先检查 Android、Windows，本地播放器继续保留 iOS、macOS、Linux 支持。每轮实际验证的平台与限制见 [社区版验证记录](docs/community-verification.md)。源码不依赖 WebView/WebView2/WPE；未参与构建的历史 Windows 插件补丁保留在第三方目录中。

## 体积和构建

源码不附带模型权重、各平台构建缓存、预编译原生库、下载器或签名密钥。保留模型清单、固定版本及构建脚本。
默认仅包含一款 OFL 中文界面字体及少量小字体。MiSans、思源宋体和狮尾圆体名称兼容回退到思源黑体；可通过现有字体导入/在线字体库补充其他字体。

```sh
flutter pub get
python tool/verify_community_project.py
python tool/verify_model_integration.py
flutter analyze --no-pub
```

网络安全测试需要本机 OpenSSL；测试会临时生成证书和密钥，并在结束后清理。Windows 上也可使用 Git for Windows 自带的 OpenSSL。

Windows 的独立 FFmpeg/ONNX 输入可显式执行 `python tool/prepare_release_assets.py --platform windows` 准备。
ASR/OCR/翻译原生扩展按 `docs/model-integration.md` 构建；模型权重沿用模型中心按需获取。缺少原生构建输入时，源码静态检查通过不代表该原生能力可以运行。
Android 需要自己的发布签名，不复制完整版密钥；使用独立 applicationId。其他平台同样采用独立应用身份和数据目录。

### Android / Windows release

首次在构建主机生成社区版专用密钥（把参数替换为本机 JDK 的 keytool）：

```powershell
python tool/create_community_signing.py --keytool "D:/Android Studio/jbr/bin/keytool.exe"
```

密钥和配置仅保存在忽略目录 `.artifacts/community-signing/`，重复运行不会覆盖。请单独安全备份整个目录，后续社区版更新继续使用这份签名。Gradle 优先使用本机 `android/key.properties`，否则读取上述社区版配置。社区版包名为 `com.example.video_player_app.community`，可与标准版同时安装。

源码不附带原生制品。首次构建须执行 `python tool/prepare_release_assets.py --platform windows`，并按 `docs/model-integration.md`、`docs/qwen-asr-integration.md`、`docs/asr-models-2026.md` 重建对应平台组件。`native/**/prebuilt/manifest.json` 是制品收据，存在清单但缺失文件会使构建失败；不能修改哈希绕过检查。Qwen 构建需要 Rust 1.88+，Android 使用项目指定的 NDK。

```powershell
flutter build apk --release --target-platform android-arm64
flutter build windows --release
```

APK 位于 `build/app/outputs/flutter-apk/app-release.apk`；Windows 须交付完整的 `build/windows/x64/runner/Release/`。Windows 社区版安装脚本使用独立安装目录、卸载 ID 和快捷方式身份，不覆盖标准版。

## 维护与发布

这里独立开发，不自动覆盖完整版或反向覆盖其源文件。详见 AGENTS.md。
分发安装包前仍须准备对应 GPL/LGPL 原生组件的匹配源码、构建配置和许可证，见 docs/release-materials.md。
没有自动创建 GitHub 仓库、推送、发布安装包或更改完整版许可。
