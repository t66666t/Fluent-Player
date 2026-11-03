import 'dart:ui' show FontFeature, ImageFilter;

import 'package:flutter/material.dart';

import '../controllers/music_volume_controller.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// A single-row volume strip with a full-height touch target.
class MusicVolumePanel extends StatelessWidget {
  const MusicVolumePanel({
    super.key,
    required this.controller,
    required this.onClose,
  });

  final MusicVolumeController controller;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '音量调节',
      onDismiss: onClose,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xED29292E),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0x24FFFFFF)),
            ),
            child: Material(
              color: Colors.transparent,
              child: ListenableBuilder(
                listenable: controller,
                builder: (context, _) => Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      DesktopButtonClickRegion(
                        child: IconButton(
                          key: const ValueKey('music-volume-mute'),
                          tooltip: controller.isMuted ? '取消静音' : '静音',
                          isSelected: controller.isMuted,
                          onPressed: controller.toggleMute,
                          icon: const Icon(Icons.volume_up_outlined, size: 19),
                          selectedIcon: const Icon(
                            Icons.volume_off_outlined,
                            size: 19,
                          ),
                          style: IconButton.styleFrom(
                            foregroundColor: controller.isMuted
                                ? Colors.white
                                : Colors.white70,
                            backgroundColor: controller.isMuted
                                ? const Color(0x26FFFFFF)
                                : Colors.transparent,
                            highlightColor: const Color(0x1FFFFFFF),
                            minimumSize: const Size.square(44),
                            padding: const EdgeInsets.all(10),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            shape: const CircleBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3.5,
                            activeTrackColor: Colors.white.withValues(
                              alpha: controller.isMuted ? 0.4 : 0.88,
                            ),
                            inactiveTrackColor: Colors.white.withValues(
                              alpha: 0.16,
                            ),
                            thumbColor: Colors.white,
                            overlayColor: Colors.white.withValues(alpha: 0.10),
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 6,
                              elevation: 0,
                              pressedElevation: 3,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 16,
                            ),
                            trackShape: const RoundedRectSliderTrackShape(),
                            showValueIndicator: ShowValueIndicator.never,
                          ),
                          child: SizedBox(
                            height: 44,
                            child: Slider(
                              key: const ValueKey('music-volume-slider'),
                              value: controller.volume,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              semanticFormatterCallback: (value) =>
                                  '音量 ${(value * 100).round()}%',
                              onChangeStart: (_) => controller.beginDrag(),
                              onChanged: controller.setVolume,
                              onChangeEnd: (_) => controller.endDrag(),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      SizedBox(
                        width: 32,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            '${(controller.volume * 100).round()}%',
                            key: const ValueKey('music-volume-percent'),
                            style: const TextStyle(
                              color: Colors.white60,
                              fontSize: 11,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
