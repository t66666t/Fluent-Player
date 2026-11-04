# 安装与升级

[项目首页](../README.md) · [使用手册](user-guide.md)

从 [项目 Releases](https://github.com/t66666t/Video-master/releases) 下载。先看版本说明，再选择与系统和 CPU 架构对应的附件。预发布版本会标注 Pre-release；Draft 是维护者尚未公开的草稿。

## Windows

通常选择 `FluentPlayer-v版本-windows-x64-setup.exe`，按安装器提示完成安装。默认安装到当前用户的应用目录，可创建开始菜单和桌面快捷方式。

不需要安装器时选择 `windows-x64-portable.zip`，解压整个目录，运行 `video_player_app.exe`。不要只复制 EXE，`data`、DLL、`resources` 等文件也是程序的一部分。这里的 portable 指免安装目录包，不表示所有用户数据都存放在该目录。

当前面向 Windows 10 / 11 x64。网页功能需要 WebView2 Runtime；遇到提示时，从 Microsoft 官方渠道安装。发布流程暂未配置可信代码签名证书，安装器可能显示未知发布者，请核对下载来源与校验值。

## Android

选择 `android-arm64.apk`。当前最低 Android 7.0，只提供 ARM64 包；32 位设备和 x86 模拟器不在发布范围内。

按照系统提示允许浏览器或文件管理器安装应用。已有用户应直接覆盖安装，保留应用数据。若系统提示签名冲突，不要急于卸载：先确认下载的版本是否使用同一发布签名，并备份媒体库。卸载会影响应用私有数据。

## macOS

最低 macOS 14。`universal` 包包含 Intel 与 Apple 芯片共同需要的架构；如果文件名只写 `arm64` 或 `x64`，请选择对应机器。

打开 DMG，把 `fluent_player.app` 拖入 Applications。也可解压 ZIP 后将 `.app` 移入 Applications。

当前流程使用 ad-hoc 签名，尚未配置 Apple Developer ID 公证。若系统拦截，请先确认来源和校验值，再按照系统“隐私与安全”页面的提示处理。若提示文件损坏，先重新下载并核对校验值；不要直接关闭系统安全保护。不同 macOS 版本的操作以 [Apple 官方说明](https://support.apple.com/102445) 为准。

## iPhone / iPad

最低 iOS / iPadOS 16.4。`ios-arm64-unsigned.ipa` 是未签名应用包，不能像 APK 一样直接安装，也不是 App Store 或 TestFlight 链接。使用前需要自己的有效签名与相应安装方式。

## Linux

源码中的打包流程分别面向 Ubuntu 22.04 / 24.04、Debian 12 / 13，当前架构为 x64。请选择文件名中与系统一致的发行版；一个 DEB 不保证适用于其他发行版。RPM、musl 与 ARM64 需要各自的构建和验证。

现有 v1.0.0 Release 的旧 Linux 包尚未替换，已知有跨发行版依赖问题。下面介绍修正后的打包约定，不能当作旧包已修复或新包已验收。

推荐使用 DEB，并通过 APT 安装依赖：

```sh
sudo apt install ./FluentPlayer-v版本-linux-x64-debian-13.deb
```

安装后从应用菜单打开 Fluent Player，也可执行 `fluent-player`。

`.tar.gz` 同样标注发行版。完整解压后执行 `./fluent-player.sh`；可运行 `./install-desktop.sh` 添加当前用户的菜单入口。请保留整个目录，添加入口后不要移动它。包内包含匹配的 libmpv、依赖树、FFmpeg、ffprobe 和说明文件，系统仍提供 libc、C++ 与显卡驱动；这不是脱离宿主系统的静态程序。

媒体探测和合成优先使用包内 `bin/ffmpeg` / `bin/ffprobe`。文件选择使用 GTK 原生窗口，无需 portal 文件选择器。网页功能仍需安装 Chrome / Chromium；账号安全存储需要用户 D-Bus 会话和桌面密钥环。声卡、显卡与软渲染说明见 [Linux 播放说明](LINUX_PLAYBACK_NOTE.md)。

## 升级前

- 保留原应用 ID 和 Android 签名，不需要为更新先卸载旧版。
- 备份媒体库以及不能重新下载的文件；本地文件若只是被引用，导出配置不等于备份了原文件。
- ZIP / 目录包请解压到新目录，不要把新旧运行库混在一起。若曾把用户数据放在旧程序目录，先按 [存储迁移说明](storage-upgrade.md) 迁移。
- 预发布版本用于测试。降级前先看对应版本说明，不保证新版本写入的数据能被旧版本完整读取。

## 检查下载文件

正式汇总包提供 `SHA256SUMS.txt`。Windows 可使用：

```powershell
Get-FileHash .\FluentPlayer-v版本-windows-x64-setup.exe -Algorithm SHA256
```

Linux 在附件所在目录执行 `sha256sum -c SHA256SUMS.txt`；macOS 可执行 `shasum -a 256 文件名`。只下载了其中一个平台时，核对该文件对应的那一行即可。

校验值用于检查文件完整性；它不能替代开发者签名和可信下载来源。
