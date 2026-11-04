import 'package:flutter/material.dart';

import '../models/bilibili_audio_quality.dart';
import '../models/bilibili_download_task.dart';
import '../models/bilibili_models.dart';
import '../services/bilibili/bilibili_audio_selection.dart';
import 'capsule_selector.dart';

/// Separate row so adding audio choices never squeezes the existing quality,
/// subtitle or download controls on narrow task cards.
class BilibiliDownloadAudioPicker extends StatelessWidget {
  const BilibiliDownloadAudioPicker({
    super.key,
    required this.episode,
    required this.onChanged,
  });

  final BilibiliDownloadEpisode episode;
  final ValueChanged<StreamItem?>? onChanged;

  @override
  Widget build(BuildContext context) {
    final chosen = episode.status == DownloadStatus.completed
        ? episode.downloadedAudioQuality ?? episode.selectedAudioQuality
        : episode.selectedAudioQuality;
    final choices = bilibiliAudioMenuTracks([
      ...episode.availableAudioQualities,
      if (chosen != null) chosen,
    ]);
    if (choices.isEmpty) return const SizedBox.shrink();
    final selected = chosen == null
        ? null
        : choices
              .where(
                (track) =>
                    BilibiliAudioQuality.fromStream(track).label ==
                    BilibiliAudioQuality.fromStream(chosen).label,
              )
              .firstOrNull;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              '音质',
              style: TextStyle(fontSize: 11, color: Colors.white54),
            ),
          ),
          Expanded(
            child: SizedBox(
              height: 28,
              child: CapsuleDropdownButton<StreamItem>(
                key: ValueKey(
                  'bilibili-download-audio-${episode.bvid}-${episode.page.cid}',
                ),
                plain: true,
                value: selected,
                isDense: true,
                isExpanded: true,
                style: const TextStyle(fontSize: 11, color: Colors.white),
                dropdownColor: const Color(0xFF333333),
                icon: const Icon(
                  Icons.arrow_drop_down,
                  size: 16,
                  color: Colors.white54,
                ),
                items: [
                  for (final track in choices)
                    DropdownMenuItem(
                      value: track,
                      child: Text(
                        BilibiliAudioQuality.fromStream(track).label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color:
                              BilibiliAudioQuality.fromStream(track).isSpecial
                              ? const Color(0xFFFF6699)
                              : Colors.white,
                        ),
                      ),
                    ),
                ],
                onChanged: onChanged,
                hint: const Text('自动选择可用音质', style: TextStyle(fontSize: 11)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
