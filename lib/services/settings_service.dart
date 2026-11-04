import 'app_storage_service.dart';
import 'subtitle_debug_session.dart';
import 'default_settings_trial.dart';
import 'app_default_settings_trial.dart';
import '../models/recommended_app_defaults.dart';
import '../models/processing_screen_protection_timing.dart';
import '../models/subtitle_debug_preset.dart';
import 'dart:convert';
import 'dart:async';
import '../debug/developer_log.dart' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';
import 'package:window_manager/window_manager.dart';
import '../models/folder_placeholder_style.dart';
import '../models/import_card_placement.dart';
import '../models/media_library_root_entry.dart';
import '../models/media_library_continue_policy.dart';
import '../models/music_lyric_display_mode.dart';
import '../models/music_lyric_anchor.dart';
import '../models/music_lyric_typography.dart';
import '../models/subtitle_copy_format.dart';
import '../models/subtitle_position.dart';
import '../models/subtitle_style.dart';
import '../models/recommended_subtitle_defaults.dart';
import '../models/subtitle_font.dart' show normalizeBundledFontFamily;
import 'subtitle_position_store.dart';
import '../models/subtitle_output_path_strategy.dart';
import '../models/danmaku_style.dart';
import '../models/video_compose_models.dart';
import '../utils/device_form_factor.dart';
import '../models/media_library_view_mode.dart';
import '../widgets/media_library_layout_profile.dart';
import '../widgets/media_library_view_defaults.dart';
import '../widgets/media_list_layout_metrics.dart';

enum PlaybackSpeedLockAction { locked, switched, unlocked }

/// Phones and tablets have a system media notification. Desktop does not, so
/// the media-library switch for it is omitted there.
bool platformShowsSystemMediaNotificationSetting() {
  if (kIsWeb) return false;
  return Platform.isAndroid || Platform.isIOS;
}

class _RegisteredSetting<T> {
  final String key;
  final T defaultValue;
  final T Function()? resolveDefaultValue;
  final T Function(SharedPreferences prefs, String key, T defaultValue) read;
  final Future<void> Function(SharedPreferences prefs, String key, T value)
  write;
  final T Function(T value) normalize;
  final void Function(SettingsService service, T value) apply;

  const _RegisteredSetting({
    required this.key,
    required this.defaultValue,
    this.resolveDefaultValue,
    required this.read,
    required this.write,
    required this.normalize,
    required this.apply,
  });

  T get currentDefaultValue => resolveDefaultValue?.call() ?? defaultValue;

  Object? get normalizedDefaultValue => normalize(currentDefaultValue);

  Future<void> loadInto(
    SettingsService service,
    SharedPreferences prefs,
  ) async {
    final rawValue = read(prefs, key, currentDefaultValue);
    final normalizedValue = normalize(rawValue);
    apply(service, normalizedValue);
    if (rawValue != normalizedValue) {
      await write(prefs, key, normalizedValue);
    }
  }

  Future<void> updateValue(
    SettingsService service,
    SharedPreferences prefs,
    Object value,
  ) {
    final normalizedValue = normalize(value as T);
    // Runtime consumers (including an already-running batch subtitle task)
    // must see the new value immediately. Persistence is deliberately the
    // second step; SharedPreferences I/O must not turn a UI change into a
    // delayed runtime change.
    apply(service, normalizedValue);
    return write(prefs, key, normalizedValue);
  }

  /// Applies the runtime value without touching disk. Callers that coalesce
  /// rapid writes persist the latest in-memory value themselves.
  void applyIncoming(SettingsService service, Object value) {
    apply(service, normalize(value as T));
  }
}

class SettingsService extends ChangeNotifier {
  static final SettingsService _instance = SettingsService._internal();
  static const String _playbackSpeedLockStateKey = 'playbackSpeedLockStateV2';
  static const int _ghostLayoutCompatibilityVersion = 1;
  static const int _textMetricCompatibilityVersion = 1;
  static const String _ghostLayoutCompatibilityVersionKey =
      'ghostLayoutCompatibilityVersion';
  static const String _textMetricCompatibilityVersionKey =
      'subtitleTextMetricCompatibilityVersion';
  static const String _subtitleAlignmentJsonKey = 'subtitleAlignmentJson';
  static const String _audioSubtitleAlignmentJsonKey =
      'audioSubtitleAlignmentJson';
  static const String _ghostModeAlignmentJsonKey = 'ghostModeAlignmentJson';
  static const SubtitleLayoutStyle _legacyGhostLayout = SubtitleLayoutStyle(
    fontSize: 28.0,
    secondaryFontSize: 17.2,
    lineSpacing: -0.1,
    letterSpacing: 0.0,
  );
  factory SettingsService() => _instance;
  SettingsService._internal();

  late SharedPreferences _prefs;
  bool _initialized = false;
  DefaultSettingsTrial? _defaultSettingsTrial;
  Map<String, dynamic>? _restoredDefaultTrialRuntime;
  final Set<Future<dynamic>> _pendingSettingsWrites = {};
  DefaultTrialFeatureStore featureSettingsForTrial =
      FileDefaultTrialFeatureStore();
  DefaultSettingsDevice defaultTrialDevice = DefaultSettingsDevice(
    defaultTargetPlatform,
    const Size(390, 844),
  );

  Map<String, Object?> get registeredDefaultPreferences => {
    for (final setting in _registeredSettings)
      if (!settingsExportExclusions.containsKey(setting.key) &&
          !RecommendedAppDefaults.localRuleExclusions.containsKey(setting.key))
        setting.key: setting.normalizedDefaultValue,
  };

  Set<String> get defaultAppTrialPreferenceKeys => {
    ...defaultTrialPreferenceKeys,
    ...registeredDefaultPreferences.keys,
    ...mediaLibraryLayoutExportKeys,
    ...RecommendedAppDefaults.preferences(defaultTrialDevice).keys,
    ...RecommendedAppDefaults.mixedPreferenceFields.keys,
    _playbackSpeedLockStateKey,
    'landscapeSidebarFontSizeScale',
    'sidebarFontSizeScale',
    'audioPortraitDisplayAspectRatio',
    'audioPortraitCustomAspectWidth',
    'audioPortraitCustomAspectHeight',
  };

  DefaultSettingsTrial get defaultSettingsTrial {
    if (_defaultSettingsTrial != null) return _defaultSettingsTrial!;
    final trial = DefaultSettingsTrial(
      journal: DefaultSettingsTrialJournal(
        () async => SharedPreferencesTrialBackend(_prefs),
      ),
      captureOriginal: _captureDefaultTrialBackup,
      applyRecommended: _applyRecommendedSubtitleSettings,
      restoreOriginal: _restoreDefaultTrialBackup,
      onReadBackup: (backup) {
        if (backup['device'] case final Map device) {
          defaultTrialDevice = DefaultSettingsDevice(
            TargetPlatform.values.firstWhere(
              (value) => value.name == device['platform'],
              orElse: () => defaultTargetPlatform,
            ),
            Size(
              (device['width'] as num).toDouble(),
              (device['height'] as num).toDouble(),
            ),
          );
        }
      },
    );
    trial.addListener(notifyListeners);
    return _defaultSettingsTrial = trial;
  }

  Future<T> _trackSettingsWrite<T>(Future<T> write) {
    late final Future<T> tracked;
    tracked = write.whenComplete(() => _pendingSettingsWrites.remove(tracked));
    _pendingSettingsWrites.add(tracked);
    return tracked;
  }

  SubtitlePositionStore? _positionStore;

  /// Last position-save failure. The in-memory position is kept; the next
  /// commit or [flushSubtitlePositions] tries again.
  String? subtitlePositionSaveError;

  SubtitlePositionStore? get positionStore => _positionStore;

  // Settings Fields
  bool showSubtitles = true;
  bool developerMode = false;
  bool showBilibiliDanmaku = true;
  bool bilibiliDanmakuOnlyInVideoArea = false;
  double bilibiliDanmakuDisplayArea = 0.5;
  double bilibiliDanmakuOpacity = 0.8;
  double bilibiliDanmakuFontScale = 0.8;
  bool bilibiliDanmakuReadableFontDefaults = false;
  double bilibiliDanmakuSpeed = 1.0;
  // Historical shared keys remain the landscape profile, preserving manual
  // settings on upgrade. Portrait starts from its own phone-friendly defaults.
  double bilibiliDanmakuDensity = 1.0;
  double bilibiliDanmakuPortraitDisplayArea = kDanmakuPortraitDisplayArea;
  double bilibiliDanmakuPortraitFontScale = kDanmakuPortraitFontScale;
  double bilibiliDanmakuPortraitSpeed = kDanmakuPortraitSpeed;
  double bilibiliDanmakuPortraitDensity = kDanmakuPortraitDensity;
  bool bilibiliDanmakuUseLockedSpeedAsBaseline = false;
  bool bilibiliDanmakuAutoUpdate = true;
  Future<void> _danmakuLockedBaselinePersistTail = Future<void>.value();
  int _danmakuLockedBaselineWriteId = 0;
  String? bilibiliDanmakuFontFamily = kDanmakuDefaultFontFamily;
  double bilibiliDanmakuOutlineScale = 1.0;
  double bilibiliDanmakuShadowScale = 1.0;
  double bilibiliDanmakuLetterSpacing = 0.0;
  int bilibiliDanmakuFontWeight = kDanmakuDefaultFontWeight;
  DanmakuOutlineType bilibiliDanmakuOutlineType = DanmakuOutlineType.standard;
  bool isMirroredH = false;
  bool isMirroredV = false;
  double playbackSpeed = 1.0;
  bool isPlaybackSpeedLocked = false;
  bool globalMute = false;
  double longPressSpeed = 2.0;
  bool showLongPressSpeedIndicator = true;
  int doubleTapSeekSeconds = 5;
  bool enableDoubleTapSubtitleSeek = true;
  double userSubtitleSidebarWidth = 262.4;
  // Zero keeps the responsive default until the user first resizes AI chat.
  double userAiSidebarWidth = 0;
  bool isLeftHandedMode = false;

  // Subtitle Settings - 新的结构
  // 文字样式 - 横竖屏共享
  SubtitleTextStyle subtitleTextStyle = const SubtitleTextStyle(
    fontFamilyChinese: 'Swei Gothic CJK SC',
    fontFamilyEnglish: 'Swei Gothic CJK SC',
    textColor: Color(0xFFFFFFFF),
    backgroundColor: Color(0xE0000000),
    hasBorder: true,
    borderColor: Color(0xFF000000),
    borderWidth: 2.5,
    hasShadow: true,
    shadowColor: Color(0xFF000000),
    shadowBlur: 2.8,
    shadowOffset: Offset(2.6, 2.6),
    backgroundOpacity: 0.88,
    fontWeightChinese: FontWeight.w600,
    fontWeightEnglish: FontWeight.w700,
    isItalic: false,
    isUnderline: false,
  );

  // 布局样式 - 横竖屏共享
  SubtitleLayoutStyle subtitleLayoutLandscape = const SubtitleLayoutStyle(
    fontSize: 39.7,
    secondaryFontSize: 22.6,
    lineSpacing: -0.1,
    letterSpacing: 0.0,
  );
  SubtitleLayoutStyle subtitleLayoutPortrait = const SubtitleLayoutStyle(
    fontSize: 39.7,
    secondaryFontSize: 22.6,
    lineSpacing: -0.1,
    letterSpacing: 0.0,
  );

  // 幽灵模式布局样式 - 与普通字幕完全独立（仅共享文字样式）
  SubtitleLayoutStyle subtitleLayoutGhostLandscape = const SubtitleLayoutStyle(
    fontSize: 39.7,
    secondaryFontSize: 22.6,
    lineSpacing: -0.1,
    letterSpacing: 0.0,
  );
  SubtitleLayoutStyle subtitleLayoutGhostPortrait = const SubtitleLayoutStyle(
    fontSize: 39.7,
    secondaryFontSize: 22.6,
    lineSpacing: -0.1,
    letterSpacing: 0.0,
  );

  // 音频字幕 - 同样结构
  bool syncAudioSubtitleStyleWithVideo = true;
  SubtitleTextStyle audioSubtitleTextStyle = const SubtitleTextStyle();
  SubtitleLayoutStyle audioSubtitleLayoutLandscape =
      const SubtitleLayoutStyle();
  SubtitleLayoutStyle audioSubtitleLayoutPortrait = const SubtitleLayoutStyle();

  // 便捷访问器 - 视频字幕完整样式
  SubtitleStyle get subtitleStyleLandscape => SubtitleStyle(
    textStyle: subtitleTextStyle,
    layoutStyle: subtitleLayoutLandscape,
  );
  SubtitleStyle get subtitleStylePortrait => SubtitleStyle(
    textStyle: subtitleTextStyle,
    layoutStyle: subtitleLayoutPortrait,
  );

  // 便捷访问器 - 视频幽灵字幕完整样式（仅布局独立）
  SubtitleStyle get subtitleStyleGhostLandscape => SubtitleStyle(
    textStyle: subtitleTextStyle,
    layoutStyle: subtitleLayoutGhostLandscape,
  );
  SubtitleStyle get subtitleStyleGhostPortrait => SubtitleStyle(
    textStyle: subtitleTextStyle,
    layoutStyle: subtitleLayoutGhostPortrait,
  );

  // 便捷访问器 - 音频字幕完整样式
  SubtitleTextStyle get effectiveAudioSubtitleTextStyle =>
      syncAudioSubtitleStyleWithVideo
      ? subtitleTextStyle
      : audioSubtitleTextStyle;
  SubtitleStyle get audioSubtitleStyleLandscape => SubtitleStyle(
    textStyle: effectiveAudioSubtitleTextStyle,
    layoutStyle: audioSubtitleLayoutLandscape,
  );
  SubtitleStyle get audioSubtitleStylePortrait => SubtitleStyle(
    textStyle: effectiveAudioSubtitleTextStyle,
    layoutStyle: audioSubtitleLayoutPortrait,
  );

  // Backward compatibility getter/setter (maps to landscape for now)
  SubtitleStyle get subtitleStyle => subtitleStyleLandscape;

  Alignment subtitleAlignment = const Alignment(0.0, 0.8947589131115533);
  Alignment audioSubtitleAlignment = const Alignment(0.0, 0.8947589131115533);
  List<Map<String, double>> subtitlePresets = [];
  Duration subtitleOffset = Duration.zero;

  // New: Auto Cache Subtitles
  bool autoCacheSubtitles = true;

  // New: Auto Scroll Subtitles
  bool autoScrollSubtitles = true;
  bool subtitleEditorAutoFollow = true;

  // New: Auto Load Embedded Subtitles
  bool autoLoadEmbeddedSubtitles = false;

  // New: Grid Size Settings
  int homeGridCrossAxisCount = 4;
  int videoCardCrossAxisCount = 4;

  // New: Home Card Style
  double homeCardTitleFontSize = 13.0;
  double homeCardAspectRatio = 0.625;

  // New: Video Card Style
  double videoCardTitleFontSize = 11.0;
  double videoCardAspectRatio = 0.625;

  /// Media manager view style; see [MediaLibraryViewMode] for the indices
  /// (0 grid, 1 media rows, 2 details table, 3 folder tree).
  int mediaLibraryViewMode = 0;

  /// Details-table sort ([MediaTableSortKey.name]). View-only: it never
  /// rewrites the stored folder order that drag-reorder edits.
  String mediaTableSortKey = MediaTableSortKey.manual.name;
  bool mediaTableSortDescending = false;

  /// Content layout inside the folder-tree shell
  /// ([MediaLibraryContentLayout] index).
  int mediaTreeContentMode = MediaLibraryContentLayout.rows.index;
  double mediaTreeSidebarWidth = MediaLibraryViewDefaults.treeSidebarWidth;
  bool mediaTreeShowCounts = true;

  /// Docked tree pane hidden by the user on wide screens.
  bool mediaTreeSidebarCollapsed = false;

  // Root entry switcher: empty until first initialized default is written.
  String mediaLibraryRootEntry = '';
  bool mediaLibraryRootEntryUserChosen = false;
  String mediaLibraryRootEntryOrder = '';

  /// When true, cold start reopens the last root page and nested folder.
  bool mediaLibraryRestoreLastPage = true;
  bool mediaLibraryReadableCardDefaults = false;

  /// Used only when [mediaLibraryRestoreLastPage] is false.
  String mediaLibraryStartupEntry = MediaLibraryRootEntry.folders.storageValue;
  String mediaLibraryLastFolderId = '';
  String mediaLibraryEntryAnchors = '';
  bool mediaLibraryLastFolderIncludeDescendants = false;

  /// Continue tab: false = all play history; true = unfinished + watch threshold.
  bool mediaLibraryContinueSeriousOnly = false;
  ContinueWatchPolicy continueWatchPolicy = ContinueWatchPolicy.defaults;

  // Unified list mode style settings
  int mediaListCrossAxisCount = 1;
  bool mediaListShowThumbnail = true;
  bool mediaListShowIndex = false;
  double mediaListItemHeightScale = 0.10;
  double mediaListMainSpacingScale = 0.012;
  double mediaListCrossSpacingScale = 0.02;
  double mediaListTitleScale = 0.042;
  double mediaListCoverOffset = 0.0;
  FolderPlaceholderSettings folderPlaceholderSettings =
      FolderPlaceholderSettings.defaults;

  MediaCardStyleSettings homeCardStyleFor(Size size) {
    return _cardStyleFor(
      size: size,
      columnsPortraitKey: 'homeGridCrossAxisCountPortrait',
      columnsLandscapeKey: 'homeGridCrossAxisCountLandscape',
      columnsLegacyKey: 'homeGridCrossAxisCount',
      columnsLegacy: homeGridCrossAxisCount,
      titlePortraitKey: 'homeCardTitleFontSizePortrait',
      titleLandscapeKey: 'homeCardTitleFontSizeLandscape',
      titleLegacyKey: 'homeCardTitleFontSize',
      titleLegacy: homeCardTitleFontSize,
      aspectPortraitKey: 'homeCardAspectRatioPortrait',
      aspectLandscapeKey: 'homeCardAspectRatioLandscape',
      aspectLegacyKey: 'homeCardAspectRatio',
      aspectLegacy: homeCardAspectRatio,
      crossSpacingPortraitKey: 'homeCardCrossSpacingScalePortrait',
      crossSpacingLandscapeKey: 'homeCardCrossSpacingScaleLandscape',
      mainSpacingPortraitKey: 'homeCardMainSpacingScalePortrait',
      mainSpacingLandscapeKey: 'homeCardMainSpacingScaleLandscape',
    );
  }

  /// Folder pages used to keep a separate card profile. They now follow the
  /// home layout so upgrades drop the old per-folder look instead of keeping
  /// two independent grids.
  MediaCardStyleSettings collectionCardStyleFor(Size size) {
    return homeCardStyleFor(size);
  }

  int cardTitleMaxLinesFor(Size size) =>
      mediaLibraryReadableCardDefaults ? 2 : 10;

  MediaLibraryViewMode get mediaLibraryViewStyle =>
      MediaLibraryViewMode.fromStorage(mediaLibraryViewMode);

  /// Layout drawn inside the scroll area; the tree style wraps one of these.
  MediaLibraryContentLayout get mediaLibraryContentLayout =>
      switch (mediaLibraryViewStyle) {
        MediaLibraryViewMode.grid => MediaLibraryContentLayout.grid,
        MediaLibraryViewMode.rows => MediaLibraryContentLayout.rows,
        MediaLibraryViewMode.table => MediaLibraryContentLayout.table,
        MediaLibraryViewMode.tree => MediaLibraryContentLayout.fromStorage(
          mediaTreeContentMode,
        ),
      };

  /// Rows and table use the fixed-extent row grid (list tiles, list geometry).
  bool get mediaLibraryUsesRowPipeline =>
      mediaLibraryContentLayout.usesRowPipeline;

  bool get mediaLibraryShowsFolderTree =>
      mediaLibraryViewStyle == MediaLibraryViewMode.tree;

  MediaTableSortKey get mediaTableSort =>
      MediaTableSortKey.fromStorage(mediaTableSortKey);

  /// Folder order is only editable when the table is not re-sorting it.
  bool get mediaLibraryAllowsManualOrder =>
      mediaLibraryContentLayout != MediaLibraryContentLayout.table ||
      mediaTableSort == MediaTableSortKey.manual;

  Future<void> setMediaLibraryViewStyle(MediaLibraryViewMode mode) =>
      updateSetting('mediaLibraryViewMode', mode.storageValue);

  /// Cycles grid → rows → table → tree (keyboard shortcut).
  Future<void> cycleMediaLibraryViewStyle() {
    const modes = MediaLibraryViewMode.values;
    return setMediaLibraryViewStyle(
      modes[(mediaLibraryViewStyle.index + 1) % modes.length],
    );
  }

  Future<void> setMediaTableSort(MediaTableSortKey key, {bool? descending}) async {
    await updateSetting('mediaTableSortKey', key.name);
    if (descending != null) {
      await updateSetting('mediaTableSortDescending', descending);
    }
  }

  /// Style of whichever row layout is active (rows unless the table shows).
  MediaListStyleSettings listStyleFor(Size size) =>
      mediaLibraryContentLayout == MediaLibraryContentLayout.table
      ? tableStyleFor(size)
      : rowsStyleFor(size);

  static const _rowsColumnsKeys = (
    'mediaListRowsColumnsPortrait',
    'mediaListRowsColumnsLandscape',
  );
  static const _rowsExtentKeys = (
    'mediaListRowsExtentPortrait',
    'mediaListRowsExtentLandscape',
  );
  static const _rowsTitleSizeKeys = (
    'mediaListRowsTitleSizePortrait',
    'mediaListRowsTitleSizeLandscape',
  );
  static const _rowsTitleLinesKeys = (
    'mediaListRowsTitleLinesPortrait',
    'mediaListRowsTitleLinesLandscape',
  );
  static const _rowsCrossSpacingKeys = (
    'mediaListRowsCrossSpacingPortrait',
    'mediaListRowsCrossSpacingLandscape',
  );
  static const _rowsMainSpacingKeys = (
    'mediaListRowsMainSpacingPortrait',
    'mediaListRowsMainSpacingLandscape',
  );
  static const _rowsOuterPaddingKeys = (
    'mediaListRowsOuterPaddingPortrait',
    'mediaListRowsOuterPaddingLandscape',
  );
  static const _rowsShowThumbnailKeys = (
    'mediaListRowsShowThumbnailPortrait',
    'mediaListRowsShowThumbnailLandscape',
  );
  static const _rowsShowIndexKeys = (
    'mediaListRowsShowIndexPortrait',
    'mediaListRowsShowIndexLandscape',
  );
  static const _rowsShowMetaKeys = (
    'mediaListRowsShowMetaPortrait',
    'mediaListRowsShowMetaLandscape',
  );
  static const _rowsShowProgressKeys = (
    'mediaListRowsShowProgressPortrait',
    'mediaListRowsShowProgressLandscape',
  );
  static const _rowsCardSurfaceKeys = (
    'mediaListRowsCardSurfacePortrait',
    'mediaListRowsCardSurfaceLandscape',
  );
  static const _tableExtentKeys = (
    'mediaListTableExtentPortrait',
    'mediaListTableExtentLandscape',
  );
  static const _tableTitleSizeKeys = (
    'mediaListTableTitleSizePortrait',
    'mediaListTableTitleSizeLandscape',
  );
  static const _tableOuterPaddingKeys = (
    'mediaListTableOuterPaddingPortrait',
    'mediaListTableOuterPaddingLandscape',
  );
  static const _tableShowThumbnailKeys = (
    'mediaListTableShowThumbnailPortrait',
    'mediaListTableShowThumbnailLandscape',
  );
  static const _tableShowIndexKeys = (
    'mediaListTableShowIndexPortrait',
    'mediaListTableShowIndexLandscape',
  );
  static const _tableStripedKeys = (
    'mediaListTableStripedPortrait',
    'mediaListTableStripedLandscape',
  );
  static const _tableColumnsKeys = (
    'mediaListTableColumnsPortrait',
    'mediaListTableColumnsLandscape',
  );

  static const _rowsSlotKeys = [
    _rowsColumnsKeys,
    _rowsExtentKeys,
    _rowsTitleSizeKeys,
    _rowsTitleLinesKeys,
    _rowsCrossSpacingKeys,
    _rowsMainSpacingKeys,
    _rowsOuterPaddingKeys,
    _rowsShowThumbnailKeys,
    _rowsShowIndexKeys,
    _rowsShowMetaKeys,
    _rowsShowProgressKeys,
    _rowsCardSurfaceKeys,
  ];
  static const _tableSlotKeys = [
    _tableExtentKeys,
    _tableTitleSizeKeys,
    _tableOuterPaddingKeys,
    _tableShowThumbnailKeys,
    _tableShowIndexKeys,
    _tableStripedKeys,
    _tableColumnsKeys,
  ];
  static const _gridSlotKeys = [
    ('homeGridCrossAxisCountPortrait', 'homeGridCrossAxisCountLandscape'),
    ('homeCardTitleFontSizePortrait', 'homeCardTitleFontSizeLandscape'),
    ('homeCardAspectRatioPortrait', 'homeCardAspectRatioLandscape'),
    ('homeCardCrossSpacingScalePortrait', 'homeCardCrossSpacingScaleLandscape'),
    ('homeCardMainSpacingScalePortrait', 'homeCardMainSpacingScaleLandscape'),
  ];

  static String _slotKeyFor((String, String) keys, Size size) =>
      MediaLibraryLayoutDefaults.isLandscape(size) ? keys.$2 : keys.$1;

  double _slotDoubleOr(
    (String, String) keys,
    Size size,
    double fallback,
    double min,
    double max,
  ) =>
      (_slotDouble(_slotKeyFor(keys, size)) ?? fallback).clamp(min, max);

  int _slotIntOr((String, String) keys, Size size, int fallback, int min, int max) =>
      (_slotInt(_slotKeyFor(keys, size)) ?? fallback).clamp(min, max);

  bool _slotBoolOr((String, String) keys, Size size, bool fallback) =>
      _slotBool(_slotKeyFor(keys, size)) ?? fallback;

  /// Media rows: thumbnail left, text right. Pixel-sized per orientation.
  MediaListStyleSettings rowsStyleFor(Size size) {
    return MediaListStyleSettings(
      layout: MediaLibraryContentLayout.rows,
      crossAxisCount: _slotIntOr(
        _rowsColumnsKeys,
        size,
        MediaLibraryViewDefaults.rowsColumns(size),
        MediaLibraryViewDefaults.minRowsColumns,
        MediaLibraryViewDefaults.maxRowsColumns,
      ),
      rowExtent: _slotDoubleOr(
        _rowsExtentKeys,
        size,
        MediaLibraryViewDefaults.rowsExtent(size),
        MediaLibraryViewDefaults.minRowsExtent,
        MediaLibraryViewDefaults.maxRowsExtent,
      ),
      titleSize: _slotDoubleOr(
        _rowsTitleSizeKeys,
        size,
        MediaLibraryViewDefaults.rowsTitleSize(size),
        MediaLibraryViewDefaults.minTitleSize,
        MediaLibraryViewDefaults.maxTitleSize,
      ),
      titleLines: _slotIntOr(
        _rowsTitleLinesKeys,
        size,
        MediaLibraryViewDefaults.rowsTitleLines,
        MediaLibraryViewDefaults.minTitleLines,
        MediaLibraryViewDefaults.maxTitleLines,
      ),
      crossSpacing: _slotDoubleOr(
        _rowsCrossSpacingKeys,
        size,
        MediaLibraryViewDefaults.rowsCrossSpacing(size),
        MediaLibraryViewDefaults.minSpacing,
        MediaLibraryViewDefaults.maxSpacing,
      ),
      mainSpacing: _slotDoubleOr(
        _rowsMainSpacingKeys,
        size,
        MediaLibraryViewDefaults.rowsMainSpacing(size),
        MediaLibraryViewDefaults.minSpacing,
        MediaLibraryViewDefaults.maxSpacing,
      ),
      outerPadding: _slotDoubleOr(
        _rowsOuterPaddingKeys,
        size,
        MediaLibraryViewDefaults.rowsOuterPadding(size),
        MediaLibraryViewDefaults.minOuterPadding,
        MediaLibraryViewDefaults.maxOuterPadding,
      ),
      showThumbnail: _slotBoolOr(_rowsShowThumbnailKeys, size, true),
      showIndex: _slotBoolOr(_rowsShowIndexKeys, size, false),
      showMeta: _slotBoolOr(_rowsShowMetaKeys, size, true),
      showProgress: _slotBoolOr(_rowsShowProgressKeys, size, true),
      // Flat rows with a hover surface read lighter than stacked cards.
      cardSurface: _slotBoolOr(_rowsCardSurfaceKeys, size, false),
      // Legacy proportional fields are unused once rowExtent is set.
      titleScale: mediaListTitleScale,
      heightScale: mediaListItemHeightScale,
      crossSpacingScale: 0,
      mainSpacingScale: 0,
    );
  }

  /// Details table: one column of fixed-height rows plus a pinned header.
  MediaListStyleSettings tableStyleFor(Size size) {
    final storedColumns = _hasPref(_slotKeyFor(_tableColumnsKeys, size))
        ? _prefs.getString(_slotKeyFor(_tableColumnsKeys, size))
        : null;
    return MediaListStyleSettings(
      layout: MediaLibraryContentLayout.table,
      crossAxisCount: 1,
      rowExtent: _slotDoubleOr(
        _tableExtentKeys,
        size,
        MediaLibraryViewDefaults.tableExtent(size),
        MediaLibraryViewDefaults.minTableExtent,
        MediaLibraryViewDefaults.maxTableExtent,
      ),
      titleSize: _slotDoubleOr(
        _tableTitleSizeKeys,
        size,
        MediaLibraryViewDefaults.tableTitleSize(size),
        MediaLibraryViewDefaults.minTitleSize,
        MediaLibraryViewDefaults.maxTitleSize,
      ),
      titleLines: 1,
      crossSpacing: 0,
      mainSpacing: 0,
      outerPadding: _slotDoubleOr(
        _tableOuterPaddingKeys,
        size,
        MediaLibraryViewDefaults.tableOuterPadding(size),
        MediaLibraryViewDefaults.minOuterPadding,
        MediaLibraryViewDefaults.maxOuterPadding,
      ),
      showThumbnail: _slotBoolOr(_tableShowThumbnailKeys, size, true),
      showIndex: _slotBoolOr(_tableShowIndexKeys, size, false),
      // Hairline row dividers already guide the eye; stripes are opt-in.
      striped: _slotBoolOr(_tableStripedKeys, size, false),
      tableColumns: storedColumns == null
          ? MediaLibraryViewDefaults.tableColumns(size)
          : MediaTableColumn.decode(storedColumns),
      titleScale: mediaListTitleScale,
      heightScale: mediaListItemHeightScale,
      crossSpacingScale: 0,
      mainSpacingScale: 0,
    );
  }

  /// Writes only the given fields into the current orientation's slots.
  Future<void> updateRowsStyleFor(
    Size size, {
    int? columns,
    double? rowExtent,
    double? titleSize,
    int? titleLines,
    double? crossSpacing,
    double? mainSpacing,
    double? outerPadding,
    bool? showThumbnail,
    bool? showIndex,
    bool? showMeta,
    bool? showProgress,
    bool? cardSurface,
  }) async {
    String k((String, String) keys) => _slotKeyFor(keys, size);
    if (columns != null) {
      await _writeSlotInt(
        k(_rowsColumnsKeys),
        columns.clamp(MediaLibraryViewDefaults.minRowsColumns, MediaLibraryViewDefaults.maxRowsColumns),
      );
    }
    if (rowExtent != null) {
      await _writeSlotDouble(
        k(_rowsExtentKeys),
        rowExtent.clamp(MediaLibraryViewDefaults.minRowsExtent, MediaLibraryViewDefaults.maxRowsExtent),
      );
    }
    if (titleSize != null) {
      await _writeSlotDouble(
        k(_rowsTitleSizeKeys),
        titleSize.clamp(MediaLibraryViewDefaults.minTitleSize, MediaLibraryViewDefaults.maxTitleSize),
      );
    }
    if (titleLines != null) {
      await _writeSlotInt(
        k(_rowsTitleLinesKeys),
        titleLines.clamp(MediaLibraryViewDefaults.minTitleLines, MediaLibraryViewDefaults.maxTitleLines),
      );
    }
    if (crossSpacing != null) {
      await _writeSlotDouble(
        k(_rowsCrossSpacingKeys),
        crossSpacing.clamp(MediaLibraryViewDefaults.minSpacing, MediaLibraryViewDefaults.maxSpacing),
      );
    }
    if (mainSpacing != null) {
      await _writeSlotDouble(
        k(_rowsMainSpacingKeys),
        mainSpacing.clamp(MediaLibraryViewDefaults.minSpacing, MediaLibraryViewDefaults.maxSpacing),
      );
    }
    if (outerPadding != null) {
      await _writeSlotDouble(
        k(_rowsOuterPaddingKeys),
        outerPadding.clamp(MediaLibraryViewDefaults.minOuterPadding, MediaLibraryViewDefaults.maxOuterPadding),
      );
    }
    if (showThumbnail != null) {
      await _writeSlotBool(k(_rowsShowThumbnailKeys), showThumbnail);
    }
    if (showIndex != null) {
      await _writeSlotBool(k(_rowsShowIndexKeys), showIndex);
    }
    if (showMeta != null) {
      await _writeSlotBool(k(_rowsShowMetaKeys), showMeta);
    }
    if (showProgress != null) {
      await _writeSlotBool(k(_rowsShowProgressKeys), showProgress);
    }
    if (cardSurface != null) {
      await _writeSlotBool(k(_rowsCardSurfaceKeys), cardSurface);
    }
    notifyListeners();
  }

  Future<void> updateTableStyleFor(
    Size size, {
    double? rowExtent,
    double? titleSize,
    double? outerPadding,
    bool? showThumbnail,
    bool? showIndex,
    bool? striped,
    Set<MediaTableColumn>? columns,
  }) async {
    String k((String, String) keys) => _slotKeyFor(keys, size);
    if (rowExtent != null) {
      await _writeSlotDouble(
        k(_tableExtentKeys),
        rowExtent.clamp(MediaLibraryViewDefaults.minTableExtent, MediaLibraryViewDefaults.maxTableExtent),
      );
    }
    if (titleSize != null) {
      await _writeSlotDouble(
        k(_tableTitleSizeKeys),
        titleSize.clamp(MediaLibraryViewDefaults.minTitleSize, MediaLibraryViewDefaults.maxTitleSize),
      );
    }
    if (outerPadding != null) {
      await _writeSlotDouble(
        k(_tableOuterPaddingKeys),
        outerPadding.clamp(MediaLibraryViewDefaults.minOuterPadding, MediaLibraryViewDefaults.maxOuterPadding),
      );
    }
    if (showThumbnail != null) {
      await _writeSlotBool(k(_tableShowThumbnailKeys), showThumbnail);
    }
    if (showIndex != null) {
      await _writeSlotBool(k(_tableShowIndexKeys), showIndex);
    }
    if (striped != null) {
      await _writeSlotBool(k(_tableStripedKeys), striped);
    }
    if (columns != null) {
      await _prefs.setString(
        k(_tableColumnsKeys),
        MediaTableColumn.encode(columns),
      );
    }
    notifyListeners();
  }

  /// Drops the current orientation's overrides so responsive defaults apply.
  Future<void> resetRowsStyleFor(Size size) async {
    for (final keys in _rowsSlotKeys) {
      await _prefs.remove(_slotKeyFor(keys, size));
    }
    notifyListeners();
  }

  Future<void> resetTableStyleFor(Size size) async {
    for (final keys in _tableSlotKeys) {
      await _prefs.remove(_slotKeyFor(keys, size));
    }
    notifyListeners();
  }

  /// Drops the current orientation's card-grid overrides (home/folder grid).
  Future<void> resetGridStyleFor(Size size) async {
    for (final keys in _gridSlotKeys) {
      await _prefs.remove(_slotKeyFor(keys, size));
    }
    notifyListeners();
  }

  /// Retired proportional list style. Its values are kept for export and
  /// for users who re-import old settings; nothing renders from it anymore.
  MediaListStyleSettings legacyListStyleFor(Size size) {
    final slot = MediaLibraryLayoutDefaults.slotFor(size);
    return MediaListStyleSettings(
      crossAxisCount: _resolveColumns(
        size: size,
        slot: slot,
        portraitKey: 'mediaListCrossAxisCountPortrait',
        landscapeKey: 'mediaListCrossAxisCountLandscape',
        legacyKey: 'mediaListCrossAxisCount',
        legacy: mediaListCrossAxisCount,
        fallback: () =>
            MediaLibraryLayoutDefaults.defaultListCrossAxisCount(size),
      ),
      titleScale:
          _resolveDouble(
            slot: slot,
            portraitKey: 'mediaListTitleScalePortrait',
            landscapeKey: 'mediaListTitleScaleLandscape',
            legacyKey: 'mediaListTitleScale',
            legacy: mediaListTitleScale,
            inheritLegacyOnPortrait: true,
            fallback: mediaListTitleScale,
          ).clamp(
            MediaListLayoutMetrics.minTitleSetting,
            MediaListLayoutMetrics.maxTitleSetting,
          ),
      heightScale:
          _resolveDouble(
            slot: slot,
            portraitKey: 'mediaListItemHeightScalePortrait',
            landscapeKey: 'mediaListItemHeightScaleLandscape',
            legacyKey: 'mediaListItemHeightScale',
            legacy: mediaListItemHeightScale,
            inheritLegacyOnPortrait: true,
            fallback: mediaListItemHeightScale,
          ).clamp(
            MediaListLayoutMetrics.minHeightSetting,
            MediaListLayoutMetrics.maxHeightSetting,
          ),
      crossSpacingScale: _resolveSpacing(
        slot: slot,
        portraitKey: 'mediaListCrossSpacingScalePortrait',
        landscapeKey: 'mediaListCrossSpacingScaleLandscape',
        fallback: MediaLibraryLayoutDefaults.defaultListSpacingScale,
      ),
      mainSpacingScale: _resolveSpacing(
        slot: slot,
        portraitKey: 'mediaListMainSpacingScalePortrait',
        landscapeKey: 'mediaListMainSpacingScaleLandscape',
        fallback: MediaLibraryLayoutDefaults.defaultListSpacingScale,
      ),
      showThumbnail: _resolveBool(
        slot: slot,
        portraitKey: 'mediaListShowThumbnailPortrait',
        landscapeKey: 'mediaListShowThumbnailLandscape',
        legacy: mediaListShowThumbnail,
      ),
      showIndex: _resolveBool(
        slot: slot,
        portraitKey: 'mediaListShowIndexPortrait',
        landscapeKey: 'mediaListShowIndexLandscape',
        legacy: mediaListShowIndex,
      ),
    );
  }

  Future<void> updateHomeCardStyleFor(
    Size size, {
    int? crossAxisCount,
    double? titleScale,
    double? heightScale,
    double? crossSpacingScale,
    double? mainSpacingScale,
  }) {
    return _updateCardStyleFor(
      size: size,
      crossAxisCount: crossAxisCount,
      titleScale: titleScale,
      heightScale: heightScale,
      crossSpacingScale: crossSpacingScale,
      mainSpacingScale: mainSpacingScale,
      columnsPortraitKey: 'homeGridCrossAxisCountPortrait',
      columnsLandscapeKey: 'homeGridCrossAxisCountLandscape',
      columnsLegacyKey: 'homeGridCrossAxisCount',
      titlePortraitKey: 'homeCardTitleFontSizePortrait',
      titleLandscapeKey: 'homeCardTitleFontSizeLandscape',
      titleLegacyKey: 'homeCardTitleFontSize',
      aspectPortraitKey: 'homeCardAspectRatioPortrait',
      aspectLandscapeKey: 'homeCardAspectRatioLandscape',
      aspectLegacyKey: 'homeCardAspectRatio',
      crossSpacingPortraitKey: 'homeCardCrossSpacingScalePortrait',
      crossSpacingLandscapeKey: 'homeCardCrossSpacingScaleLandscape',
      mainSpacingPortraitKey: 'homeCardMainSpacingScalePortrait',
      mainSpacingLandscapeKey: 'homeCardMainSpacingScaleLandscape',
      applyLegacyColumns: (value) => homeGridCrossAxisCount = value,
      applyLegacyTitle: (value) => homeCardTitleFontSize = value,
      applyLegacyAspect: (value) => homeCardAspectRatio = value,
    );
  }

  Future<void> updateCollectionCardStyleFor(
    Size size, {
    int? crossAxisCount,
    double? titleScale,
    double? heightScale,
    double? crossSpacingScale,
    double? mainSpacingScale,
  }) {
    return updateHomeCardStyleFor(
      size,
      crossAxisCount: crossAxisCount,
      titleScale: titleScale,
      heightScale: heightScale,
      crossSpacingScale: crossSpacingScale,
      mainSpacingScale: mainSpacingScale,
    );
  }

  /// Pinch-zoom column change for whichever row layout is active. The table
  /// is always one column, so it ignores the gesture.
  Future<void> updateActiveListColumnsFor(Size size, int columns) async {
    if (mediaLibraryContentLayout == MediaLibraryContentLayout.table) return;
    await updateRowsStyleFor(size, columns: columns);
  }

  /// Writes the retired proportional list slots (see [legacyListStyleFor]).
  Future<void> updateListStyleFor(
    Size size, {
    int? crossAxisCount,
    double? titleScale,
    double? heightScale,
    double? crossSpacingScale,
    double? mainSpacingScale,
    bool? showThumbnail,
    bool? showIndex,
  }) async {
    final landscape = MediaLibraryLayoutDefaults.isLandscape(size);
    if (crossAxisCount != null) {
      final columns = MediaLibraryLayoutDefaults.clampColumns(crossAxisCount);
      await _writeSlotInt(
        landscape
            ? 'mediaListCrossAxisCountLandscape'
            : 'mediaListCrossAxisCountPortrait',
        columns,
      );
      if (landscape) {
        mediaListCrossAxisCount = columns;
        await _prefs.setInt('mediaListCrossAxisCount', columns);
      }
    }
    if (titleScale != null) {
      final value = titleScale.clamp(
        MediaListLayoutMetrics.minTitleSetting,
        MediaListLayoutMetrics.maxTitleSetting,
      );
      await _writeSlotDouble(
        landscape
            ? 'mediaListTitleScaleLandscape'
            : 'mediaListTitleScalePortrait',
        value,
      );
      if (landscape) {
        mediaListTitleScale = value;
        await _prefs.setDouble('mediaListTitleScale', value);
      }
    }
    if (heightScale != null) {
      final value = heightScale.clamp(
        MediaListLayoutMetrics.minHeightSetting,
        MediaListLayoutMetrics.maxHeightSetting,
      );
      await _writeSlotDouble(
        landscape
            ? 'mediaListItemHeightScaleLandscape'
            : 'mediaListItemHeightScalePortrait',
        value,
      );
      if (landscape) {
        mediaListItemHeightScale = value;
        await _prefs.setDouble('mediaListItemHeightScale', value);
      }
    }
    if (crossSpacingScale != null) {
      await _writeSlotDouble(
        landscape
            ? 'mediaListCrossSpacingScaleLandscape'
            : 'mediaListCrossSpacingScalePortrait',
        MediaLibraryLayoutDefaults.clampSpacing(crossSpacingScale),
      );
    }
    if (mainSpacingScale != null) {
      await _writeSlotDouble(
        landscape
            ? 'mediaListMainSpacingScaleLandscape'
            : 'mediaListMainSpacingScalePortrait',
        MediaLibraryLayoutDefaults.clampSpacing(mainSpacingScale),
      );
    }
    if (showThumbnail != null) {
      await _writeSlotBool(
        landscape
            ? 'mediaListShowThumbnailLandscape'
            : 'mediaListShowThumbnailPortrait',
        showThumbnail,
      );
      if (landscape) {
        mediaListShowThumbnail = showThumbnail;
        await _prefs.setBool('mediaListShowThumbnail', showThumbnail);
      }
    }
    if (showIndex != null) {
      await _writeSlotBool(
        landscape
            ? 'mediaListShowIndexLandscape'
            : 'mediaListShowIndexPortrait',
        showIndex,
      );
      if (landscape) {
        mediaListShowIndex = showIndex;
        await _prefs.setBool('mediaListShowIndex', showIndex);
      }
    }
    notifyListeners();
  }

  MediaCardStyleSettings _cardStyleFor({
    required Size size,
    required String columnsPortraitKey,
    required String columnsLandscapeKey,
    required String columnsLegacyKey,
    required int columnsLegacy,
    required String titlePortraitKey,
    required String titleLandscapeKey,
    required String titleLegacyKey,
    required double titleLegacy,
    required String aspectPortraitKey,
    required String aspectLandscapeKey,
    required String aspectLegacyKey,
    required double aspectLegacy,
    required String crossSpacingPortraitKey,
    required String crossSpacingLandscapeKey,
    required String mainSpacingPortraitKey,
    required String mainSpacingLandscapeKey,
  }) {
    final slot = MediaLibraryLayoutDefaults.slotFor(size);
    final readable = mediaLibraryReadableCardDefaults;
    bool hasOverride(
      String portrait,
      String landscape,
      String legacy, {
      bool inheritLegacyOnPortrait = true,
    }) =>
        _prefs.containsKey(
          slot == MediaLibraryOrientationSlot.landscape ? landscape : portrait,
        ) ||
        ((slot == MediaLibraryOrientationSlot.landscape ||
                inheritLegacyOnPortrait) &&
            _prefs.containsKey(legacy));
    final aspect = _resolveDouble(
      slot: slot,
      portraitKey: aspectPortraitKey,
      landscapeKey: aspectLandscapeKey,
      legacyKey: aspectLegacyKey,
      legacy: aspectLegacy,
      inheritLegacyOnPortrait: true,
      fallback:
          1.0 /
          (readable
              ? MediaLibraryLayoutDefaults.readableHeightScale
              : MediaLibraryLayoutDefaults.defaultHeightScale),
    );
    final columns = _resolveColumns(
      size: size,
      slot: slot,
      portraitKey: columnsPortraitKey,
      landscapeKey: columnsLandscapeKey,
      legacyKey: columnsLegacyKey,
      legacy: columnsLegacy,
      fallback: () => readable
          ? MediaLibraryLayoutDefaults.readableCardCrossAxisCount(
              size,
              mobile: defaultTrialDevice.mobile,
              phone: defaultTrialDevice.phone,
            )
          : MediaLibraryLayoutDefaults.defaultCardCrossAxisCount(size),
    );
    final crossSpacing = _resolveSpacing(
      slot: slot,
      portraitKey: crossSpacingPortraitKey,
      landscapeKey: crossSpacingLandscapeKey,
    );
    return MediaCardStyleSettings(
      usesDefaultColumns:
          readable &&
          !hasOverride(
            columnsPortraitKey,
            columnsLandscapeKey,
            columnsLegacyKey,
            inheritLegacyOnPortrait: false,
          ),
      reserveTwoTitleLines:
          readable &&
          !hasOverride(aspectPortraitKey, aspectLandscapeKey, aspectLegacyKey),
      crossAxisCount: columns,
      titleScale: MediaLibraryLayoutDefaults.normalizeTitleScale(
        _resolveDouble(
          slot: slot,
          portraitKey: titlePortraitKey,
          landscapeKey: titleLandscapeKey,
          legacyKey: titleLegacyKey,
          legacy: titleLegacy,
          inheritLegacyOnPortrait: true,
          fallback: readable
              ? MediaLibraryLayoutDefaults.proportionalCardTitleScale
              : MediaLibraryLayoutDefaults.defaultTitleScale,
        ),
      ),
      heightScale: MediaLibraryLayoutDefaults.clampHeight(
        1.0 / math.max(0.1, aspect),
      ),
      crossSpacingScale: crossSpacing,
      mainSpacingScale: _resolveSpacing(
        slot: slot,
        portraitKey: mainSpacingPortraitKey,
        landscapeKey: mainSpacingLandscapeKey,
      ),
    );
  }

  Future<void> _updateCardStyleFor({
    required Size size,
    int? crossAxisCount,
    double? titleScale,
    double? heightScale,
    double? crossSpacingScale,
    double? mainSpacingScale,
    required String columnsPortraitKey,
    required String columnsLandscapeKey,
    required String columnsLegacyKey,
    required String titlePortraitKey,
    required String titleLandscapeKey,
    required String titleLegacyKey,
    required String aspectPortraitKey,
    required String aspectLandscapeKey,
    required String aspectLegacyKey,
    required String crossSpacingPortraitKey,
    required String crossSpacingLandscapeKey,
    required String mainSpacingPortraitKey,
    required String mainSpacingLandscapeKey,
    required void Function(int value) applyLegacyColumns,
    required void Function(double value) applyLegacyTitle,
    required void Function(double value) applyLegacyAspect,
  }) async {
    final landscape = MediaLibraryLayoutDefaults.isLandscape(size);
    if (crossAxisCount != null) {
      final columns = MediaLibraryLayoutDefaults.clampColumns(crossAxisCount);
      await _writeSlotInt(
        landscape ? columnsLandscapeKey : columnsPortraitKey,
        columns,
      );
      if (landscape) {
        applyLegacyColumns(columns);
        await _prefs.setInt(columnsLegacyKey, columns);
      }
    }
    if (titleScale != null) {
      final value = MediaLibraryLayoutDefaults.normalizeTitleScale(titleScale);
      await _writeSlotDouble(
        landscape ? titleLandscapeKey : titlePortraitKey,
        value,
      );
      // Keep the unsuffixed key as the landscape/migration value only, so a
      // portrait tweak cannot rewrite the other orientation.
      if (landscape) {
        applyLegacyTitle(value);
        await _prefs.setDouble(titleLegacyKey, value);
      }
    }
    if (heightScale != null) {
      final aspect = 1.0 / MediaLibraryLayoutDefaults.clampHeight(heightScale);
      await _writeSlotDouble(
        landscape ? aspectLandscapeKey : aspectPortraitKey,
        aspect,
      );
      if (landscape) {
        applyLegacyAspect(aspect);
        await _prefs.setDouble(aspectLegacyKey, aspect);
      }
    }
    if (crossSpacingScale != null) {
      await _writeSlotDouble(
        landscape ? crossSpacingLandscapeKey : crossSpacingPortraitKey,
        MediaLibraryLayoutDefaults.clampSpacing(crossSpacingScale),
      );
    }
    if (mainSpacingScale != null) {
      await _writeSlotDouble(
        landscape ? mainSpacingLandscapeKey : mainSpacingPortraitKey,
        MediaLibraryLayoutDefaults.clampSpacing(mainSpacingScale),
      );
    }
    notifyListeners();
  }

  int _resolveColumns({
    required Size size,
    required MediaLibraryOrientationSlot slot,
    required String portraitKey,
    required String landscapeKey,
    required String legacyKey,
    required int legacy,
    required int Function() fallback,
  }) {
    final stored = _slotInt(
      slot == MediaLibraryOrientationSlot.landscape
          ? landscapeKey
          : portraitKey,
    );
    if (stored != null) {
      return MediaLibraryLayoutDefaults.clampColumns(stored);
    }
    // A persisted unsuffixed key was almost certainly set in landscape; keep
    // it there and let portrait fall through to the size-class default.
    if (slot == MediaLibraryOrientationSlot.landscape && _hasPref(legacyKey)) {
      return MediaLibraryLayoutDefaults.clampColumns(legacy);
    }
    return fallback();
  }

  double _resolveDouble({
    required MediaLibraryOrientationSlot slot,
    required String portraitKey,
    required String landscapeKey,
    required String legacyKey,
    required double legacy,
    required bool inheritLegacyOnPortrait,
    required double fallback,
  }) {
    final stored = _slotDouble(
      slot == MediaLibraryOrientationSlot.landscape
          ? landscapeKey
          : portraitKey,
    );
    if (stored != null) return stored;
    final useLegacy =
        _hasPref(legacyKey) &&
        (slot == MediaLibraryOrientationSlot.landscape ||
            inheritLegacyOnPortrait);
    return useLegacy ? legacy : fallback;
  }

  double _resolveSpacing({
    required MediaLibraryOrientationSlot slot,
    required String portraitKey,
    required String landscapeKey,
    double? fallback,
  }) {
    final stored = _slotDouble(
      slot == MediaLibraryOrientationSlot.landscape
          ? landscapeKey
          : portraitKey,
    );
    return MediaLibraryLayoutDefaults.clampSpacing(
      stored ?? fallback ?? MediaLibraryLayoutDefaults.defaultSpacingScale,
    );
  }

  bool _resolveBool({
    required MediaLibraryOrientationSlot slot,
    required String portraitKey,
    required String landscapeKey,
    required bool legacy,
  }) {
    final stored = _slotBool(
      slot == MediaLibraryOrientationSlot.landscape
          ? landscapeKey
          : portraitKey,
    );
    return stored ?? legacy;
  }

  bool _hasPref(String key) {
    if (!_initialized) return false;
    return _prefs.containsKey(key);
  }

  int? _slotInt(String key) {
    if (!_hasPref(key)) return null;
    return _prefs.getInt(key);
  }

  double? _slotDouble(String key) {
    if (!_hasPref(key)) return null;
    return _prefs.getDouble(key);
  }

  bool? _slotBool(String key) {
    if (!_hasPref(key)) return null;
    return _prefs.getBool(key);
  }

  Future<void> _writeSlotInt(String key, int value) {
    return _prefs.setInt(key, value);
  }

  Future<void> _writeSlotDouble(String key, double value) {
    return _prefs.setDouble(key, value);
  }

  Future<void> _writeSlotBool(String key, bool value) {
    return _prefs.setBool(key, value);
  }

  /// Whether newly imported media is copied into app-managed storage.
  ///
  /// This is intentionally opt-in. Import operations snapshot the value when
  /// they start so a multi-file import can never end up with mixed semantics.
  bool copyImportedMediaToPrivateStorage = false;

  /// All acquisition methods share the root by default; users organise later.
  String importCardPlacement = ImportCardPlacement.libraryRoot.storageValue;
  String importSourceFolderNamesJson = '{}';
  String importSourceFolderIdsJson = '{}';
  String importPlacementRulesJson = '{}';

  ImportCardPlacement get importCardPlacementMode =>
      ImportCardPlacementX.fromStorage(importCardPlacement);

  ImportPlacementRules get importPlacementRules =>
      ImportPlacementRules.decode(importPlacementRulesJson);

  ImportPlacementRequest captureImportPlacement(
    ImportCardFeature feature, {
    String? openedFromFolderId,
  }) {
    final rule = importPlacementRules.effectiveRule(
      feature,
      importCardPlacementMode,
    );
    final folderId = switch (rule.placement) {
      ImportCardPlacement.currentFolder => openedFromFolderId,
      ImportCardPlacement.fixedFolder => rule.folderId,
      ImportCardPlacement.sourceFolder => importSourceFolderId(feature),
      _ => null,
    };
    return ImportPlacementRequest(
      feature: feature,
      placement: rule.placement,
      folderId: folderId,
      sourceFolderName: importSourceFolderName(feature),
      isResolved:
          rule.placement != ImportCardPlacement.sourceFolder &&
          rule.placement != ImportCardPlacement.askEveryTime,
    );
  }

  Future<void> saveImportPlacement(
    ImportCardPlacement preset,
    ImportPlacementRules rules,
  ) async {
    // Both runtime values change before yielding; a task sees one whole plan.
    final rulesWrite = updateSetting(
      ImportPlacementRules.settingsKey,
      rules.encode(),
    );
    final presetWrite = updateSetting(
      'importCardPlacement',
      preset.storageValue,
    );
    await Future.wait([rulesWrite, presetWrite]);
  }

  Map<String, String> get importSourceFolderNames =>
      ImportSourceFolders.decodeNames(importSourceFolderNamesJson);

  Map<String, String> get importSourceFolderIds =>
      ImportSourceFolders.decodeIds(importSourceFolderIdsJson);

  String importSourceFolderName(ImportCardFeature feature) =>
      importSourceFolderNames[feature.storageValue] ??
      feature.defaultFolderName;

  String? importSourceFolderId(ImportCardFeature feature) =>
      importSourceFolderIds[feature.storageValue];

  /// When true, opening a video from search uses the search listing as the
  /// playback queue. Default is false so next/previous stay in the original
  /// folder order and do not jump across unrelated series.
  bool useSearchResultsAsPlaybackQueue = false;

  /// When true, Mini/notification Bilibili sessions drop the video track and
  /// only fetch audio. Default is false so background playback keeps downloading
  /// video+audio and a later page entry can mount the live picture.
  bool bilibiliBackgroundAudioOnly = false;

  /// Master opt-in for every automatic clipboard link prompt, including Bilibili.
  bool clipboardLinkDetectionEnabled = true;

  /// Suppress the last handled clipboard update across activations/restarts.
  /// A new OS update may contain the same text and is eligible again.
  bool skipRepeatedClipboardText = true;

  /// Mini playback card in the media library. Default on so an active session
  /// keeps the card. Turning it off only hides the card; playback continues.
  bool showMiniPlaybackCard = true;

  /// Android/iOS system media notification, lock screen and Control Center.
  /// Default on. Desktop has no system media notification, so the switch is
  /// not shown there. Turning it off removes the notification without stopping
  /// playback.
  bool showSystemMediaNotification = true;

  bool desktopSystemMediaControls = true;
  bool desktopTaskbarMediaControls = true;
  bool desktopGlobalMediaHotkeys = false;

  /// Ctrl+Alt by default; Ctrl+Alt+Shift is an alternative if another app owns it.
  String desktopMediaHotkeyModifiers = 'ctrl+alt';

  /// Whether keyword searches on the Bilibili page are added to the search
  /// history. Turning it off keeps existing entries.
  bool bilibiliRecordSearchHistory = true;

  /// Whether videos opened from the Bilibili pages are added to the watch
  /// history. Turning it off keeps existing entries.
  bool bilibiliRecordWatchHistory = true;

  /// Whether playing from the Bilibili pages also imports the video: on, the
  /// library card for the BV + part is reused or created as before; off (the
  /// default), playback uses a watch-only card that never enters the media
  /// library.
  bool bilibiliAutoImportOnPlay = false;

  /// Where the Bilibili "import" button puts cards: empty until a place is
  /// picked (the import placement rules decide, as before), `root` for the
  /// library root or `folder:<id>` for a folder. Read through
  /// `BilibiliImportTarget`.
  String bilibiliImportTarget = '';

  /// Size cap for the online playback cache (`bilibili_stream_cache`), one of
  /// [bilibiliCacheLimitOptions].
  int bilibiliCacheLimitBytes = bilibiliCacheLimitDefault;

  static const int _mib = 1024 * 1024;
  static const List<int> bilibiliCacheLimitOptions = <int>[
    128 * _mib,
    256 * _mib,
    512 * _mib,
    1024 * _mib,
    2048 * _mib,
  ];
  static const int bilibiliCacheLimitDefault = 1024 * _mib;

  /// Nearest allowed cache cap at or below [value] (smallest option if below
  /// all of them).
  static int normalizeBilibiliCacheLimit(int value) {
    var result = bilibiliCacheLimitOptions.first;
    for (final option in bilibiliCacheLimitOptions) {
      if (option <= value) result = option;
    }
    return result;
  }

  /// Latest clipboard text whose parse attempt finished. This is not a user
  /// setting and is omitted from settings export so a backup does not carry
  /// clipboard contents to another device.
  String? clipboardLastHandledText;
  static const String clipboardLastHandledTextKey = 'clipboardLastHandledText';
  String structuredImportSortField = 'fileName';
  String structuredImportSortDirection = 'ascending';

  // New: Subtitle Sidebar Font Scale (Landscape)
  double landscapeSidebarFontSizeScale = 1.0;

  // New: Subtitle Sidebar Font Scale (Portrait)
  double portraitSidebarFontSizeScale = 1.0;

  // Subtitle sidebar list timestamp layout (kept separate per orientation).
  bool landscapeSidebarShowTimestamps = true;
  bool portraitSidebarShowTimestamps = true;
  double landscapeSidebarTimeColumnRatio = 0.18;
  double portraitSidebarTimeColumnRatio = 0.12;

  // Subtitle sidebar locate alignment, as a percentage from the top.
  int landscapeSidebarLocatePositionPercent = 30;
  int portraitSidebarLocatePositionPercent = 30;

  // Global paragraph size used by the subtitle sidebar article view.
  int subtitleArticleSentencesPerParagraph = 4;

  // Article view uses paragraphs by default. When disabled, subtitles flow as
  // one continuous article while retaining the saved paragraph size.
  bool subtitleArticleParagraphModeEnabled = true;

  // New: Subtitle Sidebar View Mode (0: List, 1: Article)
  int subtitleViewMode = 0;

  /// How subtitle-sidebar selections are joined when copied. Display layout
  /// is unchanged; only clipboard output follows this format.
  SubtitleCopyFormat subtitleCopyFormat = SubtitleCopyFormat.defaults;

  bool isLandscapeSubtitleSidebarVisible = true;
  bool showSubtitleSidebarToggle = true;

  /// Whether the landscape player's Bilibili panel was left open (one choice
  /// for all Bilibili videos). Only the panel button, its shortcut and the
  /// panel's collapse button change it; panels shown over it for a moment do
  /// not.
  bool bilibiliPlayerPanelOpen = true;

  /// Whether the portrait player's 「详情 | 字幕」 switch of Bilibili videos was
  /// left on 字幕 (one choice for all Bilibili videos); false is 详情. Only a
  /// tap on the switch in the player changes it.
  bool bilibiliPortraitShowsSubtitles = false;

  /// Selected tab in the shared landscape Bilibili/subtitle sidebar. Its
  /// visibility and width use the ordinary landscape subtitle sidebar settings.
  bool bilibiliLandscapeShowsSubtitles = false;

  // New: AI Model Selection
  String lastSelectedModelType = 'base';

  // New: Subtitle Ghost Mode
  bool isGhostModeEnabled = true;
  Alignment ghostModeAlignment = const Alignment(0.0, 0.8856727518593654);

  // 音乐播放器的字号及相对间距，竖屏、横屏分别记忆。
  double musicLyricFontSizeScalePortrait =
      MusicLyricTypography.defaultFontSizeScale;

  double musicLyricFontSizeScaleLandscape =
      MusicLyricTypography.defaultFontSizeScale;

  double musicLyricSpacingScalePortrait =
      MusicLyricTypography.defaultSpacingScale;

  double musicLyricSpacingScaleLandscape =
      MusicLyricTypography.defaultSpacingScale;

  /// Negative means the original responsive layout; custom values are 10–70%.
  double musicLyricAnchorPortrait = MusicLyricAnchor.automatic;
  double musicLyricAnchorLandscape = MusicLyricAnchor.automatic;

  /// 词级歌词是否逐词点亮。关闭后仍按整行高亮，只是不再逐词推进。
  bool musicLyricWordByWordEnabled = true;

  /// 非当前行的景深模糊。默认打开；关掉后远处歌词保持清晰。
  bool musicLyricBlurEnabled = true;

  /// 竖屏底部播放控件默认常驻；打开后允许闲置或滚动歌词时隐藏。
  bool musicPortraitControlsAutoHide = false;

  /// Music lyric role: both, primary or secondary. Unknown values load as both.
  String musicLyricTrackDisplayMode = 'both';

  // New: Split Subtitle by Line
  bool splitSubtitleByLine = true;

  // New: Continuous Subtitle Display
  bool videoContinuousSubtitle = false;
  bool audioContinuousSubtitle = false;

  Alignment _readAlignmentPreference({
    required String jsonKey,
    required String legacyXKey,
    required String legacyYKey,
    required Alignment fallback,
  }) {
    final String? rawJson = _prefs.getString(jsonKey);
    if (rawJson != null && rawJson.isNotEmpty) {
      try {
        final Map<String, dynamic> decoded = Map<String, dynamic>.from(
          json.decode(rawJson),
        );
        final double? x = (decoded['x'] as num?)?.toDouble();
        final double? y = (decoded['y'] as num?)?.toDouble();
        if (x != null && y != null && x.isFinite && y.isFinite) {
          return clampSubtitleAlignment(Alignment(x, y));
        }
      } catch (e) {
        developer.log('Error loading alignment preference', error: e);
      }
    }
    return Alignment(
      _prefs.getDouble(legacyXKey) ?? fallback.x,
      _prefs.getDouble(legacyYKey) ?? fallback.y,
    );
  }

  void _attachPositionStore() {
    _positionStore?.dispose();
    _positionStore = SubtitlePositionStore(
      SharedPreferencesSubtitleBackend(_prefs),
    );
    _positionStore!.load();
  }

  Alignment? presetVideoPosition(String presetId) =>
      _positionStore?.videoOverride(presetId);

  Alignment? presetAudioPosition(String presetId) =>
      _positionStore?.audioOverride(presetId);

  bool presetHasPositionOverride(String presetId, {required bool audio}) {
    return audio
        ? presetAudioPosition(presetId) != null
        : presetVideoPosition(presetId) != null;
  }

  Future<PositionCommitResult> flushSubtitlePositions() {
    final SubtitlePositionStore? store = _positionStore;
    if (store == null) {
      return Future<PositionCommitResult>.value(
        const PositionCommitResult.success(0),
      );
    }
    return store.flush();
  }

  // New: Auto Pause on Exit
  bool autoPauseOnExit = true;

  // Skip the portrait player on mobile and open the landscape player
  // directly. Tablets default to on, phones to off; desktop always skips
  // regardless of this flag.
  bool? _skipPortraitPlayer;
  bool get skipPortraitPlayer =>
      _skipPortraitPlayer ?? _defaultSkipPortraitPlayer;
  set skipPortraitPlayer(bool value) => _skipPortraitPlayer = value;

  // Resolve an unset preference at use time as well as at load time. Display
  // metrics can still be unavailable when the settings registry is created.
  static bool get _defaultSkipPortraitPlayer =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS) &&
      DeviceFormFactor.isTabletLikeDevice();

  // Keep the complete primary/secondary subtitle group clear of visible
  // playback controls. Enabled by default on every platform.
  bool avoidPlaybackControlsWithSubtitles = true;

  // New: Pause playback when app goes to background on mobile.
  bool pausePlaybackWhenAppBackgrounded = true;

  // New: Allow concurrent playback with other apps.
  bool allowConcurrentPlayback = false;

  // Prefer the native platform's hardware video decoder. This controls
  // libmpv's `hwdec` option; GPU texture composition remains enabled in both
  // modes because CPU-rendering a Flutter video texture is prohibitively
  // expensive for high-resolution media.
  bool useHardwareVideoDecoding = true;

  // New: Enable wired/Bluetooth headset and system media controls.
  bool enableHeadsetMediaControls = true;

  // Automatically start playback when a media card opens a playback page.
  // This is deliberately separate from episode switching and completion.
  bool autoPlayOnPageEntry = true;

  // New: Auto Play Next Video
  bool autoPlayNextVideo = true;

  // 预加载下一个视频控制器（进度达 80% 时后台 initialize，切换时热替换）
  // 低端设备可关闭以减少内存占用
  bool enableVideoPreload = true;

  // New: Auto continue playback when current media completes.
  bool autoPlayOnCompletion = false;

  // New: When auto continuing, always restart the target media from zero.
  bool autoPlayOnCompletionFromStart = false;

  // When true, reaching the last playlist item can advance/wrap to the first.
  // Default off so the next-episode button stays disabled on the last item.
  bool playlistWrapToFirst = false;

  // New: Action Buttons Collapsed State
  bool isActionButtonsCollapsed = false;

  // Shared by portrait/landscape action rails, independent of card layout.
  bool showActionButtonLabels = true;

  bool localImportFilterMediaExtensions = true;

  String? largeDataRootPath;

  // New: Window Management
  bool isFullScreen = false;

  // New: Seek Preview
  bool enableSeekPreview = true;

  /// Experimental landscape matte behind letterboxed video. Off so existing
  /// playback stays black until someone opts in.
  bool experimentalAmbientLetterbox = false;

  // App-wide haptic feedback. Only surfaced on Android and iOS.
  bool enableHapticFeedback = true;

  // New: Suppress Bilibili Restricted Dialog
  bool suppressBilibiliRestrictedDialog = false;

  int videoComposeResolutionHeight = 1080;
  String videoComposeRenderMode = VideoComposeRenderMode.precise.storageValue;
  bool videoComposeContinuousSubtitle = false;
  bool videoComposeRenderSecondary = true;
  bool videoComposeEmbedSoftSubtitles = false;
  bool videoComposeSoftSubtitleOnly = false;
  bool videoComposeSoftSubtitleUseSourceQuality = true;
  bool videoComposeDeleteOutputOnTaskDelete = true;
  String? videoComposePrimarySubtitlePath;
  String? videoComposeSecondarySubtitlePath;
  String? videoComposeCustomOutputPath;

  String portraitCustomAspectDraftWidthText = '';
  String portraitCustomAspectDraftHeightText = '';

  bool batchSubtitleAutoDelete = false;
  bool processingScreenProtection = true;
  int processingScreenProtectionWaitSeconds =
      ProcessingScreenProtectionTiming.defaultSeconds;
  bool batchSubtitleKeepScreenAwake = false;

  /// Batch page only. Off until the user turns it on. Tasks started elsewhere
  /// never read this flag.
  bool batchSubtitleTranslateEnabled = false;
  SubtitleOutputPathStrategy batchSubtitleOutputPathStrategy =
      SubtitleOutputPathStrategy.sameAsVideo;
  String? batchSubtitleCustomOutputDir;

  // 外部视频内嵌软字幕设置
  bool batchSubtitleEmbedSoftCopyAndEmbed = false;
  bool batchSubtitleEmbedSoftDeleteOriginal = false;
  bool batchSubtitleEmbedSoftPrefixEnabled = false;
  String batchSubtitleEmbedSoftPrefix = '[AI字幕]';
  bool batchSubtitleEmbedSoftSuffixEnabled = false;
  String batchSubtitleEmbedSoftSuffix = '';
  bool batchSubtitleEmbedAutoDeleteSrt = false;

  // 全局音频竖屏播放页显示比例（null = 默认 1:1）
  // 音频比例是全局共享的，设置一次应用到所有音频
  double? audioPortraitDisplayAspectRatio;
  double? audioPortraitCustomAspectWidth;
  double? audioPortraitCustomAspectHeight;

  late final List<_RegisteredSetting<dynamic>> _registeredSettings =
      _createRegisteredSettings();
  late final Map<String, _RegisteredSetting<dynamic>> _registeredSettingByKey =
      {for (final setting in _registeredSettings) setting.key: setting};

  _RegisteredSetting<bool> _boolSetting({
    required String key,
    required bool defaultValue,
    bool Function()? resolveDefaultValue,
    required void Function(SettingsService service, bool value) apply,
    bool Function(bool value)? normalize,
  }) {
    return _RegisteredSetting<bool>(
      key: key,
      defaultValue: defaultValue,
      resolveDefaultValue: resolveDefaultValue,
      read: (prefs, settingKey, fallback) =>
          prefs.getBool(settingKey) ?? fallback,
      write: (prefs, settingKey, value) => prefs.setBool(settingKey, value),
      normalize: normalize ?? (value) => value,
      apply: apply,
    );
  }

  _RegisteredSetting<int> _intSetting({
    required String key,
    required int defaultValue,
    required void Function(SettingsService service, int value) apply,
    int Function(int value)? normalize,
  }) {
    return _RegisteredSetting<int>(
      key: key,
      defaultValue: defaultValue,
      read: (prefs, settingKey, fallback) =>
          prefs.getInt(settingKey) ?? fallback,
      write: (prefs, settingKey, value) => prefs.setInt(settingKey, value),
      normalize: normalize ?? (value) => value,
      apply: apply,
    );
  }

  _RegisteredSetting<double> _doubleSetting({
    required String key,
    required double defaultValue,
    required void Function(SettingsService service, double value) apply,
    double Function(double value)? normalize,
  }) {
    return _RegisteredSetting<double>(
      key: key,
      defaultValue: defaultValue,
      read: (prefs, settingKey, fallback) =>
          prefs.getDouble(settingKey) ?? fallback,
      write: (prefs, settingKey, value) => prefs.setDouble(settingKey, value),
      normalize: normalize ?? (value) => value,
      apply: apply,
    );
  }

  _RegisteredSetting<String> _stringSetting({
    required String key,
    required String defaultValue,
    required void Function(SettingsService service, String value) apply,
    String Function(String value)? normalize,
  }) {
    return _RegisteredSetting<String>(
      key: key,
      defaultValue: defaultValue,
      read: (prefs, settingKey, fallback) =>
          prefs.getString(settingKey) ?? fallback,
      write: (prefs, settingKey, value) => prefs.setString(settingKey, value),
      normalize: normalize ?? (value) => value,
      apply: apply,
    );
  }

  List<_RegisteredSetting<dynamic>> _createRegisteredSettings() {
    return <_RegisteredSetting<dynamic>>[
      _boolSetting(
        key: 'showSubtitles',
        defaultValue: true,
        apply: (service, value) => service.showSubtitles = value,
      ),
      _boolSetting(
        key: 'showBilibiliDanmaku',
        defaultValue: true,
        apply: (service, value) => service.showBilibiliDanmaku = value,
      ),
      _boolSetting(
        key: 'bilibiliDanmakuOnlyInVideoArea',
        defaultValue: false,
        apply: (service, value) =>
            service.bilibiliDanmakuOnlyInVideoArea = value,
      ),
      _doubleSetting(
        key: 'bilibiliDanmakuDisplayArea',
        defaultValue: 0.5,
        normalize: (value) => value
            .clamp(kDanmakuDisplayAreaMin, kDanmakuDisplayAreaMax)
            .toDouble(),
        apply: (service, value) => service.bilibiliDanmakuDisplayArea = value,
      ),
      _doubleSetting(
        key: 'bilibiliDanmakuOpacity',
        defaultValue: 0.8,
        normalize: (value) => value.clamp(0.1, 1.0).toDouble(),
        apply: (service, value) => service.bilibiliDanmakuOpacity = value,
      ),
      _doubleSetting(
        key: 'bilibiliDanmakuFontScale',
        defaultValue: 0.8,
        normalize: (value) =>
            value.clamp(kDanmakuFontScaleMin, kDanmakuFontScaleMax).toDouble(),
        apply: (service, value) => service.bilibiliDanmakuFontScale = value,
      ),
      _boolSetting(
        key: 'bilibiliDanmakuReadableFontDefaults',
        defaultValue: false,
        apply: (service, value) =>
            service.bilibiliDanmakuReadableFontDefaults = value,
      ),
      _doubleSetting(
        key: 'bilibiliDanmakuSpeed',
        defaultValue: 1.0,
        normalize: (value) =>
            value.clamp(kDanmakuSpeedMin, kDanmakuSpeedMax).toDouble(),
        apply: (service, value) => service.bilibiliDanmakuSpeed = value,
      ),
      _doubleSetting(
        key: 'bilibiliDanmakuDensity',
        defaultValue: 1.0,
        normalize: (value) => value.isFinite
            ? value.clamp(kDanmakuDensityMin, kDanmakuDensityMax).toDouble()
            : 1.0,
        apply: (service, value) => service.bilibiliDanmakuDensity = value,
      ),
      _doubleSetting(
        key: 'bilibiliDanmakuPortraitDisplayArea',
        defaultValue: kDanmakuPortraitDisplayArea,
        normalize: (value) => value.isFinite
            ? value
                  .clamp(kDanmakuDisplayAreaMin, kDanmakuDisplayAreaMax)
                  .toDouble()
            : kDanmakuPortraitDisplayArea,
        apply: (service, value) =>
            service.bilibiliDanmakuPortraitDisplayArea = value,
      ),
      _doubleSetting(
        key: 'bilibiliDanmakuPortraitFontScale',
        defaultValue: kDanmakuPortraitFontScale,
        normalize: (value) => value.isFinite
            ? value.clamp(kDanmakuFontScaleMin, kDanmakuFontScaleMax).toDouble()
            : kDanmakuPortraitFontScale,
        apply: (service, value) =>
            service.bilibiliDanmakuPortraitFontScale = value,
      ),
      _doubleSetting(
        key: 'bilibiliDanmakuPortraitSpeed',
        defaultValue: kDanmakuPortraitSpeed,
        normalize: (value) => value.isFinite
            ? value.clamp(kDanmakuSpeedMin, kDanmakuSpeedMax).toDouble()
            : kDanmakuPortraitSpeed,
        apply: (service, value) => service.bilibiliDanmakuPortraitSpeed = value,
      ),
      _doubleSetting(
        key: 'bilibiliDanmakuPortraitDensity',
        defaultValue: kDanmakuPortraitDensity,
        normalize: (value) => value.isFinite
            ? value.clamp(kDanmakuDensityMin, kDanmakuDensityMax).toDouble()
            : kDanmakuPortraitDensity,
        apply: (service, value) =>
            service.bilibiliDanmakuPortraitDensity = value,
      ),
      _boolSetting(
        key: 'bilibiliDanmakuUseLockedSpeedAsBaseline',
        defaultValue: false,
        apply: (service, value) =>
            service.bilibiliDanmakuUseLockedSpeedAsBaseline = value,
      ),
      _boolSetting(
        key: 'bilibiliDanmakuAutoUpdate',
        defaultValue: true,
        apply: (service, value) => service.bilibiliDanmakuAutoUpdate = value,
      ),
      _stringSetting(
        key: 'bilibiliDanmakuFontFamily',
        defaultValue: kDanmakuDefaultFontFamily,
        normalize: (value) {
          final family = normalizeBundledFontFamily(value);
          return (kDanmakuFontFamilies.contains(
                    family.isEmpty ? null : family,
                  ) ||
                  family.startsWith('subtitle_font_'))
              ? family
              : '';
        },
        apply: (service, value) =>
            service.bilibiliDanmakuFontFamily = value.isEmpty ? null : value,
      ),
      _doubleSetting(
        key: 'bilibiliDanmakuOutlineScale',
        defaultValue: 1.0,
        normalize: (value) =>
            value.isFinite ? value.clamp(0.0, 3.0).toDouble() : 1.0,
        apply: (service, value) => service.bilibiliDanmakuOutlineScale = value,
      ),
      _doubleSetting(
        key: 'bilibiliDanmakuShadowScale',
        defaultValue: 1.0,
        normalize: (value) =>
            value.isFinite ? value.clamp(0.0, 3.0).toDouble() : 1.0,
        apply: (service, value) => service.bilibiliDanmakuShadowScale = value,
      ),
      _doubleSetting(
        key: 'bilibiliDanmakuLetterSpacing',
        defaultValue: 0.0,
        normalize: (value) =>
            value.isFinite ? value.clamp(0.0, 0.3).toDouble() : 0.0,
        apply: (service, value) => service.bilibiliDanmakuLetterSpacing = value,
      ),
      _intSetting(
        key: 'bilibiliDanmakuFontWeight',
        defaultValue: kDanmakuDefaultFontWeight,
        normalize: (value) => ((value.clamp(100, 900) / 100).round() * 100),
        apply: (service, value) => service.bilibiliDanmakuFontWeight = value,
      ),
      _stringSetting(
        key: 'bilibiliDanmakuOutlineType',
        defaultValue: DanmakuOutlineType.standard.name,
        normalize: (value) => DanmakuOutlineTypeX.fromName(value).name,
        apply: (service, value) => service.bilibiliDanmakuOutlineType =
            DanmakuOutlineTypeX.fromName(value),
      ),
      _boolSetting(
        key: 'isMirroredH',
        defaultValue: false,
        apply: (service, value) => service.isMirroredH = value,
      ),
      _boolSetting(
        key: 'isMirroredV',
        defaultValue: false,
        apply: (service, value) => service.isMirroredV = value,
      ),
      _doubleSetting(
        key: 'playbackSpeed',
        defaultValue: 1.0,
        apply: (service, value) => service.playbackSpeed = value,
      ),
      _boolSetting(
        key: 'isPlaybackSpeedLocked',
        defaultValue: false,
        apply: (service, value) => service.isPlaybackSpeedLocked = value,
      ),
      _boolSetting(
        key: 'globalMute',
        defaultValue: false,
        apply: (service, value) => service.globalMute = value,
      ),
      _doubleSetting(
        key: 'longPressSpeed',
        defaultValue: 2.0,
        // mpv's pitch-preserving scaletempo2 path is defined for 0.25x-8x.
        // Keeping persisted/custom values inside that range guarantees that
        // playback never falls back to pitched resampling or muted audio.
        normalize: (value) => value.clamp(0.25, 8.0).toDouble(),
        apply: (service, value) => service.longPressSpeed = value,
      ),
      _boolSetting(
        key: 'showLongPressSpeedIndicator',
        defaultValue: true,
        apply: (service, value) => service.showLongPressSpeedIndicator = value,
      ),
      _intSetting(
        key: 'doubleTapSeekSeconds',
        defaultValue: 5,
        apply: (service, value) => service.doubleTapSeekSeconds = value,
      ),
      _boolSetting(
        key: 'enableDoubleTapSubtitleSeek',
        defaultValue: true,
        apply: (service, value) => service.enableDoubleTapSubtitleSeek = value,
      ),
      _doubleSetting(
        key: 'userSubtitleSidebarWidth',
        defaultValue: 262.4,
        apply: (service, value) => service.userSubtitleSidebarWidth = value,
      ),
      _doubleSetting(
        key: 'userAiSidebarWidth',
        defaultValue: 0,
        normalize: (value) => value.isFinite && value > 0 ? value : 0,
        apply: (service, value) => service.userAiSidebarWidth = value,
      ),
      _boolSetting(
        key: 'isLeftHandedMode',
        defaultValue: false,
        apply: (service, value) => service.isLeftHandedMode = value,
      ),
      _boolSetting(
        key: 'autoCacheSubtitles',
        defaultValue: true,
        apply: (service, value) => service.autoCacheSubtitles = value,
      ),
      _boolSetting(
        key: 'autoScrollSubtitles',
        defaultValue: true,
        apply: (service, value) => service.autoScrollSubtitles = value,
      ),
      _boolSetting(
        key: 'subtitleEditorAutoFollow',
        defaultValue: true,
        apply: (service, value) => service.subtitleEditorAutoFollow = value,
      ),
      _boolSetting(
        key: 'autoLoadEmbeddedSubtitles',
        defaultValue: false,
        apply: (service, value) => service.autoLoadEmbeddedSubtitles = value,
      ),
      _boolSetting(
        key: 'splitSubtitleByLine',
        defaultValue: true,
        apply: (service, value) => service.splitSubtitleByLine = value,
      ),
      _boolSetting(
        key: 'videoContinuousSubtitle',
        defaultValue: false,
        apply: (service, value) => service.videoContinuousSubtitle = value,
      ),
      _boolSetting(
        key: 'audioContinuousSubtitle',
        defaultValue: false,
        apply: (service, value) => service.audioContinuousSubtitle = value,
      ),
      _boolSetting(
        key: 'syncAudioSubtitleStyleWithVideo',
        defaultValue: true,
        apply: (service, value) =>
            service.syncAudioSubtitleStyleWithVideo = value,
      ),
      _boolSetting(
        key: 'autoPauseOnExit',
        defaultValue: true,
        apply: (service, value) => service.autoPauseOnExit = value,
      ),
      _boolSetting(
        key: 'skipPortraitPlayer',
        defaultValue: false,
        resolveDefaultValue: () => _defaultSkipPortraitPlayer,
        apply: (service, value) => service.skipPortraitPlayer = value,
      ),
      _boolSetting(
        key: 'avoidPlaybackControlsWithSubtitles',
        defaultValue: true,
        apply: (service, value) =>
            service.avoidPlaybackControlsWithSubtitles = value,
      ),
      _boolSetting(
        key: 'pausePlaybackWhenAppBackgrounded',
        defaultValue: true,
        apply: (service, value) =>
            service.pausePlaybackWhenAppBackgrounded = value,
      ),
      _boolSetting(
        key: 'allowConcurrentPlayback',
        defaultValue: false,
        apply: (service, value) => service.allowConcurrentPlayback = value,
      ),
      _boolSetting(
        key: 'useHardwareVideoDecoding',
        defaultValue: true,
        apply: (service, value) => service.useHardwareVideoDecoding = value,
      ),
      _boolSetting(
        key: 'enableHeadsetMediaControls',
        defaultValue: true,
        apply: (service, value) => service.enableHeadsetMediaControls = value,
      ),
      _boolSetting(
        key: 'autoPlayOnPageEntry',
        defaultValue: true,
        apply: (service, value) => service.autoPlayOnPageEntry = value,
      ),
      _boolSetting(
        key: 'autoPlayNextVideo',
        defaultValue: true,
        apply: (service, value) => service.autoPlayNextVideo = value,
      ),
      _boolSetting(
        key: 'enableVideoPreload',
        defaultValue: true,
        apply: (service, value) => service.enableVideoPreload = value,
      ),
      _boolSetting(
        key: 'autoPlayOnCompletion',
        defaultValue: false,
        apply: (service, value) => service.autoPlayOnCompletion = value,
      ),
      _boolSetting(
        key: 'autoPlayOnCompletionFromStart',
        defaultValue: false,
        apply: (service, value) =>
            service.autoPlayOnCompletionFromStart = value,
      ),
      _boolSetting(
        key: 'playlistWrapToFirst',
        defaultValue: false,
        apply: (service, value) => service.playlistWrapToFirst = value,
      ),
      _boolSetting(
        key: 'isActionButtonsCollapsed',
        defaultValue: false,
        apply: (service, value) => service.isActionButtonsCollapsed = value,
      ),
      _boolSetting(
        key: 'showActionButtonLabels',
        defaultValue: true,
        apply: (service, value) => service.showActionButtonLabels = value,
      ),
      _boolSetting(
        key: 'localImportFilterMediaExtensions',
        defaultValue: true,
        apply: (service, value) =>
            service.localImportFilterMediaExtensions = value,
      ),
      _boolSetting(
        key: 'enableSeekPreview',
        defaultValue: true,
        apply: (service, value) => service.enableSeekPreview = value,
      ),
      _boolSetting(
        key: 'experimentalAmbientLetterbox',
        defaultValue: false,
        apply: (service, value) => service.experimentalAmbientLetterbox = value,
      ),
      _boolSetting(
        key: 'enableHapticFeedback',
        defaultValue: true,
        apply: (service, value) => service.enableHapticFeedback = value,
      ),
      _boolSetting(
        key: 'suppressBilibiliRestrictedDialog',
        defaultValue: false,
        apply: (service, value) =>
            service.suppressBilibiliRestrictedDialog = value,
      ),
      _intSetting(
        key: 'videoComposeResolutionHeight',
        defaultValue: 1080,
        apply: (service, value) => service.videoComposeResolutionHeight = value,
      ),
      _stringSetting(
        key: 'videoComposeRenderMode',
        defaultValue: VideoComposeRenderMode.precise.storageValue,
        normalize: (value) => VideoComposeRenderMode.fromStorage(
          value,
          fallback: VideoComposeRenderMode.precise,
        ).storageValue,
        apply: (service, value) => service.videoComposeRenderMode = value,
      ),
      _boolSetting(
        key: 'videoComposeContinuousSubtitle',
        defaultValue: false,
        apply: (service, value) =>
            service.videoComposeContinuousSubtitle = value,
      ),
      _boolSetting(
        key: 'videoComposeRenderSecondary',
        defaultValue: true,
        apply: (service, value) => service.videoComposeRenderSecondary = value,
      ),
      _boolSetting(
        key: 'videoComposeEmbedSoftSubtitles',
        defaultValue: false,
        apply: (service, value) =>
            service.videoComposeEmbedSoftSubtitles = value,
      ),
      _boolSetting(
        key: 'videoComposeSoftSubtitleOnly',
        defaultValue: false,
        apply: (service, value) => service.videoComposeSoftSubtitleOnly = value,
      ),
      _boolSetting(
        key: 'videoComposeSoftSubtitleUseSourceQuality',
        defaultValue: true,
        apply: (service, value) =>
            service.videoComposeSoftSubtitleUseSourceQuality = value,
      ),
      _boolSetting(
        key: 'videoComposeDeleteOutputOnTaskDelete',
        defaultValue: true,
        apply: (service, value) =>
            service.videoComposeDeleteOutputOnTaskDelete = value,
      ),
      _intSetting(
        key: 'homeGridCrossAxisCount',
        defaultValue: 4,
        normalize: (value) => MediaLibraryLayoutDefaults.clampColumns(value),
        apply: (service, value) => service.homeGridCrossAxisCount = value,
      ),
      _intSetting(
        key: 'videoCardCrossAxisCount',
        defaultValue: 4,
        normalize: (value) => MediaLibraryLayoutDefaults.clampColumns(value),
        apply: (service, value) => service.videoCardCrossAxisCount = value,
      ),
      _doubleSetting(
        key: 'homeCardTitleFontSize',
        defaultValue: 13.0,
        apply: (service, value) => service.homeCardTitleFontSize = value,
      ),
      _doubleSetting(
        key: 'homeCardAspectRatio',
        defaultValue: 0.625,
        apply: (service, value) => service.homeCardAspectRatio = value,
      ),
      _doubleSetting(
        key: 'videoCardTitleFontSize',
        defaultValue: 11.0,
        apply: (service, value) => service.videoCardTitleFontSize = value,
      ),
      _doubleSetting(
        key: 'videoCardAspectRatio',
        defaultValue: 0.625,
        apply: (service, value) => service.videoCardAspectRatio = value,
      ),
      _intSetting(
        key: 'mediaLibraryViewMode',
        defaultValue: 0,
        normalize: (value) =>
            value.clamp(0, MediaLibraryViewMode.values.length - 1),
        apply: (service, value) => service.mediaLibraryViewMode = value,
      ),
      _stringSetting(
        key: 'mediaTableSortKey',
        defaultValue: MediaTableSortKey.manual.name,
        normalize: (value) => MediaTableSortKey.fromStorage(value).name,
        apply: (service, value) => service.mediaTableSortKey = value,
      ),
      _boolSetting(
        key: 'mediaTableSortDescending',
        defaultValue: false,
        apply: (service, value) => service.mediaTableSortDescending = value,
      ),
      _intSetting(
        key: 'mediaTreeContentMode',
        defaultValue: MediaLibraryContentLayout.rows.index,
        normalize: (value) =>
            value.clamp(0, MediaLibraryContentLayout.values.length - 1),
        apply: (service, value) => service.mediaTreeContentMode = value,
      ),
      _doubleSetting(
        key: 'mediaTreeSidebarWidth',
        defaultValue: MediaLibraryViewDefaults.treeSidebarWidth,
        normalize: (value) => value.clamp(
          MediaLibraryViewDefaults.minTreeSidebarWidth,
          MediaLibraryViewDefaults.maxTreeSidebarWidth,
        ),
        apply: (service, value) => service.mediaTreeSidebarWidth = value,
      ),
      _boolSetting(
        key: 'mediaTreeShowCounts',
        defaultValue: true,
        apply: (service, value) => service.mediaTreeShowCounts = value,
      ),
      _boolSetting(
        key: 'mediaTreeSidebarCollapsed',
        defaultValue: false,
        apply: (service, value) => service.mediaTreeSidebarCollapsed = value,
      ),
      _stringSetting(
        key: 'mediaLibraryRootEntry',
        defaultValue: '',
        apply: (service, value) => service.mediaLibraryRootEntry = value,
      ),
      _boolSetting(
        key: 'mediaLibraryRootEntryUserChosen',
        defaultValue: false,
        apply: (service, value) =>
            service.mediaLibraryRootEntryUserChosen = value,
      ),
      _stringSetting(
        key: 'mediaLibraryRootEntryOrder',
        defaultValue: '',
        apply: (service, value) => service.mediaLibraryRootEntryOrder = value,
      ),
      _boolSetting(
        key: 'mediaLibraryRestoreLastPage',
        defaultValue: true,
        apply: (service, value) => service.mediaLibraryRestoreLastPage = value,
      ),
      _boolSetting(
        key: 'mediaLibraryReadableCardDefaults',
        defaultValue: false,
        apply: (service, value) =>
            service.mediaLibraryReadableCardDefaults = value,
      ),
      _stringSetting(
        key: 'mediaLibraryStartupEntry',
        defaultValue: MediaLibraryRootEntry.folders.storageValue,
        normalize: (value) =>
            MediaLibraryRootEntryX.tryParse(value)?.storageValue ??
            MediaLibraryRootEntry.folders.storageValue,
        apply: (service, value) => service.mediaLibraryStartupEntry = value,
      ),
      _stringSetting(
        key: 'mediaLibraryLastFolderId',
        defaultValue: '',
        apply: (service, value) => service.mediaLibraryLastFolderId = value,
      ),
      _boolSetting(
        key: 'mediaLibraryLastFolderIncludeDescendants',
        defaultValue: false,
        apply: (service, value) =>
            service.mediaLibraryLastFolderIncludeDescendants = value,
      ),
      _boolSetting(
        key: 'mediaLibraryContinueSeriousOnly',
        defaultValue: false,
        apply: (service, value) =>
            service.mediaLibraryContinueSeriousOnly = value,
      ),
      _stringSetting(
        key: 'mediaLibraryContinuePolicy',
        defaultValue: ContinueWatchPolicy.defaults.toJsonString(),
        normalize: (value) =>
            ContinueWatchPolicy.fromJsonString(value).toJsonString(),
        apply: (service, value) => service.continueWatchPolicy =
            ContinueWatchPolicy.fromJsonString(value),
      ),
      _stringSetting(
        key: 'mediaLibraryEntryAnchors',
        defaultValue: '',
        apply: (service, value) => service.mediaLibraryEntryAnchors = value,
      ),
      _stringSetting(
        key: 'folderPlaceholderSettings',
        defaultValue: FolderPlaceholderSettings.defaults.toJsonString(),
        normalize: (value) =>
            FolderPlaceholderSettings.fromJsonString(value).toJsonString(),
        apply: (service, value) => service.folderPlaceholderSettings =
            FolderPlaceholderSettings.fromJsonString(value),
      ),
      _intSetting(
        key: 'mediaListCrossAxisCount',
        defaultValue: 1,
        normalize: (value) => MediaLibraryLayoutDefaults.clampColumns(value),
        apply: (service, value) => service.mediaListCrossAxisCount = value,
      ),
      _boolSetting(
        key: 'mediaListShowThumbnail',
        defaultValue: true,
        apply: (service, value) => service.mediaListShowThumbnail = value,
      ),
      _boolSetting(
        key: 'mediaListShowIndex',
        defaultValue: false,
        apply: (service, value) => service.mediaListShowIndex = value,
      ),
      _doubleSetting(
        key: 'mediaListItemHeightScale',
        defaultValue: 0.10,
        normalize: (value) => value.clamp(0.001, 0.15),
        apply: (service, value) => service.mediaListItemHeightScale = value,
      ),
      _doubleSetting(
        key: 'mediaListMainSpacingScale',
        defaultValue: 0.012,
        normalize: (value) =>
            MediaLibraryLayoutDefaults.clampSpacing(value.clamp(0.0, 0.45)),
        apply: (service, value) => service.mediaListMainSpacingScale = value,
      ),
      _doubleSetting(
        key: 'mediaListCrossSpacingScale',
        defaultValue: 0.02,
        normalize: (value) =>
            MediaLibraryLayoutDefaults.clampSpacing(value.clamp(0.0, 0.45)),
        apply: (service, value) => service.mediaListCrossSpacingScale = value,
      ),
      _doubleSetting(
        key: 'mediaListTitleScale',
        defaultValue: 0.042,
        normalize: (value) => value.clamp(0.001, 0.065),
        apply: (service, value) => service.mediaListTitleScale = value,
      ),
      _doubleSetting(
        key: 'mediaListCoverOffset',
        defaultValue: 0.0,
        normalize: (value) => value.clamp(-1.0, 1.0),
        apply: (service, value) => service.mediaListCoverOffset = value,
      ),
      _boolSetting(
        key: 'copyImportedMediaToPrivateStorage',
        defaultValue: false,
        apply: (service, value) =>
            service.copyImportedMediaToPrivateStorage = value,
      ),
      _stringSetting(
        key: 'importCardPlacement',
        defaultValue: ImportCardPlacement.libraryRoot.storageValue,
        normalize: (value) =>
            ImportCardPlacementX.fromStorage(value).storageValue,
        apply: (service, value) => service.importCardPlacement = value,
      ),
      _stringSetting(
        key: ImportPlacementRules.settingsKey,
        defaultValue: '{}',
        normalize: ImportPlacementRules.normalize,
        apply: (service, value) => service.importPlacementRulesJson = value,
      ),
      _stringSetting(
        key: ImportSourceFolders.namesKey,
        defaultValue: '{}',
        normalize: ImportSourceFolders.normalizeNamesJson,
        apply: (service, value) => service.importSourceFolderNamesJson = value,
      ),
      _stringSetting(
        key: ImportSourceFolders.idsKey,
        defaultValue: '{}',
        normalize: ImportSourceFolders.normalizeIdsJson,
        apply: (service, value) => service.importSourceFolderIdsJson = value,
      ),
      _boolSetting(
        key: 'useSearchResultsAsPlaybackQueue',
        defaultValue: false,
        apply: (service, value) =>
            service.useSearchResultsAsPlaybackQueue = value,
      ),
      _boolSetting(
        key: 'bilibiliBackgroundAudioOnly',
        defaultValue: false,
        apply: (service, value) => service.bilibiliBackgroundAudioOnly = value,
      ),
      _boolSetting(
        key: 'clipboardLinkDetectionEnabled',
        defaultValue: true,
        apply: (service, value) =>
            service.clipboardLinkDetectionEnabled = value,
      ),
      _boolSetting(
        key: 'skipRepeatedClipboardText',
        defaultValue: true,
        apply: (service, value) => service.skipRepeatedClipboardText = value,
      ),
      _boolSetting(
        key: 'showMiniPlaybackCard',
        defaultValue: true,
        apply: (service, value) => service.showMiniPlaybackCard = value,
      ),
      _boolSetting(
        key: 'showSystemMediaNotification',
        defaultValue: true,
        apply: (service, value) => service.showSystemMediaNotification = value,
      ),
      _boolSetting(
        key: 'bilibiliRecordSearchHistory',
        defaultValue: true,
        apply: (service, value) => service.bilibiliRecordSearchHistory = value,
      ),
      _boolSetting(
        key: 'desktopSystemMediaControls',
        defaultValue: true,
        apply: (service, value) => service.desktopSystemMediaControls = value,
      ),
      _boolSetting(
        key: 'desktopTaskbarMediaControls',
        defaultValue: true,
        apply: (service, value) => service.desktopTaskbarMediaControls = value,
      ),
      _boolSetting(
        key: 'desktopGlobalMediaHotkeys',
        defaultValue: false,
        apply: (service, value) => service.desktopGlobalMediaHotkeys = value,
      ),
      _stringSetting(
        key: 'desktopMediaHotkeyModifiers',
        defaultValue: 'ctrl+alt',
        normalize: (value) => value == 'ctrl+alt+shift' ? value : 'ctrl+alt',
        apply: (service, value) => service.desktopMediaHotkeyModifiers = value,
      ),
      _boolSetting(
        key: 'bilibiliRecordWatchHistory',
        defaultValue: true,
        apply: (service, value) => service.bilibiliRecordWatchHistory = value,
      ),
      _boolSetting(
        key: 'bilibiliAutoImportOnPlay',
        defaultValue: false,
        apply: (service, value) => service.bilibiliAutoImportOnPlay = value,
      ),
      _stringSetting(
        key: 'bilibiliImportTarget',
        defaultValue: '',
        apply: (service, value) => service.bilibiliImportTarget = value,
      ),
      _intSetting(
        key: 'bilibiliCacheLimitBytes',
        defaultValue: bilibiliCacheLimitDefault,
        normalize: normalizeBilibiliCacheLimit,
        apply: (service, value) => service.bilibiliCacheLimitBytes = value,
      ),
      _stringSetting(
        key: 'structuredImportSortField',
        defaultValue: 'fileName',
        normalize: (value) =>
            value == 'modifiedTime' ? 'modifiedTime' : 'fileName',
        apply: (service, value) => service.structuredImportSortField = value,
      ),
      _stringSetting(
        key: 'structuredImportSortDirection',
        defaultValue: 'ascending',
        normalize: (value) =>
            value == 'descending' ? 'descending' : 'ascending',
        apply: (service, value) =>
            service.structuredImportSortDirection = value,
      ),
      _doubleSetting(
        key: 'portraitSidebarFontSizeScale',
        defaultValue: 1.0,
        apply: (service, value) => service.portraitSidebarFontSizeScale = value,
      ),
      _boolSetting(
        key: 'landscapeSidebarShowTimestamps',
        defaultValue: true,
        apply: (service, value) =>
            service.landscapeSidebarShowTimestamps = value,
      ),
      _boolSetting(
        key: 'portraitSidebarShowTimestamps',
        defaultValue: true,
        apply: (service, value) =>
            service.portraitSidebarShowTimestamps = value,
      ),
      _doubleSetting(
        key: 'landscapeSidebarTimeColumnRatio',
        defaultValue: 0.18,
        normalize: (value) => value.clamp(0.05, 0.30).toDouble(),
        apply: (service, value) =>
            service.landscapeSidebarTimeColumnRatio = value,
      ),
      _doubleSetting(
        key: 'portraitSidebarTimeColumnRatio',
        defaultValue: 0.12,
        normalize: (value) => value.clamp(0.05, 0.30).toDouble(),
        apply: (service, value) =>
            service.portraitSidebarTimeColumnRatio = value,
      ),
      _intSetting(
        key: 'landscapeSidebarLocatePositionPercent',
        defaultValue: 30,
        normalize: (value) => value.clamp(0, 100),
        apply: (service, value) =>
            service.landscapeSidebarLocatePositionPercent = value,
      ),
      _intSetting(
        key: 'portraitSidebarLocatePositionPercent',
        defaultValue: 30,
        normalize: (value) => value.clamp(0, 100),
        apply: (service, value) =>
            service.portraitSidebarLocatePositionPercent = value,
      ),
      _intSetting(
        key: 'subtitleArticleSentencesPerParagraph',
        defaultValue: 4,
        normalize: (value) => value.clamp(1, 99),
        apply: (service, value) =>
            service.subtitleArticleSentencesPerParagraph = value,
      ),
      _boolSetting(
        key: 'subtitleArticleParagraphModeEnabled',
        defaultValue: true,
        apply: (service, value) =>
            service.subtitleArticleParagraphModeEnabled = value,
      ),
      _intSetting(
        key: 'subtitleViewMode',
        defaultValue: 0,
        apply: (service, value) => service.subtitleViewMode = value,
      ),
      _stringSetting(
        key: 'subtitleCopyFormat',
        defaultValue: SubtitleCopyFormat.defaults.toJsonString(),
        normalize: (value) =>
            SubtitleCopyFormat.fromJsonString(value).toJsonString(),
        apply: (service, value) => service.subtitleCopyFormat =
            SubtitleCopyFormat.fromJsonString(value),
      ),
      _stringSetting(
        key: 'lastSelectedModelType',
        defaultValue: 'base',
        apply: (service, value) => service.lastSelectedModelType = value,
      ),
      _boolSetting(
        key: 'landscapeSubtitleSidebarVisible',
        defaultValue: true,
        apply: (service, value) =>
            service.isLandscapeSubtitleSidebarVisible = value,
      ),
      _boolSetting(
        key: 'showSubtitleSidebarToggle',
        defaultValue: true,
        apply: (service, value) => service.showSubtitleSidebarToggle = value,
      ),
      _boolSetting(
        key: 'bilibiliPlayerPanelOpen',
        defaultValue: true,
        apply: (service, value) => service.bilibiliPlayerPanelOpen = value,
      ),
      _boolSetting(
        key: 'bilibiliPortraitShowsSubtitles',
        defaultValue: false,
        apply: (service, value) =>
            service.bilibiliPortraitShowsSubtitles = value,
      ),
      _boolSetting(
        key: 'bilibiliLandscapeShowsSubtitles',
        defaultValue: false,
        apply: (service, value) =>
            service.bilibiliLandscapeShowsSubtitles = value,
      ),
      _boolSetting(
        key: 'isGhostModeEnabled',
        defaultValue: true,
        apply: (service, value) => service.isGhostModeEnabled = value,
      ),
      _stringSetting(
        key: 'portraitCustomAspectDraftWidthText',
        defaultValue: '',
        apply: (service, value) =>
            service.portraitCustomAspectDraftWidthText = value,
      ),
      _stringSetting(
        key: 'portraitCustomAspectDraftHeightText',
        defaultValue: '',
        apply: (service, value) =>
            service.portraitCustomAspectDraftHeightText = value,
      ),
      // 音乐播放器歌词字体缩放比例 - 竖屏
      _doubleSetting(
        key: 'musicLyricFontSizeScalePortrait',
        defaultValue: MusicLyricTypography.defaultFontSizeScale,
        normalize: MusicLyricTypography.normalizeFontSizeScale,
        apply: (service, value) =>
            service.musicLyricFontSizeScalePortrait = value,
      ),
      // 音乐播放器歌词字体缩放比例 - 横屏
      _doubleSetting(
        key: 'musicLyricFontSizeScaleLandscape',
        defaultValue: MusicLyricTypography.defaultFontSizeScale,
        normalize: MusicLyricTypography.normalizeFontSizeScale,
        apply: (service, value) =>
            service.musicLyricFontSizeScaleLandscape = value,
      ),
      _doubleSetting(
        key: 'musicLyricSpacingScalePortrait',
        defaultValue: MusicLyricTypography.defaultSpacingScale,
        normalize: MusicLyricTypography.normalizeSpacingScale,
        apply: (service, value) =>
            service.musicLyricSpacingScalePortrait = value,
      ),
      _doubleSetting(
        key: 'musicLyricSpacingScaleLandscape',
        defaultValue: MusicLyricTypography.defaultSpacingScale,
        normalize: MusicLyricTypography.normalizeSpacingScale,
        apply: (service, value) =>
            service.musicLyricSpacingScaleLandscape = value,
      ),
      _doubleSetting(
        key: 'musicLyricAnchorPortrait',
        defaultValue: MusicLyricAnchor.automatic,
        normalize: MusicLyricAnchor.normalize,
        apply: (service, value) => service.musicLyricAnchorPortrait = value,
      ),
      _doubleSetting(
        key: 'musicLyricAnchorLandscape',
        defaultValue: MusicLyricAnchor.automatic,
        normalize: MusicLyricAnchor.normalize,
        apply: (service, value) => service.musicLyricAnchorLandscape = value,
      ),
      // 缺省打开，和现在的逐词显示一致；用户关掉后下次进入仍然关掉。
      _boolSetting(
        key: 'musicLyricWordByWordEnabled',
        defaultValue: true,
        apply: (service, value) => service.musicLyricWordByWordEnabled = value,
      ),
      // 缺省打开，保留现在的歌词景深模糊；用户关掉后下次进入仍然关掉。
      _boolSetting(
        key: 'musicLyricBlurEnabled',
        defaultValue: true,
        apply: (service, value) => service.musicLyricBlurEnabled = value,
      ),
      _boolSetting(
        key: 'musicPortraitControlsAutoHide',
        defaultValue: false,
        apply: (service, value) =>
            service.musicPortraitControlsAutoHide = value,
      ),
      _stringSetting(
        key: 'musicLyricTrackDisplayMode',
        defaultValue: 'both',
        normalize: normalizeMusicLyricTrackDisplayMode,
        apply: (service, value) => service.musicLyricTrackDisplayMode = value,
      ),
      _boolSetting(
        key: 'batchSubtitleAutoDelete',
        defaultValue: false,
        apply: (service, value) => service.batchSubtitleAutoDelete = value,
      ),
      _boolSetting(
        key: 'processingScreenProtection',
        defaultValue: true,
        apply: (service, value) => service.processingScreenProtection = value,
      ),
      _intSetting(
        key: 'processingScreenProtectionWaitSeconds',
        defaultValue: ProcessingScreenProtectionTiming.defaultSeconds,
        normalize: ProcessingScreenProtectionTiming.normalize,
        apply: (service, value) =>
            service.processingScreenProtectionWaitSeconds = value,
      ),
      _boolSetting(
        key: 'batchSubtitleKeepScreenAwake',
        defaultValue: false,
        apply: (service, value) => service.batchSubtitleKeepScreenAwake = value,
      ),
      _boolSetting(
        key: 'batchSubtitleTranslateEnabled',
        defaultValue: false,
        apply: (service, value) =>
            service.batchSubtitleTranslateEnabled = value,
      ),
      _stringSetting(
        key: 'batchSubtitleOutputPathStrategy',
        defaultValue: 'sameAsVideo',
        apply: (service, value) =>
            service.batchSubtitleOutputPathStrategy = value == 'customDirectory'
            ? SubtitleOutputPathStrategy.customDirectory
            : SubtitleOutputPathStrategy.sameAsVideo,
      ),
      _stringSetting(
        key: 'batchSubtitleCustomOutputDir',
        defaultValue: '',
        apply: (service, value) =>
            service.batchSubtitleCustomOutputDir = value.isEmpty ? null : value,
      ),
      // 外部视频内嵌软字幕设置
      _boolSetting(
        key: 'batchSubtitleEmbedSoftCopyAndEmbed',
        defaultValue: false,
        apply: (service, value) =>
            service.batchSubtitleEmbedSoftCopyAndEmbed = value,
      ),
      _boolSetting(
        key: 'batchSubtitleEmbedSoftDeleteOriginal',
        defaultValue: false,
        apply: (service, value) =>
            service.batchSubtitleEmbedSoftDeleteOriginal = value,
      ),
      _boolSetting(
        key: 'batchSubtitleEmbedSoftPrefixEnabled',
        defaultValue: false,
        apply: (service, value) =>
            service.batchSubtitleEmbedSoftPrefixEnabled = value,
      ),
      _stringSetting(
        key: 'batchSubtitleEmbedSoftPrefix',
        defaultValue: '[AI字幕]',
        apply: (service, value) => service.batchSubtitleEmbedSoftPrefix = value,
      ),
      _boolSetting(
        key: 'batchSubtitleEmbedSoftSuffixEnabled',
        defaultValue: false,
        apply: (service, value) =>
            service.batchSubtitleEmbedSoftSuffixEnabled = value,
      ),
      _stringSetting(
        key: 'batchSubtitleEmbedSoftSuffix',
        defaultValue: '',
        apply: (service, value) => service.batchSubtitleEmbedSoftSuffix = value,
      ),
      _boolSetting(
        key: 'batchSubtitleEmbedAutoDeleteSrt',
        defaultValue: false,
        apply: (service, value) =>
            service.batchSubtitleEmbedAutoDeleteSrt = value,
      ),
      _boolSetting(
        key: 'developerMode',
        defaultValue: false,
        apply: (service, value) => service.developerMode = value,
      ),
    ];
  }

  Future<void> _loadRegisteredSettings() async {
    for (final setting in _registeredSettings) {
      await setting.loadInto(this, _prefs);
    }
    if (!_prefs.containsKey('skipPortraitPlayer')) {
      _skipPortraitPlayer = null;
    }
    // A previously collapsed separate Bilibili panel preferred subtitles.
    // Keep that choice until the user explicitly selects a shared-sidebar tab.
    if (!_prefs.containsKey('bilibiliLandscapeShowsSubtitles')) {
      bilibiliLandscapeShowsSubtitles = !bilibiliPlayerPanelOpen;
    }
  }

  Future<bool> _updateRegisteredSetting<T>(
    String key,
    T value, {
    bool notify = true,
  }) async {
    final setting = _registeredSettingByKey[key];
    if (setting == null) {
      return false;
    }
    if (value is bool && _coalescedBoolSettingKeys.contains(key)) {
      // Memory first, then one disk write of whatever the latest toggle is.
      // A burst of taps must not let an older setBool finish last.
      setting.applyIncoming(this, value);
      if (notify) {
        notifyListeners();
      }
      await _trackSettingsWrite(
        _persistLatestBool(key, () => _readCoalescedBool(key)),
      );
      return true;
    }
    final persistence = _trackSettingsWrite(
      setting.updateValue(this, _prefs, value as Object),
    );
    if (notify) {
      notifyListeners();
    }
    await persistence;
    return true;
  }

  /// These switches are tapped repeatedly. Each update applies in memory
  /// immediately; persistence keeps only the newest value.
  static const Set<String> _coalescedBoolSettingKeys = <String>{
    'clipboardLinkDetectionEnabled',
    'skipRepeatedClipboardText',
    'showMiniPlaybackCard',
    'showSystemMediaNotification',
    'bilibiliLandscapeShowsSubtitles',
    'landscapeSubtitleSidebarVisible',
  };

  final Map<String, int> _coalescedBoolEpoch = <String, int>{};
  final Map<String, Future<void>> _coalescedBoolTail = <String, Future<void>>{};

  bool _readCoalescedBool(String key) {
    switch (key) {
      case 'clipboardLinkDetectionEnabled':
        return clipboardLinkDetectionEnabled;
      case 'skipRepeatedClipboardText':
        return skipRepeatedClipboardText;
      case 'showMiniPlaybackCard':
        return showMiniPlaybackCard;
      case 'showSystemMediaNotification':
        return showSystemMediaNotification;
      case 'bilibiliLandscapeShowsSubtitles':
        return bilibiliLandscapeShowsSubtitles;
      case 'landscapeSubtitleSidebarVisible':
        return isLandscapeSubtitleSidebarVisible;
      default:
        return false;
    }
  }

  Future<void> _persistLatestBool(String key, bool Function() readLatest) {
    final epoch = (_coalescedBoolEpoch[key] ?? 0) + 1;
    _coalescedBoolEpoch[key] = epoch;
    final previous = _coalescedBoolTail[key] ?? Future<void>.value();
    final next = previous.catchError((Object _) {}).then((_) async {
      if (_coalescedBoolEpoch[key] != epoch) return;
      if (!await _prefs.setBool(key, readLatest())) {
        throw StateError('设置写入失败: $key');
      }
    });
    _coalescedBoolTail[key] = next;
    void finished() {
      if (identical(_coalescedBoolTail[key], next)) {
        _coalescedBoolTail.remove(key);
      }
    }

    // Retain only an in-flight tail. Keeping a completed Future also retains
    // its originating execution zone and can strand subsequent callers.
    unawaited(
      next.then<void>(
        (_) => finished(),
        onError: (Object _, StackTrace _) => finished(),
      ),
    );
    return next;
  }

  Future<void> _updateRegisteredSettingsAtomically(
    Map<String, Object> values, {
    bool notify = true,
  }) async {
    final persistence = <Future<void>>[];
    for (final entry in values.entries) {
      final setting = _registeredSettingByKey[entry.key];
      if (setting == null) {
        throw ArgumentError.value(entry.key, 'key', 'Unsupported setting key');
      }
      // updateValue applies synchronously and persists asynchronously, so all
      // related in-memory values become visible before the single notification.
      persistence.add(
        _trackSettingsWrite(setting.updateValue(this, _prefs, entry.value)),
      );
    }
    if (notify) {
      notifyListeners();
    }
    await Future.wait(persistence);
  }

  /// One notification for both root-entry keys so the library shell does not
  /// rebuild twice (and decode two thumbnail grids) on a single chip tap.
  /// Chip taps pass [notify] false so HomeScreen is not rebuilt on the same
  /// frame as the destination grid.
  Future<void> saveMediaLibraryRootChoice(String entry, {bool notify = true}) {
    return _updateRegisteredSettingsAtomically({
      'mediaLibraryRootEntry': entry,
      'mediaLibraryRootEntryUserChosen': true,
    }, notify: notify);
  }

  /// Chip order is chrome, not library content. Skip notify so parked
  /// grids are not rebuilt when the user rearranges titles.
  Future<void> saveMediaLibraryRootEntryOrder(String encoded) {
    return _updateRegisteredSetting<String>(
      'mediaLibraryRootEntryOrder',
      encoded,
      notify: false,
    );
  }

  /// Scroll anchors are restore hints, not UI. Skip notify so a tab switch is
  /// not followed by a second full-tree rebuild.
  Future<void> saveMediaLibraryEntryAnchors(String encoded) {
    return _updateRegisteredSetting<String>(
      'mediaLibraryEntryAnchors',
      encoded,
      notify: false,
    );
  }

  /// Remember the visit immediately, without rebuilding every mounted level.
  /// CollectionScreen refreshes locally if the last-folder identity changes
  /// its persisted descendant-view preference.
  Future<void> saveMediaLibraryLastFolder(String folderId) {
    return _updateRegisteredSetting<String>(
      'mediaLibraryLastFolderId',
      folderId,
      notify: false,
    );
  }

  Future<void> toggleFullScreen() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      isFullScreen = !isFullScreen;
      await windowManager.setFullScreen(isFullScreen);
      if (isFullScreen) {
        await windowManager.focus();
      }
      notifyListeners();
    }
  }

  // Helpers for subtitle delay (seconds <-> duration)
  double get subtitleDelay => subtitleOffset.inMilliseconds / 1000.0;

  void setSubtitleDelay(double seconds) {
    subtitleOffset = Duration(milliseconds: (seconds * 1000).round());
    notifyListeners();
  }

  Future<void> saveSubtitleDelay(double seconds) async {
    setSubtitleDelay(seconds);
    return _trackSettingsWrite(() async {
      await _prefs.setInt('subtitleOffset', subtitleOffset.inMilliseconds);
    }());
  }

  /// 更新音乐播放器歌词字体大小缩放比例 - 竖屏
  Future<void> updateMusicLyricFontSizeScalePortrait(double value) async {
    await _updateRegisteredSetting('musicLyricFontSizeScalePortrait', value);
  }

  /// 更新音乐播放器歌词字体大小缩放比例 - 横屏
  Future<void> updateMusicLyricFontSizeScaleLandscape(double value) async {
    await _updateRegisteredSetting('musicLyricFontSizeScaleLandscape', value);
  }

  Future<void> updateMusicLyricSpacingScalePortrait(double value) async {
    await _updateRegisteredSetting('musicLyricSpacingScalePortrait', value);
  }

  Future<void> updateMusicLyricSpacingScaleLandscape(double value) async {
    await _updateRegisteredSetting('musicLyricSpacingScaleLandscape', value);
  }

  Future<void> updateMusicLyricAnchorPortrait(double value) async {
    await _updateRegisteredSetting('musicLyricAnchorPortrait', value);
  }

  Future<void> updateMusicLyricAnchorLandscape(double value) async {
    await _updateRegisteredSetting('musicLyricAnchorLandscape', value);
  }

  /// 词级歌词的逐词点亮。内存先改，界面当帧就能跟上，磁盘随后写完。
  Future<void> updateMusicLyricWordByWordEnabled(bool value) async {
    await _updateRegisteredSetting('musicLyricWordByWordEnabled', value);
  }

  /// 歌词景深模糊。内存先改，界面当帧就能跟上，磁盘随后写完。
  Future<void> updateMusicLyricBlurEnabled(bool value) async {
    await _updateRegisteredSetting('musicLyricBlurEnabled', value);
  }

  Future<void> updateMusicPortraitControlsAutoHide(bool value) async {
    await _updateRegisteredSetting('musicPortraitControlsAutoHide', value);
  }

  /// Persists the music player's lyric role. This is independent of the
  /// video subtitle line filter.
  Future<void> updateMusicLyricTrackDisplayMode(String value) async {
    await _updateRegisteredSetting('musicLyricTrackDisplayMode', value);
  }

  Future<void> updateBatchSubtitleAutoDelete(bool value) async {
    await _updateRegisteredSetting('batchSubtitleAutoDelete', value);
  }

  Future<void> updateBatchSubtitleKeepScreenAwake(bool value) async {
    await _updateRegisteredSetting('batchSubtitleKeepScreenAwake', value);
  }

  Future<void> updateBatchSubtitleTranslateEnabled(bool value) async {
    await _updateRegisteredSetting('batchSubtitleTranslateEnabled', value);
  }

  Future<void> updateBatchSubtitleOutputPathStrategy(
    SubtitleOutputPathStrategy strategy,
  ) async {
    await _updateRegisteredSetting(
      'batchSubtitleOutputPathStrategy',
      strategy == SubtitleOutputPathStrategy.customDirectory
          ? 'customDirectory'
          : 'sameAsVideo',
    );
  }

  Future<void> updateBatchSubtitleCustomOutputDir(String? dir) async {
    await _updateRegisteredSetting('batchSubtitleCustomOutputDir', dir ?? '');
  }

  /// Updates the path strategy and its directory as one runtime transaction.
  /// This prevents an active task from observing `customDirectory` paired with
  /// the previous directory while the two preference writes are in flight.
  Future<void> updateBatchSubtitleOutputLocation(
    SubtitleOutputPathStrategy strategy, {
    String? customOutputDir,
  }) async {
    await _updateRegisteredSettingsAtomically({
      'batchSubtitleOutputPathStrategy':
          strategy == SubtitleOutputPathStrategy.customDirectory
          ? 'customDirectory'
          : 'sameAsVideo',
      'batchSubtitleCustomOutputDir': customOutputDir ?? '',
    });
  }

  // 外部视频内嵌软字幕设置更新方法
  Future<void> updateBatchSubtitleEmbedSoftCopyAndEmbed(bool value) async {
    await updateBatchSubtitleEmbedMode(
      copyAndEmbed: value,
      deleteOriginal: value ? false : batchSubtitleEmbedSoftDeleteOriginal,
    );
  }

  Future<void> updateBatchSubtitleEmbedSoftDeleteOriginal(bool value) async {
    await updateBatchSubtitleEmbedMode(
      copyAndEmbed: value ? false : batchSubtitleEmbedSoftCopyAndEmbed,
      deleteOriginal: value,
    );
  }

  /// Applies the two mutually-exclusive embedding modes atomically so a
  /// running task never sees both destructive and non-destructive modes on.
  Future<void> updateBatchSubtitleEmbedMode({
    required bool copyAndEmbed,
    required bool deleteOriginal,
  }) async {
    if (copyAndEmbed && deleteOriginal) {
      throw ArgumentError(
        'Soft-subtitle embedding modes are mutually exclusive.',
      );
    }
    await _updateRegisteredSettingsAtomically({
      'batchSubtitleEmbedSoftCopyAndEmbed': copyAndEmbed,
      'batchSubtitleEmbedSoftDeleteOriginal': deleteOriginal,
    });
  }

  Future<void> updateBatchSubtitleEmbedSoftPrefixEnabled(bool value) async {
    await _updateRegisteredSetting(
      'batchSubtitleEmbedSoftPrefixEnabled',
      value,
    );
  }

  Future<void> updateBatchSubtitleEmbedSoftPrefix(String value) async {
    await _updateRegisteredSetting('batchSubtitleEmbedSoftPrefix', value);
  }

  Future<void> updateBatchSubtitleEmbedSoftSuffixEnabled(bool value) async {
    await _updateRegisteredSetting(
      'batchSubtitleEmbedSoftSuffixEnabled',
      value,
    );
  }

  Future<void> updateBatchSubtitleEmbedSoftSuffix(String value) async {
    await _updateRegisteredSetting('batchSubtitleEmbedSoftSuffix', value);
  }

  Future<void> updateBatchSubtitleEmbedAutoDeleteSrt(bool value) async {
    await _updateRegisteredSetting('batchSubtitleEmbedAutoDeleteSrt', value);
  }

  Future<void> init() async {
    if (_initialized) return;
    _prefs = await SharedPreferences.getInstance();
    // Recover an interrupted switch before any settings migration/load. An
    // active trial stays active and retains its recovery button after restart.
    await defaultSettingsTrial.initialize();
    // Account interactions were removed; discard the retired preference.
    await _prefs.remove('bilibiliAccountReadOnly');
    final hadImportPlacementRules = _prefs.containsKey(
      ImportPlacementRules.settingsKey,
    );
    _attachPositionStore();
    await SubtitleDebugSession.instance.initialize(_prefs);
    await _loadRegisteredSettings();
    await _loadPlaybackSpeedLockState();
    _loadClipboardLastHandledText();

    largeDataRootPath = _prefs.getString('largeDataRootPath');
    final composePrimaryRaw = _prefs.getString(
      'videoComposePrimarySubtitlePath',
    );
    videoComposePrimarySubtitlePath =
        (composePrimaryRaw == null || composePrimaryRaw.isEmpty)
        ? null
        : composePrimaryRaw;
    final composeSecondaryRaw = _prefs.getString(
      'videoComposeSecondarySubtitlePath',
    );
    videoComposeSecondarySubtitlePath =
        (composeSecondaryRaw == null || composeSecondaryRaw.isEmpty)
        ? null
        : composeSecondaryRaw;
    final composeOutputRaw = _prefs.getString('videoComposeCustomOutputPath');
    videoComposeCustomOutputPath =
        (composeOutputRaw == null || composeOutputRaw.isEmpty)
        ? null
        : composeOutputRaw;

    // Migrate old 'sidebarFontSizeScale' to 'landscapeSidebarFontSizeScale' if present
    // Default 1.1 for Landscape
    landscapeSidebarFontSizeScale =
        _prefs.getDouble('landscapeSidebarFontSizeScale') ??
        _prefs.getDouble('sidebarFontSizeScale') ??
        1.0;
    ghostModeAlignment = _readAlignmentPreference(
      jsonKey: _ghostModeAlignmentJsonKey,
      legacyXKey: 'ghostModeAlignX',
      legacyYKey: 'ghostModeAlignY',
      fallback: const Alignment(0.0, 0.8856727518593654),
    );

    subtitleOffset = Duration(
      milliseconds: _prefs.getInt('subtitleOffset') ?? 0,
    );

    subtitleAlignment = _readAlignmentPreference(
      jsonKey: _subtitleAlignmentJsonKey,
      legacyXKey: 'subtitleAlignX',
      legacyYKey: 'subtitleAlignY',
      fallback: const Alignment(0.0, 0.8947589131115533),
    );

    audioSubtitleAlignment = _readAlignmentPreference(
      jsonKey: _audioSubtitleAlignmentJsonKey,
      legacyXKey: 'audioSubtitleAlignX',
      legacyYKey: 'audioSubtitleAlignY',
      fallback: subtitleAlignment,
    );

    // 加载字幕样式 - 新的结构
    await _loadSubtitleStyles();

    final presetsJson = _prefs.getString('subtitlePresets');
    if (presetsJson != null) {
      try {
        final List<dynamic> decoded = json.decode(presetsJson);
        subtitlePresets = decoded
            .map((e) => Map<String, double>.from(e))
            .toList();
      } catch (e) {
        developer.log('Error loading presets', error: e);
      }
    }

    // 加载全局音频竖屏比例设置
    final audioRatioRaw = _prefs.getDouble('audioPortraitDisplayAspectRatio');
    audioPortraitDisplayAspectRatio =
        (audioRatioRaw != null && audioRatioRaw.isFinite && audioRatioRaw > 0)
        ? audioRatioRaw
        : null;
    final audioWRaw = _prefs.getDouble('audioPortraitCustomAspectWidth');
    audioPortraitCustomAspectWidth =
        (audioWRaw != null && audioWRaw.isFinite && audioWRaw > 0)
        ? audioWRaw
        : null;
    final audioHRaw = _prefs.getDouble('audioPortraitCustomAspectHeight');
    audioPortraitCustomAspectHeight =
        (audioHRaw != null && audioHRaw.isFinite && audioHRaw > 0)
        ? audioHRaw
        : null;

    if (!hadImportPlacementRules && bilibiliImportTarget.isNotEmpty) {
      _applyLegacyBilibiliImportTarget(bilibiliImportTarget);
      await _prefs.setString(
        ImportPlacementRules.settingsKey,
        importPlacementRulesJson,
      );
    }
    if (_restoredDefaultTrialRuntime case final Map<String, dynamic> runtime) {
      _restoredDefaultTrialRuntime = null;
      _applyFloatingSubtitleRuntime(runtime);
    }
    _initialized = true;
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    // This wrapper is itself test-only and also resets the attached journal UI.
    // ignore: invalid_use_of_visible_for_testing_member
    _defaultSettingsTrial?.resetForTest();
    _positionStore?.dispose();
    _positionStore = null;
    subtitlePositionSaveError = null;
    _initialized = false;
    _skipPortraitPlayer = null;
    _restoredDefaultTrialRuntime = null;
    showActionButtonLabels = true;
    localImportFilterMediaExtensions = true;
    mediaLibraryReadableCardDefaults = false;
    bilibiliDanmakuReadableFontDefaults = false;
    mediaLibraryLastFolderIncludeDescendants = false;
    mediaLibraryContinueSeriousOnly = false;
    continueWatchPolicy = ContinueWatchPolicy.defaults;
    clipboardLastHandledText = null;
    clipboardLinkDetectionEnabled = true;
    bilibiliRecordSearchHistory = true;
    bilibiliRecordWatchHistory = true;
    bilibiliAutoImportOnPlay = false;
    bilibiliImportTarget = '';
    bilibiliPlayerPanelOpen = true;
    bilibiliPortraitShowsSubtitles = false;
    bilibiliLandscapeShowsSubtitles = false;
    musicLyricFontSizeScalePortrait = MusicLyricTypography.defaultFontSizeScale;
    musicLyricFontSizeScaleLandscape =
        MusicLyricTypography.defaultFontSizeScale;
    musicLyricSpacingScalePortrait = MusicLyricTypography.defaultSpacingScale;
    musicLyricSpacingScaleLandscape = MusicLyricTypography.defaultSpacingScale;
    musicLyricAnchorPortrait = MusicLyricAnchor.automatic;
    musicLyricAnchorLandscape = MusicLyricAnchor.automatic;
    musicLyricWordByWordEnabled = true;
    musicLyricBlurEnabled = true;
    musicPortraitControlsAutoHide = false;
    bilibiliCacheLimitBytes = bilibiliCacheLimitDefault;
    importCardPlacement = ImportCardPlacement.libraryRoot.storageValue;
    importSourceFolderNamesJson = '{}';
    importSourceFolderIdsJson = '{}';
    importPlacementRulesJson = '{}';
    showMiniPlaybackCard = true;
    showSystemMediaNotification = true;
    desktopSystemMediaControls = true;
    desktopTaskbarMediaControls = true;
    desktopGlobalMediaHotkeys = false;
    desktopMediaHotkeyModifiers = 'ctrl+alt';
  }

  void _loadClipboardLastHandledText() {
    final stored = _prefs.getString(clipboardLastHandledTextKey);
    clipboardLastHandledText = (stored == null || stored.trim().isEmpty)
        ? null
        : stored.trim();
  }

  /// Records [content] as the latest clipboard text that finished parsing.
  ///
  /// The in-memory value updates before disk so a later check in this process
  /// sees it even if persistence is still in flight. Empty text is ignored.
  Future<void> rememberClipboardHandledText(String content) async {
    final identity = content.trim();
    if (identity.isEmpty || identity == clipboardLastHandledText) return;
    clipboardLastHandledText = identity;
    if (!_initialized) return;
    await _prefs.setString(clipboardLastHandledTextKey, identity);
  }

  /// 加载字幕样式 - 支持新旧格式迁移
  Future<void> _loadSubtitleStyles() async {
    // 尝试加载新的文字样式格式
    final textStyleJson = _prefs.getString('subtitleTextStyle');
    if (textStyleJson != null) {
      try {
        subtitleTextStyle = SubtitleTextStyle.fromJson(
          json.decode(textStyleJson),
        );
      } catch (e) {
        developer.log('Error loading subtitle text style', error: e);
      }
    } else {
      // 从旧格式迁移
      final legacyStyleJson =
          _prefs.getString('subtitleStyleLandscape') ??
          _prefs.getString('subtitleStyle');
      if (legacyStyleJson != null) {
        try {
          final legacyStyle = SubtitleStyle.fromJson(
            json.decode(legacyStyleJson),
          );
          subtitleTextStyle = legacyStyle.textStyle;
        } catch (e) {
          developer.log('Error migrating legacy subtitle style', error: e);
        }
      }
    }

    // 加载音频文字样式
    final audioTextStyleJson = _prefs.getString('audioSubtitleTextStyle');
    if (audioTextStyleJson != null) {
      try {
        audioSubtitleTextStyle = SubtitleTextStyle.fromJson(
          json.decode(audioTextStyleJson),
        );
      } catch (e) {
        developer.log('Error loading audio subtitle text style', error: e);
      }
    } else {
      // 从旧格式迁移
      final legacyAudioStyleJson = _prefs.getString(
        'audioSubtitleStyleLandscape',
      );
      if (legacyAudioStyleJson != null) {
        try {
          final legacyStyle = SubtitleStyle.fromJson(
            json.decode(legacyAudioStyleJson),
          );
          audioSubtitleTextStyle = legacyStyle.textStyle;
        } catch (e) {
          developer.log(
            'Error migrating legacy audio subtitle style',
            error: e,
          );
        }
      }
    }

    // 加载横屏布局样式
    final layoutLandJson = _prefs.getString('subtitleLayoutLandscape');
    if (layoutLandJson != null) {
      try {
        subtitleLayoutLandscape = SubtitleLayoutStyle.fromJson(
          json.decode(layoutLandJson),
        );
      } catch (e) {
        developer.log('Error loading landscape layout style', error: e);
      }
    } else {
      // 从旧格式迁移
      final legacyStyleJson =
          _prefs.getString('subtitleStyleLandscape') ??
          _prefs.getString('subtitleStyle');
      if (legacyStyleJson != null) {
        try {
          final legacyStyle = SubtitleStyle.fromJson(
            json.decode(legacyStyleJson),
          );
          subtitleLayoutLandscape = legacyStyle.layoutStyle;
        } catch (e) {
          developer.log(
            'Error migrating legacy landscape layout style',
            error: e,
          );
        }
      }
    }

    // 加载竖屏布局样式
    final layoutPortJson = _prefs.getString('subtitleLayoutPortrait');
    if (layoutPortJson != null) {
      try {
        subtitleLayoutPortrait = SubtitleLayoutStyle.fromJson(
          json.decode(layoutPortJson),
        );
      } catch (e) {
        developer.log('Error loading portrait layout style', error: e);
      }
    } else {
      // 从旧格式迁移
      final legacyStyleJson = _prefs.getString('subtitleStylePortrait');
      if (legacyStyleJson != null) {
        try {
          final legacyStyle = SubtitleStyle.fromJson(
            json.decode(legacyStyleJson),
          );
          subtitleLayoutPortrait = legacyStyle.layoutStyle;
        } catch (e) {
          developer.log(
            'Error migrating legacy portrait layout style',
            error: e,
          );
        }
      } else {
        // 默认使用横屏布局
        subtitleLayoutPortrait = subtitleLayoutLandscape;
      }
    }

    // 加载音频横屏布局样式
    final audioLayoutLandJson = _prefs.getString(
      'audioSubtitleLayoutLandscape',
    );
    if (audioLayoutLandJson != null) {
      try {
        audioSubtitleLayoutLandscape = SubtitleLayoutStyle.fromJson(
          json.decode(audioLayoutLandJson),
        );
      } catch (e) {
        developer.log('Error loading audio landscape layout style', error: e);
      }
    } else {
      // 从旧格式迁移
      final legacyStyleJson = _prefs.getString('audioSubtitleStyleLandscape');
      if (legacyStyleJson != null) {
        try {
          final legacyStyle = SubtitleStyle.fromJson(
            json.decode(legacyStyleJson),
          );
          audioSubtitleLayoutLandscape = legacyStyle.layoutStyle;
        } catch (e) {
          developer.log(
            'Error migrating legacy audio landscape layout style',
            error: e,
          );
        }
      }
    }

    // 加载音频竖屏布局样式
    final audioLayoutPortJson = _prefs.getString('audioSubtitleLayoutPortrait');
    if (audioLayoutPortJson != null) {
      try {
        audioSubtitleLayoutPortrait = SubtitleLayoutStyle.fromJson(
          json.decode(audioLayoutPortJson),
        );
      } catch (e) {
        developer.log('Error loading audio portrait layout style', error: e);
      }
    } else {
      // 从旧格式迁移
      final legacyStyleJson = _prefs.getString('audioSubtitleStylePortrait');
      if (legacyStyleJson != null) {
        try {
          final legacyStyle = SubtitleStyle.fromJson(
            json.decode(legacyStyleJson),
          );
          audioSubtitleLayoutPortrait = legacyStyle.layoutStyle;
        } catch (e) {
          developer.log(
            'Error migrating legacy audio portrait layout style',
            error: e,
          );
        }
      } else {
        // 默认使用音频横屏布局
        audioSubtitleLayoutPortrait = audioSubtitleLayoutLandscape;
      }
    }

    // 加载幽灵模式布局样式（与普通布局完全独立）
    final ghostLayoutLandJson = _prefs.getString(
      'subtitleLayoutGhostLandscape',
    );
    final ghostLayoutPortJson = _prefs.getString('subtitleLayoutGhostPortrait');
    if (ghostLayoutLandJson != null) {
      try {
        subtitleLayoutGhostLandscape = SubtitleLayoutStyle.fromJson(
          json.decode(ghostLayoutLandJson),
        );
      } catch (e) {
        developer.log('Error loading ghost landscape layout style', error: e);
      }
    }
    if (ghostLayoutPortJson != null) {
      try {
        subtitleLayoutGhostPortrait = SubtitleLayoutStyle.fromJson(
          json.decode(ghostLayoutPortJson),
        );
      } catch (e) {
        developer.log('Error loading ghost portrait layout style', error: e);
      }
    }

    // 旧版迁移：只有 ghostSubtitleFontSize / ghostSubtitleLetterSpacing（新版本改为完整布局样式）
    final bool hasGhostLayout =
        ghostLayoutLandJson != null || ghostLayoutPortJson != null;
    if (!hasGhostLayout &&
        (_prefs.containsKey('ghostSubtitleFontSize') ||
            _prefs.containsKey('ghostSubtitleLetterSpacing'))) {
      final oldFontSize =
          _prefs.getDouble('ghostSubtitleFontSize') ??
          subtitleLayoutLandscape.fontSize;
      final oldLetterSpacing =
          _prefs.getDouble('ghostSubtitleLetterSpacing') ?? 0.0;
      final base = subtitleLayoutLandscape;
      final baseSecondary = base.secondaryFontSize ?? base.fontSize;
      final fontScale = base.fontSize == 0
          ? 1.0
          : (oldFontSize / base.fontSize);
      final migrated = base.copyWith(
        fontSize: oldFontSize,
        secondaryFontSize: baseSecondary * fontScale,
        letterSpacing: oldLetterSpacing,
      );
      subtitleLayoutGhostLandscape = migrated;
      subtitleLayoutGhostPortrait = migrated;
      await _prefs.setString(
        'subtitleLayoutGhostLandscape',
        json.encode(migrated.toJson()),
      );
      await _prefs.setString(
        'subtitleLayoutGhostPortrait',
        json.encode(migrated.toJson()),
      );
    } else {
      if (ghostLayoutPortJson == null) {
        subtitleLayoutGhostPortrait = subtitleLayoutGhostLandscape;
      }
    }

    await _migrateLegacyGhostLayoutsIfNeeded();
    await _migrateLegacyTextMetricsIfNeeded();
    await _syncSubtitleLayouts();
    await _normalizeSubtitleStyleStorage();
  }

  bool _layoutStyleEquals(SubtitleLayoutStyle a, SubtitleLayoutStyle b) {
    return a.adaptiveSizing == b.adaptiveSizing &&
        a.balancedScreenSizing == b.balancedScreenSizing &&
        a.overallScale == b.overallScale &&
        a.fontSize == b.fontSize &&
        a.secondaryFontSize == b.secondaryFontSize &&
        a.lineSpacing == b.lineSpacing &&
        a.letterSpacing == b.letterSpacing;
  }

  Future<void> _migrateLegacyGhostLayoutsIfNeeded() async {
    final int version = _prefs.getInt(_ghostLayoutCompatibilityVersionKey) ?? 0;
    if (version >= _ghostLayoutCompatibilityVersion) {
      return;
    }

    bool changed = false;
    if (_layoutStyleEquals(subtitleLayoutGhostLandscape, _legacyGhostLayout)) {
      subtitleLayoutGhostLandscape = subtitleLayoutLandscape;
      changed = true;
    }
    if (_layoutStyleEquals(subtitleLayoutGhostPortrait, _legacyGhostLayout)) {
      subtitleLayoutGhostPortrait = subtitleLayoutPortrait;
      changed = true;
    }

    if (changed) {
      await _prefs.setString(
        'subtitleLayoutGhostLandscape',
        json.encode(subtitleLayoutGhostLandscape.toJson()),
      );
      await _prefs.setString(
        'subtitleLayoutGhostPortrait',
        json.encode(subtitleLayoutGhostPortrait.toJson()),
      );
    }

    await _prefs.setInt(
      _ghostLayoutCompatibilityVersionKey,
      _ghostLayoutCompatibilityVersion,
    );
  }

  Future<void> _migrateLegacyTextMetricsIfNeeded() async {
    final int version = _prefs.getInt(_textMetricCompatibilityVersionKey) ?? 0;
    if (version >= _textMetricCompatibilityVersion) {
      return;
    }

    // If legacy absolute metrics were tuned for the old default font size,
    // normalize them to become font-size-relative.
    subtitleTextStyle = subtitleTextStyle.copyWith(
      borderWidth: subtitleTextStyle.normalizeBorderWidthForFontSize(
        subtitleTextStyle.borderWidth,
        kSubtitleTextMetricReferenceFontSize,
      ),
      shadowBlur: subtitleTextStyle.normalizeShadowBlurForFontSize(
        subtitleTextStyle.shadowBlur,
        kSubtitleTextMetricReferenceFontSize,
      ),
      shadowOffset: subtitleTextStyle.normalizeShadowOffsetForFontSize(
        subtitleTextStyle.shadowOffset,
        kSubtitleTextMetricReferenceFontSize,
      ),
    );
    audioSubtitleTextStyle = audioSubtitleTextStyle.copyWith(
      borderWidth: audioSubtitleTextStyle.normalizeBorderWidthForFontSize(
        audioSubtitleTextStyle.borderWidth,
        kSubtitleTextMetricReferenceFontSize,
      ),
      shadowBlur: audioSubtitleTextStyle.normalizeShadowBlurForFontSize(
        audioSubtitleTextStyle.shadowBlur,
        kSubtitleTextMetricReferenceFontSize,
      ),
      shadowOffset: audioSubtitleTextStyle.normalizeShadowOffsetForFontSize(
        audioSubtitleTextStyle.shadowOffset,
        kSubtitleTextMetricReferenceFontSize,
      ),
    );

    await _prefs.setString(
      'subtitleTextStyle',
      json.encode(subtitleTextStyle.toJson()),
    );
    await _prefs.setString(
      'audioSubtitleTextStyle',
      json.encode(audioSubtitleTextStyle.toJson()),
    );
    await _prefs.setInt(
      _textMetricCompatibilityVersionKey,
      _textMetricCompatibilityVersion,
    );
  }

  Future<void> _setStringIfChanged(String key, String value) async {
    if (_prefs.getString(key) == value) return;
    await _prefs.setString(key, value);
  }

  Future<void> _normalizeSubtitleStyleStorage() async {
    // 统一回写当前的共享文字样式和布局样式，确保升级后幽灵模式与普通模式
    // 除字号、行距、字距和位置外，其余视觉样式都指向同一份数据。
    await _setStringIfChanged(
      'subtitleTextStyle',
      json.encode(subtitleTextStyle.toJson()),
    );
    await _setStringIfChanged(
      'subtitleLayoutLandscape',
      json.encode(subtitleLayoutLandscape.toJson()),
    );
    await _setStringIfChanged(
      'subtitleLayoutPortrait',
      json.encode(subtitleLayoutPortrait.toJson()),
    );
    await _setStringIfChanged(
      'subtitleLayoutGhostLandscape',
      json.encode(subtitleLayoutGhostLandscape.toJson()),
    );
    await _setStringIfChanged(
      'subtitleLayoutGhostPortrait',
      json.encode(subtitleLayoutGhostPortrait.toJson()),
    );
    await _setStringIfChanged(
      'subtitleStyleLandscape',
      json.encode(subtitleStyleLandscape.toJson()),
    );
    await _setStringIfChanged(
      'subtitleStylePortrait',
      json.encode(subtitleStylePortrait.toJson()),
    );
    await _setStringIfChanged(
      'subtitleStyle',
      json.encode(subtitleStyleLandscape.toJson()),
    );
    await _setStringIfChanged(
      'audioSubtitleTextStyle',
      json.encode(audioSubtitleTextStyle.toJson()),
    );
    await _setStringIfChanged(
      'audioSubtitleLayoutLandscape',
      json.encode(audioSubtitleLayoutLandscape.toJson()),
    );
    await _setStringIfChanged(
      'audioSubtitleLayoutPortrait',
      json.encode(audioSubtitleLayoutPortrait.toJson()),
    );
    await _setStringIfChanged(
      'audioSubtitleStyleLandscape',
      json.encode(audioSubtitleStyleLandscape.toJson()),
    );
    await _setStringIfChanged(
      'audioSubtitleStylePortrait',
      json.encode(audioSubtitleStylePortrait.toJson()),
    );
    if (_prefs.getBool('syncAudioSubtitleStyleWithVideo') !=
        syncAudioSubtitleStyleWithVideo) {
      await _prefs.setBool(
        'syncAudioSubtitleStyleWithVideo',
        syncAudioSubtitleStyleWithVideo,
      );
    }

    // 清理旧版幽灵模式独立布局遗留键，避免后续再次触发旧迁移分支。
    if (_prefs.containsKey('ghostSubtitleFontSize')) {
      await _prefs.remove('ghostSubtitleFontSize');
    }
    if (_prefs.containsKey('ghostSubtitleLetterSpacing')) {
      await _prefs.remove('ghostSubtitleLetterSpacing');
    }
  }

  Future<void> _syncSubtitleLayouts() async {
    if (!_layoutStyleEquals(subtitleLayoutLandscape, subtitleLayoutPortrait)) {
      subtitleLayoutPortrait = subtitleLayoutLandscape;
      await _prefs.setString(
        'subtitleLayoutPortrait',
        json.encode(subtitleLayoutPortrait.toJson()),
      );
      await _prefs.setString(
        'subtitleStylePortrait',
        json.encode(subtitleStylePortrait.toJson()),
      );
    }

    if (!_layoutStyleEquals(
      subtitleLayoutGhostLandscape,
      subtitleLayoutGhostPortrait,
    )) {
      subtitleLayoutGhostPortrait = subtitleLayoutGhostLandscape;
      await _prefs.setString(
        'subtitleLayoutGhostPortrait',
        json.encode(subtitleLayoutGhostPortrait.toJson()),
      );
    }

    if (!_layoutStyleEquals(
      audioSubtitleLayoutLandscape,
      audioSubtitleLayoutPortrait,
    )) {
      audioSubtitleLayoutPortrait = audioSubtitleLayoutLandscape;
      await _prefs.setString(
        'audioSubtitleLayoutPortrait',
        json.encode(audioSubtitleLayoutPortrait.toJson()),
      );
      await _prefs.setString(
        'audioSubtitleStylePortrait',
        json.encode(audioSubtitleStylePortrait.toJson()),
      );
    }
  }

  Future<void> savePortraitCustomAspectDraftTexts({
    required String widthText,
    required String heightText,
    bool notify = false,
  }) async {
    if (portraitCustomAspectDraftWidthText == widthText &&
        portraitCustomAspectDraftHeightText == heightText) {
      return;
    }

    portraitCustomAspectDraftWidthText = widthText;
    portraitCustomAspectDraftHeightText = heightText;

    await Future.wait([
      _prefs.setString('portraitCustomAspectDraftWidthText', widthText),
      _prefs.setString('portraitCustomAspectDraftHeightText', heightText),
    ]);

    if (notify) {
      notifyListeners();
    }
  }

  /// 保存全局音频竖屏播放页显示比例。
  /// 音频比例是全局共享的，设置一次应用到所有音频媒体。
  Future<void> saveAudioPortraitDisplayAspectRatio(
    double? ratio, {
    double? customWidth,
    double? customHeight,
  }) async {
    audioPortraitDisplayAspectRatio = ratio;
    audioPortraitCustomAspectWidth = customWidth;
    audioPortraitCustomAspectHeight = customHeight;
    notifyListeners();

    if (ratio != null && ratio.isFinite && ratio > 0) {
      await _prefs.setDouble('audioPortraitDisplayAspectRatio', ratio);
    } else {
      await _prefs.remove('audioPortraitDisplayAspectRatio');
    }
    if (customWidth != null && customWidth.isFinite && customWidth > 0) {
      await _prefs.setDouble('audioPortraitCustomAspectWidth', customWidth);
    } else {
      await _prefs.remove('audioPortraitCustomAspectWidth');
    }
    if (customHeight != null && customHeight.isFinite && customHeight > 0) {
      await _prefs.setDouble('audioPortraitCustomAspectHeight', customHeight);
    } else {
      await _prefs.remove('audioPortraitCustomAspectHeight');
    }
  }

  Future<void> updateSetting<T>(String key, T value) async {
    if (key == 'bilibiliImportTarget') {
      _applyLegacyBilibiliImportTarget(value as String);
      final rulesWrite = _updateRegisteredSetting<String>(
        ImportPlacementRules.settingsKey,
        importPlacementRulesJson,
      );
      final targetWrite = _updateRegisteredSetting<T>(key, value);
      await Future.wait([rulesWrite, targetWrite]);
      return;
    }
    if (await _updateRegisteredSetting<T>(key, value)) {
      return;
    }

    switch (key) {
      case 'videoComposePrimarySubtitlePath':
        final v = value as String;
        await _prefs.setString(key, v);
        videoComposePrimarySubtitlePath = v.isEmpty ? null : v;
        break;
      case 'videoComposeSecondarySubtitlePath':
        final v = value as String;
        await _prefs.setString(key, v);
        videoComposeSecondarySubtitlePath = v.isEmpty ? null : v;
        break;
      case 'videoComposeCustomOutputPath':
        final v = value as String;
        await _prefs.setString(key, v);
        videoComposeCustomOutputPath = v.isEmpty ? null : v;
        break;
      case 'landscapeSidebarFontSizeScale':
        await _prefs.setDouble(key, value as double);
        landscapeSidebarFontSizeScale = value as double;
        break;
      case 'subtitleOffset':
        await _trackSettingsWrite(_prefs.setInt(key, value as int));
        subtitleOffset = Duration(milliseconds: value as int);
        break;
      default:
        throw ArgumentError.value(key, 'key', 'Unsupported setting key');
    }
    notifyListeners();
  }

  Future<void> saveStructuredImportSortField(String value) async {
    await _updateRegisteredSetting<String>('structuredImportSortField', value);
  }

  void _applyLegacyBilibiliImportTarget(String value) {
    final rules = importPlacementRules;
    final key = ImportCardFeature.bilibiliPage.storageValue;
    if (value == 'root') {
      rules.overrides[key] = const ImportPlacementRule(
        ImportCardPlacement.libraryRoot,
      );
    } else if (value.startsWith('folder:') &&
        value.substring(7).trim().isNotEmpty) {
      rules.overrides[key] = ImportPlacementRule(
        ImportCardPlacement.fixedFolder,
        folderId: value.substring(7).trim(),
      );
    } else {
      rules.overrides.remove(key);
    }
    importPlacementRulesJson = rules.encode();
  }

  Future<void> updateFolderPlaceholderSettings(
    FolderPlaceholderSettings value,
  ) {
    return updateSetting(
      'folderPlaceholderSettings',
      value.normalized().toJsonString(),
    );
  }

  Future<void> saveStructuredImportSortDirection(String value) async {
    await _updateRegisteredSetting<String>(
      'structuredImportSortDirection',
      value,
    );
  }

  Future<void> saveStructuredImportSort({
    required String field,
    required String direction,
  }) async {
    await _updateRegisteredSetting<String>(
      'structuredImportSortField',
      field,
      notify: false,
    );
    await _updateRegisteredSetting<String>(
      'structuredImportSortDirection',
      direction,
      notify: false,
    );
    notifyListeners();
  }

  Future<void> saveShowSubtitles(bool value) async {
    await _updateRegisteredSetting<bool>('showSubtitles', value);
  }

  Future<void> toggleDeveloperMode() {
    return updateSetting<bool>('developerMode', !developerMode);
  }

  Future<void> saveShowBilibiliDanmaku(bool value) async {
    await _updateRegisteredSetting<bool>('showBilibiliDanmaku', value);
  }

  Future<void> saveBilibiliDanmakuOnlyInVideoArea(bool value) async {
    await _updateRegisteredSetting<bool>(
      'bilibiliDanmakuOnlyInVideoArea',
      value,
    );
  }

  double danmakuDisplayAreaFor(DanmakuPresentationMode mode) =>
      mode == DanmakuPresentationMode.portrait
      ? bilibiliDanmakuPortraitDisplayArea
      : bilibiliDanmakuDisplayArea;

  double danmakuFontScaleFor(DanmakuPresentationMode mode) =>
      mode == DanmakuPresentationMode.portrait
      ? bilibiliDanmakuPortraitFontScale
      : bilibiliDanmakuFontScale;

  double danmakuSpeedFor(DanmakuPresentationMode mode) =>
      mode == DanmakuPresentationMode.portrait
      ? bilibiliDanmakuPortraitSpeed
      : bilibiliDanmakuSpeed;

  double danmakuDensityFor(DanmakuPresentationMode mode) =>
      mode == DanmakuPresentationMode.portrait
      ? bilibiliDanmakuPortraitDensity
      : bilibiliDanmakuDensity;

  String _danmakuProfileKey(String suffix, DanmakuPresentationMode mode) =>
      'bilibiliDanmaku${mode == DanmakuPresentationMode.portrait ? 'Portrait' : ''}$suffix';

  Future<void> saveBilibiliDanmakuDisplayArea(
    double value, {
    DanmakuPresentationMode mode = DanmakuPresentationMode.landscape,
  }) async {
    await _updateRegisteredSetting<double>(
      _danmakuProfileKey('DisplayArea', mode),
      value,
    );
  }

  Future<void> saveBilibiliDanmakuOpacity(double value) async {
    await _updateRegisteredSetting<double>('bilibiliDanmakuOpacity', value);
  }

  Future<void> saveBilibiliDanmakuFontScale(
    double value, {
    DanmakuPresentationMode mode = DanmakuPresentationMode.landscape,
  }) async {
    await _updateRegisteredSetting<double>(
      _danmakuProfileKey('FontScale', mode),
      value,
    );
  }

  Future<void> saveBilibiliDanmakuSpeed(
    double value, {
    DanmakuPresentationMode mode = DanmakuPresentationMode.landscape,
  }) async {
    await _updateRegisteredSetting<double>(
      _danmakuProfileKey('Speed', mode),
      value,
    );
  }

  Future<void> saveBilibiliDanmakuDensity(
    double value, {
    DanmakuPresentationMode mode = DanmakuPresentationMode.landscape,
  }) async {
    await _updateRegisteredSetting<double>(
      _danmakuProfileKey('Density', mode),
      value,
    );
  }

  /// Instant in-memory toggle, then persist. Skip no-ops so a repeated tap
  /// cannot enqueue extra player rebuilds. Writes are serialized against the
  /// latest memory value so a slower older write cannot resurrect a stale tick.
  Future<void> saveBilibiliDanmakuUseLockedSpeedAsBaseline(bool value) async {
    if (bilibiliDanmakuUseLockedSpeedAsBaseline == value) return;
    bilibiliDanmakuUseLockedSpeedAsBaseline = value;
    notifyListeners();
    final writeId = ++_danmakuLockedBaselineWriteId;
    final pending = _danmakuLockedBaselinePersistTail.then((_) async {
      if (writeId != _danmakuLockedBaselineWriteId) return;
      await _prefs.setBool(
        'bilibiliDanmakuUseLockedSpeedAsBaseline',
        bilibiliDanmakuUseLockedSpeedAsBaseline,
      );
    });
    _danmakuLockedBaselinePersistTail = pending.catchError((Object _) {});
    await pending;
  }

  Future<void> saveBilibiliDanmakuAutoUpdate(bool value) async {
    await _updateRegisteredSetting<bool>('bilibiliDanmakuAutoUpdate', value);
  }

  /// Slider speed after applying the locked-playback baseline, if enabled.
  ///
  /// Unlocked leftover [playbackSpeed] values must not leak into this result.
  double get effectiveBilibiliDanmakuSpeed =>
      effectiveBilibiliDanmakuSpeedFor(DanmakuPresentationMode.landscape);

  double effectiveBilibiliDanmakuSpeedFor(DanmakuPresentationMode mode) {
    return resolveDanmakuSpeedWithLockedPlaybackBaseline(
      sliderSpeed: danmakuSpeedFor(mode),
      useLockedPlaybackAsBaseline: bilibiliDanmakuUseLockedSpeedAsBaseline,
      isPlaybackSpeedLocked: isPlaybackSpeedLocked,
      lockedPlaybackSpeed: playbackSpeed,
    );
  }

  Future<void> saveBilibiliDanmakuFontFamily(String? value) async {
    await _updateRegisteredSetting<String>(
      'bilibiliDanmakuFontFamily',
      value ?? '',
    );
  }

  Future<void> saveBilibiliDanmakuOutlineScale(double value) =>
      _updateRegisteredSetting<double>('bilibiliDanmakuOutlineScale', value);

  Future<void> saveBilibiliDanmakuShadowScale(double value) =>
      _updateRegisteredSetting<double>('bilibiliDanmakuShadowScale', value);

  Future<void> saveBilibiliDanmakuLetterSpacing(double value) =>
      _updateRegisteredSetting<double>('bilibiliDanmakuLetterSpacing', value);

  Future<void> saveBilibiliDanmakuFontWeight(int value) async {
    await _updateRegisteredSetting<int>('bilibiliDanmakuFontWeight', value);
  }

  Future<void> saveBilibiliDanmakuOutlineType(DanmakuOutlineType value) async {
    await _updateRegisteredSetting<String>(
      'bilibiliDanmakuOutlineType',
      value.name,
    );
  }

  Future<void> resetBilibiliDanmakuSettings() async {
    for (final entry in <String, double>{
      'bilibiliDanmakuDensity': 1.0,
      'bilibiliDanmakuPortraitDisplayArea': kDanmakuPortraitDisplayArea,
      'bilibiliDanmakuPortraitFontScale': kDanmakuPortraitFontScale,
      'bilibiliDanmakuPortraitSpeed': kDanmakuPortraitSpeed,
      'bilibiliDanmakuPortraitDensity': kDanmakuPortraitDensity,
    }.entries) {
      await _updateRegisteredSetting<double>(
        entry.key,
        entry.value,
        notify: false,
      );
    }
    await _updateRegisteredSetting<bool>(
      'bilibiliDanmakuOnlyInVideoArea',
      false,
      notify: false,
    );
    await _updateRegisteredSetting<double>(
      'bilibiliDanmakuDisplayArea',
      0.5,
      notify: false,
    );
    await _updateRegisteredSetting<double>(
      'bilibiliDanmakuOpacity',
      0.8,
      notify: false,
    );
    await _updateRegisteredSetting<double>(
      'bilibiliDanmakuFontScale',
      0.8,
      notify: false,
    );
    await _updateRegisteredSetting<double>(
      'bilibiliDanmakuSpeed',
      1.0,
      notify: false,
    );
    _danmakuLockedBaselineWriteId++;
    await _updateRegisteredSetting<bool>(
      'bilibiliDanmakuUseLockedSpeedAsBaseline',
      false,
      notify: false,
    );
    await _updateRegisteredSetting<bool>(
      'bilibiliDanmakuAutoUpdate',
      true,
      notify: false,
    );
    await _updateRegisteredSetting<String>(
      'bilibiliDanmakuFontFamily',
      kDanmakuDefaultFontFamily,
      notify: false,
    );
    await _updateRegisteredSetting<double>(
      'bilibiliDanmakuOutlineScale',
      1.0,
      notify: false,
    );
    await _updateRegisteredSetting<double>(
      'bilibiliDanmakuShadowScale',
      1.0,
      notify: false,
    );
    await _updateRegisteredSetting<double>(
      'bilibiliDanmakuLetterSpacing',
      0.0,
      notify: false,
    );
    await _updateRegisteredSetting<int>(
      'bilibiliDanmakuFontWeight',
      kDanmakuDefaultFontWeight,
      notify: false,
    );
    await _updateRegisteredSetting<String>(
      'bilibiliDanmakuOutlineType',
      DanmakuOutlineType.standard.name,
      notify: false,
    );
    notifyListeners();
  }

  Future<void> saveMirrorHorizontal(bool value) async {
    await _updateRegisteredSetting<bool>('isMirroredH', value);
  }

  Future<void> saveMirrorVertical(bool value) async {
    await _updateRegisteredSetting<bool>('isMirroredV', value);
  }

  Future<void> saveLongPressSpeed(double value) async {
    await _updateRegisteredSetting<double>('longPressSpeed', value);
  }

  Future<void> saveShowLongPressSpeedIndicator(bool value) async {
    await _updateRegisteredSetting<bool>('showLongPressSpeedIndicator', value);
  }

  Future<void> saveGlobalMute(bool value) async {
    await _updateRegisteredSetting<bool>('globalMute', value);
  }

  Future<void> saveDoubleTapSeekSeconds(int value) async {
    await _updateRegisteredSetting<int>('doubleTapSeekSeconds', value);
  }

  Future<void> saveEnableDoubleTapSubtitleSeek(bool value) async {
    await _updateRegisteredSetting<bool>('enableDoubleTapSubtitleSeek', value);
  }

  Future<void> saveSubtitleOffsetMilliseconds(int value) async {
    await updateSetting('subtitleOffset', value);
  }

  Future<void> saveUserSubtitleSidebarWidth(double value) async {
    await _updateRegisteredSetting<double>('userSubtitleSidebarWidth', value);
  }

  Future<void> saveUserAiSidebarWidth(double value) async {
    await _updateRegisteredSetting<double>('userAiSidebarWidth', value);
  }

  Future<void> saveAutoCacheSubtitles(bool value) async {
    await _updateRegisteredSetting<bool>('autoCacheSubtitles', value);
  }

  Future<void> saveSplitSubtitleByLine(bool value) async {
    await _updateRegisteredSetting<bool>('splitSubtitleByLine', value);
  }

  Future<void> saveAudioContinuousSubtitle(bool value) async {
    await _updateRegisteredSetting<bool>('audioContinuousSubtitle', value);
  }

  Future<void> saveVideoContinuousSubtitle(bool value) async {
    await _updateRegisteredSetting<bool>('videoContinuousSubtitle', value);
  }

  Future<void> saveAutoPauseOnExit(bool value) async {
    await _updateRegisteredSetting<bool>('autoPauseOnExit', value);
  }

  Future<void> saveAvoidPlaybackControlsWithSubtitles(bool value) async {
    await _updateRegisteredSetting<bool>(
      'avoidPlaybackControlsWithSubtitles',
      value,
    );
  }

  Future<void> savePausePlaybackWhenAppBackgrounded(bool value) async {
    await _updateRegisteredSetting<bool>(
      'pausePlaybackWhenAppBackgrounded',
      value,
    );
  }

  Future<void> saveAllowConcurrentPlayback(bool value) async {
    await _updateRegisteredSetting<bool>('allowConcurrentPlayback', value);
  }

  Future<void> saveUseHardwareVideoDecoding(bool value) async {
    await _updateRegisteredSetting<bool>('useHardwareVideoDecoding', value);
  }

  Future<void> saveEnableHeadsetMediaControls(bool value) async {
    await _updateRegisteredSetting<bool>('enableHeadsetMediaControls', value);
  }

  Future<void> saveAutoPlayOnPageEntry(bool value) async {
    await _updateRegisteredSetting<bool>('autoPlayOnPageEntry', value);
  }

  Future<void> saveAutoPlayNextVideo(bool value) async {
    await _updateRegisteredSetting<bool>('autoPlayNextVideo', value);
  }

  Future<void> saveSkipPortraitPlayer(bool value) async {
    await _updateRegisteredSetting<bool>('skipPortraitPlayer', value);
  }

  Future<void> saveEnableVideoPreload(bool value) async {
    await _updateRegisteredSetting<bool>('enableVideoPreload', value);
  }

  Future<void> saveAutoPlayOnCompletion(bool value) async {
    await _updateRegisteredSetting<bool>('autoPlayOnCompletion', value);
  }

  Future<void> saveAutoPlayOnCompletionFromStart(bool value) async {
    await _updateRegisteredSetting<bool>(
      'autoPlayOnCompletionFromStart',
      value,
    );
  }

  Future<void> savePlaylistWrapToFirst(bool value) async {
    await _updateRegisteredSetting<bool>('playlistWrapToFirst', value);
  }

  Future<void> saveEnableSeekPreview(bool value) async {
    await _updateRegisteredSetting<bool>('enableSeekPreview', value);
  }

  Future<void> saveExperimentalAmbientLetterbox(bool value) async {
    await _updateRegisteredSetting<bool>('experimentalAmbientLetterbox', value);
  }

  Future<void> saveEnableHapticFeedback(bool value) async {
    await _updateRegisteredSetting<bool>('enableHapticFeedback', value);
  }

  Future<void> saveLeftHandedMode(bool value) async {
    await _updateRegisteredSetting<bool>('isLeftHandedMode', value);
  }

  Future<void> saveGhostModeEnabled(bool value) async {
    await _updateRegisteredSetting<bool>('isGhostModeEnabled', value);
  }

  Future<void> saveLandscapeSubtitleSidebarVisible(
    bool value, {
    bool notify = true,
  }) async {
    await _updateRegisteredSetting<bool>(
      'landscapeSubtitleSidebarVisible',
      value,
      notify: notify,
    );
  }

  Future<void> saveShowSubtitleSidebarToggle(bool value) async {
    await _updateRegisteredSetting<bool>('showSubtitleSidebarToggle', value);
  }

  Future<void> saveBilibiliPlayerPanelOpen(bool value) async {
    await _updateRegisteredSetting<bool>('bilibiliPlayerPanelOpen', value);
  }

  Future<void> saveBilibiliPortraitShowsSubtitles(bool value) async {
    await _updateRegisteredSetting<bool>(
      'bilibiliPortraitShowsSubtitles',
      value,
    );
  }

  Future<void> saveBilibiliLandscapeShowsSubtitles(bool value) async {
    await _updateRegisteredSetting<bool>(
      'bilibiliLandscapeShowsSubtitles',
      value,
    );
  }

  bool isSamePlaybackSpeed(double first, double second) {
    return (first - second).abs() < 0.001;
  }

  bool isLockedPlaybackSpeed(double speed) {
    return isPlaybackSpeedLocked && isSamePlaybackSpeed(playbackSpeed, speed);
  }

  double get effectiveGlobalPlaybackSpeed {
    return isPlaybackSpeedLocked ? playbackSpeed : 1.0;
  }

  Future<void> savePlaybackSpeed(double speed) async {
    await setPlaybackSpeedLock(speed, isPlaybackSpeedLocked);
  }

  Future<void> _loadPlaybackSpeedLockState() async {
    final rawState = _prefs.getString(_playbackSpeedLockStateKey);
    if (rawState == null || rawState.isEmpty) return;
    try {
      final decoded = json.decode(rawState);
      if (decoded is! Map<String, dynamic>) return;
      final speedValue = decoded['speed'];
      final lockedValue = decoded['locked'];
      if (speedValue is! num || lockedValue is! bool) return;
      final speed = speedValue.toDouble();
      if (!speed.isFinite || speed <= 0) return;
      playbackSpeed = speed;
      isPlaybackSpeedLocked = lockedValue;
    } catch (error, stackTrace) {
      developer.log(
        'Invalid playback speed lock snapshot; using legacy settings',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Stores the speed and lock flag as one canonical snapshot.
  ///
  /// The legacy keys are still mirrored for compatibility, but startup reads
  /// the snapshot first so an interrupted write can never produce a mixed
  /// speed/lock pair.
  Future<void> setPlaybackSpeedLock(double speed, bool locked) async {
    if (!speed.isFinite || speed <= 0) {
      throw ArgumentError.value(speed, 'speed', 'Must be finite and positive');
    }

    final previousSpeed = playbackSpeed;
    final previousLocked = isPlaybackSpeedLocked;
    playbackSpeed = speed;
    isPlaybackSpeedLocked = locked;
    notifyListeners();

    final snapshot = json.encode({'speed': speed, 'locked': locked});
    try {
      final saved = await _prefs.setString(
        _playbackSpeedLockStateKey,
        snapshot,
      );
      if (!saved) {
        throw StateError('Unable to save playback speed lock snapshot');
      }
    } catch (_) {
      playbackSpeed = previousSpeed;
      isPlaybackSpeedLocked = previousLocked;
      notifyListeners();
      rethrow;
    }

    // These keys are compatibility mirrors only. The single snapshot above is
    // the source of truth and has already been committed successfully.
    await Future.wait([
      _prefs.setDouble('playbackSpeed', playbackSpeed),
      _prefs.setBool('isPlaybackSpeedLocked', isPlaybackSpeedLocked),
    ]);
  }

  Future<PlaybackSpeedLockAction> togglePlaybackSpeedLock(double speed) async {
    final bool wasLocked = isPlaybackSpeedLocked;
    final bool wasLockedAtSpeed = isLockedPlaybackSpeed(speed);

    await setPlaybackSpeedLock(speed, !wasLockedAtSpeed);

    if (wasLockedAtSpeed) {
      return PlaybackSpeedLockAction.unlocked;
    }
    if (wasLocked) {
      return PlaybackSpeedLockAction.switched;
    }
    return PlaybackSpeedLockAction.locked;
  }

  // ========== 新的字幕样式保存方法 ==========

  /// 保存视频字幕文字样式 - 同步到横竖屏
  Future<void> saveSubtitleTextStyle(SubtitleTextStyle style) async {
    subtitleTextStyle = style;
    notifyListeners();
    return _trackSettingsWrite(() async {
      await _prefs.setString('subtitleTextStyle', json.encode(style.toJson()));
      // 同时更新旧格式以保持兼容
      await _prefs.setString(
        'subtitleStyleLandscape',
        json.encode(subtitleStyleLandscape.toJson()),
      );
      await _prefs.setString(
        'subtitleStylePortrait',
        json.encode(subtitleStylePortrait.toJson()),
      );
      await _prefs.setString(
        'subtitleStyle',
        json.encode(subtitleStyleLandscape.toJson()),
      );
    }());
  }

  /// 保存音频字幕文字样式 - 同步到横竖屏
  Future<void> saveAudioSubtitleTextStyle(SubtitleTextStyle style) async {
    audioSubtitleTextStyle = style;
    notifyListeners();
    return _trackSettingsWrite(() async {
      await _prefs.setString(
        'audioSubtitleTextStyle',
        json.encode(style.toJson()),
      );
      // 同时更新旧格式以保持兼容
      await _prefs.setString(
        'audioSubtitleStyleLandscape',
        json.encode(audioSubtitleStyleLandscape.toJson()),
      );
      await _prefs.setString(
        'audioSubtitleStylePortrait',
        json.encode(audioSubtitleStylePortrait.toJson()),
      );
    }());
  }

  /// 保存横屏布局样式
  Future<void> saveSubtitleLayoutLandscape(SubtitleLayoutStyle style) async {
    subtitleLayoutLandscape = style;
    subtitleLayoutPortrait = style;
    notifyListeners();
    return _trackSettingsWrite(() async {
      await _prefs.setString(
        'subtitleLayoutLandscape',
        json.encode(style.toJson()),
      );
      await _prefs.setString(
        'subtitleLayoutPortrait',
        json.encode(style.toJson()),
      );
      await _prefs.setString(
        'subtitleStyleLandscape',
        json.encode(subtitleStyleLandscape.toJson()),
      );
      await _prefs.setString(
        'subtitleStylePortrait',
        json.encode(subtitleStylePortrait.toJson()),
      );
      await _prefs.setString(
        'subtitleStyle',
        json.encode(subtitleStyleLandscape.toJson()),
      );
    }());
  }

  /// 保存竖屏布局样式
  Future<void> saveSubtitleLayoutPortrait(SubtitleLayoutStyle style) async {
    subtitleLayoutPortrait = style;
    subtitleLayoutLandscape = style;
    notifyListeners();
    return _trackSettingsWrite(() async {
      await _prefs.setString(
        'subtitleLayoutPortrait',
        json.encode(style.toJson()),
      );
      await _prefs.setString(
        'subtitleLayoutLandscape',
        json.encode(style.toJson()),
      );
      await _prefs.setString(
        'subtitleStylePortrait',
        json.encode(subtitleStylePortrait.toJson()),
      );
      await _prefs.setString(
        'subtitleStyleLandscape',
        json.encode(subtitleStyleLandscape.toJson()),
      );
      await _prefs.setString(
        'subtitleStyle',
        json.encode(subtitleStyleLandscape.toJson()),
      );
    }());
  }

  /// 保存幽灵模式布局样式（横竖屏同步，但与普通布局完全独立）
  Future<void> saveSubtitleLayoutGhostLandscape(
    SubtitleLayoutStyle style,
  ) async {
    subtitleLayoutGhostLandscape = style;
    subtitleLayoutGhostPortrait = style;
    notifyListeners();
    return _trackSettingsWrite(() async {
      await _prefs.setString(
        'subtitleLayoutGhostLandscape',
        json.encode(style.toJson()),
      );
      await _prefs.setString(
        'subtitleLayoutGhostPortrait',
        json.encode(style.toJson()),
      );
    }());
  }

  Future<void> saveSubtitleLayoutGhostPortrait(
    SubtitleLayoutStyle style,
  ) async {
    subtitleLayoutGhostPortrait = style;
    subtitleLayoutGhostLandscape = style;
    notifyListeners();
    return _trackSettingsWrite(() async {
      await _prefs.setString(
        'subtitleLayoutGhostPortrait',
        json.encode(style.toJson()),
      );
      await _prefs.setString(
        'subtitleLayoutGhostLandscape',
        json.encode(style.toJson()),
      );
    }());
  }

  /// 保存音频横屏布局样式
  Future<void> saveAudioSubtitleLayoutLandscape(
    SubtitleLayoutStyle style,
  ) async {
    audioSubtitleLayoutLandscape = style;
    audioSubtitleLayoutPortrait = style;
    notifyListeners();
    return _trackSettingsWrite(() async {
      await _prefs.setString(
        'audioSubtitleLayoutLandscape',
        json.encode(style.toJson()),
      );
      await _prefs.setString(
        'audioSubtitleLayoutPortrait',
        json.encode(style.toJson()),
      );
      await _prefs.setString(
        'audioSubtitleStyleLandscape',
        json.encode(audioSubtitleStyleLandscape.toJson()),
      );
      await _prefs.setString(
        'audioSubtitleStylePortrait',
        json.encode(audioSubtitleStylePortrait.toJson()),
      );
    }());
  }

  /// 保存音频竖屏布局样式
  Future<void> saveAudioSubtitleLayoutPortrait(
    SubtitleLayoutStyle style,
  ) async {
    audioSubtitleLayoutPortrait = style;
    audioSubtitleLayoutLandscape = style;
    notifyListeners();
    return _trackSettingsWrite(() async {
      await _prefs.setString(
        'audioSubtitleLayoutPortrait',
        json.encode(style.toJson()),
      );
      await _prefs.setString(
        'audioSubtitleLayoutLandscape',
        json.encode(style.toJson()),
      );
      await _prefs.setString(
        'audioSubtitleStylePortrait',
        json.encode(audioSubtitleStylePortrait.toJson()),
      );
      await _prefs.setString(
        'audioSubtitleStyleLandscape',
        json.encode(audioSubtitleStyleLandscape.toJson()),
      );
    }());
  }

  // ========== 向后兼容的旧方法 ==========

  // Legacy saver (maps to landscape)
  Future<void> saveSubtitleStyle(SubtitleStyle style) async {
    await saveSubtitleStyleLandscape(style);
  }

  Future<void> saveSubtitleStyleLandscape(SubtitleStyle style) async {
    subtitleTextStyle = style.textStyle;
    subtitleLayoutLandscape = style.layoutStyle;
    subtitleLayoutPortrait = style.layoutStyle;
    notifyListeners();
    return _trackSettingsWrite(() async {
      await _prefs.setString(
        'subtitleTextStyle',
        json.encode(style.textStyle.toJson()),
      );
      await _prefs.setString(
        'subtitleLayoutLandscape',
        json.encode(style.layoutStyle.toJson()),
      );
      await _prefs.setString(
        'subtitleLayoutPortrait',
        json.encode(style.layoutStyle.toJson()),
      );
      await _prefs.setString(
        'subtitleStyleLandscape',
        json.encode(style.toJson()),
      );
      await _prefs.setString(
        'subtitleStylePortrait',
        json.encode(subtitleStylePortrait.toJson()),
      );
      await _prefs.setString('subtitleStyle', json.encode(style.toJson()));
    }());
  }

  Future<void> saveSubtitleStylePortrait(SubtitleStyle style) async {
    subtitleTextStyle = style.textStyle;
    subtitleLayoutPortrait = style.layoutStyle;
    subtitleLayoutLandscape = style.layoutStyle;
    notifyListeners();
    return _trackSettingsWrite(() async {
      await _prefs.setString(
        'subtitleLayoutPortrait',
        json.encode(style.layoutStyle.toJson()),
      );
      await _prefs.setString(
        'subtitleLayoutLandscape',
        json.encode(style.layoutStyle.toJson()),
      );
      await _prefs.setString(
        'subtitleTextStyle',
        json.encode(style.textStyle.toJson()),
      );
      await _prefs.setString(
        'subtitleStylePortrait',
        json.encode(subtitleStylePortrait.toJson()),
      );
      await _prefs.setString(
        'subtitleStyleLandscape',
        json.encode(subtitleStyleLandscape.toJson()),
      );
      await _prefs.setString(
        'subtitleStyle',
        json.encode(subtitleStyleLandscape.toJson()),
      );
    }());
  }

  // Audio Subtitle Style Savers
  Future<void> saveAudioSubtitleStyleLandscape(SubtitleStyle style) async {
    audioSubtitleTextStyle = style.textStyle;
    audioSubtitleLayoutLandscape = style.layoutStyle;
    audioSubtitleLayoutPortrait = style.layoutStyle;
    notifyListeners();
    return _trackSettingsWrite(() async {
      await _prefs.setString(
        'audioSubtitleTextStyle',
        json.encode(style.textStyle.toJson()),
      );
      await _prefs.setString(
        'audioSubtitleLayoutLandscape',
        json.encode(style.layoutStyle.toJson()),
      );
      await _prefs.setString(
        'audioSubtitleLayoutPortrait',
        json.encode(style.layoutStyle.toJson()),
      );
      await _prefs.setString(
        'audioSubtitleStyleLandscape',
        json.encode(style.toJson()),
      );
      await _prefs.setString(
        'audioSubtitleStylePortrait',
        json.encode(audioSubtitleStylePortrait.toJson()),
      );
    }());
  }

  Future<void> saveAudioSubtitleStylePortrait(SubtitleStyle style) async {
    audioSubtitleTextStyle = style.textStyle;
    audioSubtitleLayoutPortrait = style.layoutStyle;
    audioSubtitleLayoutLandscape = style.layoutStyle;
    notifyListeners();
    return _trackSettingsWrite(() async {
      await _prefs.setString(
        'audioSubtitleLayoutPortrait',
        json.encode(style.layoutStyle.toJson()),
      );
      await _prefs.setString(
        'audioSubtitleLayoutLandscape',
        json.encode(style.layoutStyle.toJson()),
      );
      await _prefs.setString(
        'audioSubtitleTextStyle',
        json.encode(style.textStyle.toJson()),
      );
      await _prefs.setString(
        'audioSubtitleStylePortrait',
        json.encode(audioSubtitleStylePortrait.toJson()),
      );
      await _prefs.setString(
        'audioSubtitleStyleLandscape',
        json.encode(audioSubtitleStyleLandscape.toJson()),
      );
    }());
  }

  Future<PositionCommitResult> saveSubtitleAlignment(Alignment align) {
    return _commitChannel(
      channel: SubtitlePositionChannel.video,
      align: align,
      read: () => subtitleAlignment,
      write: (Alignment value) => subtitleAlignment = value,
    );
  }

  Future<PositionCommitResult> saveAudioSubtitleAlignment(Alignment align) {
    return _commitChannel(
      channel: SubtitlePositionChannel.audio,
      align: align,
      read: () => audioSubtitleAlignment,
      write: (Alignment value) => audioSubtitleAlignment = value,
    );
  }

  Future<PositionCommitResult> commitPresetVideoPosition(
    String presetId,
    Alignment? alignment,
  ) {
    return _commitPreset(
      presetId: presetId,
      audio: false,
      alignment: alignment,
    );
  }

  Future<PositionCommitResult> commitPresetAudioPosition(
    String presetId,
    Alignment? alignment,
  ) {
    return _commitPreset(presetId: presetId, audio: true, alignment: alignment);
  }

  /// Clears this preset's video and audio position overrides together with a
  /// style reset. Other presets, original alignments and the ghost position
  /// stay as they are.
  Future<PositionCommitResult> clearPresetPositionOverrides(
    String presetId,
  ) async {
    final SubtitlePositionStore? store = _positionStore;
    if (store == null) return const PositionCommitResult.success(0);
    final PositionCommitResult result = await store.clearPreset(presetId);
    if (!result.ok) subtitlePositionSaveError = result.message;
    notifyListeners();
    return result;
  }

  Future<PositionCommitResult> _commitChannel({
    required SubtitlePositionChannel channel,
    required Alignment align,
    required Alignment Function() read,
    required void Function(Alignment value) write,
  }) async {
    final Alignment next = clampSubtitleAlignment(align);
    final Alignment previous = read();
    // Memory updates before the disk write so a new page sees the position
    // even while the serial queue is still flushing.
    if (next != previous) {
      write(next);
      notifyListeners();
    }
    final SubtitlePositionStore? store = _positionStore;
    if (store == null) return const PositionCommitResult.success(0);
    final PositionCommitResult result = await store.commitAlignment(
      channel: channel,
      alignment: next,
      current: previous,
    );
    if (!result.ok) {
      subtitlePositionSaveError = result.message;
      developer.log(
        'Subtitle alignment save failed: ${result.message}',
        name: 'subtitle_position',
        level: 900,
      );
    }
    return result;
  }

  Future<PositionCommitResult> _commitPreset({
    required String presetId,
    required bool audio,
    required Alignment? alignment,
  }) async {
    final SubtitlePositionStore? store = _positionStore;
    if (store == null) return const PositionCommitResult.success(0);
    final PositionCommitResult result = await store.commitPreset(
      presetId: presetId,
      audio: audio,
      alignment: alignment,
    );
    if (!result.ok) subtitlePositionSaveError = result.message;
    notifyListeners();
    return result;
  }

  Future<void> setAudioSubtitleStyleSyncWithVideo(bool value) async {
    syncAudioSubtitleStyleWithVideo = value;
    return _trackSettingsWrite(() async {
      await _prefs.setBool('syncAudioSubtitleStyleWithVideo', value);
      notifyListeners();
    }());
  }

  Future<PositionCommitResult> saveGhostModeAlignment(Alignment align) {
    return _commitChannel(
      channel: SubtitlePositionChannel.ghost,
      align: align,
      read: () => ghostModeAlignment,
      write: (Alignment value) => ghostModeAlignment = value,
    );
  }

  Future<void> saveSubtitlePresets(List<Map<String, double>> presets) async {
    subtitlePresets = presets;
    return _trackSettingsWrite(() async {
      await _prefs.setString('subtitlePresets', json.encode(presets));
      notifyListeners();
    }());
  }

  /// Scope of the reversible subtitle trial. Account, model, media-library and
  /// per-video data never participate in this transaction.
  static const defaultTrialPreferenceKeys = <String>{
    'showSubtitles',
    'syncAudioSubtitleStyleWithVideo',
    'isGhostModeEnabled',
    'avoidPlaybackControlsWithSubtitles',
    'subtitleOffset',
    'subtitlePresets',
    'subtitleTextStyle',
    'subtitleLayoutLandscape',
    'subtitleLayoutPortrait',
    'subtitleLayoutGhostLandscape',
    'subtitleLayoutGhostPortrait',
    'audioSubtitleTextStyle',
    'audioSubtitleLayoutLandscape',
    'audioSubtitleLayoutPortrait',
    'subtitleStyle',
    'subtitleStyleLandscape',
    'subtitleStylePortrait',
    'audioSubtitleStyleLandscape',
    'audioSubtitleStylePortrait',
    _subtitleAlignmentJsonKey,
    _audioSubtitleAlignmentJsonKey,
    _ghostModeAlignmentJsonKey,
    'subtitleAlignX',
    'subtitleAlignY',
    'audioSubtitleAlignX',
    'audioSubtitleAlignY',
    'ghostModeAlignX',
    'ghostModeAlignY',
    kSubtitlePositionOverridesKey,
    SubtitleDebugSession.storageKey,
    _ghostLayoutCompatibilityVersionKey,
    _textMetricCompatibilityVersionKey,
    'ghostSubtitleFontSize',
    'ghostSubtitleLetterSpacing',
  };

  Future<void> _flushDefaultTrialWrites() async {
    while (_pendingSettingsWrites.isNotEmpty) {
      await Future.wait(List<Future<dynamic>>.of(_pendingSettingsWrites));
    }
    final positions = await flushSubtitlePositions();
    if (!positions.ok) throw StateError('字幕位置尚未保存，原设置未被替换');
    await SubtitleDebugSession.instance.flush();
    if (SubtitleDebugSession.instance.saveError != null) {
      throw StateError('字幕预设尚未保存，原设置未被替换');
    }
  }

  Map<String, dynamic> _floatingSubtitleRuntime() => {
    'subtitles': _subtitleSettingsSnapshot(includePresetCatalog: false),
    'avoidPlaybackControlsWithSubtitles': avoidPlaybackControlsWithSubtitles,
    'presetNavigation': {
      'category': SubtitleDebugSession.instance.browserCategory,
      'query': SubtitleDebugSession.instance.browserQuery,
      'offset': SubtitleDebugSession.instance.browserOffset,
    },
  };

  Future<Map<String, dynamic>> _captureDefaultTrialBackup() async {
    await _flushDefaultTrialWrites();
    await featureSettingsForTrial.flush();
    await _prefs.reload();
    final mixed = RecommendedAppDefaults.mixedPreferenceFields;
    final scope = defaultAppTrialPreferenceKeys.difference(mixed.keys.toSet());
    final features = await featureSettingsForTrial.capture();
    return Map<String, dynamic>.from(
      json.decode(
            json.encode({
              'version': 2,
              'device': {
                'platform': defaultTrialDevice.platform.name,
                'width': defaultTrialDevice.size.width,
                'height': defaultTrialDevice.size.height,
              },
              'preferenceKeys': scope.toList(),
              'preferences': {for (final key in scope) key: _prefs.get(key)},
              'jsonPreferences': {
                for (final entry in mixed.entries)
                  entry.key: TrialFieldMask.capture(
                    _trialJsonPreference(entry.key),
                    entry.value,
                  ),
              },
              'features': features,
              'runtime': _floatingSubtitleRuntime(),
            }),
          )
          as Map,
    );
  }

  Map<String, dynamic> _trialJsonPreference(String key) {
    final raw = _prefs.getString(key);
    if (raw == null) return {};
    final decoded = json.decode(raw);
    if (decoded is! Map) throw FormatException('设置无法完整备份：$key');
    return Map<String, dynamic>.from(decoded);
  }

  /// Check every write and its read-back. A failed or interrupted transaction
  /// leaves the immutable original journal available for another restore.
  Future<void> _writeDefaultTrialPreferences(
    Map<String, dynamic> values,
  ) async {
    if (!defaultAppTrialPreferenceKeys.containsAll(values.keys)) {
      throw const FormatException('试用设置备份包含未知字段，已保留备份');
    }
    for (final entry in values.entries) {
      final value = entry.value;
      if (value != null &&
          value is! String &&
          value is! bool &&
          value is! int &&
          value is! double) {
        throw const FormatException('试用设置备份格式不受支持，已保留备份');
      }
    }
    final backend = SharedPreferencesStorePlatform.instance;
    if (backend is SharedPreferencesWindows) {
      // This app uses SharedPreferences' standard flutter. prefix. Commit the
      // entire scoped change once, then reload its public cache for read-back.
      // Each per-key Windows write otherwise rewrites the whole (potentially
      // tens of MB) preference file, including unrelated histories and tasks.
      final saved = await backend.setValues({
        for (final entry in values.entries) 'flutter.${entry.key}': entry.value,
      });
      if (!saved) throw StateError('设置写入失败，原设置备份仍保留');
      await _prefs.reload();
      for (final entry in values.entries) {
        if (_prefs.get(entry.key) != entry.value) {
          throw StateError('设置校验失败，原设置备份仍保留：${entry.key}');
        }
      }
      return;
    }
    for (final entry in values.entries) {
      final key = entry.key, value = entry.value;
      bool saved;
      if (value == null) {
        saved = !_prefs.containsKey(key) || await _prefs.remove(key);
      } else if (value is String) {
        saved = await _prefs.setString(key, value);
      } else if (value is bool) {
        saved = await _prefs.setBool(key, value);
      } else if (value is int) {
        saved = await _prefs.setInt(key, value);
      } else {
        saved = await _prefs.setDouble(key, value as double);
      }
      if (!saved || _prefs.get(key) != value) {
        throw StateError('设置写入失败，原设置备份仍保留：$key');
      }
    }
  }

  Future<void> _applyRecommendedSubtitleSettings() async {
    await _flushDefaultTrialWrites();
    await featureSettingsForTrial.flush();
    final core = <String, dynamic>{
      ...registeredDefaultPreferences,
      ...RecommendedAppDefaults.coreOverrides(defaultTrialDevice),
      for (final key in RecommendedAppDefaults.responsiveLegacyKeys) key: null,
      for (final key in mediaLibraryLayoutExportKeys) key: null,
      ...RecommendedAppDefaults.preferences(defaultTrialDevice),
      'landscapeSidebarFontSizeScale': 1.0,
      'sidebarFontSizeScale': null,
      'audioPortraitDisplayAspectRatio': null,
      'audioPortraitCustomAspectWidth': null,
      'audioPortraitCustomAspectHeight': null,
      _playbackSpeedLockStateKey: json.encode({'speed': 1.0, 'locked': false}),
      'subtitleOffset': 0,
      'subtitlePresets': json.encode([
        {'x': 0.0, 'y': .82},
        {'x': 0.0, 'y': 0.0},
        {'x': 0.0, 'y': -.82},
      ]),
      for (final entry in RecommendedAppDefaults.mixedValues(
        defaultTrialDevice,
      ).entries)
        entry.key: json.encode({
          ..._trialJsonPreference(entry.key),
          ...entry.value,
        }),
    };
    final runtime = _floatingSubtitleRuntime();
    final subtitles = Map<String, dynamic>.from(runtime['subtitles'] as Map);
    final mode = Map<String, dynamic>.from(subtitles['presetMode'] as Map)
      ..['enabled'] = false
      ..['catalogVisible'] = false
      ..['selectedId'] = null
      ..['custom'] = <String, dynamic>{}
      ..['ghostTextScales'] = {
        for (final preset in subtitleDebugPresets) preset.id: preset.textScale,
      };
    final text = RecommendedSubtitleDefaults.textStyle;
    final layout = RecommendedSubtitleDefaults.layout;
    final style = SubtitleStyle(textStyle: text, layoutStyle: layout);
    final ordinary = RecommendedSubtitleDefaults.ordinaryAlignment;
    final ghost = RecommendedSubtitleDefaults.ghostAlignment;
    final audio = RecommendedSubtitleDefaults.audioAlignment;
    Map<String, double> alignment(Alignment value) => {
      'x': value.x,
      'y': value.y,
    };
    subtitles.addAll({
      'showSubtitles': true,
      'syncAudioSubtitleStyleWithVideo': true,
      'isGhostModeEnabled': true,
      'textStyle': text.toJson(),
      'audioTextStyle': text.toJson(),
      'layoutLandscape': layout.toJson(),
      'layoutPortrait': layout.toJson(),
      'ghostLayoutLandscape': layout.toJson(),
      'ghostLayoutPortrait': layout.toJson(),
      'audioLayoutLandscape': layout.toJson(),
      'audioLayoutPortrait': layout.toJson(),
      'alignment': alignment(ordinary),
      'audioAlignment': alignment(audio),
      'ghostAlignment': alignment(ghost),
      'presetMode': mode,
      'subtitleDelayMs': 0,
      'subtitleDelaySeconds': 0.0,
      'presets': [
        {'x': 0.0, 'y': .82},
        {'x': 0.0, 'y': 0.0},
        {'x': 0.0, 'y': -.82},
      ],
    });
    runtime['subtitles'] = subtitles;
    runtime['avoidPlaybackControlsWithSubtitles'] = true;
    await _writeDefaultTrialPreferences({
      ...core,
      'showSubtitles': true,
      'syncAudioSubtitleStyleWithVideo': true,
      'isGhostModeEnabled': true,
      'avoidPlaybackControlsWithSubtitles': true,
      'subtitleTextStyle': json.encode(text.toJson()),
      'audioSubtitleTextStyle': json.encode(text.toJson()),
      for (final key in [
        'subtitleLayoutLandscape',
        'subtitleLayoutPortrait',
        'subtitleLayoutGhostLandscape',
        'subtitleLayoutGhostPortrait',
        'audioSubtitleLayoutLandscape',
        'audioSubtitleLayoutPortrait',
      ])
        key: json.encode(layout.toJson()),
      for (final key in [
        'subtitleStyle',
        'subtitleStyleLandscape',
        'subtitleStylePortrait',
        'audioSubtitleStyleLandscape',
        'audioSubtitleStylePortrait',
      ])
        key: json.encode(style.toJson()),
      _subtitleAlignmentJsonKey: json.encode(alignment(ordinary)),
      _audioSubtitleAlignmentJsonKey: json.encode(alignment(audio)),
      _ghostModeAlignmentJsonKey: json.encode(alignment(ghost)),
      'subtitleAlignX': ordinary.x,
      'subtitleAlignY': ordinary.y,
      'audioSubtitleAlignX': audio.x,
      'audioSubtitleAlignY': audio.y,
      'ghostModeAlignX': ghost.x,
      'ghostModeAlignY': ghost.y,
      SubtitleDebugSession.storageKey: json.encode({
        'enabled': false,
        'catalogVisible': false,
        'selectedId': null,
        'custom': mode['custom'],
        'ghostTextScales': mode['ghostTextScales'],
      }),
    });
    await featureSettingsForTrial.apply(defaultTrialDevice);
    await _loadCoreTrialRuntime();
    _applyFloatingSubtitleRuntime(runtime);
    await featureSettingsForTrial.reloadRuntime();
  }

  Future<void> _loadCoreTrialRuntime() async {
    await _loadRegisteredSettings();
    await _loadPlaybackSpeedLockState();
    landscapeSidebarFontSizeScale =
        _prefs.getDouble('landscapeSidebarFontSizeScale') ??
        _prefs.getDouble('sidebarFontSizeScale') ??
        1;
    audioPortraitDisplayAspectRatio = _prefs.getDouble(
      'audioPortraitDisplayAspectRatio',
    );
    audioPortraitCustomAspectWidth = _prefs.getDouble(
      'audioPortraitCustomAspectWidth',
    );
    audioPortraitCustomAspectHeight = _prefs.getDouble(
      'audioPortraitCustomAspectHeight',
    );
  }

  Future<void> _restoreDefaultTrialBackup(Map<String, dynamic> backup) async {
    if ((backup['version'] != 1 && backup['version'] != 2) ||
        backup['preferences'] is! Map ||
        backup['runtime'] is! Map) {
      throw const FormatException('原设置备份版本无法读取，已保留备份');
    }
    final preferences = Map<String, dynamic>.from(backup['preferences'] as Map);
    final scope = backup['version'] == 1
        ? defaultTrialPreferenceKeys
        : (backup['preferenceKeys'] as List).cast<String>().toSet();
    if (preferences.length != scope.length ||
        !preferences.keys.toSet().containsAll(scope) ||
        !defaultAppTrialPreferenceKeys.containsAll(scope)) {
      throw const FormatException('原设置备份不完整，已保留备份');
    }
    if (_initialized) await _flushDefaultTrialWrites();
    // Discard any speculative cache left by a failed platform write before
    // merging the safe fields with current credentials and browser history.
    await _prefs.reload();
    if (backup['version'] == 2) {
      await featureSettingsForTrial.flush();
      final mixed = Map<String, dynamic>.from(backup['jsonPreferences'] as Map);
      if (mixed.length != RecommendedAppDefaults.mixedPreferenceFields.length) {
        throw const FormatException('混合设置备份不完整，已保留原备份');
      }
      for (final entry
          in RecommendedAppDefaults.mixedPreferenceFields.entries) {
        final restored = TrialFieldMask.restore(
          _trialJsonPreference(entry.key),
          Map<String, dynamic>.from(mixed[entry.key] as Map),
          entry.value,
        );
        preferences[entry.key] = restored.isEmpty
            ? null
            : json.encode(restored);
      }
    }
    // SharedPreferences updates its cache before a platform write completes.
    // Reload after a failed attempt so an absent cached key cannot hide a
    // still-persisted trial value during the next restoration attempt.
    await _writeDefaultTrialPreferences(preferences);
    if (backup['version'] == 2) {
      await featureSettingsForTrial.restore(
        Map<String, dynamic>.from(backup['features'] as Map),
      );
    }
    if (_initialized) {
      if (backup['version'] == 2) await _loadCoreTrialRuntime();
      _applyFloatingSubtitleRuntime(
        Map<String, dynamic>.from(backup['runtime'] as Map),
      );
    } else {
      // Preserve effective values that originally had no persisted key too.
      // Apply after the normal cold-start loaders, which may migrate defaults.
      _restoredDefaultTrialRuntime = Map<String, dynamic>.from(
        backup['runtime'] as Map,
      );
    }
    if (backup['version'] == 2) await featureSettingsForTrial.reloadRuntime();
  }

  void _applyFloatingSubtitleRuntime(Map<String, dynamic> runtime) {
    final subtitles = Map<String, dynamic>.from(runtime['subtitles'] as Map);
    Map<String, dynamic> map(String key) =>
        Map<String, dynamic>.from(subtitles[key] as Map);
    Alignment alignment(String key) {
      final value = map(key);
      return Alignment(
        (value['x'] as num).toDouble(),
        (value['y'] as num).toDouble(),
      );
    }

    subtitleTextStyle = SubtitleTextStyle.fromJson(map('textStyle'));
    audioSubtitleTextStyle = SubtitleTextStyle.fromJson(map('audioTextStyle'));
    subtitleLayoutLandscape = SubtitleLayoutStyle.fromJson(
      map('layoutLandscape'),
    );
    subtitleLayoutPortrait = SubtitleLayoutStyle.fromJson(
      map('layoutPortrait'),
    );
    subtitleLayoutGhostLandscape = SubtitleLayoutStyle.fromJson(
      map('ghostLayoutLandscape'),
    );
    subtitleLayoutGhostPortrait = SubtitleLayoutStyle.fromJson(
      map('ghostLayoutPortrait'),
    );
    audioSubtitleLayoutLandscape = SubtitleLayoutStyle.fromJson(
      map('audioLayoutLandscape'),
    );
    audioSubtitleLayoutPortrait = SubtitleLayoutStyle.fromJson(
      map('audioLayoutPortrait'),
    );
    showSubtitles = subtitles['showSubtitles'] as bool;
    syncAudioSubtitleStyleWithVideo =
        subtitles['syncAudioSubtitleStyleWithVideo'] as bool;
    isGhostModeEnabled = subtitles['isGhostModeEnabled'] as bool;
    avoidPlaybackControlsWithSubtitles =
        runtime['avoidPlaybackControlsWithSubtitles'] as bool;
    subtitleAlignment = alignment('alignment');
    audioSubtitleAlignment = alignment('audioAlignment');
    ghostModeAlignment = alignment('ghostAlignment');
    subtitleOffset = Duration(
      milliseconds: subtitles['subtitleDelayMs'] as int,
    );
    subtitlePresets = (subtitles['presets'] as List)
        .map(
          (value) => (value as Map).map(
            (key, number) =>
                MapEntry(key as String, (number as num).toDouble()),
          ),
        )
        .toList();
    _attachPositionStore();
    final session = SubtitleDebugSession.instance;
    session.applySettingsSnapshot(map('presetMode'));
    if (runtime['presetNavigation'] case final Map navigation) {
      session.browserCategory = navigation['category'] as String;
      session.browserQuery = navigation['query'] as String;
      session.browserOffset = (navigation['offset'] as num).toDouble();
    }
    notifyListeners();
  }

  /// Device-independent preferences only. Keep the explicit exclusions next to
  /// the export: the coverage test checks every registered setting against it.
  static const settingsExportExclusions = <String, String>{
    'lastSelectedModelType': 'Transcription model selection',
    'developerMode': 'Development controls',
    'mediaLibraryRootEntry': 'Last visited library page',
    'mediaLibraryRootEntryUserChosen': 'Navigation history marker',
    'mediaLibraryLastFolderId': 'Local library folder identity',
    'mediaLibraryLastFolderIncludeDescendants': 'Last visited folder state',
    'mediaLibraryEntryAnchors': 'Per-page scroll and expansion history',
    'importSourceFolderIds': 'Local library folder identities',
    'bilibiliImportTarget': 'Legacy local library folder target',
    'portraitCustomAspectDraftWidthText': 'Per-video aspect-ratio input draft',
    'portraitCustomAspectDraftHeightText': 'Per-video aspect-ratio input draft',
    'batchSubtitleCustomOutputDir': 'Machine-specific output directory',
  };

  /// Null slots mean that responsive defaults still apply. Do not resolve an
  /// unset slot to an arbitrary phone/tablet size and silently freeze it.
  static const mediaLibraryLayoutExportKeys = <String>[
    'homeGridCrossAxisCountPortrait',
    'homeGridCrossAxisCountLandscape',
    'homeCardTitleFontSizePortrait',
    'homeCardTitleFontSizeLandscape',
    'homeCardAspectRatioPortrait',
    'homeCardAspectRatioLandscape',
    'homeCardCrossSpacingScalePortrait',
    'homeCardCrossSpacingScaleLandscape',
    'homeCardMainSpacingScalePortrait',
    'homeCardMainSpacingScaleLandscape',
    'mediaListCrossAxisCountPortrait',
    'mediaListCrossAxisCountLandscape',
    'mediaListTitleScalePortrait',
    'mediaListTitleScaleLandscape',
    'mediaListItemHeightScalePortrait',
    'mediaListItemHeightScaleLandscape',
    'mediaListCrossSpacingScalePortrait',
    'mediaListCrossSpacingScaleLandscape',
    'mediaListMainSpacingScalePortrait',
    'mediaListMainSpacingScaleLandscape',
    'mediaListShowThumbnailPortrait',
    'mediaListShowThumbnailLandscape',
    'mediaListShowIndexPortrait',
    'mediaListShowIndexLandscape',
    'mediaListRowsColumnsPortrait',
    'mediaListRowsColumnsLandscape',
    'mediaListRowsExtentPortrait',
    'mediaListRowsExtentLandscape',
    'mediaListRowsTitleSizePortrait',
    'mediaListRowsTitleSizeLandscape',
    'mediaListRowsTitleLinesPortrait',
    'mediaListRowsTitleLinesLandscape',
    'mediaListRowsCrossSpacingPortrait',
    'mediaListRowsCrossSpacingLandscape',
    'mediaListRowsMainSpacingPortrait',
    'mediaListRowsMainSpacingLandscape',
    'mediaListRowsOuterPaddingPortrait',
    'mediaListRowsOuterPaddingLandscape',
    'mediaListRowsShowThumbnailPortrait',
    'mediaListRowsShowThumbnailLandscape',
    'mediaListRowsShowIndexPortrait',
    'mediaListRowsShowIndexLandscape',
    'mediaListRowsShowMetaPortrait',
    'mediaListRowsShowMetaLandscape',
    'mediaListRowsShowProgressPortrait',
    'mediaListRowsShowProgressLandscape',
    'mediaListRowsCardSurfacePortrait',
    'mediaListRowsCardSurfaceLandscape',
    'mediaListTableExtentPortrait',
    'mediaListTableExtentLandscape',
    'mediaListTableTitleSizePortrait',
    'mediaListTableTitleSizeLandscape',
    'mediaListTableOuterPaddingPortrait',
    'mediaListTableOuterPaddingLandscape',
    'mediaListTableShowThumbnailPortrait',
    'mediaListTableShowThumbnailLandscape',
    'mediaListTableShowIndexPortrait',
    'mediaListTableShowIndexLandscape',
    'mediaListTableStripedPortrait',
    'mediaListTableStripedLandscape',
    'mediaListTableColumnsPortrait',
    'mediaListTableColumnsLandscape',
  ];

  Map<String, dynamic> _subtitleSettingsSnapshot({
    bool includePresetCatalog = true,
  }) => {
    'showSubtitles': showSubtitles,
    'autoCacheSubtitles': autoCacheSubtitles,
    'autoScrollSubtitles': autoScrollSubtitles,
    'subtitleEditorAutoFollow': subtitleEditorAutoFollow,
    'autoLoadEmbeddedSubtitles': autoLoadEmbeddedSubtitles,
    'splitSubtitleByLine': splitSubtitleByLine,
    'videoContinuousSubtitle': videoContinuousSubtitle,
    'audioContinuousSubtitle': audioContinuousSubtitle,
    'syncAudioSubtitleStyleWithVideo': syncAudioSubtitleStyleWithVideo,
    'isGhostModeEnabled': isGhostModeEnabled,
    'subtitleDelayMs': subtitleOffset.inMilliseconds,
    'subtitleDelaySeconds': subtitleDelay,
    'alignment': {'x': subtitleAlignment.x, 'y': subtitleAlignment.y},
    'audioAlignment': {
      'x': audioSubtitleAlignment.x,
      'y': audioSubtitleAlignment.y,
    },
    'ghostAlignment': {'x': ghostModeAlignment.x, 'y': ghostModeAlignment.y},
    'presetPositionOverrides': _positionStore?.exportOverrides(),
    'presets': subtitlePresets,
    'textStyle': subtitleTextStyle.toJson(),
    'layoutLandscape': subtitleLayoutLandscape.toJson(),
    'layoutPortrait': subtitleLayoutPortrait.toJson(),
    'ghostLayoutLandscape': subtitleLayoutGhostLandscape.toJson(),
    'ghostLayoutPortrait': subtitleLayoutGhostPortrait.toJson(),
    'audioTextStyle': audioSubtitleTextStyle.toJson(),
    'audioLayoutLandscape': audioSubtitleLayoutLandscape.toJson(),
    'audioLayoutPortrait': audioSubtitleLayoutPortrait.toJson(),
    'presetMode': SubtitleDebugSession.instance.exportSettingsSnapshot(
      includeCatalog: includePresetCatalog,
    ),
    'legacy': {
      'subtitleStyleLandscape': subtitleStyleLandscape.toJson(),
      'subtitleStylePortrait': subtitleStylePortrait.toJson(),
      'audioSubtitleStyleLandscape': audioSubtitleStyleLandscape.toJson(),
      'audioSubtitleStylePortrait': audioSubtitleStylePortrait.toJson(),
    },
  };

  Map<String, dynamic> exportSettingsSnapshot({Size? viewportSize}) {
    return {
      'general': {
        'processingScreenProtection': processingScreenProtection,
        'processingScreenProtectionWaitSeconds':
            processingScreenProtectionWaitSeconds,
        'isLeftHandedMode': isLeftHandedMode,
        'isMirroredH': isMirroredH,
        'isMirroredV': isMirroredV,
      },
      'playback': {
        'playbackSpeed': playbackSpeed,
        'isPlaybackSpeedLocked': isPlaybackSpeedLocked,
        'globalMute': globalMute,
        'longPressSpeed': longPressSpeed,
        'showLongPressSpeedIndicator': showLongPressSpeedIndicator,
        'doubleTapSeekSeconds': doubleTapSeekSeconds,
        'enableDoubleTapSubtitleSeek': enableDoubleTapSubtitleSeek,
        'autoPauseOnExit': autoPauseOnExit,
        'skipPortraitPlayer': skipPortraitPlayer,
        'avoidPlaybackControlsWithSubtitles':
            avoidPlaybackControlsWithSubtitles,
        'pausePlaybackWhenAppBackgrounded': pausePlaybackWhenAppBackgrounded,
        'allowConcurrentPlayback': allowConcurrentPlayback,
        'useHardwareVideoDecoding': useHardwareVideoDecoding,
        'enableHeadsetMediaControls': enableHeadsetMediaControls,
        'autoPlayOnPageEntry': autoPlayOnPageEntry,
        'autoPlayNextVideo': autoPlayNextVideo,
        'enableVideoPreload': enableVideoPreload,
        'autoPlayOnCompletion': autoPlayOnCompletion,
        'autoPlayOnCompletionFromStart': autoPlayOnCompletionFromStart,
        'playlistWrapToFirst': playlistWrapToFirst,
        'enableSeekPreview': enableSeekPreview,
        'experimentalAmbientLetterbox': experimentalAmbientLetterbox,
        'enableHapticFeedback': enableHapticFeedback,
        'isActionButtonsCollapsed': isActionButtonsCollapsed,
      },
      'layout': {
        'showActionButtonLabels': showActionButtonLabels,
        'localImportFilterMediaExtensions': localImportFilterMediaExtensions,
        'userSubtitleSidebarWidth': userSubtitleSidebarWidth,
        'userAiSidebarWidth': userAiSidebarWidth,
        'landscapeSubtitleSidebarVisible': isLandscapeSubtitleSidebarVisible,
        'showSubtitleSidebarToggle': showSubtitleSidebarToggle,
        'bilibiliPlayerPanelOpen': bilibiliPlayerPanelOpen,
        'bilibiliPortraitShowsSubtitles': bilibiliPortraitShowsSubtitles,
        'bilibiliLandscapeShowsSubtitles': bilibiliLandscapeShowsSubtitles,
        'landscapeSidebarFontSizeScale': landscapeSidebarFontSizeScale,
        'portraitSidebarFontSizeScale': portraitSidebarFontSizeScale,
        'landscapeSidebarShowTimestamps': landscapeSidebarShowTimestamps,
        'portraitSidebarShowTimestamps': portraitSidebarShowTimestamps,
        'landscapeSidebarTimeColumnRatio': landscapeSidebarTimeColumnRatio,
        'portraitSidebarTimeColumnRatio': portraitSidebarTimeColumnRatio,
        'landscapeSidebarLocatePositionPercent':
            landscapeSidebarLocatePositionPercent,
        'portraitSidebarLocatePositionPercent':
            portraitSidebarLocatePositionPercent,
        'subtitleArticleSentencesPerParagraph':
            subtitleArticleSentencesPerParagraph,
        'subtitleArticleParagraphModeEnabled':
            subtitleArticleParagraphModeEnabled,
        'subtitleViewMode': subtitleViewMode,
        'subtitleCopyFormat': subtitleCopyFormat.toJson(),
        'mediaLibraryOrientationOverrides': {
          for (final key in mediaLibraryLayoutExportKeys)
            key: _hasPref(key) ? _prefs.get(key) : null,
        },
        if (viewportSize != null)
          'effectiveMediaLibraryProfiles': {
            'portrait': _exportLibraryLayout(
              Size(viewportSize.shortestSide, viewportSize.longestSide),
            ),
            'landscape': _exportLibraryLayout(
              Size(viewportSize.longestSide, viewportSize.shortestSide),
            ),
          },
      },
      'home': {
        'homeGridCrossAxisCount': homeGridCrossAxisCount,
        'homeCardTitleFontSize': homeCardTitleFontSize,
        'homeCardAspectRatio': homeCardAspectRatio,
        'mediaLibraryViewMode': mediaLibraryViewMode,
        'mediaTableSortKey': mediaTableSortKey,
        'mediaTableSortDescending': mediaTableSortDescending,
        'mediaTreeContentMode': mediaTreeContentMode,
        'mediaTreeSidebarWidth': mediaTreeSidebarWidth,
        'mediaTreeShowCounts': mediaTreeShowCounts,
        'mediaTreeSidebarCollapsed': mediaTreeSidebarCollapsed,
        'mediaLibraryRootEntryOrder': mediaLibraryRootEntryOrder,
        'mediaLibraryRestoreLastPage': mediaLibraryRestoreLastPage,
        'mediaLibraryReadableCardDefaults': mediaLibraryReadableCardDefaults,
        'mediaLibraryStartupEntry': mediaLibraryStartupEntry,
        'mediaLibraryContinueSeriousOnly': mediaLibraryContinueSeriousOnly,
        'mediaLibraryContinuePolicy': continueWatchPolicy.toJson(),
        'mediaListCrossAxisCount': mediaListCrossAxisCount,
        'mediaListShowThumbnail': mediaListShowThumbnail,
        'mediaListShowIndex': mediaListShowIndex,
        'mediaListItemHeightScale': mediaListItemHeightScale,
        'mediaListMainSpacingScale': mediaListMainSpacingScale,
        'mediaListCrossSpacingScale': mediaListCrossSpacingScale,
        'mediaListTitleScale': mediaListTitleScale,
        'mediaListCoverOffset': mediaListCoverOffset,
        'folderPlaceholderSettings': folderPlaceholderSettings.toJson(),
        'copyImportedMediaToPrivateStorage': copyImportedMediaToPrivateStorage,
        'importCardPlacement': importCardPlacement,
        ImportPlacementRules.settingsKey: {
          'version': 1,
          'overrides': {
            for (final entry in importPlacementRules.overrides.entries)
              entry.key: {'placement': entry.value.placement.storageValue},
          },
        },
        'importSourceFolderNames': importSourceFolderNames,
        'useSearchResultsAsPlaybackQueue': useSearchResultsAsPlaybackQueue,
        'bilibiliBackgroundAudioOnly': bilibiliBackgroundAudioOnly,
        'skipRepeatedClipboardText': skipRepeatedClipboardText,
        'clipboardLinkDetectionEnabled': clipboardLinkDetectionEnabled,
        'showMiniPlaybackCard': showMiniPlaybackCard,
        'showSystemMediaNotification': showSystemMediaNotification,
        'desktopSystemMediaControls': desktopSystemMediaControls,
        'desktopTaskbarMediaControls': desktopTaskbarMediaControls,
        'desktopGlobalMediaHotkeys': desktopGlobalMediaHotkeys,
        'desktopMediaHotkeyModifiers': desktopMediaHotkeyModifiers,
        'bilibiliRecordSearchHistory': bilibiliRecordSearchHistory,
        'bilibiliRecordWatchHistory': bilibiliRecordWatchHistory,
        'bilibiliAutoImportOnPlay': bilibiliAutoImportOnPlay,
        'bilibiliCacheLimitBytes': bilibiliCacheLimitBytes,
        'suppressBilibiliRestrictedDialog': suppressBilibiliRestrictedDialog,
        'structuredImportSortField': structuredImportSortField,
        'structuredImportSortDirection': structuredImportSortDirection,
      },
      'videoCard': {
        'videoCardCrossAxisCount': videoCardCrossAxisCount,
        'videoCardTitleFontSize': videoCardTitleFontSize,
        'videoCardAspectRatio': videoCardAspectRatio,
      },
      'danmaku': {
        'showBilibiliDanmaku': showBilibiliDanmaku,
        'bilibiliDanmakuOnlyInVideoArea': bilibiliDanmakuOnlyInVideoArea,
        'bilibiliDanmakuDisplayArea': bilibiliDanmakuDisplayArea,
        'bilibiliDanmakuOpacity': bilibiliDanmakuOpacity,
        'bilibiliDanmakuFontScale': bilibiliDanmakuFontScale,
        'bilibiliDanmakuReadableFontDefaults':
            bilibiliDanmakuReadableFontDefaults,
        'bilibiliDanmakuSpeed': bilibiliDanmakuSpeed,
        'bilibiliDanmakuDensity': bilibiliDanmakuDensity,
        'bilibiliDanmakuPortraitDisplayArea':
            bilibiliDanmakuPortraitDisplayArea,
        'bilibiliDanmakuPortraitFontScale': bilibiliDanmakuPortraitFontScale,
        'bilibiliDanmakuPortraitSpeed': bilibiliDanmakuPortraitSpeed,
        'bilibiliDanmakuPortraitDensity': bilibiliDanmakuPortraitDensity,
        'bilibiliDanmakuUseLockedSpeedAsBaseline':
            bilibiliDanmakuUseLockedSpeedAsBaseline,
        'bilibiliDanmakuAutoUpdate': bilibiliDanmakuAutoUpdate,
        'bilibiliDanmakuFontFamily': bilibiliDanmakuFontFamily,
        'bilibiliDanmakuOutlineScale': bilibiliDanmakuOutlineScale,
        'bilibiliDanmakuShadowScale': bilibiliDanmakuShadowScale,
        'bilibiliDanmakuLetterSpacing': bilibiliDanmakuLetterSpacing,
        'bilibiliDanmakuFontWeight': bilibiliDanmakuFontWeight,
        'bilibiliDanmakuOutlineType': bilibiliDanmakuOutlineType.name,
      },
      'subtitles': _subtitleSettingsSnapshot(),
      'batchSubtitles': {
        'batchSubtitleAutoDelete': batchSubtitleAutoDelete,
        'batchSubtitleKeepScreenAwake': batchSubtitleKeepScreenAwake,
        'batchSubtitleTranslateEnabled': batchSubtitleTranslateEnabled,
        'batchSubtitleOutputPathStrategy': batchSubtitleOutputPathStrategy.name,
        'batchSubtitleEmbedSoftCopyAndEmbed':
            batchSubtitleEmbedSoftCopyAndEmbed,
        'batchSubtitleEmbedSoftDeleteOriginal':
            batchSubtitleEmbedSoftDeleteOriginal,
        'batchSubtitleEmbedSoftPrefixEnabled':
            batchSubtitleEmbedSoftPrefixEnabled,
        'batchSubtitleEmbedSoftPrefix': batchSubtitleEmbedSoftPrefix,
        'batchSubtitleEmbedSoftSuffixEnabled':
            batchSubtitleEmbedSoftSuffixEnabled,
        'batchSubtitleEmbedSoftSuffix': batchSubtitleEmbedSoftSuffix,
        'batchSubtitleEmbedAutoDeleteSrt': batchSubtitleEmbedAutoDeleteSrt,
      },
      'videoCompose': {
        'videoComposeResolutionHeight': videoComposeResolutionHeight,
        'videoComposeRenderMode': videoComposeRenderMode,
        'videoComposeContinuousSubtitle': videoComposeContinuousSubtitle,
        'videoComposeRenderSecondary': videoComposeRenderSecondary,
        'videoComposeEmbedSoftSubtitles': videoComposeEmbedSoftSubtitles,
        'videoComposeSoftSubtitleOnly': videoComposeSoftSubtitleOnly,
        'videoComposeSoftSubtitleUseSourceQuality':
            videoComposeSoftSubtitleUseSourceQuality,
        'videoComposeDeleteOutputOnTaskDelete':
            videoComposeDeleteOutputOnTaskDelete,
      },
      'music': {
        'audioPortraitDisplayAspectRatio': audioPortraitDisplayAspectRatio,
        'audioPortraitCustomAspectWidth': audioPortraitCustomAspectWidth,
        'audioPortraitCustomAspectHeight': audioPortraitCustomAspectHeight,
        'musicLyricFontSizeScalePortrait': musicLyricFontSizeScalePortrait,
        'musicLyricFontSizeScaleLandscape': musicLyricFontSizeScaleLandscape,
        'musicLyricSpacingScalePortrait': musicLyricSpacingScalePortrait,
        'musicLyricSpacingScaleLandscape': musicLyricSpacingScaleLandscape,
        'musicLyricAnchorPortrait': musicLyricAnchorPortrait,
        'musicLyricAnchorLandscape': musicLyricAnchorLandscape,
        'musicLyricTrackDisplayMode': musicLyricTrackDisplayMode,
        'musicLyricWordByWordEnabled': musicLyricWordByWordEnabled,
        'musicLyricBlurEnabled': musicLyricBlurEnabled,
        'musicPortraitControlsAutoHide': musicPortraitControlsAutoHide,
      },
    };
  }

  Map<String, dynamic> _exportLibraryLayout(Size size) {
    final cards = homeCardStyleFor(size);
    final list = legacyListStyleFor(size);
    final rows = rowsStyleFor(size);
    final table = tableStyleFor(size);
    return {
      'cards': {
        'crossAxisCount': cards.crossAxisCount,
        'titleScale': cards.titleScale,
        'heightScale': cards.heightScale,
        'crossSpacingScale': cards.crossSpacingScale,
        'mainSpacingScale': cards.mainSpacingScale,
      },
      'list': {
        'crossAxisCount': list.crossAxisCount,
        'titleScale': list.titleScale,
        'heightScale': list.heightScale,
        'crossSpacingScale': list.crossSpacingScale,
        'mainSpacingScale': list.mainSpacingScale,
        'showThumbnail': list.showThumbnail,
        'showIndex': list.showIndex,
      },
      'rows': {
        'columns': rows.crossAxisCount,
        'rowExtent': rows.rowExtent,
        'titleSize': rows.titleSize,
        'titleLines': rows.titleLines,
        'crossSpacing': rows.crossSpacing,
        'mainSpacing': rows.mainSpacing,
        'outerPadding': rows.outerPadding,
        'showThumbnail': rows.showThumbnail,
        'showIndex': rows.showIndex,
        'showMeta': rows.showMeta,
        'showProgress': rows.showProgress,
        'cardSurface': rows.cardSurface,
      },
      'table': {
        'rowExtent': table.rowExtent,
        'titleSize': table.titleSize,
        'outerPadding': table.outerPadding,
        'showThumbnail': table.showThumbnail,
        'showIndex': table.showIndex,
        'striped': table.striped,
        'columns': MediaTableColumn.encode(table.tableColumns),
      },
    };
  }

  Future<String> getDefaultLargeDataRootPath() async =>
      (await AppStorageService.instance.defaultDataDirectory()).path;

  Future<Directory> resolveLargeDataRootDir() => AppStorageService.instance
      .resolveDataRoot(configuredRoot: largeDataRootPath);

  Future<void> setLargeDataRootPath(String? path) async {
    if (path == null || path.isEmpty) {
      largeDataRootPath = null;
      await _prefs.remove('largeDataRootPath');
    } else {
      largeDataRootPath = path;
      await _prefs.setString('largeDataRootPath', path);
    }
    notifyListeners();
  }
}
