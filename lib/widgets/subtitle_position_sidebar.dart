import 'package:flutter/material.dart';
import 'landscape_sidebar_layout.dart';
import 'package:provider/provider.dart';
import '../services/settings_service.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class SubtitlePositionSidebar extends StatefulWidget {
  final Alignment currentAlignment;
  final ValueChanged<Alignment> onAlignmentChanged;
  final List<Map<String, double>> presets; // [{"x": 0.0, "y": 0.8}, ...]
  final VoidCallback onSavePreset;
  final VoidCallback onReset;
  final VoidCallback onConfirm;

  // Ghost Mode Props
  final bool isGhostModeEnabled;
  final ValueChanged<bool> onGhostModeToggle;
  final VoidCallback onEnterGhostMode;
  final bool isGhostModeActive;
  final bool hideGhostModeControls;
  final String? resetHint;

  const SubtitlePositionSidebar({
    super.key,
    required this.currentAlignment,
    required this.onAlignmentChanged,
    required this.presets,
    required this.onSavePreset,
    required this.onReset,
    required this.onConfirm,
    required this.isGhostModeEnabled,
    required this.onGhostModeToggle,
    required this.onEnterGhostMode,
    required this.isGhostModeActive,
    this.hideGhostModeControls = false,
    this.resetHint,
  });

  @override
  State<SubtitlePositionSidebar> createState() =>
      _SubtitlePositionSidebarState();
}

class _SubtitlePositionSidebarState extends State<SubtitlePositionSidebar> {
  // Timer for long press continuous movement
  // Not implementing complex timer for now, keeping it simple with repeated taps or just relying on drag
  // But requirement said "tap or long press".

  void _move(double dx, double dy) {
    // Small step for fine tuning
    final newX = (widget.currentAlignment.x + dx).clamp(-1.0, 1.0);
    final newY = (widget.currentAlignment.y + dy).clamp(-1.0, 1.0);
    widget.onAlignmentChanged(Alignment(newX, newY));
  }

  @override
  Widget build(BuildContext context) {
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
    final paddingValue = layout.horizontalPadding;

    // Use a fixed width for the D-Pad container or scale it slightly
    final dPadSize = layout.isCompactHeight ? 96.0 : 140.0;
    final buttonSize = layout.controlHeight;
    final iconSize = layout.iconSize;

    return Container(
      color: const Color(0xFF1E1E1E),
      child: Column(
        children: [
          // Header - Optimized for mobile
          Container(
            height: layout.headerHeight,
            padding: EdgeInsets.symmetric(horizontal: paddingValue),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Colors.white10)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  "字幕样式",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: layout.titleSize,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                DesktopButtonClickRegion(child: IconButton(
                  icon: const Icon(Icons.check, color: Colors.greenAccent),
                  onPressed: widget.onConfirm,
                  tooltip: "确认保存",
                  iconSize: isSmallScreen ? 16 : 24,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 24,
                    minHeight: 24,
                  ),
                )),
              ],
            ),
          ),

          Expanded(
            child: ListView(
              key: const PageStorageKey('subtitle-position-scroll'),
              padding: EdgeInsets.symmetric(
                horizontal: paddingValue,
                vertical: isSmallScreen ? 4 : 8,
              ),
              children: [
                if (!widget.hideGhostModeControls)
                  Container(
                    height: isSmallScreen ? 32 : 48,
                    padding: EdgeInsets.symmetric(horizontal: 0),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      mainAxisSize: MainAxisSize.max,
                      children: [
                        Expanded(
                          child: Text(
                            "幽灵模式",
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: isSmallScreen ? 9 : 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Transform.scale(
                              scale: isSmallScreen ? 0.45 : 1.0,
                              child: Switch(
                                value: widget.isGhostModeEnabled,
                                onChanged: widget.onGhostModeToggle,
                                activeThumbColor: Colors.blueAccent,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                            DesktopButtonClickRegion(child: IconButton(
                              icon: Icon(
                                Icons.tune,
                                size: isSmallScreen ? 12 : 20,
                              ),
                              onPressed: widget.isGhostModeEnabled
                                  ? widget.onEnterGhostMode
                                  : null,
                              tooltip: "调整",
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 20,
                                minHeight: 20,
                              ),
                              style: IconButton.styleFrom(
                                backgroundColor: widget.isGhostModeActive
                                    ? Colors.green.withValues(alpha: 0.2)
                                    : Colors.white.withValues(alpha: 0.1),
                                foregroundColor: widget.isGhostModeActive
                                    ? Colors.green
                                    : Colors.white,
                              ),
                            )),
                          ],
                        ),
                      ],
                    ),
                  ),
                if (!widget.hideGhostModeControls)
                  Divider(
                    color: Colors.white10,
                    height: isSmallScreen ? 2 : 24,
                  ),
                if (widget.resetHint != null)
                  Padding(
                    padding: EdgeInsets.only(top: isSmallScreen ? 8 : 12),
                    child: Text(
                      widget.resetHint!,
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: isSmallScreen ? 10 : 12,
                        height: 1.4,
                      ),
                    ),
                  ),
                ...[
                  // 1. Font Settings (Size & Spacing)
                  Text(
                    "字体布局",
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: isSmallScreen ? 10 : 12,
                    ),
                  ),
                  SizedBox(height: isSmallScreen ? 4 : 8),
                  Consumer<SettingsService>(
                    builder: (context, settings, child) {
                      return Column(
                        children: [
                          // Main Font Size
                          Row(
                            children: [
                              const SizedBox(
                                width: 30,
                                child: Text(
                                  "主",
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.white70,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    trackHeight: 2,
                                    thumbShape: const RoundSliderThumbShape(
                                      enabledThumbRadius: 6,
                                    ),
                                    overlayShape: const RoundSliderOverlayShape(
                                      overlayRadius: 12,
                                    ),
                                  ),
                                  child: Slider(
                                    value: settings
                                        .subtitleStyleLandscape
                                        .fontSize,
                                    min: 10,
                                    max: 100,
                                    divisions: 90,
                                    activeColor: Colors.blueAccent,
                                    inactiveColor: Colors.white24,
                                    onChanged: (val) {
                                      settings.saveSubtitleStyleLandscape(
                                        settings.subtitleStyleLandscape
                                            .copyWith(fontSize: val),
                                      );
                                    },
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 30,
                                child: Text(
                                  settings.subtitleStyleLandscape.fontSize
                                      .toInt()
                                      .toString(),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.white70,
                                  ),
                                  textAlign: TextAlign.right,
                                ),
                              ),
                            ],
                          ),

                          // Secondary Font Size
                          Row(
                            children: [
                              const SizedBox(
                                width: 30,
                                child: Text(
                                  "副",
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.white70,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    trackHeight: 2,
                                    thumbShape: const RoundSliderThumbShape(
                                      enabledThumbRadius: 6,
                                    ),
                                    overlayShape: const RoundSliderOverlayShape(
                                      overlayRadius: 12,
                                    ),
                                  ),
                                  child: Slider(
                                    value:
                                        settings
                                            .subtitleStyleLandscape
                                            .secondaryFontSize ??
                                        settings
                                            .subtitleStyleLandscape
                                            .fontSize,
                                    min: 10,
                                    max: 100,
                                    divisions: 90,
                                    activeColor: Colors.blueAccent,
                                    inactiveColor: Colors.white24,
                                    onChanged: (val) {
                                      settings.saveSubtitleStyleLandscape(
                                        settings.subtitleStyleLandscape
                                            .copyWith(secondaryFontSize: val),
                                      );
                                    },
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 30,
                                child: Text(
                                  (settings
                                              .subtitleStyleLandscape
                                              .secondaryFontSize ??
                                          settings
                                              .subtitleStyleLandscape
                                              .fontSize)
                                      .toInt()
                                      .toString(),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.white70,
                                  ),
                                  textAlign: TextAlign.right,
                                ),
                              ),
                            ],
                          ),

                          // Line Spacing
                          Row(
                            children: [
                              const SizedBox(
                                width: 30,
                                child: Text(
                                  "距",
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.white70,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    trackHeight: 2,
                                    thumbShape: const RoundSliderThumbShape(
                                      enabledThumbRadius: 6,
                                    ),
                                    overlayShape: const RoundSliderOverlayShape(
                                      overlayRadius: 12,
                                    ),
                                  ),
                                  child: Slider(
                                    value: settings
                                        .subtitleStyleLandscape
                                        .lineSpacing,
                                    min: -10,
                                    max: 100,
                                    divisions: 110,
                                    activeColor: Colors.blueAccent,
                                    inactiveColor: Colors.white24,
                                    onChanged: (val) {
                                      settings.saveSubtitleStyleLandscape(
                                        settings.subtitleStyleLandscape
                                            .copyWith(lineSpacing: val),
                                      );
                                    },
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 30,
                                child: Text(
                                  settings.subtitleStyleLandscape.lineSpacing
                                      .toInt()
                                      .toString(),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.white70,
                                  ),
                                  textAlign: TextAlign.right,
                                ),
                              ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),

                  SizedBox(height: isSmallScreen ? 6 : 20),
                  Divider(
                    color: Colors.white10,
                    height: isSmallScreen ? 8 : 24,
                  ),

                  // 2. D-Pad for Fine Tuning
                  Text(
                    "微调",
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: isSmallScreen ? 10 : 12,
                    ),
                  ),
                  SizedBox(height: isSmallScreen ? 4 : 12),
                  Center(
                    child: SizedBox(
                      width: dPadSize,
                      height: dPadSize,
                      child: Stack(
                        children: [
                          Align(
                            alignment: Alignment.topCenter,
                            child: _buildDirectionButton(
                              Icons.arrow_upward,
                              0.0,
                              -0.05,
                              buttonSize,
                              iconSize,
                            ),
                          ),
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: _buildDirectionButton(
                              Icons.arrow_downward,
                              0.0,
                              0.05,
                              buttonSize,
                              iconSize,
                            ),
                          ),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: _buildDirectionButton(
                              Icons.arrow_back,
                              -0.05,
                              0.0,
                              buttonSize,
                              iconSize,
                            ),
                          ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: _buildDirectionButton(
                              Icons.arrow_forward,
                              0.05,
                              0.0,
                              buttonSize,
                              iconSize,
                            ),
                          ),
                          Align(
                            alignment: Alignment.center,
                            child: Container(
                              width: buttonSize * 0.8,
                              height: buttonSize * 0.8,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.05),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.open_with,
                                color: Colors.white38,
                                size: iconSize * 0.8,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  SizedBox(height: isSmallScreen ? 8 : 24),
                  Divider(
                    color: Colors.white10,
                    height: isSmallScreen ? 8 : 24,
                  ),

                  // 3. Actions
                  Row(
                    children: [
                      Expanded(
                        child: DesktopButtonClickRegion(child: ElevatedButton.icon(
                          onPressed: widget.onSavePreset,
                          icon: Icon(
                            Icons.save_as,
                            size: isSmallScreen ? 14 : 16,
                          ),
                          label: Text(
                            "保存",
                            style: TextStyle(fontSize: isSmallScreen ? 11 : 14),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blueAccent.withValues(
                              alpha: 0.2,
                            ),
                            foregroundColor: Colors.blueAccent,
                            padding: EdgeInsets.symmetric(
                              horizontal: isSmallScreen ? 6 : 12,
                              vertical: isSmallScreen ? 6 : 12,
                            ),
                          ),
                        )),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DesktopButtonClickRegion(child: OutlinedButton.icon(
                          onPressed: widget.onReset,
                          icon: Icon(
                            Icons.restart_alt,
                            size: isSmallScreen ? 14 : 16,
                          ),
                          label: Text(
                            "重置",
                            style: TextStyle(fontSize: isSmallScreen ? 11 : 14),
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white70,
                            side: const BorderSide(color: Colors.white24),
                            padding: EdgeInsets.symmetric(
                              horizontal: isSmallScreen ? 6 : 12,
                              vertical: isSmallScreen ? 6 : 12,
                            ),
                          ),
                        )),
                      ),
                    ],
                  ),

                  SizedBox(height: isSmallScreen ? 8 : 24),

                  // 4. Presets
                  Text(
                    "预设位置",
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: isSmallScreen ? 10 : 12,
                    ),
                  ),
                  SizedBox(height: isSmallScreen ? 4 : 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _buildPresetChip("底部居中", 0.0, 0.9),
                      _buildPresetChip("顶部居中", 0.0, -0.9),
                      _buildPresetChip("正中央", 0.0, 0.0),
                      ...widget.presets.map((p) {
                        return _buildPresetChip(
                          "自定义", // Could add naming later
                          p['x'] ?? 0.0,
                          p['y'] ?? 0.8,
                          isCustom: true,
                        );
                      }),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDirectionButton(
    IconData icon,
    double dx,
    double dy,
    double size,
    double iconSize,
  ) {
    return GestureDetector(
      onTap: () => _move(dx, dy),
      onLongPress: () {
        // Simple long press acceleration could be added here
        // For now just repeat
        _move(dx * 2, dy * 2);
      },
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.1),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: iconSize),
      ),
    );
  }

  Widget _buildPresetChip(
    String label,
    double x,
    double y, {
    bool isCustom = false,
  }) {
    final bool isSelected =
        (widget.currentAlignment.x - x).abs() < 0.01 &&
        (widget.currentAlignment.y - y).abs() < 0.01;

    return ActionChip(
      label: Text(label),
      avatar: isCustom ? const Icon(Icons.bookmark, size: 14) : null,
      backgroundColor: isSelected
          ? Colors.blueAccent
          : Colors.white.withValues(alpha: 0.05),
      labelStyle: TextStyle(
        color: isSelected ? Colors.white : Colors.white70,
        fontSize: 12,
      ),
      onPressed: () => widget.onAlignmentChanged(Alignment(x, y)),
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    );
  }
}
