import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:path/path.dart' as p;

import '../../services/library_service.dart';
import '../../models/import_card_placement.dart';
import '../../utils/app_toast.dart';
import '../../utils/incoming_share_signatures.dart';
import 'portable_transfer_models.dart';
import 'portable_transfer_screen.dart';
import 'portable_transfer_service.dart';

/// Classifies dropped / shared paths so FluentPack never mixes with media import.
class PortableIncomingClassification {
  static const dropMixMessage = '拖入 FluentPack 文件时请不要与媒体、压缩包或文件夹混在一起';
  static const shareMixMessage = '系统分享 FluentPack 文件时请不要与媒体或压缩包混合分享';

  static bool isPackagePath(String pathOrName) =>
      PortableTransferService.hasPackageExtension(pathOrName);

  /// File-name classification used by tests and share payloads that already
  /// resolved to a path. Directories must be detected by the caller.
  static PortableIncomingFileKind kindForFileName(String pathOrName) {
    if (isPackagePath(pathOrName)) {
      return PortableIncomingFileKind.fluentpack;
    }
    if (LibraryService.isSupportedMediaPath(pathOrName)) {
      return PortableIncomingFileKind.media;
    }
    if (LibraryService.isSupportedArchivePath(pathOrName)) {
      return PortableIncomingFileKind.archive;
    }
    return PortableIncomingFileKind.other;
  }

  static bool isMixed({
    required bool hasFluentPack,
    required bool hasOtherSupported,
  }) => hasFluentPack && hasOtherSupported;
}

enum PortableIncomingFileKind { fluentpack, media, archive, folder, other }

/// Single entry point onto [PortableTransferScreen] so FAB / drop / share /
/// media-library selection all land on the same import or export flow.
class PortableTransferNavigation {
  static const routeName = '/portable_transfer';

  static final Map<String, DateTime> _recentLaunchSignatures =
      <String, DateTime>{};

  static Future<void> open(
    BuildContext context, {
    PortableTransferKind initialTab = PortableTransferKind.export,
    List<PortableImportSource>? pendingImportSources,
    List<String>? pendingExportRootIds,
    String? libraryFolderId,
    ImportPlacementRequest? pendingImportPlacement,
  }) async {
    final navigator = _navigator(context);
    if (navigator == null) return;

    final launchSignature = _launchSignature(
      initialTab: initialTab,
      pendingImportSources: pendingImportSources,
      pendingExportRootIds: pendingExportRootIds,
    );
    if (launchSignature != null &&
        !IncomingShareSignatures.accept(
          launchSignature,
          _recentLaunchSignatures,
        )) {
      return;
    }

    await navigator.pushAndRemoveUntil<void>(
      AppMaterialPageRoute<void>(
        builder: (_) => PortableTransferScreen(
          initialTab: initialTab,
          pendingImportSources: pendingImportSources,
          pendingExportRootIds: pendingExportRootIds,
          libraryFolderId: libraryFolderId,
          pendingImportPlacement: pendingImportPlacement,
        ),
        settings: const RouteSettings(name: routeName),
      ),
      (route) => route.settings.name != routeName,
    );
  }

  static Future<void> openImportTab(
    BuildContext context, {
    String? libraryFolderId,
  }) {
    return open(
      context,
      initialTab: PortableTransferKind.import,
      libraryFolderId: libraryFolderId,
    );
  }

  static Future<void> openAndImportPackages(
    BuildContext context,
    List<PortableImportSource> sources, {
    String? libraryFolderId,
    ImportPlacementRequest? importPlacement,
  }) {
    final valid = sources
        .where((source) => source.path.trim().isNotEmpty)
        .toList(growable: false);
    if (valid.isEmpty) return Future<void>.value();
    return open(
      context,
      initialTab: PortableTransferKind.import,
      pendingImportSources: valid,
      pendingImportPlacement: importPlacement,
      libraryFolderId: libraryFolderId,
    );
  }

  static Future<void> openExportSettings(
    BuildContext context,
    List<String> rootIds,
  ) {
    final valid = rootIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    if (valid.isEmpty) return Future<void>.value();
    return open(
      context,
      initialTab: PortableTransferKind.export,
      pendingExportRootIds: valid,
    );
  }

  /// Returns true when the drop was a FluentPack (or a mixed drop that must
  /// not fall through to media / archive import). Nested [DropTarget]s may
  /// both fire; [openAndImportPackages] dedupes the actual navigation.
  static Future<bool> handleDroppedPaths(
    BuildContext context,
    List<String> paths, {
    String? libraryFolderId,
  }) async {
    final fluentpackPaths = <String>[];
    var hasOtherSupported = false;

    for (final rawPath in paths) {
      final path = rawPath.trim();
      if (path.isEmpty) continue;
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        hasOtherSupported = true;
        continue;
      }
      if (type != FileSystemEntityType.file) continue;
      final kind = PortableIncomingClassification.kindForFileName(path);
      if (kind == PortableIncomingFileKind.fluentpack) {
        fluentpackPaths.add(path);
      } else if (kind == PortableIncomingFileKind.media ||
          kind == PortableIncomingFileKind.archive) {
        hasOtherSupported = true;
      }
    }

    if (fluentpackPaths.isEmpty) return false;
    if (!context.mounted) return true;

    if (PortableIncomingClassification.isMixed(
      hasFluentPack: true,
      hasOtherSupported: hasOtherSupported,
    )) {
      AppToast.show(
        PortableIncomingClassification.dropMixMessage,
        type: AppToastType.error,
      );
      return true;
    }

    await openAndImportPackages(
      context,
      fluentpackPaths
          .map(PortableImportSource.fromPath)
          .toList(growable: false),
      libraryFolderId: libraryFolderId,
      importPlacement: ImportPlacementRequest.explicit(
        ImportCardFeature.fluentPack,
        libraryFolderId,
      ),
    );
    return true;
  }

  static NavigatorState? _navigator(BuildContext context) {
    return AppToast.navigatorKey.currentState ??
        Navigator.maybeOf(context, rootNavigator: true);
  }

  static String? _launchSignature({
    required PortableTransferKind initialTab,
    List<PortableImportSource>? pendingImportSources,
    List<String>? pendingExportRootIds,
  }) {
    final importPaths = pendingImportSources
        ?.map((source) {
          final normalized = p.normalize(source.path);
          return Platform.isWindows ? normalized.toLowerCase() : normalized;
        })
        .where((path) => path.isNotEmpty)
        .toList();
    importPaths?.sort();
    final exportIds = pendingExportRootIds
        ?.map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList();
    exportIds?.sort();
    if ((importPaths == null || importPaths.isEmpty) &&
        (exportIds == null || exportIds.isEmpty)) {
      // Opening the bare tab should not be swallowed by drop/share dedupe.
      return null;
    }
    return <String>[
      initialTab.name,
      if (importPaths != null && importPaths.isNotEmpty)
        'import:${importPaths.join('|')}',
      if (exportIds != null && exportIds.isNotEmpty)
        'export:${exportIds.join('|')}',
    ].join('||');
  }
}

bool get isDesktopPortableDropHost =>
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
