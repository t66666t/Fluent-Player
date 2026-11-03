# 发布材料与源码交付

本文保留项目已有的第三方材料记录；构建与上传步骤见 [构建与发布](releasing.md)。

## 必须同时提供的材料

二进制包应附带 `LICENSE`、`NOTICE`、`THIRD_PARTY_NOTICES.md`、`PRIVACY.md` 和 `assets/licenses/`、`assets/fonts/licenses/` 中相应的许可。应用设置中已有开源许可和隐私说明入口。原生 ASR 与 UnRAR 工具的自有桥接代码采用 MIT；DirectML 二进制保留微软条款，UnRAR 保留其解压用途限制。Windows 默认仅打包独立 UnRAR 工具，不打包 UnRAR FFI DLL。

应用源码可导出：

```sh
python tool/package_release_source.py --output .artifacts/releases/fluent-player-application-source.zip
```

此 ZIP 包含当前工作区的应用源代码与可公开资源，不包含 Git 历史、签名密钥、MiSans 原字体和平台预编译输入。`source-snapshot.json` 记录每个文件及分开准备的输入的哈希。它只解决应用自身源码交付，不能替代下面的第三方对应源码。

分发 GPL 原生二进制时，还须将匹配该构建的第三方源码及必要补丁、配置和构建脚本放在同一发布页，或提供符合 GPL 的等效源码下载方式。发布说明需明确下载入口，源码应在二进制可下载期间持续可用。不能只写一个上游首页或“需要源码请联系作者”。依据：[GNU GPL FAQ](https://www.gnu.org/licenses/gpl-faq.html#SourceAndBinaryOnDifferentSites)。

本次已保留以下来源和材料，但**尚未收齐、验证全部预编译原生组件的完整对应源码，正式二进制发布前仍需完成这一项**：

| 分发组件 | 当前匹配记录 | 对应源码交付仍需核实 |
| --- | --- | --- |
| Windows FFmpeg / FFprobe | Gyan 8.0.1；FFmpeg 提交 `894da5ca7d`；配置和外部库版本见 `FFmpeg-Windows-build.txt` | 同构建外部依赖源码、补丁和构建配置；其中 publisher 记录仍有 `openal-soft latest`，不能自行编造精确版本 |
| Windows libmpv | media_kit_libs_windows_video 1.0.11；构建 2023-09-24，mpv 提交 `652a1dd`；许可已随应用提供 | 该构建的 FFmpeg 及全部相关依赖源码与脚本 |
| FFmpegKit | Dart 包 4.6.2；平台脚本引用 Full GPL 8.1.2；本机 Windows 构建还受 `FFMPEGKIT_LOCAL_DIR` 覆盖，实际本地库报告 FFmpeg `n7.1.1`、GPLv3+；保留 GPL/LGPL 文本和源仓库 | 各目标平台预编译包与 sk3llo/ffmpeg-kit 中实际构建提交、依赖和补丁的对应关系；Windows 本地 bundle 的完整构建材料也需补齐，不能拿 CLI 的 FFmpeg 8.0.1 源码代替 |
| yt-dlp 独立包 | 2026.10.21，官方 SHA-256 和第三方声明已固定 | 按官方 ThirdPartyNotices 为打包依赖准备匹配源码，不能只提供 yt-dlp 自身 Python 文件 |

这个缺口不能通过新增一个 GPL 文件消除。收齐前可继续内部测试和审阅应用源代码，不能把本记录描述成“所有版权义务已履行”。

## 发布范围

`.artifacts/` 已从当前 Git 索引取消跟踪，文件仍保留在本机。本机 AI 对话导出和提取脚本也已移至工程外备份并取消跟踪。MiSans 原 OTF 和 OPPO 字体不再属于当前源码发布范围；旧字体选择迁移到 Noto。历史提交不会因此自动改写，旧版本中的字体分发仍需按原授权和既有公开范围处理。不要使用上传脚本强推覆盖共创者的历史。

完成对应源码交付与平台验收后，再在固定提交上打标签、上传源码和二进制、记录哈希与验证结果。不要将临时目录、开发签名包或工作区中的旧运行数据一起上传。
