# Fluent Player 标准开源版构建与发布

当前应用版本为 `1.0.0`，根目录 `pubspec.yaml` 为 `1.0.0+3`。只有用户明确要求时才调整应用版本号或构建号；改名、换图标、功能开发或修复均不自动升级版本。

此目录是独立社区项目。完整版的 GitHub Release 上传工作流和下载器打包脚本不适用于这里；此项目没有自动发布任务。

1. 安装与 pubspec.lock 相容的 Flutter SDK、Python 及目标平台构建工具。
2. 执行 flutter pub get，然后执行 python tool/verify_community_project.py。所需的开源字体随源码提供，不需要额外准备 MiSans。
3. 运行 README 和 docs/community-verification.md 中记录的检查。
4. 按 docs/model-integration.md 准备需要的原生组件。权重仍通过现有模型中心按需取得，不放进源码仓库。
5. Windows 额外运行 python tool/prepare_release_assets.py --platform windows，准备独立媒体工具及 ONNX Runtime；此脚本不获取下载器。
6. 分别使用 flutter build windows、flutter build apk、flutter build macos、flutter build ios 或 flutter build linux。各平台需要对应主机、SDK 和签名；Windows 主机上的 Dart 测试不能代替这些构建及安装验收。

   Windows Release 构建后，运行独立社区版打包器：

   ```powershell
   python tool/package_windows_release.py --iscc "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
   ```

   命令按 CMake 安装与运行库清单收集文件，校验应用身份、版本、VC 运行库和原生依赖，在 `dist/windows/` 生成社区版 ZIP、安装器及校验清单；只在本机打包，不安装或自动发布。
   尚未安装 Inno Setup 时，可先运行 `python tool/package_windows_release.py --stage-only`；该模式保留相同的应用身份、版本和原生依赖校验，只生成隔离的运行目录，不生成 ZIP、安装器或发布清单。

7. Android 使用 `cn.teezy.fluentplayer.standard` 与本项目独立签名；Pro 版使用 `cn.teezy.fluentplayer.pro`，两个版本可同时安装并隔离应用私有数据。不要复制完整版密钥。
   FileProvider authority 随 `${applicationId}` 自动生成；内部 Kotlin/JNI namespace 与跨平台通道名称保留。
8. 分发安装包前，按 docs/release-materials.md 提供实际使用组件的许可、匹配源码与构建材料。核实后手动发布，不上传 build 缓存、权重、用户文件或密钥。

## 当前 Pro / 标准版名称与服务身份

| 项目 | Fluent Player（本标准开源版） | Fluent Player Pro |
| --- | --- | --- |
| 平台应用身份 | `cn.teezy.fluentplayer.standard` | `cn.teezy.fluentplayer.pro` |
| 发布附件前缀 | `FluentPlayer-` | `FluentPlayerPro-` |
| Windows 入口 | `fluent-player.exe` | `fluent-player-pro.exe` |
| Apple 产品 | `Fluent Player.app` | `Fluent Player Pro.app` |
| Linux 命令 | `fluent-player` | `fluent-player-pro` |
| MCP 配置名称 | `fluent_player` | `fluent_player_pro` |
| MCP HTTP 默认端口 | `38462` | `38461` |
| 同步 HTTP 默认端口 | `47793` | `47791` |
| 同步 UDP 监听端口 | `47794` | `47792` |

本项目的产物均以 `FluentPlayer-v版本-平台-架构` 开头，例如 `FluentPlayer-v1.0.0-windows-x64-setup.exe`、`FluentPlayer-v1.0.0-android-arm64.apk`，与发布清单和安装器一致。旧 `FluentPlayerCommunity-` 前缀仅属于先前方案；不要将旧附件改个名字冒充本轮构建。

两版 Apple 产品名已不同，可同时放入 Applications。Windows 安装、快捷方式、通知、偏好和凭据按版本隔离。同步发现向固定的两个 UDP 端口广播，原配对确认与信任规则保留；应用身份切换不自动删除旧数据或合并其他安装的设置。

构建前执行 `python tool/verify_application_identity.py` 与 `python tool/verify_community_project.py`，再运行平台打包及隔离回归。配置检查、模拟打包、实际构建、签名和目标机安装属于不同验收阶段；本轮实际结果以后续日志为准，以下历史记录不能代替本轮验收。正式分发仍须提供实际原生组件的许可、对应源码、签名及目标设备检查。

## 历史记录：2026-11-06 前一轮同名方案

> 以下旧名称、ID、附件前缀及测试统计属于前一轮方案，不是当前 Pro / 标准版的安装或验收结论。


Android / iOS / macOS / Linux / Windows 的应用显示名称均为 **Fluent Player**，
平台安装身份统一为 `cn.teezy.fluentplayer.community`，与完整版分开。
Windows 使用 `fluent-player.exe`，Apple 使用 `Fluent Player.app`，
Linux 使用 `fluent-player-community`；技术目标名遵循各平台工具链规则，无需下划线。
内部 Dart/JNI/通道名及原版权声明保留，未更改模型契约与旧文件。
Windows 的公司字段 Teezy Community、安装目录与开始菜单组区分版本；
上一轮两版同名 .app 当时需要不同安装子目录；当前不同产品名已消除该限制。

先运行 `python tool/verify_application_identity.py` 和 `python tool/verify_community_project.py`。
本轮 Windows x64 Release、Android arm64 Debug 已实际构建，APK label/ID/Provider 核验通过；
Apple 配置及打包空格路径、Linux 启动器/打包、Windows 严格清单与依赖回归通过。
未在 Windows 主机上执行 Apple/Linux 原生构建、Apple 签名/公证或真机推理；
本机未安装 Inno Setup，本轮不声称已生成或验收 Windows setup。
旧自动发布工具已退役，其5项专属测试显式跳过，其余元数据/Android/Apple测试仍执行。

公开项目及下载地址为 [t66666t/Fluent-Player](https://github.com/t66666t/Fluent-Player/releases)。
2026-11-06 经 GitHub 官方 API 检查，仓库公开但没有已发布 Release；本轮未推送或发布安装包。
附件前缀保持 `FluentPlayerCommunity-...`，与打包清单、安装器和下载示例一致。
分发之前仍须完成实际原生组件的对应源码、许可、签名和目标设备验证。

Windows 最终实测：增量Release通过，严格收集306份文件；153个原生二进制依赖检查通过。无调用者的ANGLE调试zlib从运行清单排除，ASR子目录补齐官方CRT。15项Windows打包回归及18项数据目录/外部AI回归通过。未生成新setup/ZIP，未安装或发布。

## 当前 Pro / 标准版更名验收（2026-11-06）

本轮标准版为 Fluent Player / cn.teezy.fluentplayer.standard，Pro 为 Fluent Player Pro / cn.teezy.fluentplayer.pro。
两版 Windows x64 Release 和 Android arm64 Debug 均实际构建成功；实际 APK 的显示名、包名、启动入口、5 个 Provider 和图标像素均核对通过。
标准版图标保留原图；Pro 图标为用户最终选定的白底、原版蓝色弧线、右下角 PRO 图，未继续重绘。
MCP 的 fluent_player / fluent_player_pro 配置在两种安装顺序下均共存，不覆盖旧连接或另一版本的凭据；同步 TCP/UDP 默认端口独立且本机同时绑定及收包测试通过。
社区同步过滤退役网盘来源，同时保留原条目、历史来源、进度和原文件，本地/RSS 同步服务29项通过。
Windows 安装目录不继承旧路径，对方 runner 或无法核验的现有程序会在文件覆盖前被拒绝；本机没有运行 Inno Setup 编译或安装。
Apple/Linux 配置、路径及打包回归通过，但本轮没有原生构建、签名/公证或真机播放/模型推理验收。原有依赖与发布门槛保留，未推送或发布。
本仓库构建及实际身份报告见 .artifacts/edition-pro-20261106/。
