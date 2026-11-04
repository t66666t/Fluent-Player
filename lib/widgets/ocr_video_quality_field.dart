import 'package:flutter/material.dart';

import '../features/media_cache/media_cache_models.dart';
import 'capsule_selector.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

CacheQuality defaultOcrVideoQuality(
  List<CacheQuality> qualities, {
  String? preferredId,
  bool preferOriginal = false,
}) {
  final preferred = qualities.where((q) => q.id == preferredId).firstOrNull;
  if (preferred != null) return preferred;
  if (preferOriginal) {
    final original = qualities.where((q) => q.id == 'original').firstOrNull;
    if (original != null) return original;
  }
  final sized = qualities.where((q) => q.resolutionHeight != null).toList()
    ..sort((a, b) => a.resolutionHeight!.compareTo(b.resolutionHeight!));
  if (sized.isEmpty) return qualities.first;
  final adequate = sized.where((q) => q.resolutionHeight! >= 1080).firstOrNull;
  return adequate ?? sized.last;
}

/// A single full-width field also fits the player's narrow landscape sidebar.
class OcrVideoQualityField extends StatelessWidget {
  const OcrVideoQualityField({
    super.key,
    required this.qualities,
    required this.value,
    required this.loading,
    required this.enabled,
    required this.podcast,
    required this.error,
    required this.onChanged,
    required this.onRetry,
  });

  final List<CacheQuality> qualities;
  final String? value, error;
  final bool loading, enabled, podcast;
  final ValueChanged<String> onChanged;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (loading)
        const Row(
          children: [
            SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                '正在获取可下载画质…',
                style: TextStyle(color: Colors.white60, fontSize: 12),
              ),
            ),
          ],
        )
      else if (error != null) ...[
        Text(
          error!,
          style: const TextStyle(color: Colors.orangeAccent, fontSize: 12),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: DesktopButtonClickRegion(
            child: TextButton.icon(
              onPressed: enabled ? onRetry : null,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重新获取画质'),
            ),
          ),
        ),
      ] else if (qualities.isNotEmpty) ...[
        CapsuleDropdownButtonFormField<String>(
          key: const ValueKey('ocr-video-quality'),
          value: value,
          decoration: const InputDecoration(labelText: '素材画质'),
          items: [
            for (final quality in qualities)
              DropdownMenuItem(value: quality.id, child: Text(quality.label)),
          ],
          onChanged: enabled && qualities.length > 1
              ? (id) {
                  if (id != null) onChanged(id);
                }
              : null,
        ),
        const SizedBox(height: 8),
        Text(
          podcast ? '来源仅提供原视频，无法选择其他画质。' : '较低画质可减少下载量和解码负担；字幕过小可能影响准确率。',
          style: const TextStyle(color: Colors.white54, fontSize: 11),
        ),
      ],
    ],
  );
}
