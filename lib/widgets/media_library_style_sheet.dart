import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/media_library_view_mode.dart';
import '../services/settings_service.dart';
import '../theme/app_tokens.dart';
import 'folder_placeholder_style_dialog.dart';
import 'media_library_layout_profile.dart';
import 'media_library_view_defaults.dart';

/// Shared portrait/landscape style sheet for the home and collection grids.
class MediaLibraryStyleSheet {
  const MediaLibraryStyleSheet._();

  static const Key bodyKey = ValueKey('media-library-style-sheet-body');

  static Future<void> show({
    required BuildContext context,
    required MediaLibraryCardStyleScope scope,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: AppTokens.bgRaised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (context) => KeyedSubtree(
        key: MediaLibraryStyleSheet.bodyKey,
        child: _MediaLibraryStyleSheetBody(scope: scope),
      ),
    );
  }
}

class _MediaLibraryStyleSheetBody extends StatefulWidget {
  const _MediaLibraryStyleSheetBody({required this.scope});

  final MediaLibraryCardStyleScope scope;

  @override
  State<_MediaLibraryStyleSheetBody> createState() =>
      _MediaLibraryStyleSheetBodyState();
}

class _MediaLibraryStyleSheetBodyState extends State<_MediaLibraryStyleSheetBody> {
  late MediaLibraryViewMode _editingMode;

  @override
  void initState() {
    super.initState();
    _editingMode = context.read<SettingsService>().mediaLibraryViewStyle;
  }

  Duration get _animDuration => MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 200);

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final size = MediaQuery.sizeOf(context);
    final isLandscape = MediaLibraryLayoutDefaults.isLandscape(size);
    final orientationLabel = isLandscape ? '横屏' : '竖屏';
    final maxHeight = size.height * 0.70;
    final title = '${_editingMode.label}样式 · $orientationLabel';

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: AppTokens.text1,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '横屏和竖屏分别保存',
                    style: TextStyle(
                      color: AppTokens.text3,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _ViewModeSegmentedControl(
                    selected: _editingMode,
                    onSelected: (mode) => setState(() => _editingMode = mode),
                    duration: _animDuration,
                  ),
                  const SizedBox(height: 12),
                  _StylePreviewStrip(
                    mode: _editingMode,
                    settings: settings,
                    size: size,
                    scope: widget.scope,
                    duration: _animDuration,
                  ),
                ],
              ),
            ),
            Flexible(
              child: AnimatedSwitcher(
                duration: _animDuration,
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeOutCubic,
                transitionBuilder: (child, animation) => SizeTransition(
                  sizeFactor: animation,
                  alignment: Alignment.topCenter,
                  child: FadeTransition(opacity: animation, child: child),
                ),
                child: ListView(
                  key: ValueKey<String>(_editingMode.name),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
                  children: [
                    SwitchListTile(
                      key: const ValueKey('show-action-button-labels'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: settings.showActionButtonLabels,
                      activeThumbColor: AppTokens.accent,
                      title: const Text(
                        '显示按钮名称',
                        style: TextStyle(color: AppTokens.text1),
                      ),
                      subtitle: const Text(
                        '在展开、收起的悬浮按钮中显示名称，横竖屏通用',
                        style: TextStyle(color: AppTokens.text2, fontSize: 12),
                      ),
                      onChanged: (value) =>
                          settings.updateSetting('showActionButtonLabels', value),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      key: const ValueKey('local-media-extension-filter'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: settings.localImportFilterMediaExtensions,
                      activeThumbColor: AppTokens.accent,
                      title: const Text(
                        '导入时仅接受媒体后缀文件',
                        style: TextStyle(color: AppTokens.text1),
                      ),
                      subtitle: const Text(
                        '适用于文件、拖入、文件夹和压缩包导入',
                        style: TextStyle(color: AppTokens.text2, fontSize: 12),
                      ),
                      onChanged: (value) => settings.updateSetting(
                        'localImportFilterMediaExtensions',
                        value,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ..._sectionsForMode(
                      context: context,
                      settings: settings,
                      size: size,
                      mode: _editingMode,
                    ),
                    if (_editingMode == MediaLibraryViewMode.grid ||
                        _editingMode == MediaLibraryViewMode.rows ||
                        _editingMode == MediaLibraryViewMode.table)
                      _ResetOrientationButton(
                        label: '恢复本方向默认',
                        onPressed: () {
                          if (_editingMode == MediaLibraryViewMode.grid) {
                            unawaited(settings.resetGridStyleFor(size));
                          } else if (_editingMode == MediaLibraryViewMode.rows) {
                            unawaited(settings.resetRowsStyleFor(size));
                          } else {
                            unawaited(settings.resetTableStyleFor(size));
                          }
                        },
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _sectionsForMode({
    required BuildContext context,
    required SettingsService settings,
    required Size size,
    required MediaLibraryViewMode mode,
  }) {
    switch (mode) {
      case MediaLibraryViewMode.grid:
        return _gridSection(context, settings, size);
      case MediaLibraryViewMode.rows:
        return _rowsSection(context, settings, size);
      case MediaLibraryViewMode.table:
        return _tableSection(context, settings, size);
      case MediaLibraryViewMode.tree:
        return _treeSection(context, settings, size);
    }
  }

  List<Widget> _gridSection(
    BuildContext context,
    SettingsService settings,
    Size size, {
    bool includePlaceholder = true,
  }) {
    final cardStyle = widget.scope == MediaLibraryCardStyleScope.home
        ? settings.homeCardStyleFor(size)
        : settings.collectionCardStyleFor(size);
    final cardMetrics = MediaLibraryLayoutDefaults.cardGrid(
      textScaler: MediaQuery.textScalerOf(context),
      textStyle: DefaultTextStyle.of(context).style,
      screenSize: size,
      style: cardStyle,
    );

    Future<void> update({
      int? crossAxisCount,
      double? titleScale,
      double? heightScale,
      double? crossSpacingScale,
      double? mainSpacingScale,
    }) {
      if (widget.scope == MediaLibraryCardStyleScope.home) {
        return settings.updateHomeCardStyleFor(
          size,
          crossAxisCount: crossAxisCount,
          titleScale: titleScale,
          heightScale: heightScale,
          crossSpacingScale: crossSpacingScale,
          mainSpacingScale: mainSpacingScale,
        );
      }
      return settings.updateCollectionCardStyleFor(
        size,
        crossAxisCount: crossAxisCount,
        titleScale: titleScale,
        heightScale: heightScale,
        crossSpacingScale: crossSpacingScale,
        mainSpacingScale: mainSpacingScale,
      );
    }

    final titlePx = settings.mediaLibraryReadableCardDefaults
        ? cardMetrics.cellWidth * cardStyle.titleScale
        : MediaLibraryLayoutDefaults.titleFontSize(
            cardMetrics.cellWidth,
            cardStyle.titleScale,
          );
    final displayedHeightScale = cardStyle.reserveTwoTitleLines
        ? cardMetrics.cellHeight / cardMetrics.cellWidth
        : cardStyle.heightScale;

    return [
      if (includePlaceholder) _placeholderEntry(context),
      _logSlider(
        title: '每行卡片数量',
        valueText:
            '${cardStyle.crossAxisCount} 列 · 宽 ${cardMetrics.cellWidth.round()}',
        range: MediaLibraryLayoutDefaults.columnRange,
        value: cardStyle.crossAxisCount.toDouble(),
        divisions: 240,
        onChanged: (value) =>
            update(crossAxisCount: value.round().clamp(1, 20)),
      ),
      _logSlider(
        title: '标题字号',
        valueText:
            '${(cardStyle.titleScale * 100).toStringAsFixed(1)}% · ${titlePx.toStringAsFixed(1)} px',
        range: MediaLibraryLayoutDefaults.titleRange,
        value: cardStyle.titleScale,
        divisions: 280,
        onChanged: (value) => update(titleScale: value),
      ),
      _logSlider(
        title: '卡片高度',
        valueText: '${displayedHeightScale.toStringAsFixed(2)} × 宽',
        range: MediaLibraryLayoutDefaults.heightRange,
        value: displayedHeightScale,
        divisions: 280,
        onChanged: (value) => update(heightScale: value),
      ),
      _logSlider(
        title: '横向间距',
        valueText:
            '${(cardStyle.crossSpacingScale * 100).toStringAsFixed(1)}% 宽 · ${cardMetrics.crossSpacing.toStringAsFixed(1)} px',
        range: MediaLibraryLayoutDefaults.spacingRange,
        value: cardStyle.crossSpacingScale,
        divisions: 280,
        onChanged: (value) => update(crossSpacingScale: value),
      ),
      _logSlider(
        title: '纵向间距',
        valueText:
            '${(cardStyle.mainSpacingScale * 100).toStringAsFixed(1)}% 宽 · ${cardMetrics.mainSpacing.toStringAsFixed(1)} px',
        range: MediaLibraryLayoutDefaults.spacingRange,
        value: cardStyle.mainSpacingScale,
        divisions: 280,
        onChanged: (value) => update(mainSpacingScale: value),
      ),
    ];
  }

  List<Widget> _rowsSection(
    BuildContext context,
    SettingsService settings,
    Size size, {
    bool includePlaceholder = true,
  }) {
    final style = settings.rowsStyleFor(size);
    return [
      if (includePlaceholder) _placeholderEntry(context),
      _valueSlider(
        key: const ValueKey('media-library-style-rows-columns'),
        title: '每行栏数',
        value: style.crossAxisCount.toDouble(),
        min: MediaLibraryViewDefaults.minRowsColumns.toDouble(),
        max: MediaLibraryViewDefaults.maxRowsColumns.toDouble(),
        divisions: MediaLibraryViewDefaults.maxRowsColumns -
            MediaLibraryViewDefaults.minRowsColumns,
        valueText: '${style.crossAxisCount} 栏',
        onChanged: (v) => settings.updateRowsStyleFor(
          size,
          columns: v.round(),
        ),
      ),
      _valueSlider(
        title: '行高',
        value: style.rowExtent ?? MediaLibraryViewDefaults.rowsExtent(size),
        min: MediaLibraryViewDefaults.minRowsExtent,
        max: MediaLibraryViewDefaults.maxRowsExtent,
        divisions: 176,
        valueText:
            '${(style.rowExtent ?? MediaLibraryViewDefaults.rowsExtent(size)).round()} px',
        onChanged: (v) => settings.updateRowsStyleFor(size, rowExtent: v),
      ),
      _valueSlider(
        title: '标题字号',
        value: style.titleSize ?? MediaLibraryViewDefaults.rowsTitleSize(size),
        min: MediaLibraryViewDefaults.minTitleSize,
        max: MediaLibraryViewDefaults.maxTitleSize,
        divisions: 140,
        valueText:
            '${(style.titleSize ?? MediaLibraryViewDefaults.rowsTitleSize(size)).toStringAsFixed(1)} px',
        onChanged: (v) => settings.updateRowsStyleFor(size, titleSize: v),
      ),
      _valueSlider(
        title: '标题行数',
        value: style.titleLines.toDouble(),
        min: MediaLibraryViewDefaults.minTitleLines.toDouble(),
        max: MediaLibraryViewDefaults.maxTitleLines.toDouble(),
        divisions: MediaLibraryViewDefaults.maxTitleLines -
            MediaLibraryViewDefaults.minTitleLines,
        valueText: '${style.titleLines} 行',
        onChanged: (v) => settings.updateRowsStyleFor(
          size,
          titleLines: v.round(),
        ),
      ),
      _valueSlider(
        title: '横向间距',
        value: style.crossSpacing ?? MediaLibraryViewDefaults.rowsCrossSpacing(size),
        min: MediaLibraryViewDefaults.minSpacing,
        max: MediaLibraryViewDefaults.maxSpacing,
        divisions: 40,
        valueText:
            '${(style.crossSpacing ?? MediaLibraryViewDefaults.rowsCrossSpacing(size)).round()} px',
        onChanged: (v) => settings.updateRowsStyleFor(size, crossSpacing: v),
      ),
      _valueSlider(
        title: '纵向间距',
        value: style.mainSpacing ?? MediaLibraryViewDefaults.rowsMainSpacing(size),
        min: MediaLibraryViewDefaults.minSpacing,
        max: MediaLibraryViewDefaults.maxSpacing,
        divisions: 40,
        valueText:
            '${(style.mainSpacing ?? MediaLibraryViewDefaults.rowsMainSpacing(size)).round()} px',
        onChanged: (v) => settings.updateRowsStyleFor(size, mainSpacing: v),
      ),
      _valueSlider(
        title: '外边距',
        value: style.outerPadding ?? MediaLibraryViewDefaults.rowsOuterPadding(size),
        min: MediaLibraryViewDefaults.minOuterPadding,
        max: MediaLibraryViewDefaults.maxOuterPadding,
        divisions: 64,
        valueText:
            '${(style.outerPadding ?? MediaLibraryViewDefaults.rowsOuterPadding(size)).round()} px',
        onChanged: (v) => settings.updateRowsStyleFor(size, outerPadding: v),
      ),
      _boolSwitch(
        title: '显示缩略图',
        value: style.showThumbnail,
        onChanged: (v) => settings.updateRowsStyleFor(size, showThumbnail: v),
      ),
      _boolSwitch(
        title: '显示序号',
        value: style.showIndex,
        onChanged: (v) => settings.updateRowsStyleFor(size, showIndex: v),
      ),
      _boolSwitch(
        title: '显示路径与时长',
        value: style.showMeta,
        onChanged: (v) => settings.updateRowsStyleFor(size, showMeta: v),
      ),
      _boolSwitch(
        title: '显示观看进度',
        value: style.showProgress,
        onChanged: (v) => settings.updateRowsStyleFor(size, showProgress: v),
      ),
      _boolSwitch(
        title: '卡片底色',
        value: style.cardSurface,
        onChanged: (v) => settings.updateRowsStyleFor(size, cardSurface: v),
      ),
    ];
  }

  List<Widget> _tableSection(
    BuildContext context,
    SettingsService settings,
    Size size, {
    bool includePlaceholder = true,
  }) {
    final style = settings.tableStyleFor(size);
    return [
      if (includePlaceholder) _placeholderEntry(context),
      _valueSlider(
        title: '行高',
        value: style.rowExtent ?? MediaLibraryViewDefaults.tableExtent(size),
        min: MediaLibraryViewDefaults.minTableExtent,
        max: MediaLibraryViewDefaults.maxTableExtent,
        divisions: 68,
        valueText:
            '${(style.rowExtent ?? MediaLibraryViewDefaults.tableExtent(size)).round()} px',
        onChanged: (v) => settings.updateTableStyleFor(size, rowExtent: v),
      ),
      _valueSlider(
        title: '标题字号',
        value: style.titleSize ?? MediaLibraryViewDefaults.tableTitleSize(size),
        min: MediaLibraryViewDefaults.minTitleSize,
        max: MediaLibraryViewDefaults.maxTitleSize,
        divisions: 140,
        valueText:
            '${(style.titleSize ?? MediaLibraryViewDefaults.tableTitleSize(size)).toStringAsFixed(1)} px',
        onChanged: (v) => settings.updateTableStyleFor(size, titleSize: v),
      ),
      _valueSlider(
        title: '外边距',
        value:
            style.outerPadding ?? MediaLibraryViewDefaults.tableOuterPadding(size),
        min: MediaLibraryViewDefaults.minOuterPadding,
        max: MediaLibraryViewDefaults.maxOuterPadding,
        divisions: 64,
        valueText:
            '${(style.outerPadding ?? MediaLibraryViewDefaults.tableOuterPadding(size)).round()} px',
        onChanged: (v) => settings.updateTableStyleFor(size, outerPadding: v),
      ),
      _boolSwitch(
        title: '显示缩略图',
        value: style.showThumbnail,
        onChanged: (v) => settings.updateTableStyleFor(size, showThumbnail: v),
      ),
      _boolSwitch(
        title: '显示序号',
        value: style.showIndex,
        onChanged: (v) => settings.updateTableStyleFor(size, showIndex: v),
      ),
      _boolSwitch(
        title: '斑马纹',
        value: style.striped,
        onChanged: (v) => settings.updateTableStyleFor(size, striped: v),
      ),
      const SizedBox(height: 8),
      Text('显示列', style: TextStyle(color: AppTokens.text2, fontSize: 13)),
      const SizedBox(height: 6),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final column in MediaTableColumn.values)
            FilterChip(
              key: ValueKey('media-library-style-table-column-${column.name}'),
              label: Text(column.label),
              selected: style.tableColumns.contains(column),
              selectedColor: AppTokens.accentSoft,
              checkmarkColor: AppTokens.accent,
              labelStyle: TextStyle(
                color: style.tableColumns.contains(column)
                    ? AppTokens.accent
                    : AppTokens.text2,
                fontSize: 12,
              ),
              onSelected: (selected) {
                final next = Set<MediaTableColumn>.from(style.tableColumns);
                if (selected) {
                  next.add(column);
                } else {
                  next.remove(column);
                }
                unawaited(settings.updateTableStyleFor(size, columns: next));
              },
            ),
        ],
      ),
      const SizedBox(height: 12),
      Text('当前排序', style: TextStyle(color: AppTokens.text2, fontSize: 13)),
      const SizedBox(height: 6),
      _TableSortPicker(settings: settings),
    ];
  }

  List<Widget> _treeSection(
    BuildContext context,
    SettingsService settings,
    Size size,
  ) {
    final content = MediaLibraryContentLayout.fromStorage(
      settings.mediaTreeContentMode,
    );
    return [
      Text(
        '右侧内容视图',
        style: TextStyle(color: AppTokens.text2, fontSize: 13),
      ),
      const SizedBox(height: 8),
      _ContentLayoutSegment(
        selected: content,
        onSelected: (layout) => settings.updateSetting(
          'mediaTreeContentMode',
          layout.index,
        ),
      ),
      const SizedBox(height: 12),
      _valueSlider(
        key: const ValueKey('media-library-style-tree-sidebar-width'),
        title: '侧栏宽度',
        value: settings.mediaTreeSidebarWidth,
        min: MediaLibraryViewDefaults.minTreeSidebarWidth,
        max: MediaLibraryViewDefaults.maxTreeSidebarWidth,
        divisions: 260,
        valueText: '${settings.mediaTreeSidebarWidth.round()} px',
        onChanged: (v) => settings.updateSetting('mediaTreeSidebarWidth', v),
      ),
      _boolSwitch(
        title: '显示项目数',
        value: settings.mediaTreeShowCounts,
        onChanged: (v) => settings.updateSetting('mediaTreeShowCounts', v),
      ),
      const SizedBox(height: 16),
      Text(
        '右侧视图样式',
        style: TextStyle(
          color: AppTokens.text1,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 8),
      ...switch (content) {
        MediaLibraryContentLayout.grid => _gridSection(
          context,
          settings,
          size,
          includePlaceholder: false,
        ),
        MediaLibraryContentLayout.rows => _rowsSection(
          context,
          settings,
          size,
          includePlaceholder: false,
        ),
        MediaLibraryContentLayout.table => _tableSection(
          context,
          settings,
          size,
          includePlaceholder: false,
        ),
      },
    ];
  }

  Widget _placeholderEntry(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final label = settings.folderPlaceholderSettings.paintStyleLabel;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: AppTokens.bgCard,
        borderRadius: BorderRadius.circular(12),
        child: ListTile(
          key: const ValueKey<String>('folder-placeholder-style-entry'),
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          title: const Text(
            '文件夹占位',
            style: TextStyle(color: AppTokens.text1, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(label, style: TextStyle(color: AppTokens.text3)),
          trailing: const Icon(Icons.chevron_right, color: AppTokens.text3),
          onTap: () {
            unawaited(
              FolderPlaceholderStyleDialog.show(
                context: context,
                scope: widget.scope,
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _logSlider({
    required String title,
    required String valueText,
    required LogMappedRange range,
    required double value,
    required int divisions,
    required ValueChanged<double> onChanged,
  }) {
    final sliderValue = range.toSlider(value).clamp(0.0, 1.0);
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(title, style: const TextStyle(color: AppTokens.text1)),
            Flexible(
              child: Text(
                valueText,
                textAlign: TextAlign.right,
                style: const TextStyle(
                  color: AppTokens.accent,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
        Slider(
          value: sliderValue,
          min: 0,
          max: 1,
          divisions: divisions,
          activeColor: AppTokens.accent,
          onChanged: (t) => onChanged(range.fromSlider(t)),
        ),
      ],
    );
  }

  Widget _valueSlider({
    Key? key,
    required String title,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String valueText,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      key: key,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(title, style: const TextStyle(color: AppTokens.text1)),
            Text(
              valueText,
              style: const TextStyle(
                color: AppTokens.accent,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: math.max(1, divisions),
          activeColor: AppTokens.accent,
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _boolSwitch({
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      value: value,
      activeThumbColor: AppTokens.accent,
      title: Text(title, style: const TextStyle(color: AppTokens.text1)),
      onChanged: onChanged,
    );
  }
}

class _ResetOrientationButton extends StatelessWidget {
  const _ResetOrientationButton({
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          key: const ValueKey('media-library-style-reset-orientation'),
          onPressed: onPressed,
          child: Text(label, style: TextStyle(color: AppTokens.text2)),
        ),
      ),
    );
  }
}

class _ViewModeSegmentedControl extends StatelessWidget {
  const _ViewModeSegmentedControl({
    required this.selected,
    required this.onSelected,
    required this.duration,
  });

  final MediaLibraryViewMode selected;
  final ValueChanged<MediaLibraryViewMode> onSelected;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const count = 4;
        final itemWidth = constraints.maxWidth / count;
        final index = selected.index;
        return Container(
          key: const ValueKey('media-library-style-mode-segment'),
          height: 36,
          decoration: BoxDecoration(
            color: AppTokens.bgCard,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Stack(
            children: [
              AnimatedPositioned(
                duration: duration,
                curve: Curves.easeOutCubic,
                left: itemWidth * index + 2,
                top: 2,
                bottom: 2,
                width: itemWidth - 4,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppTokens.accentSoft,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTokens.accent.withValues(alpha: 0.35)),
                  ),
                ),
              ),
              Row(
                children: [
                  for (final mode in MediaLibraryViewMode.values)
                    Expanded(
                      child: Material(
                        type: MaterialType.transparency,
                        child: InkWell(
                          onTap: () => onSelected(mode),
                          borderRadius: BorderRadius.circular(8),
                          child: Center(
                            child: Text(
                              mode.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: mode == selected
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                color: mode == selected
                                    ? AppTokens.accent
                                    : AppTokens.text2,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ContentLayoutSegment extends StatelessWidget {
  const _ContentLayoutSegment({
    required this.selected,
    required this.onSelected,
  });

  final MediaLibraryContentLayout selected;
  final ValueChanged<MediaLibraryContentLayout> onSelected;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final layout in MediaLibraryContentLayout.values)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Material(
                color: layout == selected
                    ? AppTokens.accentSoft
                    : AppTokens.bgCard,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  onTap: () => onSelected(layout),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Center(
                      child: Text(
                        layout.label,
                        style: TextStyle(
                          fontSize: 12,
                          color: layout == selected
                              ? AppTokens.accent
                              : AppTokens.text2,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _TableSortPicker extends StatelessWidget {
  const _TableSortPicker({required this.settings});

  final SettingsService settings;

  @override
  Widget build(BuildContext context) {
    final active = settings.mediaTableSort;
    final descending = settings.mediaTableSortDescending;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<MediaTableSortKey>(
          key: const ValueKey('media-library-style-table-sort'),
          initialValue: active,
          dropdownColor: AppTokens.bgCard,
          decoration: InputDecoration(
            filled: true,
            fillColor: AppTokens.bgCard,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
          items: [
            for (final key in MediaTableSortKey.values)
              DropdownMenuItem(
                value: key,
                child: Text(
                  _sortName(key),
                  style: TextStyle(color: AppTokens.text1, fontSize: 13),
                ),
              ),
          ],
          onChanged: (key) {
            if (key == null) return;
            unawaited(settings.setMediaTableSort(key));
          },
        ),
        if (active != MediaTableSortKey.manual)
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: descending,
            activeThumbColor: AppTokens.accent,
            title: const Text(
              '降序排列',
              style: TextStyle(color: AppTokens.text1, fontSize: 13),
            ),
            onChanged: (value) => unawaited(
              settings.setMediaTableSort(active, descending: value),
            ),
          ),
      ],
    );
  }

  String _sortName(MediaTableSortKey key) => switch (key) {
    MediaTableSortKey.manual => '手动顺序',
    MediaTableSortKey.title => '名称',
    MediaTableSortKey.type => '类型',
    MediaTableSortKey.duration => '时长',
    MediaTableSortKey.progress => '进度',
    MediaTableSortKey.updated => '最近更新',
  };
}

class _StylePreviewStrip extends StatelessWidget {
  const _StylePreviewStrip({
    required this.mode,
    required this.settings,
    required this.size,
    required this.scope,
    required this.duration,
  });

  final MediaLibraryViewMode mode;
  final SettingsService settings;
  final Size size;
  final MediaLibraryCardStyleScope scope;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final height = 52.0;
    Widget preview;
    switch (mode) {
      case MediaLibraryViewMode.grid:
        final style = scope == MediaLibraryCardStyleScope.home
            ? settings.homeCardStyleFor(size)
            : settings.collectionCardStyleFor(size);
        final cols = style.crossAxisCount.clamp(2, 4);
        preview = Row(
          children: [
            for (var i = 0; i < cols; i++)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Column(
                    children: [
                      for (var r = 0; r < 2; r++)
                        Expanded(
                          child: AnimatedContainer(
                            duration: duration,
                            margin: const EdgeInsets.only(bottom: 3),
                            decoration: BoxDecoration(
                              color: AppTokens.bgCard,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        );
      case MediaLibraryViewMode.rows:
        final rowStyle = settings.rowsStyleFor(size);
        final rowH = (rowStyle.rowExtent ??
                MediaLibraryViewDefaults.rowsExtent(size)) /
            4;
        preview = Column(
          children: [
            for (var i = 0; i < 3; i++)
              Expanded(
                child: AnimatedContainer(
                  duration: duration,
                  margin: const EdgeInsets.only(bottom: 3),
                  decoration: BoxDecoration(
                    color: AppTokens.bgCard,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  height: rowH,
                ),
              ),
          ],
        );
      case MediaLibraryViewMode.table:
        preview = Column(
          children: [
            for (var i = 0; i < 4; i++)
              Expanded(
                child: Container(
                  margin: const EdgeInsets.only(bottom: 2),
                  color: i.isOdd ? AppTokens.bgCard : AppTokens.bgOverlay,
                ),
              ),
          ],
        );
      case MediaLibraryViewMode.tree:
        preview = Row(
          children: [
            AnimatedContainer(
              duration: duration,
              width: settings.mediaTreeSidebarWidth.clamp(48, 120) / 3,
              decoration: BoxDecoration(
                color: AppTokens.bgCard,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                children: [
                  for (var i = 0; i < 3; i++)
                    Expanded(
                      child: AnimatedContainer(
                        duration: duration,
                        margin: const EdgeInsets.only(bottom: 3),
                        decoration: BoxDecoration(
                          color: AppTokens.bgCard,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
    }

    return AnimatedContainer(
      duration: duration,
      height: height,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: AppTokens.bgOverlay,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTokens.lineSubtle),
      ),
      child: preview,
    );
  }
}
