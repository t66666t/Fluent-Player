# 存储布局与覆盖升级

本次调整采用“兼容优先、按需整理”。用户的数据目录、旧文件和下载记录不会因为新增目录名称而被清空。新下载分来源保存；旧任务使用登记的实际位置。程序身份、系统偏好设置位置和安全存储身份保持不变。

## 默认布局

```text
数据根/
  downloads/{bilibili,douyin,web,yt_dlp}/
    files/                 下载成品
    tasks/                 持久续传和合并工作文件
  imported_media/          新导入音视频副本
  podcasts/               播客索引、离线节目、文稿
  cloud_drive_material/   网盘素材及续传数据
  cloud_drive_subtitles/  网盘字幕副本
  subtitles/              已保存字幕成果
  artwork/                共享封面仓库
  thumbnails/             缩略图
  exports/composed/       默认合成成果
```

Windows 新安装通过系统 Known Folder API 取得 LocalAppData，使用 `FluentPlayer/VideoPlayerData`；macOS 使用应用 Application Support；Linux 使用应用 XDG 数据目录并兼容历史目录。三个桌面端均可在“大文件数据目录”中切换位置。

Android 使用应用私有的持久文件目录。iOS 使用 Application Support；用户原件及生成成果放 Documents。下载目录单独设置排除备份属性，其他用户成果和索引不整体排除。移动端导出继续使用系统分享、文件选择器和已有媒体导出功能。Android FileProvider 同时支持私有 `files` 和 Flutter `app_flutter` 目录。

用户已设置的数据根继续有效。本机现有设置 `D:\Fluent Player\VideoPlayerData` 不需要改动。旧的 `imported_videos` 是共享导入目录，不能直接整体重命名为 B站目录。

## 社区版存储空间管理

社区版保留按需扫描、逻辑字节计数、路径去重、快照复用和删除前定向核对。此次调整只补充用途/来源规则与展示，不改变目录遍历、系统空间检测、任务恢复或社区版独立数据根。

社区版的来源入口为本地媒体、RSS 播客、应用数据、共享资源和其他来源。若社区版自己的已知目录内存在保留的旧来源文件，显示“历史来源文件”，仅查看和管理现存文件；不提供 B 站、网盘、网页下载器的活动入口，也不启用相关服务或读取完整版目录。附加来源只在存在相应文件时显示。

筛选同时控制十进制/二进制容量、文件数、分类、缓存清理、外部原文件和明细页清理后的列表。共享资源可出现在多个来源中，但“全部”只计一次。用途分为媒体与保存的成果、缓存与工作文件、导出/模型/应用数据、需要核实的文件四组；组内保留详细分类与容量排序。模型分类使用“本地模型”，处理素材不显示网盘功能说明。窄屏使用横向分布条，桌面使用环形图；Android 系统对照始终表示整个应用。

- “清理此范围缓存”只处理策略确认为可重建且当前可删除的文件。播客离线节目、字幕、导出包、未关联媒体、无法确认可重建的封面和模型不参与普通缓存清理。
- 可删除的成果需确认，确认框列出文件数、容量和用途；播客离线节目、字幕、续传数据保留独立操作。没有可用删除操作的资源不会计入“需确认删除”。
- Agent 设置、权限与操作日志归入配置与任务记录；媒体处理工作目录归入处理临时文件，由所属功能管理。未知文件保留待核实状态。
- 搜索后的操作仅作用于匹配文件；回收站入口和移入回收站操作只出现在对应媒体分类。删除确认期间不提前显示正在清理。

设计参考了 [Spotify 对缓存和离线下载的区分](https://support.spotify.com/sg-en/article/storage-information/) 及 [Plex 对已完成下载容量、数量和独立删除操作的展示](https://support.plex.tv/articles/download-ios-android/)，并保留社区版的本地媒体、字幕、模型与 RSS 播客边界。

分类与清理边界见 `test/storage_classification_test.dart`；来源计数见 `test/storage_presentation_test.dart`；社区版入口见 `test/storage_edition_policy_test.dart`；交互与布局见 `test/storage_management_screen_test.dart`。另运行 `python tool/verify_community_project.py` 检查社区版功能和数据身份边界。

## 接管和路径兼容

`AppStorageService` 是目录入口，`StorageLocations` 将平台 API 与可测试逻辑分开。稳定支持目录中的 `storage/layout.json` 登记数据根、元数据位置、历史根、实际任务记录位置和迁移映射；设置与密钥仍由原来的系统偏好和安全存储管理。

启动严格等待设置、目录接管和媒体库读取完成，再允许播放器恢复和下载任务工作。优先使用已登记根，其次旧配置和唯一可确认的旧媒体库。多个独立媒体库并存时要求用户选择；已登记磁盘离线、索引缺失或损坏时进入恢复页，不写入空媒体库覆盖旧记录。

旧网页 `web_media_downloads/queue_v2/index.json`、抖音 `douyin_downloads/tasks.json` 和旧元数据目录继续读取。Cookie 迁移目录、yt-dlp Cookie、AI 会话、批量导入和转写记录也参与元数据位置识别。播客、封面、网盘素材可登记独立历史根；后台播客任务每次重新解析目录，而不是依赖旧容器的绝对路径。

本地路径在原绝对路径字段之外附加 `_storagePaths`，内容为字段名到 `{rootId, relativePath}` 的映射。公共编解码器只处理声明的路径字段、字幕路径映射和路径列表；标题、来源网址、远端 ID 和 `content://` 不做全局替换。旧字段仍可读取，iOS 容器 UUID 变化时重新定位。转移多次的路径映射可继续追踪到最新位置。

应用管理文件与外部原件有明确边界。尤其是历史 Documents 根，只搬应用已知目录及明确登记的资源，不把整个 Documents 目录视为软件所有。

## 整理、迁移与中断恢复

`StorageMigrationCoordinator` 先取得迁移锁，通过 `StorageParticipant` 停止下载准入、确认原生下载暂停、落盘并关闭数据库，再复制和校验文件。正在进行的导入、转写、OCR、合成和设备同步会阻止迁移，避免中途终止用户任务。索引切换完成或维护阶段失败后，通过重启重新打开各服务。

迁移检查空间、源目标包含关系、链接和目标中的独立媒体库。它保留原件，并以 SHA-256 校验复制结果；提交前再次检查源文件，发现其他程序写入会停止。SQLite 由参与者关闭后复制，包括必要辅助文件，并检查数据库完整性。JSON 写入保留最后一个可读备份。

`storage/migration.json` 记录复制阶段、来源、目标和校验值；`storage/migration-backups/` 保留关键记录。提交之前失败时旧目录仍为有效根，同一目标可重试已有副本。若目标被其他程序修改，拒绝覆盖。不同内容的同名媒体使用稳定后缀，原有目标文件保持完整。

“整理旧文件”按已有来源信息将可确认的 B站文件归入 B站下载目录，普通或来源不明确的导入资源归入 `imported_media`。旧副本默认保留，迁移证据和仍可恢复的任务受存储清理保护。用户可在确认新版本使用正常后，通过文件管理器另行管理这些保留副本。

B站旧缓存续传文件在继续任务时校验复制到持久工作目录；移动端 yt-dlp 同时识别旧缓存和新的持久工作目录。抖音保留任务和完成文件；原本需要重新解析的过期链接不会被描述为可直接续传。

## Windows Release 构建保护

使用：

```powershell
.\scripts\build_windows_release.ps1
# 只做保护快照：
.\scripts\build_windows_release.ps1 -BackupOnly
```

脚本正常关闭本项目中占用目标 EXE 的实例，拒绝强制终止；备份关键记录和构建输出中的应用数据。外部大媒体登记路径和大小，不重复全量备份。快照默认放在 LocalAppData 的 `FluentPlayer/BuildBackups`，不在 `build` 中。脚本核对与上次构建的应用身份，构建后验证已登记文件，失败时保留快照。

程序不再将新数据默认写入 EXE 旁。旧数据位于构建输出或程序包内时，启动阶段先以相同的保留原件流程接管到稳定默认位置。发布时只分发程序资源，不打包个人快照、历史 `VideoPlayerData` 或用户媒体。不要通过卸载、清除数据或更换应用签名完成覆盖更新。

## 验证入口与边界

`test/fixtures/storage_upgrade/historical_libraries.json` 是根据 `release`、`v0.4.4`、`v0.5.1` 的真实存储键及 schema 制作的最小脱敏样本，并非用户数据库。测试覆盖加载、再次保存和重启后的条目 ID、文件夹、播放进度与字幕。

```text
flutter test test/app_storage_upgrade_test.dart
flutter test integration_test/storage_platform_upgrade_test.dart -d windows
flutter test integration_test/storage_platform_upgrade_test.dart -d macos
flutter test integration_test/storage_platform_upgrade_test.dart -d linux
flutter test integration_test/storage_platform_upgrade_test.dart -d <移动端设备ID>
```

原生测试使用独立探测目录，避免修改实际媒体库。GitHub 的 `Storage upgrade compatibility` 工作流在 Windows、macOS 和 Linux 执行兼容测试。平台真实安装覆盖升级、系统文件授权以及 Android/iOS 的签名和系统行为仍需要对应设备验收；桌面上的平台策略测试不代表移动设备实测。

卸载、系统“清除数据”、原文件被手动删除和磁盘损坏需要备份恢复，不属于保留原数据的覆盖升级。
