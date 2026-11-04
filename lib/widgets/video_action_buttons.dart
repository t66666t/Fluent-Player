import 'dart:async';
import 'dart:math' as math;
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'operation_status.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';

import '../theme/app_tokens.dart';
import 'video_action_rail.dart';
import 'video_action_rail_layout.dart';
import 'video_action_rail_button.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';
import 'package:path/path.dart' as p;
import '../utils/local_filesystem_path.dart';
import '../utils/import_gallery_access.dart';
import '../utils/import_cache_roots.dart';

import '../services/library_service.dart';
import '../services/settings_service.dart';
import '../screens/batch_import_screen.dart';
import '../screens/batch_subtitle_screen.dart';
import '../utils/android_hardware_input_bridge.dart';
import 'media_library_shell.dart';
import 'library_create_collection_dialog.dart';
import '../utils/desktop_media_management_shortcuts.dart';
import '../utils/hardware_keyboard_shortcuts.dart';
import '../utils/import_sheet_shortcuts.dart';
import '../utils/incoming_share_signatures.dart';
import '../utils/page_shortcut_keys.dart';
import '../features/portable_transfer/portable_transfer_models.dart';
import '../features/portable_transfer/portable_transfer_navigation.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class VideoActionButtons extends StatefulWidget {
  final String? collectionId;
  final double? maxExpandedHeight;
  final VoidCallback? onCreateCollection;
  final bool
  isHorizontal; // For empty state usage if needed, though mostly for FAB

  static String? _importFolder;
  static final _importFailure =
      ValueNotifier<
        ({
          String? folder,
          String message,
          String? details,
          VoidCallback? action,
          String? actionLabel,
        })?
      >(null);

  static const MethodChannel _fileManagerChannel = MethodChannel(
    'com.example.video_player_app/file_manager',
  );

  static String _cleanImportedTitle(String path) {
    final name = p.basename(path);
    final cleaned = name
        .replaceFirst(RegExp(r'^incoming_media_\d+_'), '')
        .replaceFirst(RegExp(r'^shared_media_\d+_'), '')
        .replaceFirst(
          RegExp(
            r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}_',
          ),
          '',
        );
    return cleaned.isEmpty ? name : cleaned;
  }

  static Future<void> showImportMenu(
    BuildContext context,
    String? collectionId,
  ) {
    return _VideoActionButtonsState.openImportMenu(context, collectionId);
  }

  static Future<void> openCreateCollectionDialog(
    BuildContext context,
    String? parentId,
  ) => showLibraryCreateCollectionDialog(
    context: context,
    onCreate: (name) async {
      await context.read<LibraryService>().createCollection(name, parentId);
    },
  );

  static void openBilibiliDownloadPage(
    BuildContext context, {
    String? collectionId,
    bool streamingMode = false,
  }) {
    _showLocalOnlyNotice(context);
  }

  static void openYtDlpDownloadPage(
    BuildContext context, {
    String? collectionId,
  }) {
    _showLocalOnlyNotice(context);
  }

  static void openWebMediaPage(BuildContext context, {String? collectionId}) {
    _showLocalOnlyNotice(context);
  }

  static void openDouyinDownloadPage(
    BuildContext context, {
    String? collectionId,
  }) {
    _showLocalOnlyNotice(context);
  }

  static void openCloudDrivePage(BuildContext context, String? targetFolderId) {
    _showLocalOnlyNotice(context);
  }

  static void openBatchSubtitlePage(
    BuildContext context, {
    String? collectionId,
  }) {
    pushAboveMediaLibrary(
      context,
      AppMaterialPageRoute(
        builder: (_) => BatchSubtitleScreen(collectionId: collectionId),
        settings: const RouteSettings(name: '/batch_subtitle'),
      ),
    );
  }

  static void openBatchImportPage(
    BuildContext context, {
    String? collectionId,
  }) {
    pushAboveMediaLibrary(
      context,
      AppMaterialPageRoute(
        builder: (_) => BatchImportScreen(folderId: collectionId),
        settings: const RouteSettings(name: '/batch_import'),
      ),
    );
  }

  static void openCacheManagementPage(
    BuildContext context, {
    String? collectionId,
  }) {
    _showLocalOnlyNotice(context);
  }

  static void _showLocalOnlyNotice(BuildContext context) {
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('社区版仅支持本地媒体，请导入本地文件。')));
  }

  const VideoActionButtons({
    super.key,
    this.collectionId,
    this.maxExpandedHeight,
    this.onCreateCollection,
    this.isHorizontal = false,
  });

  static void _showTopBanner(
    BuildContext context,
    String message, {
    Color? backgroundColor,
    String? actionText,
    VoidCallback? onActionPressed,
    Duration autoHideDuration = const Duration(milliseconds: 2000),
  }) {
    if (backgroundColor == null || backgroundColor.toARGB32() != 0xFFB00020) {
      return;
    }
    _importFailure.value = (
      folder: _importFolder,
      message: message,
      details: null,
      action: onActionPressed,
      actionLabel: actionText,
    );
  }

  static Future<void> _showImportFailure(
    BuildContext context,
    String title,
    Object error,
  ) async {
    _importFailure.value = (
      folder: _importFolder,
      message: operationErrorSummary(error, fallback: '$title，请重新选择后重试。'),
      details: safeOperationDiagnostic(error),
      action: null,
      actionLabel: null,
    );
  }

  static Future<T> _prepareWithProgress<T>(
    BuildContext context,
    String message,
    Future<T> Function() prepare,
  ) async {
    LibraryService? library;
    try {
      library = context.read<LibraryService>();
    } catch (_) {}
    final reported =
        library?.reportTransientImportProgress(
          progress: 0.02,
          status: message,
        ) ??
        false;
    try {
      return await prepare();
    } finally {
      if (reported) library?.clearTransientImportProgress();
    }
  }

  static Future<void> processImportedFiles(
    BuildContext context,
    List<String> paths,
    String? collectionId, {
    bool explicitPlacement = false,
    Map<String, String> sidecarSourcePaths = const {},
  }) async {
    _importFolder = collectionId;
    _importFailure.value = null;
    final filterExtensions = SettingsService().localImportFilterMediaExtensions;

    final validPaths = paths
        .map(normalizeLocalFilesystemPath)
        .whereType<String>()
        .where(
          (path) =>
              !filterExtensions || LibraryService.isSupportedMediaPath(path),
        )
        .toList();
    if (validPaths.isEmpty) {
      if (context.mounted) {
        _showTopBanner(
          context,
          "未找到可用的媒体文件",
          backgroundColor: const Color(0xFFB00020),
        );
      }
      return;
    }

    final originalTitles = validPaths
        .map((path) => _cleanImportedTitle(path))
        .toList();
    if (!context.mounted) return;
    final library = Provider.of<LibraryService>(context, listen: false);
    if (library.hasActiveImport) {
      _showTopBanner(
        context,
        '已有导入任务正在运行，请等待完成后再试',
        backgroundColor: const Color(0xFFB00020),
      );
      return;
    }
    _showTopBanner(
      context,
      "已开始后台导入 ${validPaths.length} 个媒体文件",
      autoHideDuration: const Duration(seconds: 2),
    );
    try {
      await library.importVideosBackground(
        validPaths,
        collectionId,
        shouldCopy: false,
        originalTitles: originalTitles,
        sidecarSourcePaths: _selectedSourcePathHints(
          sidecarSourcePaths,
          validPaths,
        ),
        useOriginalPath: false,
        allowCacheRescue: true,
        explicitPlacement: explicitPlacement,
      );
    } catch (error) {
      if (context.mounted) {
        await VideoActionButtons._showImportFailure(context, '无法导入媒体', error);
      }
    }
  }

  // Hints describe only the already-readable source of this selection. They
  // are never media paths or ownership records, and must not be URI requests.
  static Map<String, String> _selectedSourcePathHints(
    Object? value,
    Iterable<String> selectedPaths,
  ) {
    if (value is! Map) return const {};
    final selected = selectedPaths
        .map(normalizeLocalFilesystemPath)
        .whereType<String>()
        .toSet();
    final hints = <String, String>{};
    for (final entry in value.entries) {
      if (entry.key is! String || entry.value is! String) continue;
      final source = entry.value as String;
      if (source.contains('://') ||
          source.split(RegExp(r'[/\\]')).contains('..') ||
          !p.isAbsolute(source)) {
        continue;
      }
      final path = normalizeLocalFilesystemPath(entry.key as String);
      if (path != null && selected.contains(path)) {
        hints[path] = p.normalize(source);
      }
    }
    return hints;
  }

  static const List<String> _structuredArchiveExtensions = [
    'zip',
    'tar',
    'tgz',
    'gz',
    'tbz',
    'tbz2',
    'bz2',
    'txz',
    'xz',
  ];

  static Future<void> processDroppedPaths(
    BuildContext context,
    List<String> paths,
    String? collectionId,
  ) async {
    _importFolder = collectionId;
    _importFailure.value = null;
    final normalizedPaths = <String>[];
    final seen = <String>{};
    for (final rawPath in paths) {
      final normalized = normalizeLocalFilesystemPath(rawPath);
      if (normalized == null) continue;
      final dedupeKey = Platform.isWindows
          ? normalized.toLowerCase()
          : normalized;
      if (seen.add(dedupeKey)) {
        normalizedPaths.add(normalized);
      }
    }

    if (normalizedPaths.isEmpty) {
      if (context.mounted) {
        _showTopBanner(
          context,
          "未找到可导入的内容",
          backgroundColor: const Color(0xFFB00020),
        );
      }
      return;
    }

    // FluentPack is handled by the portable-transfer page, not media import.
    // Nested desktop DropTargets may also see this drop; navigation dedupes.
    if (await PortableTransferNavigation.handleDroppedPaths(
      context,
      normalizedPaths,
      libraryFolderId: collectionId,
    )) {
      return;
    }

    if (!context.mounted) {
      return;
    }

    final mediaPaths = <String>[];
    final archivePaths = <String>[];
    final folderPaths = <String>[];
    final filterExtensions = SettingsService().localImportFilterMediaExtensions;

    for (final path in normalizedPaths) {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        folderPaths.add(path);
        continue;
      }
      if (type != FileSystemEntityType.file) {
        continue;
      }
      if (LibraryService.isSupportedArchivePath(path)) {
        archivePaths.add(path);
        continue;
      }
      if (!filterExtensions || LibraryService.isSupportedMediaPath(path)) {
        mediaPaths.add(path);
      }
    }

    if (!context.mounted) {
      return;
    }

    final structuredItemCount = archivePaths.length + folderPaths.length;
    if (structuredItemCount > 0) {
      if (structuredItemCount > 1 || mediaPaths.isNotEmpty) {
        if (context.mounted) {
          _showTopBanner(
            context,
            "拖拽压缩包或文件夹时请一次只拖入一个，并且不要与媒体文件混拖",
            backgroundColor: const Color(0xFFB00020),
            autoHideDuration: const Duration(seconds: 3),
          );
        }
        return;
      }

      if (folderPaths.isNotEmpty) {
        await processDroppedFolder(context, folderPaths.single, collectionId);
        return;
      }

      await processDroppedArchive(context, archivePaths.single, collectionId);
      return;
    }

    await processImportedFiles(
      context,
      mediaPaths,
      collectionId,
      explicitPlacement: true,
    );
  }

  static int _structuredImportDialogCount = 0;
  static bool _archiveImportUiBusy = false;

  static Future<void> processIncomingSharedItems(
    BuildContext context,
    List<dynamic> items,
    String? collectionId, {
    bool requireCurrentRoute = true,
  }) async {
    _importFolder = collectionId;
    _importFailure.value = null;
    final mediaPaths = <String>[];
    final mediaSourceHints = <String, String>{};
    final archiveSelections = <_ArchiveSelection>[];
    final fluentPackItems = <Map<dynamic, dynamic>>[];
    final fluentPackStringPaths = <String>[];

    for (final item in items) {
      if (item is String) {
        final path = item.trim();
        if (path.isEmpty) continue;
        if (PortableIncomingClassification.isPackagePath(path)) {
          fluentPackStringPaths.add(path);
        } else {
          mediaPaths.add(path);
        }
        continue;
      }
      if (item is! Map) {
        continue;
      }

      final rawKind = item['kind'];
      final kind = rawKind is String ? rawKind.trim().toLowerCase() : '';
      final rawPath = item['path'];
      final path = rawPath is String ? rawPath.trim() : '';
      if (kind == 'fluentpack' ||
          PortableIncomingClassification.isPackagePath(path) ||
          PortableIncomingClassification.isPackagePath(
            item['displayName']?.toString() ?? '',
          )) {
        fluentPackItems.add(item);
        continue;
      }
      if (kind == 'archive') {
        archiveSelections.add(_ArchiveSelection.fromNativeMap(item));
        continue;
      }
      if (kind == 'media' && path.isNotEmpty) {
        mediaPaths.add(path);
        final hint = item['sourcePathHint'];
        if (hint is String) mediaSourceHints[path] = hint;
      }
    }

    final hasFluentPack =
        fluentPackItems.isNotEmpty || fluentPackStringPaths.isNotEmpty;
    if (hasFluentPack) {
      if (archiveSelections.isNotEmpty || mediaPaths.isNotEmpty) {
        if (context.mounted) {
          _showTopBanner(
            context,
            PortableIncomingClassification.shareMixMessage,
            backgroundColor: const Color(0xFFB00020),
            autoHideDuration: const Duration(seconds: 3),
          );
        }
        return;
      }
      final sources = await _resolveSharedFluentPackSources(
        fluentPackItems,
        fluentPackStringPaths,
      );
      if (!context.mounted) return;
      if (sources.isEmpty) {
        _showTopBanner(
          context,
          '无法读取 FluentPack 文件',
          backgroundColor: const Color(0xFFB00020),
        );
        return;
      }
      await PortableTransferNavigation.openAndImportPackages(
        context,
        sources,
        libraryFolderId: collectionId,
      );
      return;
    }

    if (archiveSelections.isNotEmpty) {
      if (archiveSelections.length > 1 || mediaPaths.isNotEmpty) {
        if (context.mounted) {
          _showTopBanner(
            context,
            '系统分享压缩包时请一次只选择一个，且不要与媒体文件混合分享',
            backgroundColor: const Color(0xFFB00020),
            autoHideDuration: const Duration(seconds: 3),
          );
        }
        return;
      }
      await _processSelectedArchive(
        context,
        archiveSelections.single,
        collectionId,
        requireCurrentRoute: requireCurrentRoute,
      );
      return;
    }

    await processImportedFiles(
      context,
      mediaPaths,
      collectionId,
      sidecarSourcePaths: mediaSourceHints,
    );
  }

  static Future<List<PortableImportSource>> _resolveSharedFluentPackSources(
    List<Map<dynamic, dynamic>> items,
    List<String> stringPaths,
  ) async {
    final sources = <PortableImportSource>[];
    final seen = <String>{};

    void addSource(PortableImportSource source) {
      final key = Platform.isWindows ? source.path.toLowerCase() : source.path;
      if (source.path.isEmpty || !seen.add(key)) return;
      sources.add(source);
    }

    for (final path in stringPaths) {
      addSource(PortableImportSource.fromPath(path));
    }

    for (final item in items) {
      final displayName = item['displayName']?.toString().trim();
      final rawPath = item['path']?.toString().trim() ?? '';
      final owned = item['ownedTemporaryCopy'] == true || item['owned'] == true;
      if (rawPath.isNotEmpty && await File(rawPath).exists()) {
        addSource(
          PortableImportSource(
            path: rawPath,
            displayName: (displayName != null && displayName.isNotEmpty)
                ? displayName
                : p.basename(rawPath),
            ownedTemporaryCopy: owned,
          ),
        );
        continue;
      }
      final uri = item['uri']?.toString().trim() ?? '';
      if (uri.isEmpty || !Platform.isAndroid) continue;
      try {
        final materialized = await _fileManagerChannel.invokeMethod<String>(
          'materializeFluentPackForImport',
          {'uri': uri, 'displayName': displayName ?? 'package.fluentpack'},
        );
        if (materialized == null || materialized.isEmpty) continue;
        addSource(
          PortableImportSource(
            path: materialized,
            displayName: (displayName != null && displayName.isNotEmpty)
                ? displayName
                : p.basename(materialized),
            ownedTemporaryCopy: true,
          ),
        );
      } catch (error) {
        debugPrint('materialize FluentPack failed: $error');
      }
    }
    return sources;
  }

  static Future<void> processDroppedArchive(
    BuildContext context,
    String archivePath,
    String? collectionId, {
    bool explicitPlacement = true,
  }) async {
    _importFolder = collectionId;
    _importFailure.value = null;
    final selection = _ArchiveSelection.fromResolvedPath(archivePath);
    await _processSelectedArchive(
      context,
      selection,
      collectionId,
      explicitPlacement: explicitPlacement,
    );
  }

  static bool _canPresentStructuredImport(
    BuildContext context, {
    required bool requireCurrentRoute,
  }) {
    if (!context.mounted) return false;
    return canPresentIncomingImportUi(
      requireCurrentRoute: requireCurrentRoute,
      routeIsCurrent: mediaLibraryRouteIsCurrent(context),
    );
  }

  static Future<void> _processSelectedArchive(
    BuildContext context,
    _ArchiveSelection selection,
    String? collectionId, {
    bool requireCurrentRoute = true,
    bool explicitPlacement = false,
  }) async {
    _importFolder = collectionId;
    _importFailure.value = null;
    if (!_canPresentStructuredImport(
      context,
      requireCurrentRoute: requireCurrentRoute,
    )) {
      return;
    }
    if (_archiveImportUiBusy || _structuredImportDialogCount > 0) {
      if (context.mounted) {
        _showTopBanner(
          context,
          '请先完成当前的导入确认，再分享下一个压缩包',
          backgroundColor: const Color(0xFFB00020),
        );
      }
      return;
    }
    _archiveImportUiBusy = true;
    try {
      if (!_canPresentStructuredImport(
        context,
        requireCurrentRoute: requireCurrentRoute,
      )) {
        await _cleanupTemporaryArchiveSelection(selection.resolvedPath);
        return;
      }

      final library = Provider.of<LibraryService>(context, listen: false);
      if (library.hasActiveImport) {
        _showTopBanner(
          context,
          '已有导入任务正在运行，请等待完成后再试',
          backgroundColor: const Color(0xFFB00020),
        );
        return;
      }
      final summary = await _prepareArchiveSelectionSummary(selection, library);
      if (!context.mounted) {
        await _cleanupTemporaryArchiveSelection(selection.resolvedPath);
        return;
      }
      if (!_canPresentStructuredImport(
        context,
        requireCurrentRoute: requireCurrentRoute,
      )) {
        await _cleanupTemporaryArchiveSelection(selection.resolvedPath);
        return;
      }

      final action = await _showStructuredImportDialog(context, summary);
      if (!context.mounted ||
          action == null ||
          action == _StructuredImportDialogAction.cancel) {
        await _cleanupTemporaryArchiveSelection(selection.resolvedPath);
        return;
      }

      if (action == _StructuredImportDialogAction.preview) {
        await _cleanupTemporaryArchiveSelection(selection.resolvedPath);
        if (!context.mounted) return;
        if (!_canPresentStructuredImport(
          context,
          requireCurrentRoute: requireCurrentRoute,
        )) {
          return;
        }
        _showTopBanner(context, "压缩包预览功能暂未开放");
        return;
      }

      if (!context.mounted) return;
      final settings = Provider.of<SettingsService>(context, listen: false);
      final sortOptions = StructuredImportSortOptions.fromSettings(settings);
      final archivePath = await _ensureArchivePathForImport(context, selection);
      await library.importArchiveSelection(
        archivePath,
        collectionId,
        sortOptions: sortOptions,
        explicitPlacement: explicitPlacement,
      );
      if (!context.mounted) return;
      if (!_canPresentStructuredImport(
        context,
        requireCurrentRoute: requireCurrentRoute,
      )) {
        return;
      }
      if (library.hasPersistenceFailure) {
        return;
      }
    } catch (e) {
      await _cleanupTemporaryArchiveSelection(selection.resolvedPath);
      if (context.mounted) {
        await VideoActionButtons._showImportFailure(context, '压缩包导入失败', e);
      }
    } finally {
      _archiveImportUiBusy = false;
    }
  }

  static Future<void> processDroppedFolder(
    BuildContext context,
    String folderPath,
    String? collectionId, {
    bool explicitPlacement = true,
  }) async {
    _importFolder = collectionId;
    _importFailure.value = null;
    try {
      if (!context.mounted) return;
      if (!isMediaLibraryRouteCurrent(context)) return;
      final library = Provider.of<LibraryService>(context, listen: false);
      if (library.hasActiveImport) {
        _showTopBanner(
          context,
          '已有导入任务正在运行，请等待完成后再试',
          backgroundColor: const Color(0xFFB00020),
        );
        return;
      }
      final summary = await library.analyzeFolderSelection(folderPath);
      if (!context.mounted) return;
      if (!isMediaLibraryRouteCurrent(context)) return;

      final action = await _showStructuredImportDialog(context, summary);
      if (!context.mounted ||
          action == null ||
          action == _StructuredImportDialogAction.cancel) {
        return;
      }

      if (action == _StructuredImportDialogAction.preview) {
        _showTopBanner(context, "文件夹预览功能暂未开放");
        return;
      }

      final settings = Provider.of<SettingsService>(context, listen: false);
      final sortOptions = StructuredImportSortOptions.fromSettings(settings);
      _showTopBanner(context, "已开始导入文件夹：${summary.sourceName}");
      await library.importFolderSelection(
        folderPath,
        collectionId,
        sortOptions: sortOptions,
        explicitPlacement: explicitPlacement,
      );
      if (!context.mounted) return;
      if (!isMediaLibraryRouteCurrent(context)) return;
      if (library.hasPersistenceFailure) {
        return;
      }
    } catch (e) {
      if (context.mounted) {
        await VideoActionButtons._showImportFailure(context, '文件夹导入失败', e);
      }
    }
  }

  static Future<bool> _isTemporarySelectionPath(String path) async {
    try {
      final normalizedPath = p.normalize(path);
      for (final dir in await resolveImportCacheRoots()) {
        final archiveCache = p.normalize(p.join(dir.path, 'picked_archives'));
        if (p.isWithin(archiveCache, normalizedPath)) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  static Future<void> _cleanupTemporaryArchiveSelection(String? path) async {
    if (path == null || path.isEmpty) {
      return;
    }
    if (!await _isTemporarySelectionPath(path)) {
      return;
    }
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  static Future<StructuredImportSelectionSummary>
  _prepareArchiveSelectionSummary(
    _ArchiveSelection selection,
    LibraryService library,
  ) async {
    return selection.toSelectionSummary(library);
  }

  static Future<String> _ensureArchivePathForImport(
    BuildContext context,
    _ArchiveSelection selection,
  ) async {
    if (selection.hasResolvedPath) {
      return selection.resolvedPath!;
    }
    if (!Platform.isAndroid || selection.uri == null) {
      throw StateError('无法获取压缩包文件路径');
    }

    return _prepareWithProgress(context, '正在读取所选压缩包', () async {
      final result = await _fileManagerChannel.invokeMethod<Object?>(
        "materializeArchiveForImport",
        {"uri": selection.uri, "displayName": selection.displayName},
      );
      if (result is! String || result.isEmpty) {
        throw StateError('无法准备压缩包文件');
      }
      selection.resolvedPath = result;
      return result;
    });
  }

  static Future<_StructuredImportDialogAction?> _showStructuredImportDialog(
    BuildContext context,
    StructuredImportSelectionSummary summary,
  ) async {
    final settings = Provider.of<SettingsService>(context, listen: false);
    String sortField = settings.structuredImportSortField;
    String sortDirection = settings.structuredImportSortDirection;

    if (_structuredImportDialogCount > 0) {
      return _StructuredImportDialogAction.cancel;
    }
    _structuredImportDialogCount++;
    try {
      return await showDialog<_StructuredImportDialogAction>(
        context: context,
        useRootNavigator: true,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (context, setState) {
              Future<void> updateSortSetting({
                String? field,
                String? direction,
              }) async {
                if (field != null && direction != null) {
                  await settings.saveStructuredImportSort(
                    field: field,
                    direction: direction,
                  );
                } else if (field != null) {
                  await settings.saveStructuredImportSortField(field);
                } else if (direction != null) {
                  await settings.saveStructuredImportSortDirection(direction);
                } else {
                  return;
                }
                if (!dialogContext.mounted) {
                  return;
                }
                setState(() {
                  sortField = field ?? sortField;
                  sortDirection = direction ?? sortDirection;
                });
              }

              return AlertDialog(
                title: Text(summary.isArchive ? '确认导入压缩包' : '确认导入文件夹'),
                content: SizedBox(
                  width: 420,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('名称：${summary.sourceName}'),
                      const SizedBox(height: 8),
                      Text(
                        summary.isArchive
                            ? '导入后外层文件夹名称：${summary.rootCollectionName}'
                            : '最外层文件夹名称：${summary.rootCollectionName}',
                      ),
                      const SizedBox(height: 8),
                      Text('位置：${summary.sourcePath}'),
                      const SizedBox(height: 12),
                      if (summary.detailsDeferred)
                        const Text(
                          '压缩包将在点击“直接导入”后再解析与解压，当前不会触发解压操作。',
                          style: TextStyle(fontSize: 12, color: Colors.white70),
                        )
                      else
                        Text(
                          '检测到 ${summary.folderCount} 个文件夹，${summary.mediaFileCount} 个可导入媒体文件。',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white70,
                          ),
                        ),
                      const SizedBox(height: 16),
                      const Text(
                        '导入顺序',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      CapsuleDropdownButtonFormField<String>(
                        initialValue: sortField,
                        items: const [
                          DropdownMenuItem(
                            value: 'fileName',
                            child: Text('按文件名排序'),
                          ),
                          DropdownMenuItem(
                            value: 'modifiedTime',
                            child: Text('按修改时间排序'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          updateSortSetting(field: value);
                        },
                        decoration: const InputDecoration(labelText: '排序方式'),
                      ),
                      const SizedBox(height: 8),
                      CapsuleDropdownButtonFormField<String>(
                        initialValue: sortDirection,
                        items: [
                          DropdownMenuItem(
                            value: 'ascending',
                            child: Text(
                              sortField == 'modifiedTime' ? '从旧到新' : '正序',
                            ),
                          ),
                          DropdownMenuItem(
                            value: 'descending',
                            child: Text(
                              sortField == 'modifiedTime' ? '从新到旧' : '倒序',
                            ),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          updateSortSetting(direction: value);
                        },
                        decoration: const InputDecoration(labelText: '顺序方向'),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        '以上排序会永久保存，下次导入时会自动沿用。',
                        style: TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                    ],
                  ),
                ),
                actions: [
                  DesktopButtonClickRegion(
                    child: TextButton(
                      onPressed: () {
                        Navigator.pop(
                          dialogContext,
                          _StructuredImportDialogAction.cancel,
                        );
                      },
                      child: const Text('取消导入'),
                    ),
                  ),
                  DesktopButtonClickRegion(
                    child: TextButton(
                      onPressed: () {
                        Navigator.pop(
                          dialogContext,
                          _StructuredImportDialogAction.preview,
                        );
                      },
                      child: const Text('预览'),
                    ),
                  ),
                  DesktopButtonClickRegion(
                    child: FilledButton(
                      onPressed: () {
                        Navigator.pop(
                          dialogContext,
                          _StructuredImportDialogAction.confirm,
                        );
                      },
                      child: const Text('直接导入'),
                    ),
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      _structuredImportDialogCount--;
    }
  }

  @override
  State<VideoActionButtons> createState() => _VideoActionButtonsState();
}

class _VideoActionButtonsState extends State<VideoActionButtons> {
  final ScrollController _railScrollController = ScrollController();

  String _fabTooltip(
    String label,
    DesktopMediaManagementShortcutAction action,
  ) {
    if (!supportsNativeHardwareKeyboardShortcuts) return label;
    return DesktopMediaManagementShortcuts.buildTooltip(
      label,
      action,
      context: context,
    );
  }

  Future<void> importVideos(BuildContext context, String? collectionId) {
    return VideoActionButtons.showImportMenu(context, collectionId);
  }

  @override
  void dispose() {
    _railScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: VideoActionButtons._importFailure,
    builder: (context, failure, _) => _buildActions(context),
  );

  bool get _importFailed =>
      VideoActionButtons._importFailure.value != null &&
      VideoActionButtons._importFailure.value!.folder == widget.collectionId;

  Widget _buildActions(BuildContext context) {
    if (widget.isHorizontal) {
      return Wrap(
        alignment: WrapAlignment.center,
        spacing: 16,
        runSpacing: 12,
        children: [
          DesktopButtonClickRegion(
            child: ElevatedButton(
              onPressed: () {
                pushAboveMediaLibrary(
                  context,
                  AppMaterialPageRoute(
                    builder: (_) =>
                        BatchSubtitleScreen(collectionId: widget.collectionId),
                    settings: const RouteSettings(name: '/batch_subtitle'),
                  ),
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.teal,
                foregroundColor: Colors.white,
              ),
              child: const Text("语音转录"),
            ),
          ),
          DesktopButtonClickRegion(
            child: ElevatedButton(
              onPressed: () => VideoActionButtons.openBatchImportPage(
                context,
                collectionId: widget.collectionId,
              ),
              child: const Text('批量字幕导入'),
            ),
          ),
          DesktopButtonClickRegion(
            child: ElevatedButton(
              onPressed: () =>
                  showCreateCollectionDialog(context, widget.collectionId),
              child: const Text("新建合集"),
            ),
          ),
          DesktopButtonClickRegion(
            child: ElevatedButton(
              onPressed: () => importVideos(context, widget.collectionId),
              child: Text(_importFailed ? "导入失败，重新选择" : "导入视频或音频"),
            ),
          ),
        ],
      );
    }

    return Consumer<SettingsService>(
      builder: (context, settings, _) => LayoutBuilder(
        builder: (context, constraints) {
          final isCollapsed = settings.isActionButtonsCollapsed;
          final screenSize = MediaQuery.sizeOf(context);
          final padding = MediaQuery.paddingOf(context);
          final availableHeight = math.max(
            0.0,
            math.min(
              widget.maxExpandedHeight ?? double.infinity,
              math.min(
                constraints.maxHeight,
                screenSize.height - padding.vertical - 80,
              ),
            ),
          );
          final availableWidth = math.min(
            constraints.maxWidth,
            math.max(0.0, screenSize.width - padding.horizontal - 32),
          );
          final actionBuilders = <Widget Function(VideoActionRailLayout)>[
            (layout) => _railButton(
              label: '语音转录',
              layout: layout,
              tooltip: _fabTooltip(
                "语音转录",
                DesktopMediaManagementShortcutAction.openBatchSubtitle,
              ),
              icon: Icons.closed_caption,
              onPressed: () {
                pushAboveMediaLibrary(
                  context,
                  AppMaterialPageRoute(
                    builder: (_) =>
                        BatchSubtitleScreen(collectionId: widget.collectionId),
                    settings: const RouteSettings(name: '/batch_subtitle'),
                  ),
                );
              },
            ),
            (layout) => _railButton(
              label: '批量字幕导入',
              layout: layout,
              tooltip: _fabTooltip(
                '批量字幕导入',
                DesktopMediaManagementShortcutAction.openBatchImport,
              ),
              icon: Icons.playlist_add,
              onPressed: () => VideoActionButtons.openBatchImportPage(
                context,
                collectionId: widget.collectionId,
              ),
            ),
            (layout) => _railButton(
              label: '新建合集',
              layout: layout,
              tooltip: _fabTooltip(
                "新建合集",
                DesktopMediaManagementShortcutAction.createCollection,
              ),
              icon: Icons.create_new_folder,
              onPressed: () =>
                  showCreateCollectionDialog(context, widget.collectionId),
            ),
            (layout) => _railButton(
              label: _importFailed ? '导入失败' : '导入媒体',
              layout: layout,
              tooltip: _fabTooltip(
                "导入视频或音频",
                DesktopMediaManagementShortcutAction.importMedia,
              ),
              icon: _importFailed ? Icons.error_outline : Icons.video_call,
              color: _importFailed
                  ? Theme.of(context).colorScheme.error
                  : AppTokens.text1,
              onPressed: () => importVideos(context, widget.collectionId),
            ),
          ];
          final layout = VideoActionRailLayout.resolve(
            screenSize: screenSize,
            availableWidth: availableWidth,
            availableHeight: availableHeight,
            textScaler: MediaQuery.textScalerOf(context),
            showLabels: settings.showActionButtonLabels,
            actionCount: actionBuilders.length,
          );
          Widget toggle([Animation<double>? expansion]) => _railButton(
            label: isCollapsed ? '展开' : '收起',
            layout: layout,
            isToggle: true,
            isCollapsed: isCollapsed,
            expansion: expansion,
            tooltip: _fabTooltip(
              isCollapsed ? '展开' : '收起',
              DesktopMediaManagementShortcutAction.toggleActionButtons,
            ),
            icon: Icons.keyboard_arrow_up,
            color: AppTokens.text1,
            onPressed: () {
              settings.updateSetting(
                'isActionButtonsCollapsed',
                !settings.isActionButtonsCollapsed,
              );
            },
          );

          // In exceptionally small windows keep just the toggle within bounds.
          if (availableHeight < layout.cellHeight ||
              availableWidth < layout.cellWidth) {
            return SizedBox(
              width: math.min(layout.cellWidth, availableWidth),
              height: math.min(layout.cellHeight, availableHeight),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.bottomRight,
                child: toggle(),
              ),
            );
          }

          return VideoActionRail(
            layout: layout,
            maxHeight: availableHeight,
            collapsed: isCollapsed,
            scrollController: _railScrollController,
            actions: [
              for (final buildAction in actionBuilders) buildAction(layout),
            ],
            toggleBuilder: toggle,
          );
        },
      ),
    );
  }

  /// The circle handles input; the name is only a visual identifier.
  Widget _railButton({
    required String label,
    required VideoActionRailLayout layout,
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
    Color color = AppTokens.text1,
    bool isToggle = false,
    bool isCollapsed = false,
    Animation<double>? expansion,
  }) => VideoActionRailButton(
    label: label,
    layout: layout,
    tooltip: tooltip,
    icon: icon,
    onPressed: onPressed,
    color: color,
    showLabel: context.read<SettingsService>().showActionButtonLabels,
    isToggle: isToggle,
    isCollapsed: isCollapsed,
    expansion: expansion,
  );

  void showCreateCollectionDialog(BuildContext context, String? parentId) {
    if (widget.onCreateCollection case final create?) {
      create();
    } else {
      unawaited(
        VideoActionButtons.openCreateCollectionDialog(context, parentId),
      );
    }
  }

  static Future<bool> _requestStoragePermissionIfNeeded(
    BuildContext context,
  ) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return true;
    }
    final hasPermission =
        await Permission.videos.request().isGranted ||
        await Permission.storage.request().isGranted ||
        await Permission.manageExternalStorage.request().isGranted;
    if (!hasPermission && context.mounted) {
      VideoActionButtons._showTopBanner(
        context,
        "未获得存储权限，请在系统设置中开启",
        backgroundColor: const Color(0xFFB00020),
        actionText: "去设置",
        onActionPressed: () {
          openAppSettings();
        },
      );
    }
    return hasPermission;
  }

  static String sheetTitle(
    BuildContext context,
    String label,
    ImportSheetShortcutAction action,
  ) {
    return tooltipWithShortcutKey(
      label,
      ImportSheetShortcuts.defaults[action]!,
      context: context,
    );
  }

  static Future<void> openImportMenu(
    BuildContext context,
    String? collectionId,
  ) async {
    VideoActionButtons._importFolder = collectionId;
    final mainContext = context;
    await showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) {
        void run(ImportSheetShortcutAction action) {
          if (action != ImportSheetShortcutAction.close) {
            VideoActionButtons._importFailure.value = null;
          }
          switch (action) {
            case ImportSheetShortcutAction.close:
              Navigator.pop(sheetContext);
              return;
            case ImportSheetShortcutAction.gallery:
              if (!ImportSheetShortcuts.isVisible(action)) return;
              Navigator.pop(sheetContext);
              _VideoActionButtonsState._pickFromGallery(
                mainContext,
                collectionId,
              );
              return;
            case ImportSheetShortcutAction.files:
              Navigator.pop(sheetContext);
              _VideoActionButtonsState._pickFromFileManager(
                mainContext,
                collectionId,
              );
              return;
            case ImportSheetShortcutAction.bilibiliOnline:
              Navigator.pop(sheetContext);
              VideoActionButtons.openBilibiliDownloadPage(
                mainContext,
                collectionId: collectionId,
                streamingMode: true,
              );
              return;
            case ImportSheetShortcutAction.archive:
              Navigator.pop(sheetContext);
              _VideoActionButtonsState._pickArchiveFromFileManager(
                mainContext,
                collectionId,
              );
              return;
            case ImportSheetShortcutAction.folder:
              if (!ImportSheetShortcuts.isVisible(action)) return;
              Navigator.pop(sheetContext);
              _VideoActionButtonsState._pickFolderFromFileManager(
                mainContext,
                collectionId,
              );
              return;
            case ImportSheetShortcutAction.fluentPack:
              Navigator.pop(sheetContext);
              unawaited(
                PortableTransferNavigation.openImportTab(
                  mainContext,
                  libraryFolderId: collectionId,
                ),
              );
              return;
          }
        }

        return _ImportSheetShortcutHost(
          onAction: run,
          child: SafeArea(
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                ValueListenableBuilder(
                  valueListenable: VideoActionButtons._importFailure,
                  builder: (context, failure, _) {
                    if (failure == null || failure.folder != collectionId) {
                      return const SizedBox.shrink();
                    }
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: OperationStatus(
                        title: failure.message,
                        kind: OperationStatusKind.error,
                        details: failure.details,
                        actions: [
                          if (failure.action != null)
                            TextButton(
                              onPressed: failure.action,
                              child: Text(failure.actionLabel ?? '重试'),
                            ),
                        ],
                      ),
                    );
                  },
                ),
                if (ImportSheetShortcuts.isVisible(
                  ImportSheetShortcutAction.gallery,
                ))
                  ListTile(
                    leading: const Icon(Icons.photo_library),
                    title: Text(
                      _VideoActionButtonsState.sheetTitle(
                        sheetContext,
                        '从相册导入',
                        ImportSheetShortcutAction.gallery,
                      ),
                    ),
                    onTap: () => run(ImportSheetShortcutAction.gallery),
                  ),
                ListTile(
                  leading: const Icon(Icons.folder_open),
                  title: Text(
                    _VideoActionButtonsState.sheetTitle(
                      sheetContext,
                      '从文件管理导入',
                      ImportSheetShortcutAction.files,
                    ),
                  ),
                  onTap: () => run(ImportSheetShortcutAction.files),
                ),
                ListTile(
                  leading: const Icon(Icons.archive_outlined),
                  title: Text(
                    _VideoActionButtonsState.sheetTitle(
                      sheetContext,
                      '从文件管理导入压缩包',
                      ImportSheetShortcutAction.archive,
                    ),
                  ),
                  onTap: () => run(ImportSheetShortcutAction.archive),
                ),
                if (ImportSheetShortcuts.isVisible(
                  ImportSheetShortcutAction.folder,
                ))
                  ListTile(
                    leading: const Icon(Icons.create_new_folder_outlined),
                    title: Text(
                      _VideoActionButtonsState.sheetTitle(
                        sheetContext,
                        '从文件管理导入文件夹',
                        ImportSheetShortcutAction.folder,
                      ),
                    ),
                    onTap: () => run(ImportSheetShortcutAction.folder),
                  ),
                ListTile(
                  leading: const Icon(Icons.south_west_rounded),
                  title: Text(
                    _VideoActionButtonsState.sheetTitle(
                      sheetContext,
                      '从 FluentPack 文件导入',
                      ImportSheetShortcutAction.fluentPack,
                    ),
                  ),
                  subtitle: const Text('打开导入页，选择 .fluentpack 或压缩包'),
                  onTap: () => run(ImportSheetShortcutAction.fluentPack),
                ),
                ListTile(
                  leading: const Icon(Icons.playlist_add),
                  title: const Text('批量字幕导入'),
                  subtitle: const Text('选择本地媒体与字幕，配对后导入媒体库'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    VideoActionButtons.openBatchImportPage(
                      mainContext,
                      collectionId: collectionId,
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static Future<void> _pickFromGallery(
    BuildContext context,
    String? collectionId,
  ) async {
    try {
      final requestType = await requestImportGalleryAccess();
      if (requestType == null) {
        if (context.mounted) {
          VideoActionButtons._showTopBanner(
            context,
            "未获得相册权限，请在系统设置中开启",
            backgroundColor: const Color(0xFFB00020),
            actionText: "去设置",
            onActionPressed: () {
              openAppSettings();
            },
          );
        }
        return;
      }

      if (!context.mounted) return;
      final List<AssetEntity>? assets = await AssetPicker.pickAssets(
        context,
        pickerConfig: AssetPickerConfig(
          requestType: requestType,
          maxAssets: 999,
        ),
      );

      if (assets == null || assets.isEmpty) {
        if (context.mounted) {
          VideoActionButtons._showTopBanner(context, "未选择任何媒体");
        }
        return;
      }

      if (!context.mounted) return;
      final List<String> paths = [];
      final List<String> originalTitles = [];

      await VideoActionButtons._prepareWithProgress(
        context,
        '正在读取所选媒体文件',
        () async {
          for (final asset in assets) {
            final File? file = await asset.file;
            if (file == null) continue;
            paths.add(file.path);

            String title = asset.title ?? '';
            if (title.isEmpty || title.trim().isEmpty) {
              final date = asset.createDateTime;
              final prefix = asset.type == AssetType.video
                  ? "Video"
                  : (asset.type == AssetType.audio ? "Audio" : "Media");
              title =
                  "${prefix}_${date.year}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}_${date.hour.toString().padLeft(2, '0')}${date.minute.toString().padLeft(2, '0')}${date.second.toString().padLeft(2, '0')}";
            }
            originalTitles.add(title);
          }
        },
      );

      if (paths.isEmpty) {
        if (context.mounted) {
          VideoActionButtons._showTopBanner(
            context,
            "未找到可用的视频文件",
            backgroundColor: const Color(0xFFB00020),
          );
        }
        return;
      }

      if (context.mounted) {
        final library = Provider.of<LibraryService>(context, listen: false);
        VideoActionButtons._showTopBanner(
          context,
          "已开始后台导入 ${paths.length} 个媒体文件",
          autoHideDuration: const Duration(seconds: 2),
        );
        library.importVideosBackground(
          paths,
          collectionId,
          shouldCopy: false,
          originalTitles: originalTitles,
        );
      }
    } catch (e) {
      if (context.mounted) {
        await VideoActionButtons._showImportFailure(context, '相册导入失败', e);
      }
    }
  }

  static Future<void> _pickFromFileManager(
    BuildContext context,
    String? collectionId,
  ) async {
    try {
      final filterExtensions =
          SettingsService().localImportFilterMediaExtensions;
      // SAF grants access to the selected files; broad media/all-files
      // permissions must not block the system document picker.
      if (defaultTargetPlatform == TargetPlatform.android) {
        final result = await VideoActionButtons._fileManagerChannel
            .invokeMethod<Object?>("pickFiles", {
              "mimeTypes": filterExtensions ? ["video/*", "audio/*"] : ["*/*"],
              "filterMediaExtensions": filterExtensions,
              "allowMultiple": true,
              "includeSourceHints": true,
            });
        final rawPaths = result is Map ? result['paths'] : result;
        final pickedPaths = rawPaths is List
            ? rawPaths.whereType<String>().toList()
            : <String>[];
        if (pickedPaths.isEmpty) {
          if (context.mounted) {
            VideoActionButtons._showTopBanner(context, "未选择任何媒体");
          }
          return;
        }

        if (context.mounted) {
          await VideoActionButtons.processImportedFiles(
            context,
            pickedPaths,
            collectionId,
            sidecarSourcePaths: VideoActionButtons._selectedSourcePathHints(
              result is Map ? result['sourcePathHints'] : null,
              pickedPaths,
            ),
          );
        }
        return;
      }

      final result = await FilePicker.platform.pickFiles(
        type: filterExtensions ? FileType.custom : FileType.any,
        allowedExtensions: filterExtensions
            ? LibraryService.supportedMediaExtensions
                  .map((ext) => ext.replaceFirst('.', ''))
                  .toList()
            : null,
        allowMultiple: true,
        withData: false,
        withReadStream: false,
      );

      if (result == null || result.files.isEmpty) {
        return;
      }

      final paths = result.files
          .map((f) => normalizeLocalFilesystemPath(f.path))
          .whereType<String>()
          .toList();
      if (paths.isEmpty) {
        if (context.mounted) {
          VideoActionButtons._showTopBanner(context, "未选择任何媒体");
        }
        return;
      }

      if (context.mounted) {
        await VideoActionButtons.processImportedFiles(
          context,
          paths,
          collectionId,
        );
      }
    } catch (e) {
      if (context.mounted) {
        await VideoActionButtons._showImportFailure(context, '导入启动失败', e);
      }
    }
  }

  static Future<void> _pickArchiveFromFileManager(
    BuildContext context,
    String? collectionId,
  ) async {
    String? archivePath;
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final result = await VideoActionButtons._fileManagerChannel
            .invokeMethod<Map<dynamic, dynamic>?>("pickArchive");
        if (result == null) {
          if (context.mounted) {
            VideoActionButtons._showTopBanner(context, "未选择压缩包");
          }
          return;
        }
        final selection = _ArchiveSelection.fromNativeMap(result);
        archivePath = selection.resolvedPath;
        if (context.mounted) {
          await VideoActionButtons._processSelectedArchive(
            context,
            selection,
            collectionId,
          );
        }
        return;
      }

      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: VideoActionButtons._structuredArchiveExtensions,
        allowMultiple: false,
        withData: false,
        withReadStream: false,
      );
      archivePath = normalizeLocalFilesystemPath(
        result?.files.singleOrNull?.path,
      );
      if (archivePath == null || archivePath.isEmpty) {
        if (context.mounted) {
          VideoActionButtons._showTopBanner(context, "未选择压缩包");
        }
        return;
      }

      if (!context.mounted) {
        return;
      }
      await VideoActionButtons.processDroppedArchive(
        context,
        archivePath,
        collectionId,
        explicitPlacement: false,
      );
    } catch (e) {
      await VideoActionButtons._cleanupTemporaryArchiveSelection(archivePath);
      if (context.mounted) {
        await VideoActionButtons._showImportFailure(context, '压缩包导入失败', e);
      }
    }
  }

  static Future<void> _pickFolderFromFileManager(
    BuildContext context,
    String? collectionId,
  ) async {
    try {
      if (!await _requestStoragePermissionIfNeeded(context)) {
        return;
      }

      final folderPath = normalizeLocalFilesystemPath(
        await FilePicker.platform.getDirectoryPath(dialogTitle: '选择要导入的文件夹'),
      );
      if (folderPath == null || folderPath.isEmpty) {
        if (context.mounted) {
          VideoActionButtons._showTopBanner(context, "未选择文件夹");
        }
        return;
      }

      if (!context.mounted) return;
      await VideoActionButtons.processDroppedFolder(
        context,
        folderPath,
        collectionId,
        explicitPlacement: false,
      );
    } catch (e) {
      if (context.mounted) {
        await VideoActionButtons._showImportFailure(context, '文件夹导入失败', e);
      }
    }
  }
}

enum _StructuredImportDialogAction { cancel, preview, confirm }

class _ArchiveSelection {
  final String displayName;
  final String? uri;
  final int? sizeBytes;
  String? resolvedPath;

  _ArchiveSelection({
    required this.displayName,
    required this.uri,
    required this.sizeBytes,
    required this.resolvedPath,
  });

  factory _ArchiveSelection.fromResolvedPath(String path) {
    int? sizeBytes;
    try {
      final file = File(path);
      if (file.existsSync()) {
        sizeBytes = file.lengthSync();
      }
    } catch (_) {}
    return _ArchiveSelection(
      displayName: p.basename(path),
      uri: null,
      sizeBytes: sizeBytes,
      resolvedPath: path,
    );
  }

  factory _ArchiveSelection.fromNativeMap(Map<dynamic, dynamic> raw) {
    final displayName = (raw['displayName'] as String?)?.trim();
    final uri = (raw['uri'] as String?)?.trim();
    final path = (raw['path'] as String?)?.trim();
    final sizeValue = raw['sizeBytes'];
    int? sizeBytes;
    if (sizeValue is int) {
      sizeBytes = sizeValue;
    } else if (sizeValue is num) {
      sizeBytes = sizeValue.toInt();
    }
    return _ArchiveSelection(
      displayName: (displayName == null || displayName.isEmpty)
          ? (path == null || path.isEmpty ? 'archive' : p.basename(path))
          : displayName,
      uri: uri == null || uri.isEmpty ? null : uri,
      sizeBytes: sizeBytes,
      resolvedPath: path == null || path.isEmpty ? null : path,
    );
  }

  bool get hasResolvedPath => resolvedPath != null && resolvedPath!.isNotEmpty;

  String? get sizeLabel {
    if (sizeBytes == null || sizeBytes! <= 0) {
      return null;
    }
    return LibraryService.formatSize(sizeBytes!);
  }

  StructuredImportSelectionSummary toSelectionSummary(LibraryService library) {
    // App-owned temporary copies may have UUID/timestamp prefixes. The
    // original display name is the stable source for validation and the root
    // collection title.
    final archiveNameOrPath = displayName;
    if (!LibraryService.isSupportedArchivePath(archiveNameOrPath)) {
      throw UnsupportedError('当前仅支持 zip、tar、tar.gz、tar.bz2、tar.xz 压缩包');
    }
    final sourcePath = hasResolvedPath
        ? resolvedPath!
        : 'Android 系统文件管理器已选中：$displayName';
    return StructuredImportSelectionSummary(
      sourcePath: sourcePath,
      sourceName: displayName,
      rootCollectionName: LibraryService.archiveRootCollectionName(
        archiveNameOrPath,
      ),
      isArchive: true,
      folderCount: 0,
      mediaFileCount: 0,
      detailsDeferred: true,
    );
  }
}

/// Owns hardware-keyboard listeners for the import bottom sheet so keys still
/// fire when Focus is lost or an attached phone keyboard bypasses Focus.
class _ImportSheetShortcutHost extends StatefulWidget {
  const _ImportSheetShortcutHost({required this.onAction, required this.child});

  final void Function(ImportSheetShortcutAction action) onAction;
  final Widget child;

  @override
  State<_ImportSheetShortcutHost> createState() =>
      _ImportSheetShortcutHostState();
}

class _ImportSheetShortcutHostState extends State<_ImportSheetShortcutHost> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'ImportSheetShortcuts');
  final AndroidHardwareKeyDeduplicator _androidKeyDeduplicator =
      AndroidHardwareKeyDeduplicator();

  @override
  void initState() {
    super.initState();
    AndroidHardwareInputBridge.addKeyListener(_handleAndroidHardwareKeyEvent);
    HardwareKeyboard.instance.addHandler(_handleGlobalHardwareKeyEvent);
  }

  @override
  void dispose() {
    AndroidHardwareInputBridge.removeKeyListener(
      _handleAndroidHardwareKeyEvent,
    );
    HardwareKeyboard.instance.removeHandler(_handleGlobalHardwareKeyEvent);
    _focusNode.dispose();
    super.dispose();
  }

  bool _handleGlobalHardwareKeyEvent(KeyEvent event) {
    if (_focusNode.hasFocus) return false;
    return _handleKey(event) != KeyEventResult.ignored;
  }

  void _handleAndroidHardwareKeyEvent(AndroidHardwareKeyMessage message) {
    _handleKey(
      message.toKeyEvent(),
      fromAndroidNativeBridge: true,
      hasBlockingModifierOverride: message.hasBlockingModifier,
    );
  }

  KeyEventResult _handleKey(
    KeyEvent event, {
    bool fromAndroidNativeBridge = false,
    bool? hasBlockingModifierOverride,
  }) {
    if (!supportsNativeHardwareKeyboardShortcuts) {
      return KeyEventResult.ignored;
    }
    if (Platform.isAndroid &&
        !_androidKeyDeduplicator.shouldDispatch(
          event,
          fromNativeBridge: fromAndroidNativeBridge,
        )) {
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final bool hasBlockingModifier =
        hasBlockingModifierOverride ?? hasBlockingKeyboardModifier();
    if (hasBlockingModifier) return KeyEventResult.ignored;
    final ImportSheetShortcutAction? action = ImportSheetShortcuts.matchAction(
      event.logicalKey,
    );
    if (action == null) return KeyEventResult.ignored;
    widget.onAction(action);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (node, event) => _handleKey(event),
      child: widget.child,
    );
  }
}
