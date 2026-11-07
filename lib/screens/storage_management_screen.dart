import '../utils/app_branding.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show compute, ValueListenable;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../services/library_service.dart';
import '../services/storage_audit_models.dart';
import '../services/storage_audit_service.dart';
import '../services/storage_presentation.dart';
import '../theme/app_tokens.dart';
import '../utils/page_shortcut_keys.dart';
import '../widgets/confirmation_dialog_shortcuts.dart';
import '../widgets/media_library_page_shortcuts.dart';
import '../widgets/operation_status.dart';
import 'recycle_bin_screen.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Every category has its own color. Adding a category must not use an index.
Color storageCategoryColor(StorageCategory category) => switch (category) {
  StorageCategory.libraryMedia => const Color(0xFF6BA6FF),
  StorageCategory.recycleBin => const Color(0xFFF39968),
  StorageCategory.downloads => const Color(0xFFF0C76A),
  StorageCategory.offlineDownloads => const Color(0xFF4C8DFF),
  StorageCategory.streaming => const Color(0xFFFB83AF),
  StorageCategory.materialized => const Color(0xFFAF97EF),
  StorageCategory.thumbnails => const Color(0xFF63C9BB),
  StorageCategory.subtitles => const Color(0xFF97BC75),
  StorageCategory.compatibility => const Color(0xFF83B7D4),
  StorageCategory.picker => const Color(0xFFD3A97C),
  StorageCategory.downloadTemp => const Color(0xFFDF8D94),
  StorageCategory.workTemp => const Color(0xFF8EA2EB),
  StorageCategory.transfer => const Color(0xFF65B9A1),
  StorageCategory.orphaned => const Color(0xFFDFACDF),
  StorageCategory.models => const Color(0xFFADA289),
  StorageCategory.metadata => const Color(0xFFA5AFBC),
  StorageCategory.other => const Color(0xFF747F8C),
};
Color _color(StorageCategory category) => storageCategoryColor(category);

class StorageManagementScreen extends StatefulWidget {
  const StorageManagementScreen({
    super.key,
    required this.service,
    this.library,
    this.onDispose,
    this.initialSnapshot,
  });
  final StorageAuditService service;
  final LibraryService? library;
  final VoidCallback? onDispose;
  final StorageSnapshot? initialSnapshot;

  @override
  State<StorageManagementScreen> createState() =>
      _StorageManagementScreenState();
}

class _StorageManagementScreenState extends State<StorageManagementScreen> {
  StorageSnapshot? _snapshot;
  bool _scanning = false;
  bool _deleting = false;
  final _deletionProgress = ValueNotifier<StorageDeletionProgress?>(null);
  int _files = 0;
  int _bytes = 0;
  String? _error;
  String? _errorDetails;
  String _errorTitle = '扫描未完成';
  Future<void> Function()? _retryError;
  StorageCategory? _errorCategory;
  StorageSourceFilter _sourceFilter = StorageSourceFilter.all;

  @override
  void initState() {
    super.initState();
    _snapshot = widget.initialSnapshot ?? widget.service.lastSnapshot;
    if (_snapshot == null) unawaited(_scan());
  }

  @override
  void dispose() {
    if (widget.onDispose != null) {
      widget.onDispose!();
    } else {
      widget.service.dispose();
    }
    _deletionProgress.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    if (_scanning || _deleting || !mounted) return;
    setState(() {
      _scanning = true;
      _error = null;
      _errorTitle = '扫描未完成';
      _errorCategory = null;
      _retryError = _scan;
      _errorDetails = null;
      _files = 0;
      _bytes = 0;
    });
    try {
      final snapshot = await widget.service.scan(
        onProgress: (files, bytes) {
          if (mounted) {
            setState(() {
              _files = files;
              _bytes = bytes;
            });
          }
        },
      );
      if (mounted) setState(() => _snapshot = snapshot);
    } on StorageScanCancelled {
      // Closing this page explicitly cancels its directory walk.
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = operationErrorSummary(
            error,
            fallback: '无法完成存储扫描，请检查数据目录是否可访问后重试。',
          );
          _errorDetails = safeOperationDiagnostic(error);
        });
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _delete(
    List<StorageFileEntry> files, {
    StorageCleanupAction action = StorageCleanupAction.listed,
  }) async {
    if (_deleting || _scanning) return;
    final plan = StorageDeletionPlan(
      files.where((file) => storageDeletionPermitted(action, file)).toList(),
      action: action,
    );
    if (plan.files.isEmpty) return;
    final reason = widget.service.deletionBlockedReason();
    if (reason != null) {
      _notice(reason, category: plan.files.first.category);
      return;
    }
    final needsConfirmation =
        action != StorageCleanupAction.clearCache &&
        plan.files.any(
          (file) => file.cleanupPolicy != StorageCleanupPolicy.regenerableCache,
        );
    if (needsConfirmation) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => ConfirmationDialogShortcuts(
          onCancel: () => Navigator.pop(context, false),
          confirmKey: LogicalKeyboardKey.keyD,
          onConfirm: () => Navigator.pop(context, true),
          child: AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            title: Text(
              '删除 ${plan.files.length} 个文件？',
              style: const TextStyle(fontSize: 16),
            ),
            content: Text(
              '${formatStorageSize(plan.bytes)} · ${plan.files.map((file) => file.category.title).toSet().join('、')}\n\n${_deletionExplanation(action)}',
            ),
            actions: [
              DesktopButtonClickRegion(
                child: TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const ConfirmationShortcutLabel('取消', 'Esc'),
                ),
              ),
              DesktopButtonClickRegion(
                child: FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const ConfirmationShortcutLabel('删除这些文件', 'Enter / D'),
                ),
              ),
            ],
          ),
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    if (!mounted) return;
    _deletionProgress.value = StorageDeletionProgress(
      completedFiles: 0,
      totalFiles: plan.files.length,
      releasedBytes: 0,
    );
    setState(() {
      _deleting = true;
      _errorCategory = plan.files.first.category;
      _error = null;
      _errorDetails = null;
      _retryError = null;
    });
    try {
      final result = await widget.service.delete(
        plan,
        onProgress: (progress) {
          if (mounted) _deletionProgress.value = progress;
        },
      );
      if (!mounted) return;
      _deletionProgress.value = null;
      setState(() {
        _deleting = false;
        _snapshot = widget.service.lastSnapshot;
      });
      final remaining = {...result.skipped, ...result.failed};
      if (remaining.isNotEmpty || result.warnings.isNotEmpty) {
        final retryFiles = plan.files
            .where((file) => remaining.containsKey(file.path))
            .toList();
        setState(() {
          _errorTitle = '部分文件未清理';
          _error = remaining.isEmpty
              ? '存储记录未能更新，请重新扫描。'
              : '${remaining.length} 个文件未清理，可稍后重试。';
          _errorDetails = safeOperationDiagnostic(
            [
              for (final item in remaining.entries) '${item.key}：${item.value}',
              ...result.warnings,
            ].join('\n'),
          );
          _retryError = retryFiles.isEmpty
              ? _scan
              : () => _delete(retryFiles, action: action);
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _errorTitle = '清理未完成';
          _error = operationErrorSummary(error, fallback: '无法完成清理，请重试。');
          _errorDetails = safeOperationDiagnostic(error);
          _retryError = () => _delete(plan.files, action: action);
        });
      }
    } finally {
      if (mounted) {
        _deletionProgress.value = null;
        setState(() => _deleting = false);
      }
    }
  }

  void _notice(String text, {StorageCategory? category}) {
    setState(() {
      _errorTitle = '暂时无法清理';
      _errorCategory = category;
      _error = text;
      _errorDetails = null;
      _retryError = null;
    });
  }

  String _deletionExplanation(StorageCleanupAction action) => switch (action) {
    StorageCleanupAction.deleteOffline => '离线文件将被删除，需要重新下载。',
    StorageCleanupAction.deleteSubtitle => '已保存的字幕及修改将被删除，无法恢复。',
    StorageCleanupAction.abandonResume => '未完成的下载需要从头开始。',
    _ => '删除后无法恢复。',
  };

  Future<void> _copyReport() async {
    final snapshot = _snapshot;
    if (snapshot == null) return;
    final report = StringBuffer(
      '$kAppDisplayName 存储诊断\n扫描时间：${snapshot.scannedAt.toLocal()}\n',
    );
    report.writeln(
      '应用文件：${snapshot.appBytes} B (${formatStorageSize(snapshot.appBytes)} / ${formatStorageSize(snapshot.appBytes, binary: true)})',
    );
    report.writeln(
      '外部引用：${snapshot.externalBytes} B\n可清理缓存：${StorageView(snapshot, StorageSourceFilter.all).cacheBytes} B\n可删除文件（含需确认成果）：${snapshot.clearableBytes} B',
    );
    final system = snapshot.platformUsage;
    if (system != null) {
      report.writeln(
        'Android 系统统计：合计 ${system.totalBytes} B，安装与编译 ${system.appBytes} B，数据 ${system.dataBytes} B，其中缓存 ${system.cacheBytes} B（缓存已包含在数据内）',
      );
    }
    for (final category in snapshot.categories) {
      report.writeln(
        '${category.category.title}：${category.bytes} B，${category.files.length} 个文件，可清理 ${category.clearableBytes} B',
      );
    }
    report.writeln('\n扫描目录：');
    for (final root in snapshot.roots) {
      report.writeln(
        '${root.label}：${root.path}${root.scoped ? '（仅应用目录）' : ''}',
      );
    }
    report.writeln('\n体积最大的 20 个应用文件：');
    for (final file in snapshot.files.where((f) => !f.external).take(20)) {
      report.writeln(
        '${file.bytes} B | ${file.category.title} | ${file.path} | ${file.protection ?? (storageDeletionPermitted(StorageCleanupAction.clearCache, file)
                ? '可重建缓存'
                : file.canDelete || file.explicitDelete
                ? '需确认删除'
                : '由对应功能管理')}',
      );
    }
    if (snapshot.warnings.isNotEmpty) {
      report.writeln('\n未完整读取：\n${snapshot.warnings.join('\n')}');
    }
    await Clipboard.setData(ClipboardData(text: report.toString()));
  }

  Future<void> _openCategory(StorageCategoryUsage usage) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _StorageDetailScreen(
          title: usage.category.title,
          description: usage.category.description,
          files: usage.files,
          deletionProgress: _deletionProgress,
          onDelete: _delete,
          failure: () => _error,
          failureDetails: () => _errorDetails,
          onManage:
              widget.library == null ||
                  (usage.category != StorageCategory.libraryMedia &&
                      usage.category != StorageCategory.recycleBin)
              ? null
              : (files) =>
                    _manageCards(StorageCategoryUsage(usage.category, files)),
          onSnapshot: () => _snapshot == null
              ? usage.files
              : StorageView(_snapshot!, _sourceFilter).files
                    .where(
                      (file) =>
                          !file.external && file.category == usage.category,
                    )
                    .toList(),
        ),
      ),
    );
  }

  Future<void> _manageCards(StorageCategoryUsage usage) async {
    if (usage.category == StorageCategory.recycleBin) {
      await Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const RecycleBinScreen()));
      if (mounted) await _scan();
      return;
    }
    final library = widget.library!;
    final ids = usage.files
        .expand((f) => f.ownerIds)
        .where(
          (id) =>
              library.getVideo(id) != null || library.getCollection(id) != null,
        )
        .toSet()
        .toList();
    if (ids.isEmpty) {
      _notice('当前列表没有可管理的媒体库卡片。', category: usage.category);
      return;
    }
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => ConfirmationDialogShortcuts(
        onCancel: () => Navigator.pop(context, false),
        confirmKey: LogicalKeyboardKey.keyR,
        onConfirm: () => Navigator.pop(context, true),
        child: AlertDialog(
          title: Text('将 ${ids.length} 张卡片移入回收站？'),
          content: const Text('原文件会随卡片保留在回收站。要释放空间，请在回收站永久删除；外部原文件仍留在设备上。'),
          actions: [
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const ConfirmationShortcutLabel('取消', 'Esc'),
              ),
            ),
            DesktopButtonClickRegion(
              child: FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const ConfirmationShortcutLabel('移入回收站', 'Enter / R'),
              ),
            ),
          ],
        ),
      ),
    );
    if (approved != true || !mounted) return;
    await library.moveToRecycleBin(ids);
    if (mounted) await _scan();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final view = snapshot == null ? null : StorageView(snapshot, _sourceFilter);
    return MediaLibraryPageShortcuts(
      bindings: {
        LogicalKeyboardKey.keyR: () {
          if (!_scanning && !_deleting) unawaited(_scan());
        },
        LogicalKeyboardKey.keyC: () {
          if (_snapshot != null) unawaited(_copyReport());
        },
      },
      child: Scaffold(
        backgroundColor: AppTokens.bgBase,
        appBar: AppBar(
          title: const Text('存储空间管理'),
          backgroundColor: AppTokens.bgBase,
          actions: [
            DesktopButtonClickRegion(
              child: IconButton(
                tooltip: hoverAwareShortcutTooltip(
                  '复制诊断摘要',
                  LogicalKeyboardKey.keyC,
                  context: context,
                ),
                onPressed: snapshot == null ? null : _copyReport,
                icon: const Icon(Icons.copy_outlined),
              ),
            ),
            DesktopButtonClickRegion(
              child: IconButton(
                key: const ValueKey('storageRefresh'),
                tooltip: hoverAwareShortcutTooltip(
                  '重新扫描',
                  LogicalKeyboardKey.keyR,
                  context: context,
                ),
                onPressed: _scanning || _deleting ? null : _scan,
                icon: const Icon(Icons.refresh),
              ),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1000),
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  if (_scanning || _deleting) ...[
                    if (_deleting)
                      _StorageDeletionIndicator(progress: _deletionProgress)
                    else ...[
                      const LinearProgressIndicator(),
                      const SizedBox(height: 10),
                      Text('已扫描 $_files 个文件 · ${formatStorageSize(_bytes)}'),
                    ],
                    const SizedBox(height: 18),
                  ],
                  if (_error != null && _errorCategory == null) ...[
                    OperationStatus(
                      title: _errorTitle,
                      message: _error,
                      kind: OperationStatusKind.error,
                      details: _errorDetails,
                      actions: [
                        if (_retryError != null)
                          DesktopButtonClickRegion(
                            child: TextButton(
                              onPressed: _retryError,
                              child: Text(
                                _errorTitle == '扫描未完成' ? '重试扫描' : '重试',
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (snapshot != null && view != null) ...[
                    if (widget.service.resourcesChanged?.call() == true &&
                        !_scanning)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Material(
                          color: AppTokens.bgCard,
                          borderRadius: BorderRadius.circular(12),
                          child: ListTile(
                            title: const Text('存储记录已变化'),
                            subtitle: const Text('当前为上次扫描结果，可刷新查看最新占用。'),
                            trailing: DesktopButtonClickRegion(
                              child: TextButton(
                                onPressed: _deleting ? null : _scan,
                                child: const Text('刷新'),
                              ),
                            ),
                          ),
                        ),
                      ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final filter in storageSourceFilters.where(
                          (filter) =>
                              filter == _sourceFilter ||
                              filter == StorageSourceFilter.all ||
                              filter == StorageSourceFilter.local ||
                              filter == StorageSourceFilter.podcast ||
                              snapshot.files.any(filter.matches),
                        ))
                          ChoiceChip(
                            label: Text(filter.title),
                            selected: _sourceFilter == filter,
                            onSelected: (_) =>
                                setState(() => _sourceFilter = filter),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '来源可以交叉。共享封面会同时出现在相关来源里，但总量只计算一次，不要把各来源再加一遍。',
                      style: TextStyle(color: AppTokens.text2, fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    _StorageSummary(
                      snapshot: snapshot,
                      view: view,
                      source: _sourceFilter,
                      enabled: !_scanning && !_deleting,
                      onClearCache: () => _delete(
                        view.cacheFiles,
                        action: StorageCleanupAction.clearCache,
                      ),
                    ),
                    if (snapshot.platformUsage case final system?) ...[
                      const SizedBox(height: 12),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Android 系统占用对照',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              if (_sourceFilter != StorageSourceFilter.all)
                                const Text('以下系统统计始终对应整个应用。'),
                              const SizedBox(height: 10),
                              Text(
                                '系统合计：${formatStorageSize(system.totalBytes)}',
                              ),
                              Text(
                                '安装包、编译及运行库：${formatStorageSize(system.appBytes)}',
                              ),
                              Text(
                                '应用数据：${formatStorageSize(system.dataBytes)}',
                              ),
                              Text(
                                '其中系统认定的缓存：${formatStorageSize(system.cacheBytes)}',
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                '缓存已经包含在应用数据里。系统按目录统计缓存；里面若有旧版本留下的媒体原文件，本页会保护其卡片引用。系统值与文件扫描可能因统计时间、存储卷及文件系统分配方式不同而存在差异。',
                                style: TextStyle(
                                  color: AppTokens.text2,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    const Text(
                      '按用途分类',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      '点击分类查看每个文件、关联卡片、路径和清理范围。',
                      style: TextStyle(color: AppTokens.text2),
                    ),
                    const SizedBox(height: 12),
                    if (view.categories.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Text('此来源暂无应用文件。'),
                      ),
                    for (final section in StorageSection.values)
                      if (view.categories.any(
                        (usage) => storageSection(usage.category) == section,
                      )) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 12, bottom: 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                section.title,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                section.description,
                                style: const TextStyle(
                                  color: AppTokens.text2,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        for (final usage in view.categories.where(
                          (usage) => storageSection(usage.category) == section,
                        ))
                          _CategoryTile(
                            usage: usage,
                            total: view.bytes,
                            enabled: !_scanning && !_deleting,
                            onOpen: () => _openCategory(usage),
                            onDelete: () => _delete(usage.files),
                            feedback:
                                _error != null &&
                                    _errorCategory == usage.category
                                ? OperationStatus(
                                    title: _error!,
                                    kind: OperationStatusKind.error,
                                    details: _errorDetails,
                                    actions: [
                                      if (_retryError != null)
                                        TextButton(
                                          onPressed: _retryError,
                                          child: const Text('重试'),
                                        ),
                                    ],
                                  )
                                : null,
                          ),
                      ],
                    if (view.externalFiles.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: ListTile(
                          tileColor: AppTokens.bgCard,
                          leading: const Icon(Icons.folder_open),
                          title: Text(
                            '外部原文件 · ${formatStorageSize(view.externalBytes)}',
                          ),
                          subtitle: const Text('仅引用，不计入上面的应用文件占用。'),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => _StorageDetailScreen(
                                title: '外部原文件',
                                description:
                                    '这些文件位于应用目录之外。应用只引用它们；请通过设备文件管理器删除。',
                                files: view.externalFiles,
                                onDelete: _delete,
                                deletionProgress: _deletionProgress,
                              ),
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 20),
                    ExpansionTile(
                      title: const Text('统计口径与扫描目录'),
                      children: [
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text(
                            '总量是已读取文件的逻辑字节数，每个路径只计一次。GB = 10⁹ 字节，GiB = 2³⁰ 字节。系统应用详情还可能计入安装包、文件系统分配空间和系统维护的数据，不能直接与卡片合计相减。本次运行内保留上次扫描结果，重新进入无需重扫；右上角可手动刷新。清理只处理已选文件，不重新扫描全部目录。',
                          ),
                        ),
                        for (final root in snapshot.roots)
                          ListTile(
                            dense: true,
                            title: Text(root.label),
                            subtitle: SelectableText(
                              '${root.path}${root.scoped ? '\n仅扫描本应用的已知目录' : ''}',
                            ),
                          ),
                      ],
                    ),
                    if (snapshot.warnings.isNotEmpty)
                      ExpansionTile(
                        initiallyExpanded: true,
                        title: Text(
                          '${snapshot.warnings.length} 项未完整读取，统计可能偏小',
                          style: const TextStyle(color: AppTokens.danger),
                        ),
                        children: [
                          SizedBox(
                            height: math.min(
                              200,
                              snapshot.warnings.length * 80.0,
                            ),
                            child: ListView.builder(
                              itemCount: snapshot.warnings.length,
                              itemBuilder: (_, i) => Padding(
                                padding: const EdgeInsets.all(12),
                                child: SelectableText(
                                  safeOperationDiagnostic(snapshot.warnings[i]),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                  ] else if (!_scanning && _error == null)
                    const Text('暂无统计，点击右上角重新扫描。'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StorageSummary extends StatelessWidget {
  const _StorageSummary({
    required this.snapshot,
    required this.view,
    required this.source,
    required this.enabled,
    required this.onClearCache,
  });
  final StorageSnapshot snapshot;
  final StorageView view;
  final StorageSourceFilter source;
  final bool enabled;
  final VoidCallback onClearCache;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: AppTokens.bgCard,
      borderRadius: BorderRadius.circular(20),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final text = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              source == StorageSourceFilter.all
                  ? '已扫描应用文件'
                  : '${source.title} · 应用文件',
              style: const TextStyle(color: AppTokens.text2),
            ),
            const SizedBox(height: 8),
            Text(
              formatStorageSize(view.bytes),
              key: const ValueKey('storageTotal'),
              style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w700),
            ),
            Text(
              '${formatStorageSize(view.bytes, binary: true)} · ${view.fileCount} 个文件',
              style: const TextStyle(color: AppTokens.text2),
            ),
            const SizedBox(height: 16),
            Text(
              '可清理缓存 ${formatStorageSize(view.cacheBytes)}',
              key: const ValueKey('storageCacheTotal'),
              style: const TextStyle(color: Color(0xFF63C9BB), fontSize: 16),
            ),
            if (view.confirmationBytes > 0)
              Text(
                '需确认删除 ${formatStorageSize(view.confirmationBytes)}',
                style: const TextStyle(color: AppTokens.text2),
              ),
            if (view.cacheFiles.isNotEmpty) ...[
              const SizedBox(height: 8),
              DesktopButtonClickRegion(
                child: FilledButton.tonalIcon(
                  key: const ValueKey('storageClearCache'),
                  onPressed: enabled ? onClearCache : null,
                  icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                  label: const Text('清理此范围缓存'),
                ),
              ),
            ],
            const SizedBox(height: 6),
            Text(
              '扫描于 ${snapshot.scannedAt.toLocal().toString().split('.').first}',
              style: const TextStyle(color: AppTokens.text2, fontSize: 12),
            ),
          ],
        );
        final chart = Semantics(
          label: '${source.title}的应用文件存储分布。各类别大小与占比见下方列表。',
          child: SizedBox(
            width: 180,
            height: 180,
            child: CustomPaint(
              painter: _StorageChart(view.categories, view.bytes),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${view.categories.length} 类',
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Text(
                      '用途分布',
                      style: TextStyle(color: AppTokens.text2, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        if (constraints.maxWidth < 540) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              text,
              const SizedBox(height: 20),
              Semantics(
                label: '${source.title}的应用文件存储分布。各类别大小与占比见下方列表。',
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    height: 12,
                    width: double.infinity,
                    child: CustomPaint(
                      painter: _StorageBar(view.categories, view.bytes),
                    ),
                  ),
                ),
              ),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: text),
            chart,
          ],
        );
      },
    ),
  );
}

class _StorageBar extends CustomPainter {
  _StorageBar(this.categories, this.total);
  final List<StorageCategoryUsage> categories;
  final int total;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = AppTokens.bgOverlay;
    canvas.drawRect(Offset.zero & size, paint);
    if (total <= 0) return;
    var start = 0.0;
    for (final category in categories) {
      final width = size.width * category.bytes / total;
      canvas.drawRect(
        Rect.fromLTWH(start, 0, width, size.height),
        paint..color = _color(category.category),
      );
      start += width;
    }
  }

  @override
  bool shouldRepaint(_StorageBar old) =>
      old.total != total || old.categories != categories;
}

class _StorageChart extends CustomPainter {
  _StorageChart(this.categories, this.total);
  final List<StorageCategoryUsage> categories;
  final int total;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final ring = rect.deflate(15);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 22;
    canvas.drawArc(
      ring,
      0,
      math.pi * 2,
      false,
      paint..color = AppTokens.bgOverlay,
    );
    if (total <= 0) return;
    var start = -math.pi / 2;
    for (final category in categories) {
      final sweep = math.pi * 2 * category.bytes / total;
      canvas.drawArc(
        ring,
        start,
        sweep,
        false,
        paint..color = _color(category.category),
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_StorageChart old) =>
      old.total != total || old.categories != categories;
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.usage,
    required this.total,
    required this.enabled,
    required this.onOpen,
    required this.onDelete,
    this.feedback,
  });
  final StorageCategoryUsage usage;
  final int total;
  final bool enabled;
  final VoidCallback onOpen;
  final VoidCallback onDelete;
  final Widget? feedback;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Material(
      color: AppTokens.bgCard,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: enabled ? onOpen : null,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: _color(usage.category),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      usage.category.title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: AppTokens.text2,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '${formatStorageSize(usage.bytes)} · ${total == 0 ? '0' : (usage.bytes / total * 100).toStringAsFixed(2)}% · ${usage.files.length} 个文件',
                style: const TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 8),
              if (feedback != null)
                feedback!
              else ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: total == 0 ? 0 : usage.bytes / total,
                    minHeight: 5,
                    color: _color(usage.category),
                    backgroundColor: AppTokens.bgOverlay,
                  ),
                ),
                if (usage.clearableBytes > 0)
                  Align(
                    alignment: Alignment.centerRight,
                    child: DesktopButtonClickRegion(
                      child: TextButton(
                        onPressed: enabled ? onDelete : null,
                        child: Text(
                          '${usage.cacheBytes == usage.clearableBytes ? '清理' : '删除'} ${formatStorageSize(usage.clearableBytes)}',
                        ),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

class _StorageDeletionIndicator extends StatelessWidget {
  const _StorageDeletionIndicator({required this.progress});

  final ValueListenable<StorageDeletionProgress?> progress;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: progress,
    builder: (context, value, _) {
      if (value == null) return const SizedBox.shrink();
      final finishing = value.completedFiles == value.totalFiles;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(
            value: finishing || value.totalFiles == 0
                ? null
                : value.completedFiles / value.totalFiles,
          ),
          const SizedBox(height: 10),
          Text(finishing ? '正在更新存储记录…' : '正在清理文件…'),
          Text(
            '已处理 ${value.completedFiles} / ${value.totalFiles} 个文件 · 已释放 ${formatStorageSize(value.releasedBytes)}',
            style: const TextStyle(fontSize: 12, color: AppTokens.text2),
          ),
          const SizedBox(height: 10),
        ],
      );
    },
  );
}

class _StorageDetailScreen extends StatefulWidget {
  const _StorageDetailScreen({
    required this.title,
    required this.description,
    required this.files,
    required this.onDelete,
    required this.deletionProgress,
    this.onManage,
    this.onSnapshot,
    this.failure,
    this.failureDetails,
  });
  final String title;
  final String description;
  final List<StorageFileEntry> files;
  final ValueListenable<StorageDeletionProgress?> deletionProgress;
  final Future<void> Function(
    List<StorageFileEntry> files, {
    StorageCleanupAction action,
  })
  onDelete;
  final Future<void> Function(List<StorageFileEntry> files)? onManage;
  final List<StorageFileEntry> Function()? onSnapshot;
  final String? Function()? failure, failureDetails;
  @override
  State<_StorageDetailScreen> createState() => _StorageDetailScreenState();
}

class _StorageDetailScreenState extends State<_StorageDetailScreen> {
  final FocusNode _searchFocus = FocusNode(debugLabel: 'storage detail search');
  late List<StorageFileEntry> _all;
  late List<StorageFileEntry> _filtered;
  String _query = '';
  String? _filterError;
  String? _filterDetails;
  bool _busy = false;
  bool _searching = false;
  Timer? _searchTimer;
  int _filterRevision = 0;
  int _bytes = 0;
  bool _hasDeletable = false;
  @override
  void initState() {
    super.initState();
    _all = widget.files;
    _filtered = _all;
    _updateTotals();
  }

  void _updateTotals() {
    _bytes = _all.fold(0, (sum, file) => sum + file.bytes);
    _hasDeletable = _all.any((file) => file.canDelete);
  }

  @override
  void dispose() {
    _searchFocus.dispose();
    _searchTimer?.cancel();
    _filterRevision++;
    super.dispose();
  }

  void _scheduleFilter(String query) {
    _searchTimer?.cancel();
    _filterRevision++;
    _query = query.toLowerCase();
    setState(() => _searching = true);
    _searchTimer = Timer(
      const Duration(milliseconds: 180),
      () => unawaited(_filter(_query)),
    );
  }

  Future<void> _filter(String query) async {
    final revision = ++_filterRevision;
    _query = query.toLowerCase();
    final input = (_all, _query);
    setState(() {
      _searching = true;
      _filterError = null;
    });
    try {
      final result = _query.isEmpty
          ? _all
          : _all.length <= 1000
          ? _filterStorageEntries(input)
          : await compute(_filterStorageEntries, input);
      if (mounted && revision == _filterRevision) {
        setState(() {
          _filtered = result;
          _searching = false;
        });
      }
    } catch (error) {
      if (mounted && revision == _filterRevision) {
        setState(() {
          _filtered = [];
          _searching = false;
        });
        setState(() {
          _filterError = '无法搜索文件，请重试。';
          _filterDetails = safeOperationDiagnostic(error);
        });
      }
    }
  }

  Future<void> _action(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _all = widget.onSnapshot?.call() ?? _all;
          _updateTotals();
        });
        await _filter(_query);
      }
    }
  }

  @override
  Widget build(BuildContext context) => MediaLibraryPageShortcuts(
    bindings: {
      LogicalKeyboardKey.keyS: _searchFocus.requestFocus,
      LogicalKeyboardKey.slash: _searchFocus.requestFocus,
    },
    child: _buildDetail(context),
  );

  Widget _buildDetail(BuildContext context) => Scaffold(
    backgroundColor: AppTokens.bgBase,
    appBar: AppBar(title: Text(widget.title)),
    body: SafeArea(
      top: false,
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_filterError != null || widget.failure?.call() != null)
                    OperationStatus(
                      title: _filterError ?? widget.failure!.call()!,
                      kind: OperationStatusKind.error,
                      details: _filterError != null
                          ? _filterDetails
                          : widget.failureDetails?.call(),
                      actions: [
                        if (_filterError != null)
                          TextButton(
                            onPressed: _busy ? null : () => _filter(_query),
                            child: const Text('重试'),
                          ),
                      ],
                    )
                  else
                    Text(widget.description),
                  const SizedBox(height: 8),
                  Text(
                    '${formatStorageSize(_bytes)} · ${_all.length} 个文件，按大小排列',
                    style: const TextStyle(color: AppTokens.text2),
                  ),
                  if (_query.isNotEmpty)
                    Text(
                      '当前匹配 ${_filtered.length} 个文件 · ${formatStorageSize(_filtered.fold<int>(0, (sum, file) => sum + file.bytes))}，以下操作仅作用于匹配文件。',
                      style: const TextStyle(
                        color: AppTokens.text2,
                        fontSize: 12,
                      ),
                    ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      if (_filtered.any(
                        (file) => storageDeletionPermitted(
                          StorageCleanupAction.clearCache,
                          file,
                        ),
                      ))
                        DesktopButtonClickRegion(
                          child: FilledButton.tonal(
                            onPressed: _busy || _searching
                                ? null
                                : () => _action(
                                    () => widget.onDelete(
                                      _filtered,
                                      action: StorageCleanupAction.clearCache,
                                    ),
                                  ),
                            child: const Text('清理缓存'),
                          ),
                        ),
                      if (_filtered.any(
                        (file) => storageDeletionPermitted(
                          StorageCleanupAction.deleteOffline,
                          file,
                        ),
                      ))
                        DesktopButtonClickRegion(
                          child: FilledButton.tonal(
                            onPressed: _busy || _searching
                                ? null
                                : () => _action(
                                    () => widget.onDelete(
                                      _filtered,
                                      action:
                                          StorageCleanupAction.deleteOffline,
                                    ),
                                  ),
                            child: const Text('删除离线下载'),
                          ),
                        ),
                      if (_filtered.any(
                        (file) => storageDeletionPermitted(
                          StorageCleanupAction.deleteSubtitle,
                          file,
                        ),
                      ))
                        DesktopButtonClickRegion(
                          child: FilledButton.tonal(
                            onPressed: _busy || _searching
                                ? null
                                : () => _action(
                                    () => widget.onDelete(
                                      _filtered,
                                      action:
                                          StorageCleanupAction.deleteSubtitle,
                                    ),
                                  ),
                            child: const Text('删除已保存字幕'),
                          ),
                        ),
                      if (_filtered.any(
                        (file) => storageDeletionPermitted(
                          StorageCleanupAction.abandonResume,
                          file,
                        ),
                      ))
                        DesktopButtonClickRegion(
                          child: FilledButton.tonal(
                            onPressed: _busy || _searching
                                ? null
                                : () => _action(
                                    () => widget.onDelete(
                                      _filtered,
                                      action:
                                          StorageCleanupAction.abandonResume,
                                    ),
                                  ),
                            child: const Text('放弃续传数据'),
                          ),
                        ),
                      if (_hasDeletable &&
                          _filtered.any((file) => file.canDelete))
                        DesktopButtonClickRegion(
                          child: FilledButton.tonal(
                            onPressed: _busy || _searching
                                ? null
                                : () =>
                                      _action(() => widget.onDelete(_filtered)),
                            child: const Text('清理当前列表可删除文件'),
                          ),
                        ),
                      if (widget.onManage != null)
                        DesktopButtonClickRegion(
                          child: TextButton(
                            onPressed: _busy || _searching || _filtered.isEmpty
                                ? null
                                : () => _action(
                                    () => widget.onManage!(_filtered),
                                  ),
                            child: Text(
                              widget.title == StorageCategory.recycleBin.title
                                  ? '打开回收站管理'
                                  : '将关联卡片移入回收站',
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    focusNode: _searchFocus,
                    onChanged: _scheduleFilter,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: '搜索文件路径或关联卡片',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_busy)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _StorageDeletionIndicator(
                  progress: widget.deletionProgress,
                ),
              ),
            )
          else if (_searching)
            const SliverToBoxAdapter(child: LinearProgressIndicator()),
          SliverList.builder(
            itemCount: _filtered.length,
            itemBuilder: (_, index) {
              final file = _filtered[index];
              return ListTile(
                title: Text(
                  '${p.basename(file.path)} · ${formatStorageSize(file.bytes)}',
                ),
                subtitle: Text(
                  '${file.ownerTitles.isEmpty ? file.rootLabel : file.ownerTitles.join('、')}\n${_fileCleanupLabel(file)}\n${file.path}',
                  style: const TextStyle(fontSize: 12),
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                ),
                isThreeLine: true,
                trailing:
                    file.canDelete &&
                        file.role != StorageAssetRole.mediaSegment &&
                        file.role != StorageAssetRole.assembledMedia &&
                        file.role != StorageAssetRole.resumePart
                    ? DesktopButtonClickRegion(
                        child: IconButton(
                          tooltip: '删除此文件',
                          onPressed: _busy || _searching
                              ? null
                              : () => _action(() => widget.onDelete([file])),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      )
                    : Tooltip(
                        message: _fileCleanupLabel(file),
                        child: Icon(
                          file.canDelete || storageNeedsConfirmation(file)
                              ? Icons.info_outline
                              : Icons.lock_outline,
                          size: 18,
                          color: AppTokens.text2,
                        ),
                      ),
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text(p.basename(file.path)),
                    content: SingleChildScrollView(
                      child: SelectableText(
                        '${file.bytes} 字节\n${formatStorageSize(file.bytes)} / ${formatStorageSize(file.bytes, binary: true)}\n\n${file.category.title}\n来源：${file.origin.title}${file.subtitleKind == null ? '' : '\n字幕：${file.subtitleKind}'}\n${file.detail ?? ''}\n${file.rootLabel}\n${file.path}\n\n关联：${file.ownerTitles.isEmpty ? '无卡片引用' : file.ownerTitles.join('、')}\n${_fileCleanupLabel(file)}',
                      ),
                    ),
                    actions: [
                      DesktopButtonClickRegion(
                        child: TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('关闭'),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    ),
  );
}

String _fileCleanupLabel(StorageFileEntry file) {
  if (file.protection != null) return file.protection!;
  if (storageDeletionPermitted(StorageCleanupAction.clearCache, file)) {
    return '可重建缓存';
  }
  if (file.explicitDelete && storageNeedsConfirmation(file)) {
    return '需通过上方对应操作确认删除';
  }
  if (file.canDelete) return '需确认删除，删除后无法恢复';
  return file.cleanupPolicy == StorageCleanupPolicy.unknown
      ? '用途待核实，保留文件'
      : '由对应功能管理';
}

List<StorageFileEntry> _filterStorageEntries(
  (List<StorageFileEntry>, String) input,
) {
  final (files, query) = input;
  return files
      .where(
        (file) =>
            file.path.toLowerCase().contains(query) ||
            file.ownerTitles.any(
              (title) => title.toLowerCase().contains(query),
            ),
      )
      .toList();
}
