import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/settings_service.dart';
import '../theme/app_tokens.dart';
import 'folder_placeholder_style_dialog.dart';
import 'media_library_layout_profile.dart';
import 'media_list_layout_metrics.dart';

/// Shared portrait/landscape style sheet for the home and collection grids.
class MediaLibraryStyleSheet {
  const MediaLibraryStyleSheet._();

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
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (context) => _MediaLibraryStyleSheetBody(scope: scope),
    );
  }
}

class _MediaLibraryStyleSheetBody extends StatelessWidget {
  const _MediaLibraryStyleSheetBody({required this.scope});

  final MediaLibraryCardStyleScope scope;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final size = MediaQuery.sizeOf(context);
    final isLandscape = MediaLibraryLayoutDefaults.isLandscape(size);
    final isListMode = settings.mediaLibraryViewMode == 1;
    final orientationLabel = isLandscape ? '横屏' : '竖屏';
    final cardStyle = scope == MediaLibraryCardStyleScope.home
        ? settings.homeCardStyleFor(size)
        : settings.collectionCardStyleFor(size);
    final listStyle = settings.listStyleFor(size);
    final cardMetrics = MediaLibraryLayoutDefaults.cardGrid(
      textScaler: MediaQuery.textScalerOf(context),
      textStyle: DefaultTextStyle.of(context).style,
      screenSize: size,
      style: cardStyle,
    );
    final maxHeight = MediaQuery.sizeOf(context).height * 0.62;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
        children: [
          Text(
            isListMode
                ? '列表样式调整 · $orientationLabel'
                : '卡片样式调整 · $orientationLabel',
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '横屏和竖屏的样式分开保存。间距、字号都以当前卡片宽度为基准。',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.46),
              fontSize: 12,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            key: const ValueKey('show-action-button-labels'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: settings.showActionButtonLabels,
            activeThumbColor: Colors.blueAccent,
            title: const Text(
              '显示按钮名称',
              style: TextStyle(color: Colors.white70),
            ),
            subtitle: const Text(
              '在展开、收起的悬浮按钮中显示名称，横竖屏通用',
              style: TextStyle(color: AppTokens.text2, fontSize: 12),
            ),
            onChanged: (value) =>
                settings.updateSetting('showActionButtonLabels', value),
          ),
          const SizedBox(height: 12),
          if (!isListMode)
            ..._cardSliders(
              context: context,
              settings: settings,
              size: size,
              style: cardStyle,
              metrics: cardMetrics,
            )
          else
            ..._listSliders(
              context: context,
              settings: settings,
              size: size,
              style: listStyle,
            ),
        ],
      ),
    );
  }

  List<Widget> _cardSliders({
    required BuildContext context,
    required SettingsService settings,
    required Size size,
    required MediaCardStyleSettings style,
    required MediaLibraryCardGridMetrics metrics,
  }) {
    Future<void> update({
      int? crossAxisCount,
      double? titleScale,
      double? heightScale,
      double? crossSpacingScale,
      double? mainSpacingScale,
    }) {
      if (scope == MediaLibraryCardStyleScope.home) {
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
        ? metrics.cellWidth * style.titleScale
        : MediaLibraryLayoutDefaults.titleFontSize(
            metrics.cellWidth,
            style.titleScale,
          );
    final displayedHeightScale = style.reserveTwoTitleLines
        ? metrics.cellHeight / metrics.cellWidth
        : style.heightScale;
    return [
      _placeholderEntry(context),
      _logSlider(
        title: '每行卡片数量',
        valueText: '${style.crossAxisCount} 列 · 宽 ${metrics.cellWidth.round()}',
        range: MediaLibraryLayoutDefaults.columnRange,
        value: style.crossAxisCount.toDouble(),
        divisions: 240,
        onChanged: (value) =>
            update(crossAxisCount: value.round().clamp(1, 20)),
      ),
      _logSlider(
        title: '标题字号',
        valueText:
            '${(style.titleScale * 100).toStringAsFixed(1)}% · ${titlePx.toStringAsFixed(1)} px',
        range: MediaLibraryLayoutDefaults.titleRange,
        value: style.titleScale,
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
            '${(style.crossSpacingScale * 100).toStringAsFixed(1)}% 宽 · ${metrics.crossSpacing.toStringAsFixed(1)} px',
        range: MediaLibraryLayoutDefaults.spacingRange,
        value: style.crossSpacingScale,
        divisions: 280,
        onChanged: (value) => update(crossSpacingScale: value),
      ),
      _logSlider(
        title: '纵向间距',
        valueText:
            '${(style.mainSpacingScale * 100).toStringAsFixed(1)}% 宽 · ${metrics.mainSpacing.toStringAsFixed(1)} px',
        range: MediaLibraryLayoutDefaults.spacingRange,
        value: style.mainSpacingScale,
        divisions: 280,
        onChanged: (value) => update(mainSpacingScale: value),
      ),
    ];
  }

  List<Widget> _listSliders({
    required BuildContext context,
    required SettingsService settings,
    required Size size,
    required MediaListStyleSettings style,
  }) {
    final metrics = MediaListLayoutMetrics.forGrid(
      screenShortestSide: size.shortestSide,
      availableWidth: size.width,
      crossAxisCount: style.crossAxisCount,
      heightSetting: style.heightScale,
      titleSetting: style.titleScale,
      mainSpacingSetting: style.mainSpacingScale,
      crossSpacingSetting: style.crossSpacingScale,
    );
    return [
      _placeholderEntry(context),
      _logSlider(
        title: '每行数量',
        valueText: '${style.crossAxisCount} 列 · 宽 ${metrics.cellWidth.round()}',
        range: MediaLibraryLayoutDefaults.listColumnRange,
        value: style.crossAxisCount.toDouble(),
        divisions: 240,
        onChanged: (value) => settings.updateListStyleFor(
          size,
          crossAxisCount: value.round().clamp(1, 20),
        ),
      ),
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        value: style.showThumbnail,
        activeThumbColor: Colors.blueAccent,
        title: const Text('显示缩略图', style: TextStyle(color: Colors.white70)),
        onChanged: (value) =>
            settings.updateListStyleFor(size, showThumbnail: value),
      ),
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        value: style.showIndex,
        activeThumbColor: Colors.blueAccent,
        title: const Text('显示序号', style: TextStyle(color: Colors.white70)),
        onChanged: (value) =>
            settings.updateListStyleFor(size, showIndex: value),
      ),
      _logSlider(
        title: '卡片高度',
        valueText:
            '${MediaListLayoutMetrics.referenceRowHeight(style.titleScale, style.heightScale).round()} px @390 · ×${MediaListLayoutMetrics.heightAdjustment(style.heightScale).toStringAsFixed(2)}',
        range: const LogMappedRange(min: 0.001, max: 0.15, pivot: 0.10),
        value: style.heightScale,
        divisions: 200,
        onChanged: (value) =>
            settings.updateListStyleFor(size, heightScale: value),
      ),
      _logSlider(
        title: '横向间距',
        valueText:
            '${(style.crossSpacingScale * 100).toStringAsFixed(1)}% 宽 · ${metrics.crossSpacing.toStringAsFixed(1)} px',
        range: MediaLibraryLayoutDefaults.spacingRange,
        value: style.crossSpacingScale,
        divisions: 280,
        onChanged: (value) =>
            settings.updateListStyleFor(size, crossSpacingScale: value),
      ),
      _logSlider(
        title: '纵向间距',
        valueText:
            '${(style.mainSpacingScale * 100).toStringAsFixed(1)}% 宽 · ${metrics.mainSpacing.toStringAsFixed(1)} px',
        range: MediaLibraryLayoutDefaults.spacingRange,
        value: style.mainSpacingScale,
        divisions: 280,
        onChanged: (value) =>
            settings.updateListStyleFor(size, mainSpacingScale: value),
      ),
      _logSlider(
        title: '标题字号',
        valueText:
            '${MediaListLayoutMetrics.referenceTitleSize(style.titleScale).toStringAsFixed(1)} px @390',
        range: const LogMappedRange(min: 0.001, max: 0.065, pivot: 0.042),
        value: style.titleScale,
        divisions: 200,
        onChanged: (value) =>
            settings.updateListStyleFor(size, titleScale: value),
      ),
    ];
  }

  Widget _placeholderEntry(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final label = settings.folderPlaceholderSettings.paintStyleLabel;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(12),
        child: ListTile(
          key: const ValueKey<String>('folder-placeholder-style-entry'),
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          title: const Text(
            '文件夹占位',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            label,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.55)),
          ),
          trailing: const Icon(Icons.chevron_right, color: Colors.white38),
          onTap: () {
            unawaited(
              FolderPlaceholderStyleDialog.show(context: context, scope: scope),
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
            Text(title, style: const TextStyle(color: Colors.white70)),
            Flexible(
              child: Text(
                valueText,
                textAlign: TextAlign.right,
                style: const TextStyle(
                  color: Colors.blueAccent,
                  fontWeight: FontWeight.w600,
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
          onChanged: (t) => onChanged(range.fromSlider(t)),
        ),
      ],
    );
  }
}
