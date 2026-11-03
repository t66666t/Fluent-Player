import '../../models/bilibili_models.dart';
import '../../models/import_card_placement.dart';
import '../../models/video_item.dart';
import '../library_service.dart';
import '../settings_service.dart';
import 'bilibili_download_service.dart';
import 'bilibili_history_service.dart';
import 'bilibili_stream_card.dart';

/// Multi-part videos up to this size are imported with every part (the
/// episode list is complete); larger ones only with the current part.
const int kBilibiliAutoFillPartLimit = 50;

enum BilibiliImportTargetKind {
  /// Nothing picked yet: the import placement rules decide, as before.
  automatic,
  root,
  folder,
}

/// Where the Bilibili import button puts cards, as kept in
/// [SettingsService.bilibiliImportTarget].
class BilibiliImportTarget {
  const BilibiliImportTarget._(this.kind, [this.folderId]);

  static const BilibiliImportTarget automatic = BilibiliImportTarget._(
    BilibiliImportTargetKind.automatic,
  );
  static const BilibiliImportTarget root = BilibiliImportTarget._(
    BilibiliImportTargetKind.root,
  );

  factory BilibiliImportTarget.folder(String id) =>
      BilibiliImportTarget._(BilibiliImportTargetKind.folder, id);

  /// A place picked in the folder picker; null is the library root.
  factory BilibiliImportTarget.picked(String? folderId) =>
      folderId == null ? root : BilibiliImportTarget.folder(folderId);

  factory BilibiliImportTarget.fromSettings(SettingsService settings) {
    final rule = settings.importPlacementRules.effectiveRule(
      ImportCardFeature.bilibiliPage,
      settings.importCardPlacementMode,
    );
    return switch (rule.placement) {
      ImportCardPlacement.libraryRoot => root,
      ImportCardPlacement.fixedFolder => BilibiliImportTarget.picked(
        rule.folderId,
      ),
      _ => automatic,
    };
  }

  static const String _rootValue = 'root';
  static const String _folderPrefix = 'folder:';

  factory BilibiliImportTarget.parse(String raw) {
    final value = raw.trim();
    if (value == _rootValue) return root;
    if (value.startsWith(_folderPrefix)) {
      final id = value.substring(_folderPrefix.length);
      if (id.isNotEmpty) return BilibiliImportTarget.folder(id);
    }
    return automatic;
  }

  final BilibiliImportTargetKind kind;
  final String? folderId;

  String encode() => switch (kind) {
    BilibiliImportTargetKind.automatic => '',
    BilibiliImportTargetKind.root => _rootValue,
    BilibiliImportTargetKind.folder => '$_folderPrefix$folderId',
  };

  @override
  bool operator ==(Object other) =>
      other is BilibiliImportTarget &&
      other.kind == kind &&
      other.folderId == folderId;

  @override
  int get hashCode => Object.hash(kind, folderId);

  @override
  String toString() => 'BilibiliImportTarget(${encode()})';
}

/// The library card of [bvid] part [page], when it was imported.
VideoItem? findImportedBilibiliCard(
  LibraryService library, {
  required String bvid,
  required int page,
}) {
  return findBilibiliStreamCard(
    library.bilibiliStreamItems,
    bvid: bvid,
    page: page,
    collectionOf: library.getCollection,
  );
}

/// The part an import acts on when the caller names none: the part of a
/// watch-only card still alive for [bvid] (the one being watched; the
/// playing one wins), else the part saved in the watch history, else 1.
int bilibiliImportPartOf(
  LibraryService library, {
  required String bvid,
  BilibiliHistoryService? history,
  String? playingItemId,
}) {
  final watching = findBilibiliStreamCardsOfVideo(
    library.transientVideos,
    bvid: bvid,
    collectionOf: library.getCollection,
  );
  VideoItem? card;
  for (final item in watching) {
    if (item.id == playingItemId) {
      card = item;
      break;
    }
    if (card == null || item.lastUpdated > card.lastUpdated) card = item;
  }
  final page = card?.sourceRef?.page;
  if (page != null && page > 0) return page;
  final entry = (history ?? BilibiliHistoryService.instance).watchEntryOf(bvid);
  if (entry != null && entry.page > 0) return entry.page;
  return 1;
}

/// Name shown for a folder in import messages.
String bilibiliFolderLabel(LibraryService library, String? folderId) {
  if (folderId == null) return '媒体库根目录';
  return library.getCollection(folderId)?.name ?? '媒体库根目录';
}

class BilibiliQuickImportResult {
  const BilibiliQuickImportResult({
    required this.item,
    required this.folderLabel,
    this.batch,
    this.alreadyImported = false,
    this.fellBackToRoot = false,
    this.partCount = 1,
    this.currentPartOnly = false,
  });

  /// Library card of the part the import was asked for.
  final VideoItem item;

  /// Null when the part was already in the library and nothing ran.
  final BilibiliStreamCardBatch? batch;
  final bool alreadyImported;

  /// The saved default folder no longer exists or sits in the recycle bin
  /// (itself or a folder above it); the cards went to the root.
  final bool fellBackToRoot;
  final String folderLabel;

  /// Number of parts of the video.
  final int partCount;

  /// A long multi-part video (over [kBilibiliAutoFillPartLimit] parts) where
  /// only the current part was imported because nothing was asked.
  final bool currentPartOnly;

  bool get createdAny => (batch?.createdCount ?? 0) > 0;

  String get message {
    if (alreadyImported || (batch != null && !createdAny)) {
      return '已在媒体库中（$folderLabel），未重复导入';
    }
    final failed = batch?.failedPages.length ?? 0;
    final placed = currentPartOnly
        ? '已导入当前P到 $folderLabel（共 $partCount P，要导入全部请点右侧按钮）'
        : '已导入到 $folderLabel';
    final text = fellBackToRoot ? '原默认文件夹已删除或在回收站，$placed' : placed;
    return failed > 0 ? '$text，$failed 个分P失败' : text;
  }
}

/// One-tap import of [bvid] (the "import" button and the folder picker).
///
/// * [page] null takes the part being watched or the one in the watch
///   history ([bilibiliImportPartOf]).
/// * [target] null uses the saved default place; a saved folder that no
///   longer exists, or that is in the recycle bin itself or below a folder
///   in it, falls back to the library root and the default is reset to the
///   root.
/// * [allParts] null imports every part of a multi-part video up to
///   [kBilibiliAutoFillPartLimit] parts, else only the current part.
/// * [rememberTarget] stores [target] as the new default.
/// * [selectedPages] explicitly imports only these parts, overriding [allParts]
///   and the automatic limit. Empty or unknown selections are rejected.
///
/// When the part already has a library card and nothing was asked
/// explicitly, nothing is created. A watch-only card of an imported part
/// becomes the library card (same card, position kept); a newly created
/// card of the current part takes the position saved in the watch history.
Future<BilibiliQuickImportResult> runBilibiliQuickImport({
  required BilibiliDownloadService service,
  required LibraryService library,
  required String bvid,
  int? page,
  BilibiliImportTarget? target,
  bool? allParts,
  List<int>? selectedPages,
  bool rememberTarget = false,
  bool again = false,
  BilibiliVideoInfo? videoInfo,
  SettingsService? settings,
  BilibiliHistoryService? history,
  String? playingItemId,
}) async {
  final config = settings ?? SettingsService();
  final watchHistory = history ?? BilibiliHistoryService.instance;
  await watchHistory.ensureLoaded();
  final part =
      page ??
      bilibiliImportPartOf(
        library,
        bvid: bvid,
        history: watchHistory,
        playingItemId: playingItemId,
      );

  final explicit = target != null || allParts != null || selectedPages != null;
  final imported = findImportedBilibiliCard(library, bvid: bvid, page: part);
  // A plain second call stays quiet. The import button passes [again] so
  // the same tap still runs the import instead of stopping on "已导入".
  if (imported != null && !explicit && !again) {
    return BilibiliQuickImportResult(
      item: imported,
      alreadyImported: true,
      folderLabel: bilibiliFolderLabel(library, imported.parentId),
    );
  }

  final place = target ?? BilibiliImportTarget.fromSettings(config);
  if (place.kind == BilibiliImportTargetKind.folder) {
    // Moving a folder to the recycle bin only marks that folder, so the
    // folders inside it count as gone too.
    if (!library.activityProjection.isVisibleCollection(place.folderId!)) {
      throw const ImportPlacementException('导入目标文件夹已不可用，请重新选择导入位置');
    }
  }
  if (rememberTarget) {
    await config.updateSetting<String>('bilibiliImportTarget', place.encode());
  }

  final info = videoInfo ?? await service.apiService.fetchVideoInfo(bvid);
  if (selectedPages != null &&
      (selectedPages.isEmpty ||
          selectedPages.any(
            (number) => !info.pages.any((p) => p.page == number),
          ))) {
    throw ArgumentError.value(selectedPages, 'selectedPages', '请选择有效的分P');
  }
  final partCount = info.pages.length;
  final everyPart =
      allParts ?? (partCount > 1 && partCount <= kBilibiliAutoFillPartLimit);
  final pages =
      selectedPages?.toSet().toList() ??
      <int>[
        part,
        if (everyPart)
          for (final p in info.pages)
            if (p.page != part) p.page,
      ];
  final batch = await service.obtainStreamCardsForVideo(
    library,
    bvid: bvid,
    pages: pages,
    videoInfo: info,
    useDefaultLocation: place.kind == BilibiliImportTargetKind.automatic,
    targetFolderId: place.folderId,
  );

  VideoItem? card;
  for (final result in batch.cards) {
    if (result.item.sourceRef?.page == part) card = result.item;
  }
  card ??= batch.cards.first.item;
  final entry = watchHistory.watchEntryOf(bvid);
  if (card.lastPositionMs <= 0 &&
      entry != null &&
      entry.page == card.sourceRef?.page &&
      entry.positionMs > 0 &&
      batch.cards.any((r) => r.created && identical(r.item, card))) {
    await library.updateVideoProgress(card.id, entry.positionMs);
  }

  final createdAny = batch.createdCount > 0;
  return BilibiliQuickImportResult(
    item: card,
    batch: batch,
    partCount: partCount,
    currentPartOnly:
        selectedPages == null &&
        allParts == null &&
        partCount > kBilibiliAutoFillPartLimit,
    folderLabel: createdAny
        ? bilibiliFolderLabel(library, batch.targetFolderId)
        : bilibiliFolderLabel(library, card.parentId),
  );
}
