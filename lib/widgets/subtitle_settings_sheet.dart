import 'subtitle_font_settings_page.dart';
import '../services/subtitle_debug_session.dart';
import 'subtitle_debug_panel.dart';
import 'subtitle_preset_chrome.dart';
import 'package:flutter/material.dart';
import 'landscape_sidebar_layout.dart';
import 'package:provider/provider.dart';
import '../models/subtitle_style.dart';
import '../services/settings_service.dart';
import 'default_settings_trial_action.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// 字幕设置面板
/// 文字样式（字体、颜色、描边、阴影等）会同步到横竖屏
/// 布局样式（字号、行间距、字间距等）同步到横竖屏
class SubtitleSettingsSheet extends StatefulWidget {
  bool _useCompactLayout(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    if (MediaQuery.orientationOf(context) != Orientation.landscape) {
      return screenSize.width < 600;
    }
    final sidebarSize = Size(
      LandscapeSidebarLayout.functionalWidthFor(screenSize),
      screenSize.height,
    );
    final layout = LandscapeSidebarLayout.fromSize(sidebarSize);
    return layout.isNarrow || layout.isCompactHeight;
  }

  /// 当前完整样式（包含文字样式和布局样式）
  final SubtitleStyle style;
  final String? positionError;
  final String? primarySource;
  final String? secondarySource;
  final String? primaryLanguage;
  final String? secondaryLanguage;

  /// 是否是横屏模式
  final bool isLandscape;

  /// 是否是音频模式
  final bool isAudio;

  /// Actual editing target supplied by the player (compose always uses false).
  final bool isGhostMode;

  /// 当文字样式改变时的回调
  final ValueChanged<SubtitleTextStyle>? onTextStyleChanged;

  /// 当布局样式改变时的回调
  final ValueChanged<SubtitleLayoutStyle>? onLayoutStyleChanged;

  /// 当完整样式改变时的回调（向后兼容）
  final ValueChanged<SubtitleStyle>? onStyleChanged;

  final VoidCallback onClose;
  final VoidCallback? onBack;
  final bool hideGhostModeToggle;
  final bool syncAudioSubtitleStyleWithVideo;
  final ValueChanged<bool>? onSyncAudioSubtitleStyleWithVideoChanged;

  const SubtitleSettingsSheet({
    super.key,
    required this.style,
    this.positionError,
    this.primarySource,
    this.secondarySource,
    this.primaryLanguage,
    this.secondaryLanguage,
    this.isLandscape = true,
    this.isAudio = false,
    this.isGhostMode = false,
    this.hideGhostModeToggle = false,
    this.onTextStyleChanged,
    this.onLayoutStyleChanged,
    this.onStyleChanged,
    required this.onClose,
    this.onBack,
    this.syncAudioSubtitleStyleWithVideo = true,
    this.onSyncAudioSubtitleStyleWithVideoChanged,
  });

  @override
  State<SubtitleSettingsSheet> createState() => SubtitleSettingsSheetState();
}

class SubtitleSettingsSheetState extends State<SubtitleSettingsSheet> {
  final _fontPageKey = GlobalKey<SubtitleFontSettingsPageState>();
  bool _fontsVisible = false;
  bool handleBack() {
    if (!_fontsVisible || SubtitleDebugSession.instance.catalogVisible) {
      return false;
    }
    final page = _fontPageKey.currentState;
    if (page != null) {
      page.handleBack();
    } else {
      _closeFonts();
    }
    return true;
  }

  final _scrollController = ScrollController();
  double _scrollOffset = 0;
  bool _useCompactLayout(BuildContext context) =>
      widget._useCompactLayout(context);
  SubtitleStyle get style => widget.style;
  bool get isLandscape => widget.isLandscape;
  bool get isAudio => widget.isAudio;
  bool get isGhostMode => widget.isGhostMode;
  bool get hideGhostModeToggle => widget.hideGhostModeToggle;
  bool get syncAudioSubtitleStyleWithVideo =>
      widget.syncAudioSubtitleStyleWithVideo;
  ValueChanged<bool>? get onSyncAudioSubtitleStyleWithVideoChanged =>
      widget.onSyncAudioSubtitleStyleWithVideoChanged;
  ValueChanged<SubtitleTextStyle>? get onTextStyleChanged =>
      widget.onTextStyleChanged;
  ValueChanged<SubtitleLayoutStyle>? get onLayoutStyleChanged =>
      widget.onLayoutStyleChanged;
  ValueChanged<SubtitleStyle>? get onStyleChanged => widget.onStyleChanged;
  VoidCallback get onClose => widget.onClose;
  VoidCallback? get onBack => widget.onBack;
  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _openFonts() {
    _scrollOffset = _scrollController.hasClients ? _scrollController.offset : 0;
    setState(() => _fontsVisible = true);
  }

  void _closeFonts() {
    setState(() => _fontsVisible = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients) {
        _scrollController.jumpTo(
          _scrollOffset.clamp(0, _scrollController.position.maxScrollExtent),
        );
      }
    });
  }

  void _showGhostModeHelp(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2C),
        title: const Text("幽灵模式说明", style: TextStyle(color: Colors.white)),
        content: const Text(
          "开启后，在字幕边栏或 AI 对话中，字幕可以拖到视频画面外的可用区域。\n"
          "普通与幽灵字号独立保存。普通大小随视频缩放；幽灵大小随整个页面适配，换视频或调整边栏不会改变字号。",
          style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
        ),
        actions: [
          DesktopButtonClickRegion(
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                "我知道了",
                style: TextStyle(color: Colors.blueAccent),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      SubtitleDebugSession.instance,
      SettingsService().defaultSettingsTrial,
    ]),
    builder: (context, _) => AbsorbPointer(
      absorbing: SettingsService().defaultSettingsTrial.busy,
      child: _build(context),
    ),
  );

  Widget _build(BuildContext context) {
    final presetSession = SubtitleDebugSession.instance;
    if (presetSession.catalogVisible) {
      return Material(
        color: const Color(0xFF1E1E1E),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final chrome = SubtitlePresetChrome.of(constraints);
            return Column(
              children: [
                SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(chrome.pad, 4, 2, 2),
                    child: SizedBox(
                      height: chrome.rowHeight,
                      child: Row(
                        children: [
                          if (onBack != null)
                            SubtitlePresetIconButton(
                              tooltip: '返回',
                              icon: Icons.arrow_back,
                              size: chrome.iconButton,
                              iconSize: chrome.iconSize,
                              color: Colors.white,
                              onPressed: onBack,
                            ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(left: 4, right: 6),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  '字幕排版',
                                  maxLines: 1,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                    fontSize: chrome.titleSize,
                                    height: 1.1,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (!isAudio && !hideGhostModeToggle)
                            Consumer<SettingsService>(
                              builder: (context, settings, _) =>
                                  SubtitleGhostModeToggle(
                                    enabled: settings.isGhostModeEnabled,
                                    onChanged: (value) =>
                                        settings.updateSetting(
                                          'isGhostModeEnabled',
                                          value,
                                        ),
                                    onHelp: () => _showGhostModeHelp(context),
                                    label: chrome.ghostLabel,
                                    fontSize: chrome.captionSize,
                                    markSize: chrome.isPhone ? 12 : 13,
                                    helpIconSize: chrome.iconSize - 2,
                                    helpButtonSize: chrome.iconButton - 4,
                                  ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                Expanded(child: SubtitleDebugPanel(isGhostMode: isGhostMode)),
              ],
            );
          },
        ),
      );
    }

    if (_fontsVisible) {
      return SubtitleFontSettingsPage(
        key: _fontPageKey,
        style: style.textStyle,
        onChanged: _updateTextStyle,
        onBack: _closeFonts,
        onClose: onClose,
        primarySource: widget.primarySource,
        secondarySource: widget.secondarySource,
        primaryLanguage: widget.primaryLanguage,
        secondaryLanguage: widget.secondaryLanguage,
      );
    }
    final screenSize = MediaQuery.sizeOf(context);
    final sidebarSize =
        MediaQuery.orientationOf(context) == Orientation.landscape
        ? Size(
            LandscapeSidebarLayout.functionalWidthFor(screenSize),
            screenSize.height,
          )
        : screenSize;
    final layout = LandscapeSidebarLayout.fromSize(sidebarSize);
    final isSmallScreen = layout.isNarrow || layout.isCompactHeight;
    final bool showAudioSyncRow =
        isAudio && onSyncAudioSubtitleStyleWithVideoChanged != null;
    final paddingValue = layout.horizontalPadding;
    final headerHPadding = layout.horizontalPadding;
    final headerVPadding = layout.verticalPadding / 2;
    final headerIconSize = isSmallScreen ? 16.0 : 18.0;
    final headerTitleFontSize = layout.titleSize;
    final headerButtonSize = isSmallScreen ? 28.0 : 32.0;
    final headerTopRowHeight = isSmallScreen ? 28.0 : 32.0;
    final headerBottomRowHeight = isSmallScreen ? 20.0 : 24.0;
    final headerRowGap = isSmallScreen ? 0.0 : 2.0;
    final bool showBottomRow = showAudioSyncRow;
    final headerHeight =
        headerTopRowHeight +
        (showBottomRow ? (headerBottomRowHeight + headerRowGap) : 0.0) +
        headerVPadding * 2;

    // Adaptive sizes
    final double titleFontSize = isSmallScreen ? 11 : 12;

    return Material(
      color: const Color(0xFF1E1E1E), // 深色背景
      child: Column(
        children: [
          // Header
          SizedBox(
            height: headerHeight,
            child: Theme(
              data: Theme.of(context).copyWith(
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: headerHPadding,
                  vertical: headerVPadding,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: headerTopRowHeight,
                      child: Row(
                        children: [
                          if (onBack != null)
                            DesktopButtonClickRegion(
                              child: IconButton(
                                icon: Icon(
                                  Icons.arrow_back,
                                  color: Colors.white70,
                                  size: headerIconSize,
                                ),
                                onPressed: onBack,
                                padding: EdgeInsets.zero,
                                constraints: BoxConstraints.tightFor(
                                  width: headerButtonSize,
                                  height: headerButtonSize,
                                ),
                                splashRadius: headerButtonSize / 2,
                                tooltip: "返回",
                              ),
                            ),
                          if (onBack != null) const SizedBox(width: 4),
                          Expanded(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                isAudio ? "音频字幕样式" : "视频字幕样式",
                                maxLines: 1,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: headerTitleFontSize,
                                  fontWeight: FontWeight.w600,
                                  height: 1.1,
                                ),
                              ),
                            ),
                          ),
                          if (!isAudio && !hideGhostModeToggle)
                            Consumer<SettingsService>(
                              builder: (context, settings, _) =>
                                  SubtitleGhostModeToggle(
                                    enabled: settings.isGhostModeEnabled,
                                    onChanged: (value) =>
                                        settings.updateSetting(
                                          'isGhostModeEnabled',
                                          value,
                                        ),
                                    onHelp: () => _showGhostModeHelp(context),
                                    label: isSmallScreen ? '幽灵' : '幽灵模式',
                                    fontSize: isSmallScreen ? 10 : 11,
                                    markSize: isSmallScreen ? 12 : 13,
                                    helpIconSize: headerIconSize - 2,
                                    helpButtonSize: headerButtonSize - 6,
                                  ),
                            ),
                          DesktopButtonClickRegion(
                            child: IconButton(
                              icon: Icon(
                                Icons.close,
                                color: Colors.white70,
                                size: headerIconSize,
                              ),
                              onPressed: onClose,
                              padding: EdgeInsets.zero,
                              constraints: BoxConstraints.tightFor(
                                width: headerButtonSize,
                                height: headerButtonSize,
                              ),
                              splashRadius: headerButtonSize / 2,
                              tooltip: "关闭",
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (showBottomRow) SizedBox(height: headerRowGap),
                    if (showAudioSyncRow)
                      SizedBox(
                        height: headerBottomRowHeight,
                        child: Row(
                          children: [
                            if (onBack != null)
                              SizedBox(width: headerButtonSize + 4.0),
                            Text(
                              isSmallScreen ? "同步视频样式" : "同步视频播放页样式",
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: isSmallScreen ? 10 : 11,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Transform.scale(
                              scale: isSmallScreen ? 0.66 : 0.78,
                              alignment: Alignment.centerLeft,
                              child: Switch(
                                value: syncAudioSubtitleStyleWithVideo,
                                onChanged:
                                    onSyncAudioSubtitleStyleWithVideoChanged,
                                activeThumbColor: Colors.blueAccent,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const Divider(color: Colors.white10, height: 1),

          Expanded(
            child: ListView(
              key: const PageStorageKey('subtitle-style-scroll'),
              controller: _scrollController,
              padding: EdgeInsets.symmetric(
                horizontal: paddingValue,
                vertical: 8,
              ),
              children: [
                DefaultSettingsTrialNotice(settings: SettingsService()),
                if (widget.positionError != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      widget.positionError!,
                      key: const ValueKey('subtitle-position-save-error'),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
                  ),
                if (presetSession.enabled)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SubtitlePresetTextAction(
                      onPressed: presetSession.openCatalog,
                      icon: Icons.auto_awesome,
                      label: '选择字幕预设',
                      fontSize: titleFontSize,
                      height: isSmallScreen ? 26 : 28,
                    ),
                  ),
                if (SubtitleDebugSession.instance.preset == null) ...[
                  // Ordinary layout settings are shared by both orientations.
                  _buildSectionTitle(
                    context,
                    "大小与间距",
                    Icons.format_size,
                    color: Colors.orangeAccent,
                  ),
                  Text(
                    isGhostMode
                        ? '幽灵大小 · 自动保持易读，换视频或调整边栏不变'
                        : (isAudio
                              ? '普通大小 · 随字幕显示区域缩放'
                              : '普通大小 · 横竖屏与合成保持相同画面比例'),
                    style: const TextStyle(fontSize: 11, color: Colors.white60),
                  ),
                  Row(
                    children: [
                      Text(
                        '整体大小',
                        style: TextStyle(
                          color: Colors.white60,
                          fontSize: titleFontSize,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildSlider(
                          context,
                          value: style.overallScale,
                          divisions: 120,
                          min: 0.6,
                          max: 1.8,
                          label: '${(style.overallScale * 100).round()}%',
                          onChanged: (value) => _updateLayoutStyle(
                            style.layoutStyle.copyWith(overallScale: value),
                          ),
                        ),
                      ),
                    ],
                  ),
                  // Main Font Size
                  Row(
                    children: [
                      Text(
                        "主字号",
                        style: TextStyle(
                          color: Colors.white60,
                          fontSize: titleFontSize,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildSlider(
                          context,
                          value: style.fontSize,
                          min: 10,
                          max: 100,
                          label: style.fontSize.toInt().toString(),
                          onChanged: (val) => _updateLayoutStyle(
                            style.layoutStyle.copyWith(fontSize: val),
                          ),
                        ),
                      ),
                    ],
                  ),
                  // Secondary Font Size
                  Row(
                    children: [
                      Text(
                        "副字号",
                        style: TextStyle(
                          color: Colors.white60,
                          fontSize: titleFontSize,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildSlider(
                          context,
                          value: style.secondaryFontSize ?? style.fontSize,
                          min: 10,
                          max: 100,
                          label: (style.secondaryFontSize ?? style.fontSize)
                              .toInt()
                              .toString(),
                          onChanged: (val) => _updateLayoutStyle(
                            style.layoutStyle.copyWith(secondaryFontSize: val),
                          ),
                        ),
                      ),
                    ],
                  ),
                  // Line Spacing
                  Row(
                    children: [
                      Text(
                        "行间距",
                        style: TextStyle(
                          color: Colors.white60,
                          fontSize: titleFontSize,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildSlider(
                          context,
                          value: style.lineSpacing,
                          min: -10,
                          max: 100,
                          label: style.lineSpacing.toInt().toString(),
                          onChanged: (val) => _updateLayoutStyle(
                            style.layoutStyle.copyWith(lineSpacing: val),
                          ),
                        ),
                      ),
                    ],
                  ),
                  // Letter Spacing
                  Row(
                    children: [
                      Text(
                        "字间距",
                        style: TextStyle(
                          color: Colors.white60,
                          fontSize: titleFontSize,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildSlider(
                          context,
                          value: style.letterSpacing,
                          min: -5,
                          max: 20,
                          label: style.letterSpacing.toStringAsFixed(1),
                          onChanged: (val) => _updateLayoutStyle(
                            style.layoutStyle.copyWith(letterSpacing: val),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  const Divider(color: Colors.white10, height: 24),

                  // 2. Text Style Settings - 同步到横竖屏
                  _buildSectionTitle(
                    context,
                    "文字样式",
                    Icons.text_fields,
                    color: Colors.greenAccent,
                  ),

                  ListTile(
                    key: const ValueKey('subtitle-font-settings'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      '字体设置',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: titleFontSize,
                      ),
                    ),
                    trailing: const Icon(
                      Icons.chevron_right,
                      color: Colors.white54,
                      size: 18,
                    ),
                    onTap: _openFonts,
                  ),
                  const SizedBox(height: 8),

                  // 3. Font Style
                  _buildSectionTitle(context, "样式", Icons.format_paint),
                  Row(
                    children: [
                      _buildStyleToggle(
                        context,
                        icon: Icons.format_italic,
                        isActive: style.isItalic,
                        onTap: () => _updateTextStyle(
                          style.textStyle.copyWith(isItalic: !style.isItalic),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _buildStyleToggle(
                        context,
                        icon: Icons.format_underlined,
                        isActive: style.isUnderline,
                        onTap: () => _updateTextStyle(
                          style.textStyle.copyWith(
                            isUnderline: !style.isUnderline,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // 4. Text Color
                  _buildSectionTitle(context, "文本颜色", Icons.color_lens),
                  _buildColorPicker(
                    context,
                    storageId: 'text',
                    selectedColor: style.textColor,
                    onColorChanged: (c) => _updateTextStyle(
                      style.textStyle.copyWith(textColor: c),
                    ),
                  ),
                  const SizedBox(height: 16),

                  _buildSwitchSection(
                    context,
                    '背景',
                    style.backgroundEnabled,
                    (value) {
                      _updateTextStyle(
                        style.textStyle.copyWith(
                          backgroundEnabled: value,
                          backgroundOpacity:
                              value && style.backgroundOpacity == 0
                              ? 0.5
                              : style.backgroundOpacity,
                        ),
                      );
                    },
                    children: [
                      _buildColorPicker(
                        context,
                        storageId: 'background',
                        selectedColor: style.backgroundColor.withValues(
                          alpha: 1,
                        ),
                        onColorChanged: (color) => _updateTextStyle(
                          style.textStyle.copyWith(backgroundColor: color),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Text(
                            '不透明度',
                            style: TextStyle(
                              color: Colors.white60,
                              fontSize: titleFontSize,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildSlider(
                              context,
                              value: style.backgroundOpacity,
                              min: 0,
                              max: 1,
                              label:
                                  '${(style.backgroundOpacity * 100).round()}%',
                              onChanged: (value) => _updateTextStyle(
                                style.textStyle.copyWith(
                                  backgroundOpacity: value,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),

                  const Divider(color: Colors.white10, height: 24),

                  // 6. Border & Shadow
                  _buildSwitchSection(
                    context,
                    "描边",
                    style.hasBorder,
                    (val) => _updateTextStyle(
                      style.textStyle.copyWith(hasBorder: val),
                    ),
                    children: [
                      _buildColorPicker(
                        context,
                        storageId: 'border',
                        selectedColor: style.borderColor,
                        onColorChanged: (c) => _updateTextStyle(
                          style.textStyle.copyWith(borderColor: c),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Text(
                            "宽度",
                            style: TextStyle(
                              color: Colors.white60,
                              fontSize: titleFontSize,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildSlider(
                              context,
                              value: style.effectiveBorderWidth,
                              min: 0,
                              max: 10,
                              label: style.effectiveBorderWidth.toStringAsFixed(
                                1,
                              ),
                              onChanged: (val) => _updateTextStyle(
                                style.textStyle.copyWith(
                                  borderWidth: style.textStyle
                                      .normalizeBorderWidthForFontSize(
                                        val,
                                        style.fontSize,
                                      ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),

                  _buildSwitchSection(
                    context,
                    "阴影",
                    style.hasShadow,
                    (val) => _updateTextStyle(
                      style.textStyle.copyWith(hasShadow: val),
                    ),
                    children: [
                      _buildColorPicker(
                        context,
                        storageId: 'shadow',
                        selectedColor: style.shadowColor,
                        onColorChanged: (c) => _updateTextStyle(
                          style.textStyle.copyWith(shadowColor: c),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Text(
                            "模糊",
                            style: TextStyle(
                              color: Colors.white60,
                              fontSize: titleFontSize,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildSlider(
                              context,
                              value: style.effectiveShadowBlur,
                              min: 0,
                              max: 10,
                              label: style.effectiveShadowBlur.toStringAsFixed(
                                1,
                              ),
                              onChanged: (val) => _updateTextStyle(
                                style.textStyle.copyWith(
                                  shadowBlur: style.textStyle
                                      .normalizeShadowBlurForFontSize(
                                        val,
                                        style.fontSize,
                                      ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Text(
                            "距离",
                            style: TextStyle(
                              color: Colors.white60,
                              fontSize: titleFontSize,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildSlider(
                              context,
                              value: style.effectiveShadowOffset.dx,
                              min: 0,
                              max: 10,
                              label: style.effectiveShadowOffset.dx
                                  .toStringAsFixed(1),
                              onChanged: (val) => _updateTextStyle(
                                style.textStyle.copyWith(
                                  shadowOffset: style.textStyle
                                      .normalizeShadowOffsetForFontSize(
                                        Offset(val, val),
                                        style.fontSize,
                                      ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 更新文字样式 - 会同步到横竖屏
  void _updateTextStyle(SubtitleTextStyle newTextStyle) {
    if (onTextStyleChanged != null) {
      onTextStyleChanged!.call(newTextStyle);
      return;
    }
    onStyleChanged?.call(
      SubtitleStyle(textStyle: newTextStyle, layoutStyle: style.layoutStyle),
    );
  }

  /// 更新布局样式 - 只影响当前方向
  void _updateLayoutStyle(SubtitleLayoutStyle newLayoutStyle) {
    if (onLayoutStyleChanged != null) {
      onLayoutStyleChanged!.call(newLayoutStyle);
      return;
    }
    onStyleChanged?.call(
      SubtitleStyle(textStyle: style.textStyle, layoutStyle: newLayoutStyle),
    );
  }

  Widget _buildSectionTitle(
    BuildContext context,
    String text,
    IconData icon, {
    Color? color,
  }) {
    final isSmallScreen = _useCompactLayout(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(
            icon,
            size: isSmallScreen ? 12 : 14,
            color: (color ?? Colors.blueAccent).withValues(alpha: 0.8),
          ),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: color ?? Colors.white70,
              fontSize: isSmallScreen ? 11 : 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSlider(
    BuildContext context, {
    required double value,
    required double min,
    required double max,
    int divisions = 100,
    required String label,
    required ValueChanged<double> onChanged,
  }) {
    final isSmallScreen = _useCompactLayout(context);
    return SizedBox(
      height: !isLandscape ? 40 : (isSmallScreen ? 24 : 30),
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 2,
          thumbShape: RoundSliderThumbShape(
            enabledThumbRadius: isSmallScreen ? 4 : 6,
          ),
          overlayShape: RoundSliderOverlayShape(
            overlayRadius: isSmallScreen ? 8 : 12,
          ),
          valueIndicatorShape: const PaddleSliderValueIndicatorShape(),
          valueIndicatorTextStyle: TextStyle(fontSize: isSmallScreen ? 10 : 12),
        ),
        child: Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          label: label,
          activeColor: Colors.blueAccent,
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildStyleToggle(
    BuildContext context, {
    required IconData icon,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    final isSmallScreen = _useCompactLayout(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(isSmallScreen ? 6 : 8),
        decoration: BoxDecoration(
          color: isActive
              ? Colors.blueAccent
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isActive ? Colors.blueAccent : Colors.white10,
          ),
        ),
        child: Icon(
          icon,
          color: isActive ? Colors.white : Colors.white60,
          size: isSmallScreen ? 16 : 18,
        ),
      ),
    );
  }

  Widget _buildColorPicker(
    BuildContext context, {
    required String storageId,
    required Color selectedColor,
    required ValueChanged<Color> onColorChanged,
  }) {
    final isSmallScreen = _useCompactLayout(context);
    final colors = [
      Colors.white,
      Colors.black,
      Colors.redAccent,
      Colors.blueAccent,
      Colors.greenAccent,
      Colors.amberAccent,
      Colors.cyanAccent,
      Colors.purpleAccent,
      Colors.grey,
      Colors.brown,
    ];

    return SingleChildScrollView(
      key: PageStorageKey('subtitle-style-color-$storageId'),
      scrollDirection: Axis.horizontal,
      child: Row(
        children: colors.map((color) {
          final isSelected = color.toARGB32() == selectedColor.toARGB32();
          return GestureDetector(
            onTap: () => onColorChanged(color),
            child: Container(
              margin: EdgeInsets.only(right: isSmallScreen ? 8 : 12),
              width: isSmallScreen ? 24 : 28,
              height: isSmallScreen ? 24 : 28,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSelected ? Colors.white : Colors.white24,
                  width: isSelected ? 2 : 1,
                ),
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color: Colors.white.withValues(alpha: 0.3),
                          blurRadius: 4,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
              child: isSelected
                  ? Icon(
                      Icons.check,
                      size: isSmallScreen ? 14 : 16,
                      color: color.computeLuminance() > 0.5
                          ? Colors.black
                          : Colors.white,
                    )
                  : null,
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildSwitchSection(
    BuildContext context,
    String title,
    bool value,
    ValueChanged<bool> onChanged, {
    required List<Widget> children,
  }) {
    final isSmallScreen = _useCompactLayout(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              title,
              style: TextStyle(
                color: Colors.white70,
                fontSize: isSmallScreen ? 12 : 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            SizedBox(
              height: 24,
              child: Transform.scale(
                scale: isSmallScreen ? 0.8 : 1.0,
                child: Switch(
                  value: value,
                  onChanged: onChanged,
                  activeThumbColor: Colors.blueAccent,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          ],
        ),
        if (value) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.03),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white10),
            ),
            child: Column(children: children),
          ),
        ],
      ],
    );
  }
}
