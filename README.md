# Fluent Player Community（独立开源版）

此项目从完整版独立分出，采用 GPL-3.0-or-later。这里是单独维护的 Flutter 项目，不依赖私有项目路径或 Git 历史。

## 功能范围

保留本地媒体播放、媒体库、字幕/文稿、转录、OCR、翻译、AI 学习及本地文件合成/导出。
移除网站媒体下载与解析入口、抖音提取、yt-dlp 运行时和浏览器嗅探/AES 提取实现；相关旧数据接口仅保留拒绝执行的兼容层。
网盘/平台媒体的完整离线缓存及转录/合成素材下载也停用，本地导入仍可使用。模型资源下载、字幕数据请求及正常播放缓冲保留。

## 体积和构建

源码不附带模型权重、各平台构建缓存、预编译原生库、下载器或签名密钥。保留模型清单、固定版本及构建脚本。
默认仅包含一款 OFL 中文界面字体及少量小字体。MiSans、思源宋体和狮尾圆体名称兼容回退到思源黑体；可通过现有字体导入/在线字体库补充其他字体。

```sh
flutter pub get
python tool/verify_community_project.py
python tool/verify_model_integration.py
flutter analyze --no-pub
```

Windows 的独立 FFmpeg/ONNX 输入可显式执行 `python tool/prepare_release_assets.py --platform windows` 准备。
ASR/OCR/翻译原生扩展按 `docs/model-integration.md` 构建；模型权重沿用模型中心按需获取。缺少原生构建输入时，源码静态检查通过不代表该原生能力可以运行。
Android 需要自己的发布签名，不复制完整版密钥；使用独立 applicationId。其他平台同样采用独立应用身份和数据目录。

## 维护与发布

这里独立开发，不自动覆盖完整版或反向覆盖其源文件。详见 AGENTS.md。
分发安装包前仍须准备对应 GPL/LGPL 原生组件的匹配源码、构建配置和许可证，见 docs/release-materials.md。
没有自动创建 GitHub 仓库、推送、发布安装包或更改完整版许可。
