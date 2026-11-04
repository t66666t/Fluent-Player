import 'dart:async';
import 'dart:developer' as developer;
import 'bilibili_parts_import_dialog.dart';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_history_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_quick_import.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/widgets/library_folder_picker.dart';
import 'package:video_player_app/widgets/stable_width_label.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';
import 'package:video_player_app/widgets/add_to_playlist_button.dart';
import 'package:video_player_app/widgets/playback_queue_add_actions.dart';

/// Runs an import from the import buttons. Pages take one of these so tests
/// can check the taps without the network.
typedef BilibiliQuickImporter =
    Future<void> Function(
      BuildContext context, {
      required String bvid,
      int? page,
      required bool pickPlace,
    });

bool _importRunning = false;

/// Multi-part videos ask which parts to import, defaulting to all parts.
/// With [pickPlace], a folder picker then asks where to put the selection.
Future<void> importBilibiliVideoQuick(
  BuildContext context, {
  required String bvid,
  int? page,
  bool pickPlace = false,
  bool again = false,
  BilibiliVideoInfo? videoInfo,
  VoidCallback? onImportStarted,
}) async {
  if (_importRunning) return;
  _importRunning = true;
  final service = context.read<BilibiliDownloadService>();
  final library = context.read<LibraryService>();
  String? playingItemId;
  try {
    playingItemId = context.read<MediaPlaybackService>().currentItem?.id;
  } on ProviderNotFoundException {
    playingItemId = null;
  }
  final settings = SettingsService();
  final history = BilibiliHistoryService.instance;
  try {
    await service.init();
    BilibiliImportTarget? target;
    bool? allParts;
    var remember = false;
    final info = videoInfo ?? await service.apiService.fetchVideoInfo(bvid);
    if (!context.mounted) return;
    List<int>? selectedPages;
    if (info.pages.length > 1) {
      selectedPages = await showBilibiliPartsImportDialog(context, info: info);
      if (selectedPages == null || !context.mounted) return;
    }
    if (pickPlace) {
      await history.ensureLoaded();
      if (!context.mounted) return;
      final part =
          page ??
          bilibiliImportPartOf(
            library,
            bvid: bvid,
            history: history,
            playingItemId: playingItemId,
          );
      final pick = await showBilibiliImportPicker(
        context,
        library: library,
        current: BilibiliImportTarget.fromSettings(settings),
        // Parts were already chosen in the dedicated selector.
        partCount: 1,
        currentPage: part,
      );
      if (pick == null) return;
      target = BilibiliImportTarget.picked(pick.folderId);
      allParts = pick.allParts;
      remember = pick.setAsDefault;
      page = part;
    }
    // 选完文件夹才算真正开始导入，按钮这时才显示「正在导入…」。
    onImportStarted?.call();
    await runBilibiliQuickImport(
      service: service,
      library: library,
      bvid: bvid,
      page: page,
      target: target,
      allParts: allParts,
      selectedPages: selectedPages,
      rememberTarget: remember,
      again: again,
      videoInfo: info,
      settings: settings,
      history: history,
      playingItemId: playingItemId,
    );
  } catch (error, stack) {
    developer.log('Import of $bvid failed', error: error, stackTrace: stack);
    rethrow;
  } finally {
    _importRunning = false;
  }
}

/// Choice made in [showBilibiliImportPicker].
class BilibiliImportPick {
  const BilibiliImportPick({
    required this.folderId,
    required this.setAsDefault,
    required this.allParts,
  });

  /// Null is the library root.
  final String? folderId;
  final bool setAsDefault;
  final bool allParts;
}

/// The folder picker of the import buttons. A multi-part video also offers
/// "all parts" / "current part only"; all parts is preselected up to
/// [kBilibiliAutoFillPartLimit] parts, as the one-tap import does.
Future<BilibiliImportPick?> showBilibiliImportPicker(
  BuildContext context, {
  required LibraryService library,
  required BilibiliImportTarget current,
  int partCount = 1,
  int currentPage = 1,
}) async {
  var allParts = partCount > 1 && partCount <= kBilibiliAutoFillPartLimit;
  final pick = await showLibraryFolderPicker(
    context,
    library: library,
    initialFolderId: current.folderId,
    title: '导入到…',
    accent: AppTokens.brandBilibili,
    header: partCount > 1
        ? (context) => StatefulBuilder(
            builder: (context, setHeaderState) => Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  key: const ValueKey('bilibili-import-all-parts'),
                  label: Text('全部分P（$partCount 个）'),
                  selected: allParts,
                  onSelected: (_) => setHeaderState(() => allParts = true),
                ),
                ChoiceChip(
                  key: const ValueKey('bilibili-import-current-part'),
                  label: Text('仅当前 P$currentPage'),
                  selected: !allParts,
                  onSelected: (_) => setHeaderState(() => allParts = false),
                ),
              ],
            ),
          )
        : null,
  );
  if (pick == null) return null;
  return BilibiliImportPick(
    folderId: pick.folderId,
    setAsDefault: pick.setAsDefault,
    allParts: partCount > 1 && allParts,
  );
}

/// Compact outline for import, download and external links on the Bilibili
/// panel: stadium, 13px label, 17px icon.
ButtonStyle bilibiliCompactOutlinedStyle({
  required Color foreground,
  bool active = false,
  EdgeInsetsGeometry padding = const EdgeInsets.symmetric(horizontal: 12),
}) {
  return OutlinedButton.styleFrom(
    foregroundColor: foreground,
    disabledForegroundColor: foreground.withValues(alpha: 0.6),
    side: BorderSide(color: active ? AppTokens.brandBilibili : AppTokens.text4),
    visualDensity: VisualDensity.compact,
    padding: padding,
    shape: const StadiumBorder(),
    splashFactory: NoSplash.splashFactory,
  );
}

/// Compact import action with a separate folder target. After a part is in the library the
/// label says 已导入, but both zones still start the import again.
/// Used on search results, uploader posts, collections, the watch history
/// and the player's Bilibili panel.
class BilibiliImportButtons extends StatefulWidget {
  const BilibiliImportButtons({
    super.key,
    required this.bvid,
    this.page,
    this.onImport,
    this.library,
    this.history,
    this.emphasized = false,
    this.onRemove,
    this.showQueueAction = true,
  });

  final String bvid;

  /// Null: the part being watched or the one in the watch history.
  final int? page;
  final BilibiliQuickImporter? onImport;
  final LibraryService? library;
  final BilibiliHistoryService? history;

  /// A stronger main action for the detail panel; lists use quiet text actions.
  final bool emphasized;

  /// History folds removal into the secondary menu to keep the row compact.
  final VoidCallback? onRemove;
  final bool showQueueAction;

  @override
  State<BilibiliImportButtons> createState() => _BilibiliImportButtonsState();
}

class _BilibiliImportButtonsState extends State<BilibiliImportButtons> {
  bool _busy = false;

  /// 真正在导入（不是在选文件夹）时才为 true，只有这时左侧显示「导入中」。
  bool _importing = false;
  String? _error;

  /// The app's library from the widget tree; pages pumped on their own in
  /// tests have none and simply show the import button.
  static LibraryService? _libraryOf(BuildContext context) {
    try {
      return Provider.of<LibraryService>(context, listen: false);
    } on ProviderNotFoundException {
      return null;
    }
  }

  Future<void> _invoke({required bool pickPlace}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _importing = false;
      _error = null;
    });
    try {
      final custom = widget.onImport;
      if (custom != null) {
        await custom(
          context,
          bvid: widget.bvid,
          page: widget.page,
          pickPlace: pickPlace,
        );
      } else {
        await importBilibiliVideoQuick(
          context,
          bvid: widget.bvid,
          page: widget.page,
          pickPlace: pickPlace,
          again: true,
          onImportStarted: () {
            if (mounted) setState(() => _importing = true);
          },
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error is StateError
            ? '导入失败：${error.message}'
            : '导入失败，请检查网络或 B 站登录状态';
      });
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(_error!)));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _importing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final lib = widget.library ?? _libraryOf(context);
    final watchHistory = widget.history ?? BilibiliHistoryService.instance;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[?lib, watchHistory]),
      builder: (context, _) {
        final part =
            widget.page ??
            (lib == null
                ? watchHistory.watchEntryOf(widget.bvid)?.page ?? 1
                : bilibiliImportPartOf(
                    lib,
                    bvid: widget.bvid,
                    history: watchHistory,
                  ));
        final imported = lib == null
            ? null
            : findImportedBilibiliCard(lib, bvid: widget.bvid, page: part);
        final label = _error != null
            ? '重试'
            : _importing
            ? '导入中'
            : imported != null
            ? '已导入'
            : '导入';
        final foreground = _error != null
            ? AppTokens.danger
            : widget.emphasized || _importing
            ? AppTokens.brandBilibili
            : imported != null
            ? AppTokens.text3
            : AppTokens.brandBilibili;
        final textStyle = DefaultTextStyle.of(context).style.copyWith(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          height: 1.2,
        );
        final labelPainter = TextPainter(
          text: TextSpan(text: '导入中', style: textStyle),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final preferredWidth = labelPainter.width.ceilToDouble() + 64;
        final height = (labelPainter.height + 16).clamp(44.0, double.infinity);
        final compactQueue =
            widget.showQueueAction &&
            !widget.emphasized &&
            widget.onRemove == null;
        final sideWidth = compactQueue ? 30.0 : 44.0;
        labelPainter.dispose();
        return LayoutBuilder(
          builder: (context, constraints) => SizedBox(
            width: preferredWidth.clamp(0.0, constraints.maxWidth),
            height: height,
            child: Material(
              type: MaterialType.transparency,
              child: DefaultTextStyle(
                style: textStyle.copyWith(color: foreground),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Tooltip(
                        message:
                            _error ??
                            (imported != null ? '已导入，点击重新导入' : '导入到默认位置'),
                        child: Semantics(
                          button: true,
                          enabled: !_busy,
                          liveRegion: true,
                          label: _error ?? label,
                          excludeSemantics: true,
                          child: Ink(
                            decoration: BoxDecoration(
                              color: widget.emphasized
                                  ? foreground.withValues(alpha: .12)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: InkWell(
                              key: ValueKey('bilibili-import-${widget.bvid}'),
                              borderRadius: BorderRadius.circular(8),
                              splashFactory: NoSplash.splashFactory,
                              highlightColor: Colors.transparent,
                              hoverColor: AppTokens.bgCard,
                              onTap: _busy
                                  ? null
                                  : () => unawaited(_invoke(pickPlace: false)),
                              child: Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: compactQueue ? 1 : 8,
                                ),
                                child: Center(
                                  child: StableWidthLabel(
                                    label,
                                    key: _error == null
                                        ? null
                                        : ValueKey(
                                            'bilibili-import-error-${widget.bvid}',
                                          ),
                                    variants: const ['导入', '已导入', '导入中', '重试'],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(width: compactQueue ? 1 : 4),
                    if (widget.onRemove != null)
                      CapsulePopupMenuButton<String>(
                        useRootNavigator: true,
                        key: ValueKey('bilibili-import-pick-${widget.bvid}'),
                        enabled: !_busy,
                        tooltip: '更多操作',
                        position: PopupMenuPosition.under,
                        color: AppTokens.bgOverlay,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        onSelected: (action) {
                          if (action == 'add_to_playlist') {
                            unawaited(
                              addBilibiliVideoToQueue(context, widget.bvid),
                            );
                          } else if (action == 'folder') {
                            unawaited(_invoke(pickPlace: true));
                          } else if (action == 'remove') {
                            widget.onRemove?.call();
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'add_to_playlist',
                            child: Row(
                              children: [
                                Icon(
                                  AddToPlaylistButton.icon,
                                  size: 19,
                                  color: AppTokens.text2,
                                ),
                                SizedBox(width: 10),
                                Flexible(
                                  child: Text(
                                    AddToPlaylistButton.defaultLabel,
                                    style: TextStyle(
                                      color: AppTokens.text1,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'folder',
                            child: Row(
                              children: [
                                Icon(
                                  Icons.drive_folder_upload_outlined,
                                  size: 19,
                                  color: AppTokens.text2,
                                ),
                                SizedBox(width: 10),
                                Flexible(
                                  child: Text(
                                    '选择导入位置',
                                    style: TextStyle(
                                      color: AppTokens.text1,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'remove',
                            child: Row(
                              children: [
                                Icon(
                                  Icons.delete_outline,
                                  size: 19,
                                  color: AppTokens.text2,
                                ),
                                SizedBox(width: 10),
                                Flexible(
                                  child: Text(
                                    '删除记录',
                                    style: TextStyle(
                                      color: AppTokens.text1,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        child: SizedBox(
                          width: sideWidth,
                          height: height,
                          child: Center(
                            child: IconTheme(
                              data: const IconThemeData(color: AppTokens.text3),
                              child: StableIconSlot(
                                icon: Icons.more_horiz_rounded,
                                size: 19,
                                busy: _busy,
                                spinnerColor: foreground,
                              ),
                            ),
                          ),
                        ),
                      )
                    else
                      Tooltip(
                        message: '选择导入位置',
                        child: Semantics(
                          button: true,
                          enabled: !_busy,
                          label: '选择导入位置',
                          excludeSemantics: true,
                          child: InkWell(
                            key: ValueKey(
                              'bilibili-import-pick-${widget.bvid}',
                            ),
                            borderRadius: BorderRadius.circular(8),
                            splashFactory: NoSplash.splashFactory,
                            highlightColor: Colors.transparent,
                            hoverColor: AppTokens.bgCard,
                            onTap: _busy
                                ? null
                                : () => unawaited(_invoke(pickPlace: true)),
                            child: SizedBox(
                              width: sideWidth,
                              height: height,
                              child: Center(
                                child: IconTheme(
                                  data: IconThemeData(
                                    color: widget.emphasized
                                        ? foreground
                                        : AppTokens.text3,
                                  ),
                                  child: StableIconSlot(
                                    icon: _error != null
                                        ? Icons.error_outline_rounded
                                        : Icons.drive_folder_upload_outlined,
                                    size: 17,
                                    busy: _busy,
                                    spinnerColor: foreground,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (compactQueue) ...[
                      const SizedBox(width: 1),
                      SizedBox(
                        width: sideWidth,
                        child: AddToPlaylistButton(
                          onAdd: (progress) => addBilibiliVideoToQueue(
                            context,
                            widget.bvid,
                            progress: progress,
                          ),
                          key: ValueKey(
                            'bilibili-add-to-playlist-${widget.bvid}',
                          ),
                          iconOnly: true,
                          height: height,
                          iconSize: 18,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
