import 'media_library_card_scale.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/folder_placeholder_style.dart';
import '../models/video_collection.dart';
import '../services/settings_service.dart';
import '../theme/app_tokens.dart';
import 'adaptive_settings_dialog.dart';
import 'folder_placeholder_cover.dart';
import 'media_library_grid_card.dart';
import 'media_library_layout_profile.dart';
import 'media_library_list_tile.dart';
import 'media_list_layout_metrics.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Fixed 3×2 sample folders so the picker can show color/glyph diversity
/// without reading the user's library.
const List<FolderPlaceholderPreviewSample>
kFolderPlaceholderPreviewSamples = <FolderPlaceholderPreviewSample>[
  FolderPlaceholderPreviewSample(id: 'preview-riju', name: '日剧', itemCount: 12),
  FolderPlaceholderPreviewSample(
    id: 'preview-movies',
    name: 'Movies',
    itemCount: 28,
  ),
  FolderPlaceholderPreviewSample(
    id: 'preview-music',
    name: '音乐',
    itemCount: 45,
  ),
  FolderPlaceholderPreviewSample(id: 'preview-math', name: '数学', itemCount: 7),
  FolderPlaceholderPreviewSample(
    id: 'preview-sanguo',
    name: '《三国演义》',
    itemCount: 19,
  ),
  FolderPlaceholderPreviewSample(
    id: 'preview-2024',
    name: '2024',
    itemCount: 3,
  ),
];

class FolderPlaceholderPreviewSample {
  const FolderPlaceholderPreviewSample({
    required this.id,
    required this.name,
    required this.itemCount,
  });

  final String id;
  final String name;
  final int itemCount;
}

/// How the dialog chrome is arranged for a given screen.
enum FolderPlaceholderPane {
  /// Phone portrait: picker, capped preview, then scrolling controls.
  stacked,

  /// Phone landscape: preview left, picker + controls right.
  landscapeStrip,

  /// Tablet/desktop landscape: picker + preview left, controls right.
  splitStart,

  /// Tablet/desktop portrait: picker on top, preview | controls below.
  splitTop,
}

/// Layout knobs so picker, 3×2 preview, and sliders share the dialog without
/// looking like the same row of cards twice.
@immutable
class FolderPlaceholderDialogLayout {
  const FolderPlaceholderDialogLayout({
    required this.pane,
    required this.previewMaxHeight,
    required this.pickerCoverMaxHeight,
    required this.gridSpacing,
    required this.compactControls,
    required this.panelRadius,
    required this.panelPadding,
    required this.shortCaption,
  });

  final FolderPlaceholderPane pane;
  final double previewMaxHeight;
  final double pickerCoverMaxHeight;
  final double gridSpacing;
  final bool compactControls;
  final double panelRadius;
  final EdgeInsets panelPadding;
  final bool shortCaption;

  bool get useSplitPane => pane != FolderPlaceholderPane.stacked;

  factory FolderPlaceholderDialogLayout.from({
    required Size screen,
    required AdaptiveSettingsDialogMetrics metrics,
  }) {
    final width = screen.width;
    final height = screen.height;
    final landscape = width > height;
    final shortest = math.min(width, height);
    final compact = metrics.isCompact || height < 520;
    final isPhone = shortest < 600;
    final pane = isPhone
        ? (landscape
              ? FolderPlaceholderPane.landscapeStrip
              : FolderPlaceholderPane.stacked)
        : (landscape
              ? FolderPlaceholderPane.splitStart
              : FolderPlaceholderPane.splitTop);
    final previewBudget = switch (pane) {
      FolderPlaceholderPane.stacked =>
        (metrics.contentMaxHeight * (compact ? 0.20 : 0.22)).clamp(
          96.0,
          compact ? 132.0 : 148.0,
        ),
      FolderPlaceholderPane.landscapeStrip => metrics.contentMaxHeight,
      FolderPlaceholderPane.splitStart =>
        (metrics.contentMaxHeight * 0.62).clamp(150.0, 300.0),
      FolderPlaceholderPane.splitTop => (metrics.contentMaxHeight * 0.78).clamp(
        170.0,
        440.0,
      ),
    };
    final pickerCoverMaxHeight = switch (pane) {
      FolderPlaceholderPane.stacked => compact ? 30.0 : 34.0,
      FolderPlaceholderPane.landscapeStrip => 26.0,
      FolderPlaceholderPane.splitStart => compact ? 38.0 : 44.0,
      FolderPlaceholderPane.splitTop => 46.0,
    };
    return FolderPlaceholderDialogLayout(
      pane: pane,
      previewMaxHeight: previewBudget.toDouble(),
      pickerCoverMaxHeight: pickerCoverMaxHeight,
      gridSpacing: compact || pane == FolderPlaceholderPane.landscapeStrip
          ? 5.0
          : 8.0,
      compactControls: compact || pane == FolderPlaceholderPane.landscapeStrip,
      panelRadius: compact ? 10.0 : 12.0,
      panelPadding: EdgeInsets.fromLTRB(
        compact ? 8 : 10,
        compact ? 6 : 8,
        compact ? 8 : 10,
        compact ? 6 : 8,
      ),
      shortCaption: pane == FolderPlaceholderPane.landscapeStrip || compact,
    );
  }
}

class FolderPlaceholderStyleDialog {
  const FolderPlaceholderStyleDialog._();

  static const Key dialogKey = ValueKey<String>(
    'folder-placeholder-style-dialog',
  );
  static const Key previewGridKey = ValueKey<String>(
    'folder-placeholder-preview-grid',
  );
  static const Key pickerPanelKey = ValueKey<String>(
    'folder-placeholder-picker-panel',
  );
  static const Key previewPanelKey = ValueKey<String>(
    'folder-placeholder-preview-panel',
  );

  /// Recessed toolbox behind the three paint swatches.
  static const Color pickerPanelColor = Color(0xFF12151A);

  /// Library-stage board behind the live 3×2 cards.
  static const Color previewPanelColor = Color(0xFF2B3038);

  static Future<void> show({
    required BuildContext context,
    required MediaLibraryCardStyleScope scope,
  }) {
    return showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) {
        return FolderPlaceholderStyleDialogBody(scope: scope);
      },
    );
  }
}

class FolderPlaceholderStyleDialogBody extends StatelessWidget {
  const FolderPlaceholderStyleDialogBody({super.key, required this.scope});

  final MediaLibraryCardStyleScope scope;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final metrics = AdaptiveSettingsDialogMetrics.fromSize(
      screen,
      preferredWidth: screen.width >= 1400
          ? 1040
          : screen.width >= 1100
          ? 960
          : screen.width >= 800
          ? 840
          : 760,
    );
    final layout = FolderPlaceholderDialogLayout.from(
      screen: screen,
      metrics: metrics,
    );
    return AdaptiveSettingsDialogTheme(
      metrics: metrics,
      child: AlertDialog(
        key: FolderPlaceholderStyleDialog.dialogKey,
        backgroundColor: AppTokens.bgRaised,
        insetPadding: metrics.insetPadding,
        titlePadding: metrics.titlePadding,
        contentPadding: metrics.contentPadding,
        actionsPadding: metrics.actionsPadding,
        constraints: BoxConstraints(
          maxWidth: metrics.dialogWidth,
          maxHeight: metrics.dialogMaxHeight,
        ),
        title: Text(
          '文件夹占位',
          style: TextStyle(
            color: Colors.white,
            fontSize: metrics.titleSize,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: SizedBox(
          width: metrics.dialogWidth,
          height: metrics.contentMaxHeight,
          child: Consumer<SettingsService>(
            builder: (context, settings, _) {
              return _DialogBody(
                metrics: metrics,
                layout: layout,
                settings: settings,
                scope: scope,
              );
            },
          ),
        ),
        actions: [
          DesktopButtonClickRegion(
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('完成'),
            ),
          ),
        ],
      ),
    );
  }
}

class _DialogBody extends StatelessWidget {
  const _DialogBody({
    required this.metrics,
    required this.layout,
    required this.settings,
    required this.scope,
  });

  final AdaptiveSettingsDialogMetrics metrics;
  final FolderPlaceholderDialogLayout layout;
  final SettingsService settings;
  final MediaLibraryCardStyleScope scope;

  @override
  Widget build(BuildContext context) {
    final current = settings.folderPlaceholderSettings;
    final caption = Text(
      layout.shortCaption
          ? '网格和列表共用，大小按封面短边缩放。'
          : '网格和列表共用这一套。大小按封面短边比例缩放，避免 16:9 封面把字撑出画面。',
      style: TextStyle(
        color: Colors.white.withValues(alpha: 0.46),
        fontSize: metrics.captionSize,
        height: 1.3,
      ),
    );
    final picker = _SectionShell(
      panelKey: FolderPlaceholderStyleDialog.pickerPanelKey,
      title: '画法',
      color: FolderPlaceholderStyleDialog.pickerPanelColor,
      layout: layout,
      metrics: metrics,
      child: _PaintStylePicker(
        current: current,
        coverMaxHeight: layout.pickerCoverMaxHeight,
        compact: layout.compactControls,
        onSelected: (style) => settings.updateFolderPlaceholderSettings(
          current.copyWith(paintStyle: style),
        ),
      ),
    );
    final previewGrid = _LivePreviewGrid(settings: settings, scope: scope);
    final preview = _SectionShell(
      panelKey: FolderPlaceholderStyleDialog.previewPanelKey,
      title: '实时预览',
      color: FolderPlaceholderStyleDialog.previewPanelColor,
      layout: layout,
      metrics: metrics,
      expandChild: true,
      child: previewGrid,
    );
    final controls = _ControlsColumn(
      metrics: metrics,
      layout: layout,
      settings: settings,
      current: current,
    );

    return switch (layout.pane) {
      FolderPlaceholderPane.stacked => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          caption,
          SizedBox(height: metrics.gap),
          picker,
          SizedBox(height: metrics.gap),
          SizedBox(height: layout.previewMaxHeight, child: preview),
          SizedBox(height: metrics.gap),
          Expanded(child: SingleChildScrollView(child: controls)),
        ],
      ),
      FolderPlaceholderPane.landscapeStrip => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          picker,
          SizedBox(height: metrics.gap),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 7, child: preview),
                SizedBox(width: metrics.gap),
                Expanded(
                  flex: 8,
                  child: SingleChildScrollView(child: controls),
                ),
              ],
            ),
          ),
        ],
      ),
      FolderPlaceholderPane.splitStart => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          caption,
          SizedBox(height: metrics.gap),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 12,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      picker,
                      SizedBox(height: metrics.gap),
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final height = math.min(
                              layout.previewMaxHeight,
                              constraints.maxHeight,
                            );
                            return Align(
                              alignment: Alignment.topCenter,
                              child: SizedBox(
                                height: height,
                                width: constraints.maxWidth,
                                child: preview,
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: metrics.gap + 6),
                Expanded(
                  flex: 10,
                  child: SingleChildScrollView(child: controls),
                ),
              ],
            ),
          ),
        ],
      ),
      FolderPlaceholderPane.splitTop => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          caption,
          SizedBox(height: metrics.gap),
          picker,
          SizedBox(height: metrics.gap),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 13,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final height = math.min(
                        layout.previewMaxHeight,
                        constraints.maxHeight,
                      );
                      return Align(
                        alignment: Alignment.topCenter,
                        child: SizedBox(
                          height: height,
                          width: constraints.maxWidth,
                          child: preview,
                        ),
                      );
                    },
                  ),
                ),
                SizedBox(width: metrics.gap + 6),
                Expanded(
                  flex: 10,
                  child: SingleChildScrollView(child: controls),
                ),
              ],
            ),
          ),
        ],
      ),
    };
  }
}

class _SectionShell extends StatelessWidget {
  const _SectionShell({
    required this.panelKey,
    required this.title,
    required this.color,
    required this.layout,
    required this.metrics,
    required this.child,
    this.expandChild = false,
  });

  final Key panelKey;
  final String title;
  final Color color;
  final FolderPlaceholderDialogLayout layout;
  final AdaptiveSettingsDialogMetrics metrics;
  final Widget child;
  final bool expandChild;

  @override
  Widget build(BuildContext context) {
    final header = Padding(
      padding: EdgeInsets.only(bottom: layout.compactControls ? 4 : 6),
      child: Text(
        title,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.72),
          fontSize: metrics.captionSize,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
    final body = expandChild
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              Expanded(child: child),
            ],
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [header, child],
          );
    return DecoratedBox(
      key: panelKey,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(layout.panelRadius),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Padding(padding: layout.panelPadding, child: body),
    );
  }
}

class _ControlsColumn extends StatelessWidget {
  const _ControlsColumn({
    required this.metrics,
    required this.layout,
    required this.settings,
    required this.current,
  });

  final AdaptiveSettingsDialogMetrics metrics;
  final FolderPlaceholderDialogLayout layout;
  final SettingsService settings;
  final FolderPlaceholderSettings current;

  @override
  Widget build(BuildContext context) {
    final isTintedBadge =
        current.paintStyle == FolderPlaceholderPaintStyle.tintedIcon;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: const ValueKey<String>('folder-placeholder-show-cover-text'),
          contentPadding: EdgeInsets.zero,
          dense: layout.compactControls,
          title: Text(
            isTintedBadge ? '显示字母徽章' : '显示封面文字',
            style: TextStyle(color: Colors.white70, fontSize: metrics.bodySize),
          ),
          subtitle: Text(
            isTintedBadge ? '关闭后只保留染色文件夹图标' : '关闭后封面只保留颜色和图标',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.46),
              fontSize: metrics.captionSize,
            ),
          ),
          value: current.showCoverText,
          onChanged: (value) => settings.updateFolderPlaceholderSettings(
            current.copyWith(showCoverText: value),
          ),
        ),
        if (current.showCoverText) ...[
          SizedBox(height: metrics.gap),
          Text(
            isTintedBadge ? '徽章文字上限' : '封面文字上限',
            style: TextStyle(color: Colors.white70, fontSize: metrics.bodySize),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final count in <int>[1, 2, 3, 4])
                ChoiceChip(
                  key: ValueKey<String>('folder-placeholder-max-text-$count'),
                  label: Text('$count 字'),
                  selected: current.maxCoverTextLength == count,
                  onSelected: (_) => settings.updateFolderPlaceholderSettings(
                    current.copyWith(maxCoverTextLength: count),
                  ),
                  selectedColor: Colors.blueAccent.withValues(alpha: 0.28),
                  backgroundColor: const Color(0xFF2A2A2A),
                  visualDensity: layout.compactControls
                      ? VisualDensity.compact
                      : VisualDensity.standard,
                  labelStyle: TextStyle(
                    color: Colors.white.withValues(
                      alpha: current.maxCoverTextLength == count ? 0.95 : 0.7,
                    ),
                    fontSize: metrics.captionSize,
                  ),
                  side: BorderSide(
                    color: current.maxCoverTextLength == count
                        ? Colors.blueAccent
                        : Colors.white12,
                  ),
                ),
            ],
          ),
        ],
        SizedBox(height: metrics.gap),
        Text(
          '颜色风格',
          style: TextStyle(color: Colors.white70, fontSize: metrics.bodySize),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final style in FolderPlaceholderColorStyle.values)
              ChoiceChip(
                key: ValueKey<String>('folder-placeholder-color-${style.name}'),
                label: Text(folderPlaceholderColorStyleLabel(style)),
                selected: current.colorStyle == style,
                onSelected: (_) => settings.updateFolderPlaceholderSettings(
                  current.copyWith(colorStyle: style),
                ),
                selectedColor: Colors.blueAccent.withValues(alpha: 0.28),
                backgroundColor: const Color(0xFF2A2A2A),
                visualDensity: layout.compactControls
                    ? VisualDensity.compact
                    : VisualDensity.standard,
                labelStyle: TextStyle(
                  color: Colors.white.withValues(
                    alpha: current.colorStyle == style ? 0.95 : 0.7,
                  ),
                  fontSize: metrics.captionSize,
                ),
                side: BorderSide(
                  color: current.colorStyle == style
                      ? Colors.blueAccent
                      : Colors.white12,
                ),
              ),
          ],
        ),
        SizedBox(height: metrics.gap),
        ..._slidersFor(current),
        Align(
          alignment: Alignment.centerRight,
          child: DesktopButtonClickRegion(
            child: TextButton(
              onPressed: () => settings.updateFolderPlaceholderSettings(
                current.resetCurrentPaintDefaults(),
              ),
              child: const Text('恢复此画法默认'),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _slidersFor(FolderPlaceholderSettings current) {
    switch (current.paintStyle) {
      case FolderPlaceholderPaintStyle.letterBlock:
        return [
          if (current.showCoverText) ...[
            _ScaleSlider(
              keyName: 'letterScale',
              title: '文字大小',
              value: current.letterScale,
              spec: FolderPlaceholderSettings.letterScaleSpec,
              compact: layout.compactControls,
              onChanged: (value) => settings.updateFolderPlaceholderSettings(
                current.copyWith(letterScale: value),
              ),
            ),
            _ScaleSlider(
              keyName: 'letterOpacity',
              title: '文字不透明度',
              value: current.letterOpacity,
              spec: FolderPlaceholderSettings.letterOpacitySpec,
              compact: layout.compactControls,
              onChanged: (value) => settings.updateFolderPlaceholderSettings(
                current.copyWith(letterOpacity: value),
              ),
            ),
          ],
          _ScaleSlider(
            keyName: 'cornerBadgeScale',
            title: '角标大小',
            value: current.cornerBadgeScale,
            spec: FolderPlaceholderSettings.cornerBadgeScaleSpec,
            compact: layout.compactControls,
            zeroLabel: '关闭',
            onChanged: (value) => settings.updateFolderPlaceholderSettings(
              current.copyWith(cornerBadgeScale: value),
            ),
          ),
        ];
      case FolderPlaceholderPaintStyle.tintedIcon:
        return [
          _ScaleSlider(
            keyName: 'folderIconScale',
            title: '文件夹大小',
            value: current.folderIconScale,
            spec: FolderPlaceholderSettings.folderIconScaleSpec,
            compact: layout.compactControls,
            onChanged: (value) => settings.updateFolderPlaceholderSettings(
              current.copyWith(folderIconScale: value),
            ),
          ),
          _ScaleSlider(
            keyName: 'iconOpacity',
            title: '图标不透明度',
            value: current.iconOpacity,
            spec: FolderPlaceholderSettings.iconOpacitySpec,
            compact: layout.compactControls,
            onChanged: (value) => settings.updateFolderPlaceholderSettings(
              current.copyWith(iconOpacity: value),
            ),
          ),
          if (current.showCoverText) ...[
            _ScaleSlider(
              keyName: 'letterBadgeScale',
              title: '字母徽章大小',
              value: current.letterBadgeScale,
              spec: FolderPlaceholderSettings.letterBadgeScaleSpec,
              compact: layout.compactControls,
              onChanged: (value) => settings.updateFolderPlaceholderSettings(
                current.copyWith(letterBadgeScale: value),
              ),
            ),
            _ScaleSlider(
              keyName: 'letterBadgeGlyphScale',
              title: '徽章文字大小',
              value: current.letterBadgeGlyphScale,
              spec: FolderPlaceholderSettings.letterBadgeGlyphScaleSpec,
              compact: layout.compactControls,
              onChanged: (value) => settings.updateFolderPlaceholderSettings(
                current.copyWith(letterBadgeGlyphScale: value),
              ),
            ),
          ],
        ];
      case FolderPlaceholderPaintStyle.gradientGhost:
        return [
          if (current.showCoverText) ...[
            _ScaleSlider(
              keyName: 'gradientLetterScale',
              title: '文字大小',
              value: current.gradientLetterScale,
              spec: FolderPlaceholderSettings.gradientLetterScaleSpec,
              compact: layout.compactControls,
              onChanged: (value) => settings.updateFolderPlaceholderSettings(
                current.copyWith(gradientLetterScale: value),
              ),
            ),
            _ScaleSlider(
              keyName: 'gradientLetterOpacity',
              title: '文字不透明度',
              value: current.gradientLetterOpacity,
              spec: FolderPlaceholderSettings.gradientLetterOpacitySpec,
              compact: layout.compactControls,
              onChanged: (value) => settings.updateFolderPlaceholderSettings(
                current.copyWith(gradientLetterOpacity: value),
              ),
            ),
          ],
          _ScaleSlider(
            keyName: 'silhouetteScale',
            title: '剪影大小',
            value: current.silhouetteScale,
            spec: FolderPlaceholderSettings.silhouetteScaleSpec,
            compact: layout.compactControls,
            onChanged: (value) => settings.updateFolderPlaceholderSettings(
              current.copyWith(silhouetteScale: value),
            ),
          ),
          _ScaleSlider(
            keyName: 'silhouetteOpacity',
            title: '剪影不透明度',
            value: current.silhouetteOpacity,
            spec: FolderPlaceholderSettings.silhouetteOpacitySpec,
            compact: layout.compactControls,
            onChanged: (value) => settings.updateFolderPlaceholderSettings(
              current.copyWith(silhouetteOpacity: value),
            ),
          ),
        ];
    }
  }
}

class _PaintStylePicker extends StatelessWidget {
  const _PaintStylePicker({
    required this.current,
    required this.coverMaxHeight,
    required this.onSelected,
    required this.compact,
  });

  final FolderPlaceholderSettings current;
  final double coverMaxHeight;
  final ValueChanged<FolderPlaceholderPaintStyle> onSelected;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final style in FolderPlaceholderPaintStyle.values) ...[
          if (style != FolderPlaceholderPaintStyle.values.first)
            SizedBox(width: compact ? 6 : 8),
          Expanded(
            child: _PaintStyleTile(
              style: style,
              selected: current.paintStyle == style,
              previewSettings: current.copyWith(paintStyle: style),
              coverMaxHeight: coverMaxHeight,
              compact: compact,
              onTap: () => onSelected(style),
            ),
          ),
        ],
      ],
    );
  }
}

class _PaintStyleTile extends StatelessWidget {
  const _PaintStyleTile({
    required this.style,
    required this.selected,
    required this.previewSettings,
    required this.coverMaxHeight,
    required this.compact,
    required this.onTap,
  });

  final FolderPlaceholderPaintStyle style;
  final bool selected;
  final FolderPlaceholderSettings previewSettings;
  final double coverMaxHeight;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: ValueKey<String>('folder-placeholder-paint-tile-${style.name}'),
      color: selected ? const Color(0xFF1B2430) : const Color(0xFF1A1C20),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(compact ? 8 : 10),
        side: BorderSide(
          color: selected
              ? Colors.blueAccent
              : Colors.white.withValues(alpha: 0.08),
          width: selected ? 1.6 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? 5 : 6,
            compact ? 5 : 6,
            compact ? 5 : 6,
            compact ? 5 : 6,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final height = math.min(
                    constraints.maxWidth * 9 / 16,
                    coverMaxHeight,
                  );
                  return SizedBox(
                    height: height,
                    width: double.infinity,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: CustomPaint(
                          painter: const _CheckerboardPainter(),
                          child: Padding(
                            padding: const EdgeInsets.all(3),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(3),
                              child: FolderPlaceholderCover(
                                folderId:
                                    kFolderPlaceholderPreviewSamples.first.id,
                                folderName:
                                    kFolderPlaceholderPreviewSamples.first.name,
                                settings: previewSettings,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
              SizedBox(height: compact ? 3 : 5),
              Text(
                folderPlaceholderPaintStyleLabel(style),
                key: ValueKey<String>('folder-placeholder-paint-${style.name}'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: selected ? 0.95 : 0.68),
                  fontSize: compact ? 10 : 11,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CheckerboardPainter extends CustomPainter {
  const _CheckerboardPainter();

  @override
  void paint(Canvas canvas, Size size) {
    const cell = 5.0;
    final light = Paint()..color = const Color(0xFF3C414A);
    final dark = Paint()..color = const Color(0xFF2A2E35);
    for (var y = 0.0; y < size.height; y += cell) {
      for (var x = 0.0; x < size.width; x += cell) {
        final odd = ((x / cell).floor() + (y / cell).floor()).isOdd;
        canvas.drawRect(Rect.fromLTWH(x, y, cell, cell), odd ? dark : light);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _LivePreviewGrid extends StatelessWidget {
  const _LivePreviewGrid({required this.settings, required this.scope});

  final SettingsService settings;
  final MediaLibraryCardStyleScope scope;

  @override
  Widget build(BuildContext context) {
    final isListMode = settings.mediaLibraryViewMode == 1;
    return KeyedSubtree(
      key: FolderPlaceholderStyleDialog.previewGridKey,
      child: isListMode
          ? _ListPreviewGrid(settings: settings)
          : _CardPreviewGrid(settings: settings, scope: scope),
    );
  }
}

/// Builds a 3×2 of **full-size** library cells, then scales the whole grid
/// with [BoxFit.contain]. Shrinking each card independently would re-run
/// padding/font clamps and stretch the cover vs. title block.
class _UniformScaledSampleGrid extends StatelessWidget {
  const _UniformScaledSampleGrid({
    required this.itemWidth,
    required this.itemHeight,
    required this.crossSpacing,
    required this.mainSpacing,
    required this.itemBuilder,
  });

  final double itemWidth;
  final double itemHeight;
  final double crossSpacing;
  final double mainSpacing;
  final Widget Function(BuildContext context, int index) itemBuilder;

  @override
  Widget build(BuildContext context) {
    const columns = 3;
    const rows = 2;
    if (itemWidth <= 0 || itemHeight <= 0) {
      return const SizedBox.shrink();
    }
    final gridWidth = itemWidth * columns + crossSpacing * (columns - 1);
    final gridHeight = itemHeight * rows + mainSpacing * (rows - 1);
    return FittedBox(
      fit: BoxFit.contain,
      alignment: Alignment.topCenter,
      child: SizedBox(
        width: gridWidth,
        height: gridHeight,
        child: GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: kFolderPlaceholderPreviewSamples.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: mainSpacing,
            crossAxisSpacing: crossSpacing,
            childAspectRatio: itemWidth / itemHeight,
          ),
          itemBuilder: itemBuilder,
        ),
      ),
    );
  }
}

class _CardPreviewGrid extends StatelessWidget {
  const _CardPreviewGrid({required this.settings, required this.scope});

  final SettingsService settings;
  final MediaLibraryCardStyleScope scope;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final style = scope == MediaLibraryCardStyleScope.home
        ? settings.homeCardStyleFor(size)
        : settings.collectionCardStyleFor(size);
    // Same cell as the library grid on this screen; the 3×2 is only a crop.
    final metrics = MediaLibraryLayoutDefaults.cardGrid(
      textScaler: MediaQuery.textScalerOf(context),
      textStyle: DefaultTextStyle.of(context).style,
      screenSize: size,
      style: style,
    );
    return _UniformScaledSampleGrid(
      itemWidth: metrics.cellWidth,
      itemHeight: metrics.cellHeight,
      crossSpacing: metrics.crossSpacing,
      mainSpacing: metrics.mainSpacing,
      itemBuilder: (context, index) {
        final sample = kFolderPlaceholderPreviewSamples[index];
        return MediaLibraryCardScale(
          builder: (context) => LayoutBuilder(
            builder: (context, constraints) {
              final cardWidth = constraints.maxWidth;
              final titleSize = MediaLibraryLayoutDefaults.titleFontSize(
                cardWidth,
                style.titleScale,
              );
              final metaSize = MediaLibraryLayoutDefaults.metaFontSize(
                titleSize,
              );
              return MediaLibraryGridCard(
                radius: MediaLibraryLayoutDefaults.cardCornerRadius(cardWidth),
                isSelected: false,
                onTap: () {},
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AspectRatio(
                      aspectRatio: 16 / 9,
                      child: FolderPlaceholderCover(
                        folderId: sample.id,
                        folderName: sample.name,
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: MediaListLayoutMetrics.cardGridContentPadding(
                          cardWidth,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                sample.name,
                                maxLines: settings.cardTitleMaxLinesFor(
                                  MediaQuery.sizeOf(context),
                                ),
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: titleSize,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${sample.itemCount} 个项目',
                              style: TextStyle(
                                fontSize: metaSize,
                                color: Colors.white54,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _ListPreviewGrid extends StatelessWidget {
  const _ListPreviewGrid({required this.settings});

  final SettingsService settings;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final listStyle = settings.listStyleFor(size);
    // Full-screen list cells, then the 3×2 crop is scaled as one piece.
    final metrics = MediaListLayoutMetrics.forGrid(
      screenShortestSide: size.shortestSide,
      availableWidth: size.width,
      crossAxisCount: listStyle.crossAxisCount,
      heightSetting: listStyle.heightScale,
      titleSetting: listStyle.titleScale,
      mainSpacingSetting: listStyle.mainSpacingScale,
      crossSpacingSetting: listStyle.crossSpacingScale,
    );
    return _UniformScaledSampleGrid(
      itemWidth: metrics.cellWidth,
      itemHeight: metrics.rowHeight,
      crossSpacing: metrics.crossSpacing,
      mainSpacing: metrics.mainSpacing,
      itemBuilder: (context, index) {
        final sample = kFolderPlaceholderPreviewSamples[index];
        return ClipRect(
          child: MediaLibraryListTile.collection(
            collection: VideoCollection(
              id: sample.id,
              name: sample.name,
              createTime: 0,
              childrenIds: List<String>.filled(sample.itemCount, 'item'),
            ),
            index: index,
            showIndex: false,
            showThumbnail: true,
            isSelected: false,
            isSelectionMode: false,
            titleScale: listStyle.titleScale,
            onTap: () {},
          ),
        );
      },
    );
  }
}

class _ScaleSlider extends StatelessWidget {
  const _ScaleSlider({
    required this.keyName,
    required this.title,
    required this.value,
    required this.spec,
    required this.onChanged,
    required this.compact,
    this.zeroLabel,
  });

  final String keyName;
  final String title;
  final double value;
  final FolderPlaceholderSliderSpec spec;
  final ValueChanged<double> onChanged;
  final bool compact;
  final String? zeroLabel;

  @override
  Widget build(BuildContext context) {
    final slider = spec.toSlider(value);
    final label = zeroLabel != null && value <= spec.min + 0.001
        ? zeroLabel!
        : slider.round().toString();
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              title,
              style: TextStyle(
                color: Colors.white70,
                fontSize: compact ? 12 : 13,
              ),
            ),
            Flexible(
              child: Text(
                label,
                textAlign: TextAlign.right,
                style: const TextStyle(
                  color: Colors.blueAccent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            overlayShape: compact
                ? const RoundSliderOverlayShape(overlayRadius: 12)
                : SliderTheme.of(context).overlayShape,
            thumbShape: RoundSliderThumbShape(
              enabledThumbRadius: compact ? 6 : 8,
            ),
            trackHeight: compact ? 2.5 : 3.5,
            tickMarkShape: SliderTickMarkShape.noTickMark,
            showValueIndicator: ShowValueIndicator.never,
          ),
          child: Slider(
            key: ValueKey<String>('folder-placeholder-slider-$keyName'),
            value: slider,
            min: FolderPlaceholderSliderCurve.sliderMin,
            max: FolderPlaceholderSliderCurve.sliderMax,
            onChanged: (next) => onChanged(spec.fromSlider(next)),
          ),
        ),
      ],
    );
  }
}
