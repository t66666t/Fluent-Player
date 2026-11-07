# Windows 发布前问题修复记录 2026年10月31日

本轮修复 [Windows 审计](../docs/windows-release-audit-20261031.md) 中确认的 W01 至 W06，并在回归中确认、修复另两项问题。保留工作区原有改动、模型 ID、权重、任务和兼容性基线，没有升级 FFmpeg 版本。修复代码与测试已写入工作区；原有 dist 安装包和 ZIP 尚未替换。

## 修复内容

| 问题 | 修复方式 |
| --- | --- |
| W01 正常关窗原生崩溃 | FFmpeg 停止日志消费线程后再卸载；执行任务改由插件管理，取消等待有界，不响应的任务由独立回收器等待真正退出后释放 DLL。WebView 的视图、通道、合成器与 DispatcherQueue 在引擎仍有效时显式清理，异步创建回调使用生存期守卫；COM 覆盖窗口与引擎析构。统一清理同时覆盖 WM_DESTROY 与消息循环先退出的 C++ 析构路径。 |
| W02 缺少 Windows 运行库 | 打包从官方 VS Redist 完整复制 VC 运行库到主程序及独立组件目录。检查普通与延迟导入，不再从开发机 System32 借用 VC／第三方依赖。固定且无引用的 ANGLE Debug zlib 从 stage 排除，实际使用的 zlib1 保留。 |
| W03 最后字幕修改丢失 | 编辑器关闭、切换分组、销毁前提交捕获的草稿；移除播放页会丢弃的第二层写入定时器。保存绑定媒体和文档，按库串行写入，外部原件生成可复用编辑副本。写入使用完整临时文件再替换，保留词级时间轴。Windows 正常关窗先等当前草稿和库保留的失败文档完成，失败时保留窗口提示；同文档新编辑淘汰旧失败回调，避免退出把新内容回滚。 |
| W04 Windows 下载路径参数损坏 | 使用 Windows CRT 参数引用规则，正确处理空参数、引号及其前后的连续反斜杠、根目录、空格、中文和 UNC 路径。 |
| W05 完成校验时暂停卡住 | 下载退出后的文件校验有独立归属，暂停／取消／删除停止其对应探测，迟到结果不能提交到新代次。继续时只重做本地校验。新增可选任务标记仅在 true 时写入，缺失字段的旧任务仍按原行为解析。已入库原件不因取消重新校验被删除。 |
| W06 B 站下载来源未随目录迁移 | 将 bilibiliDownloadPath 接入统一路径编码与还原；旧库无路径引用时也沿用迁移别名恢复，覆盖连续迁移与重启。 |
| W07 小窗口键盘弹出后字体面板溢出 | 仅字幕样式工具在键盘出现时为面板腾出更多空间；字体选择器在极矮区域内让搜索、工具栏与字体列表共同滚动，保留正常窗口布局、字体筛选和滚动条。 |
| W08 B 站起播超时后重试状态错误 | 先把来源会话标为失败，再触发外层预算的取消清理。避免网关释放同步把会话变成 cancelled，使 hasFailed 与专用重试入口失效。没有增加等待或延长超时。 |

FFmpeg 补丁使用项目内的 `third_party/ffmpeg_kit_flutter_new`，仍为 4.6.2；相对本轮修复前的工作区，依赖锁只把这一包的来源从 hosted 改为本地 path。Windows 补丁说明见 [FFmpeg PATCHES](../third_party/ffmpeg_kit_flutter_new/PATCHES.md) 和 [WebView PATCHES](../third_party/flutter_inappwebview_windows/PATCHES.md)。其他平台源码和许可证保留。

## 复现与验证

测试分组有重叠，不把计数相加为独立覆盖数。

| 检查 | 结果与范围 |
| --- | --- |
| FFmpeg 卸载因果对照 | 独立进程中直接加载／卸载旧行为 5 次崩溃；停止并 join 日志消费线程后 5 次正常。 |
| 真实 Windows 退出 | 前期 FFmpeg／合成器修复版本正常关窗 10/10、加载 WebView 后关窗 3/3 exit 0。新增通道和析构路径保护后另测：加载后关窗 2/2、创建中关窗 1/1、延迟 100 毫秒保存字幕后关窗 1/1 exit 0。没有用强杀或直接 exit 绕过清理。 |
| 原生任务生命周期故障注入 | 短任务完成回调、长任务运行中关闭、故意 8 秒不响应取消均通过。最后一组在窗口销毁后让测试进程继续存活，确认任务返回后才卸载 DLL。这组使用专用测试 DLL，不能当成真实编解码推理。 |
| Windows 参数解析 | 11 组参数经过 CommandLineToArgvW 和真实 CreateProcess 子进程验证，全部通过。 |
| 运行库依赖与实际加载 | 170 个二进制的普通／延迟依赖闭包通过；旧三份 CRT 的对照加载失败、完整 CRT 加载成功；根／OCR／ASR 的 ORT 及 EGL、GLES、mpv、翻译运行库实际加载通过。 |
| 存储与 yt-dlp 分组 | 106 项通过，含新增迁移恢复与下载校验／暂停／取消／删除／重启／迟到结果保护。 |
| 字幕保存、整窗退出与键盘 | 最终分组 74 项通过，含 16 项保存、10 项退出草稿、2 项窗口接线、真实库重启与已有键盘／默认布局检查。另一个较早的 33 项分组还包括列表组件隔离。 |
| 真实媒体库字幕集成 | 1 项通过：真实文件与 LibraryService 登记、重复编辑复用、外部 ASS 逐字节不变、落盘重启后的主字幕／asset ID／词级时间恢复。 |
| 模型接入标准入口 | 1017 项通过、3 项跳过，相关静态分析通过。兼容性基线没有修改。 |
| Python 完整测试 | 87 项通过。 |
| 修改涉及的 Dart 入口 | 最终 22 个入口静态分析无问题；原测试替身的无效 override 已修正。全项目仍有原有 info 级提示。 |
| 全项目静态分析 | 无 error／warning，仍有 11 项已有 info；使用 --no-fatal-infos 返回 0，不把默认规则下的 info 当作已消除。见 [全项目分析](../build/release-fixes-20261031/analyze-complete.log)。 |
| 扩展播放分组 | 最终 168 项全部通过，含原生媒体合成、播放恢复与请求竞争、起播、质量切换、传输同步、字幕保存及键盘；首次 162 通过／4 失败的日志保留，见下一节。 |
| 小窗口字体与默认键盘布局 | 修复后 45 项通过，保留原面板高度、视频高度、键盘边界及 widget identity 断言，新增真实滚动到“使用”按钮并点击选字体验证；原在线字体滚动条另 3 项通过。 |
| B 站质量切换与起播截止 | 原整文件 46 项全部通过，原 250 毫秒超时及断言保持不变。 |

主要证据目录为 [build/release-fixes-20261031](../build/release-fixes-20261031)。可直接查看 [字幕与退出最终回归](../build/release-fixes-20261031/subtitle-exit-final.log)、[真实库与文件重启测试](../build/release-fixes-20261031/subtitle-library-native-io.log)、[存储与下载回归](../build/release-fixes-20261031/storage-ytdlp-regressions.log)、[模型标准检查](../build/release-fixes-20261031/model-integration.log)、[运行库实际加载](../build/release-fixes-20261031/windows-dependency-validation.json)。

合并全部修复的普通 `lib/main.dart` Windows Release 已构建并核对正式插件注册表，不包含 integration_test 开发插件；没有用正式入口启动用户数据。原生修复、真实库／测试 DLL 的边界与源码哈希见 [原生修复收据](../build/release-fixes-20261031/windows-native-fixes.json)。另外将这一正式 AOT 和已修复 DLL 组成全新验证目录，补齐 CRT 后通过依赖闭包及独立翻译 worker 启动、通信、正常退出检查，见 [组合包检查](../build/release-fixes-20261031/combined-package-validation.json)。该目录用于内部验收，尚未替换正式 dist 安装包，也不是“所有发布检查已通过”的结论。

最终验证目录为 [combined-windows-package-final](../build/release-fixes-20261031/combined-windows-package-final)，不是较早的 `combined-windows-package` 或 `windows-package-after`。正式构建耗时 203.2 秒，1281 份源码与独立构建快照一致；最终 stage 的 EXE、FFmpeg 插件、WebView 插件与 AOT 均核对匹配正式构建指纹。模型推理没有在这一启动与通信检查中执行。

新正式测试包括 [字幕保存](../test/subtitle_editor_persistence_test.dart)、[退出草稿顺序](../test/subtitle_window_exit_test.dart)、[窗口等待与失败保留](../test/windows_subtitle_exit_guard_test.dart)、[真实字幕库重启](../test/subtitle_editor_library_integration_test.dart)、[下载校验生命周期](../test/yt_dlp_desktop_verification_test.dart)，迁移和打包检查补入原有测试文件。修改前副本与哈希也保留在证据目录。最终扩展播放日志见 [168 项回归](../build/release-fixes-20261031/playback-regressions-final.log)，相关源码分析见 [22 个入口检查](../build/release-fixes-20261031/changed-analysis-complete.log)。

退出修复中的可失败对照同样保留：通道注销最初放在插件析构内，实测 messenger 已进入 shutdown；只在 OnDestroy 提前清理仍遗漏 window_manager.destroy 的 PostQuitMessage 路径。最终由派生类析构与 OnDestroy 共用幂等 ShutdownEngine，在 controller 成员析构之前清理。因此新版 runner EXE 和 WebView DLL 需配套更新，不能只替换其中一个。

## 扩展回归发现与剩余检查

首次扩展分组的四个失败进一步定位为两类真实问题，修复后的分项与重新组合的 168 项分组均已通过：

1. `bilibili_quality_handoff_test.dart` 的起播截止场景实际失败的是 `context.hasFailed`，并非先前怀疑的遮罩撤下；诊断确认遮罩一直保留，旧判断撤回。两项相邻测试即可稳定复现：外层预算取消同步释放网关，把尚未 fail 的来源上下文变成 cancelled。W08 调整顺序后原整文件 46 项全部通过。见 [修复收据](../build/release-fixes-20261031/bilibili-deadline-fix-receipt.json)。
2. 修正 `portrait_subtitle_style_settings_test.dart` 测试替身缺少 audioQualityId 的编译错误后，320×568 小窗口的 Android／iOS／Windows 模拟布局暴露真实 RenderFlex 溢出，并非单纯任意高度断言。W07 修复后原 9 项、默认布局 36 项及滚动条 3 项通过；原高度要求没有降低。见 [布局修复说明](../build/release-fixes-20261031/portrait-font-fix.md)。

原审计中其余过时 fixture、布局断言与设置导出分类问题，没有在这轮全部处理。完整 Flutter 套件也没有在修复后重新取得全部通过的结果。外部字幕在磁盘故障后重试保存成功时，编辑副本可在字幕库查看；不会为自动采用旧分组而覆盖用户已经切换的新选择。

## 发布范围

本轮实机是 Windows 11 x64、Intel Ultra X7／Arc B390。未完成 Win10、其他 CPU／GPU、低内存电脑及其他系统的实机矩阵。Android 等平台的模拟行为测试不是其安装包验收；这轮也未重新执行全部真实模型推理。

这些结果说明八项已确认问题有对应修复和验证，不能推导出软件已经零缺陷或所有发布检查都已通过。公开首发前，仍需使用最终打包产物完成干净机器安装／升级与剩余回归验收。
