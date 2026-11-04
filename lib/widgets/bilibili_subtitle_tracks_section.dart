import 'package:flutter/material.dart';

import '../models/video_item.dart';
import '../services/bilibili/bilibili_subtitle_tracks.dart';

/// Historical source metadata never activates remote subtitle discovery.
BilibiliSubtitleTracks? bilibiliSubtitleTracksFor(
  BuildContext context,
  VideoItem? item,
) => null;

class BilibiliAiBadge extends StatelessWidget {
  const BilibiliAiBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('bilibili-ai-badge'),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.tealAccent.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.tealAccent.withValues(alpha: 0.5)),
      ),
      child: const Text(
        'AI',
        style: TextStyle(
          color: Colors.tealAccent,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// The「B 站字幕」group of the subtitle area: every track of the part, the
/// saved ones through [savedRow] (so they keep the actions of a local
/// subtitle file), the others fetched when tapped and then handed to
/// [onPick] to be selected like any subtitle file.
///
/// Retained constructor for old callers; online track UI is retired.
class BilibiliSubtitleTracksSection extends StatelessWidget {
  const BilibiliSubtitleTracksSection({
    super.key,
    required this.itemId,
    required this.tracks,
    required this.onPick,
    required this.savedRow,
    this.openLogin,
  });
  final String itemId;
  final BilibiliSubtitleTracks tracks;
  final ValueChanged<String> onPick;
  final Widget Function(BilibiliSubtitleTrack track) savedRow;
  final Future<void> Function(BuildContext context)? openLogin;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
