import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/video_item.dart';
import '../services/bilibili/bilibili_download_service.dart';
import '../services/bilibili/bilibili_subtitle_tracks.dart';
import '../services/library_service.dart';
import '../utils/app_toast.dart';
import 'bilibili_login_dialogs.dart';

/// The Bilibili subtitle tracks of [item] for the subtitle area, or null when
/// [item] is no Bilibili video (or the app services are not there).
BilibiliSubtitleTracks? bilibiliSubtitleTracksFor(
  BuildContext context,
  VideoItem? item,
) {
  if (!BilibiliSubtitleTracks.covers(item)) return null;
  final override = BilibiliSubtitleTracks.overrideForTesting;
  if (override != null) return override;
  try {
    return BilibiliSubtitleTracks.forApp(
      download: context.read<BilibiliDownloadService>(),
      library: context.read<LibraryService>(),
    );
  } on ProviderNotFoundException {
    return null;
  }
}

/// The small「AI」mark of a machine-made subtitle track.
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
/// Logged out, the tracks Bilibili keeps for logged-in users are listed
/// greyed with a login line (a tap opens the login); a list that could not
/// be had says so with a retry; only a part without any subtitle says「这个
/// 视频没有字幕」. A spinner shows only while the list is on its way.
class BilibiliSubtitleTracksSection extends StatefulWidget {
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

  /// Selects the subtitle file of a track that was just fetched.
  final ValueChanged<String> onPick;

  /// The row of a track that is a file of the card.
  final Widget Function(BilibiliSubtitleTrack track) savedRow;

  /// Opens the login; defaults to the app's Bilibili login dialog.
  final Future<void> Function(BuildContext context)? openLogin;

  @override
  State<BilibiliSubtitleTracksSection> createState() =>
      _BilibiliSubtitleTracksSectionState();
}

class _BilibiliSubtitleTracksSectionState
    extends State<BilibiliSubtitleTracksSection> {
  @override
  void initState() {
    super.initState();
    widget.tracks.addListener(_tracksChanged);
    _ask();
  }

  @override
  void didUpdateWidget(BilibiliSubtitleTracksSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.tracks, widget.tracks)) {
      oldWidget.tracks.removeListener(_tracksChanged);
      widget.tracks.addListener(_tracksChanged);
    }
    if (oldWidget.itemId != widget.itemId ||
        !identical(oldWidget.tracks, widget.tracks)) {
      _ask();
    }
  }

  @override
  void dispose() {
    widget.tracks.removeListener(_tracksChanged);
    super.dispose();
  }

  void _ask() => unawaited(widget.tracks.ensureLoaded(widget.itemId));

  /// A login change dropped the list: asked again for the new login.
  void _tracksChanged() {
    if (widget.tracks.needsAsking(widget.itemId)) _ask();
  }

  void _retry() => unawaited(widget.tracks.reload(widget.itemId));

  Future<void> _login() async {
    final open = widget.openLogin ?? _openAppLogin;
    await open(context);
    // A login reports itself through the login change, which asks again;
    // without that signal the list is asked again here.
    if (!mounted || widget.tracks.source.loginChanges != null) return;
    _retry();
  }

  static Future<void> _openAppLogin(BuildContext context) async {
    try {
      context.read<BilibiliDownloadService>();
    } on ProviderNotFoundException {
      AppToast.show('请先在「B 站账号」里登录', type: AppToastType.info);
      return;
    }
    await showBilibiliLoginDialog(context);
  }

  Future<void> _pick(BilibiliSubtitleTrack track) async {
    final itemId = widget.itemId;
    final path = await widget.tracks.load(itemId, track);
    if (path == null || !mounted || widget.itemId != itemId) return;
    widget.onPick(path);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.tracks,
      builder: (context, _) {
        final list = widget.tracks.listFor(widget.itemId);
        final empty = list.emptyMessage;
        final failure = list.failureMessage;
        final login = list.loginMessage;
        return Column(
          key: const ValueKey('bilibili-subtitle-tracks'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 4, top: 4),
              child: Text(
                'B 站字幕',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            for (final track in list.tracks)
              track.isDownloaded
                  ? widget.savedRow(track)
                  : _RemoteTrackRow(
                      track: track,
                      loading: widget.tracks.isLoading(widget.itemId, track),
                      failed: widget.tracks.hasFailed(widget.itemId, track),
                      onTap: () => _pick(track),
                    ),
            for (final track in list.locked)
              _LockedTrackRow(track: track, onTap: _login),
            if (list.loading)
              const _Note(
                key: ValueKey('bilibili-subtitles-loading'),
                leading: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.8),
                ),
                text: '正在获取 B 站字幕…',
              ),
            if (empty != null)
              _Note(
                key: const ValueKey('bilibili-subtitles-empty'),
                leading: const Icon(
                  Icons.subtitles_off_outlined,
                  color: Colors.white38,
                  size: 16,
                ),
                text: empty,
              ),
            if (failure != null)
              _Note(
                key: const ValueKey('bilibili-subtitles-retry'),
                leading: const Icon(
                  Icons.refresh,
                  color: Colors.orangeAccent,
                  size: 16,
                ),
                text: failure,
                color: Colors.orangeAccent,
                onTap: _retry,
              ),
            if (login != null)
              _Note(
                key: const ValueKey('bilibili-subtitles-login-hint'),
                leading: const Icon(
                  Icons.lock_outline,
                  color: Colors.white38,
                  size: 16,
                ),
                text: login,
                action: '去登录',
                onTap: _login,
              ),
          ],
        );
      },
    );
  }
}

class _RemoteTrackRow extends StatelessWidget {
  const _RemoteTrackRow({
    required this.track,
    required this.loading,
    required this.failed,
    required this.onTap,
  });

  final BilibiliSubtitleTrack track;
  final bool loading;
  final bool failed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('bilibili-track-${track.lan}-${track.label}'),
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white12),
      ),
      // Its own surface, so the tap ripple shows above the row colour.
      child: Material(
        type: MaterialType.transparency,
        child: ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          leading: const Icon(
            Icons.cloud_download_outlined,
            color: Colors.white54,
            size: 20,
          ),
          title: Row(
            children: [
              Flexible(
                child: Text(
                  track.label,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (track.isAi) ...[
                const SizedBox(width: 6),
                const BilibiliAiBadge(),
              ],
            ],
          ),
          subtitle: Text(
            loading
                ? '正在加载…'
                : failed
                ? '加载失败，点一下重试'
                : '点一下加载',
            style: TextStyle(
              color: failed && !loading ? Colors.orangeAccent : Colors.white30,
              fontSize: 11,
            ),
          ),
          trailing: loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 1.8),
                )
              : null,
          onTap: loading ? null : onTap,
        ),
      ),
    );
  }
}

/// A track Bilibili hands out only to a logged-in request: its name greyed,
/// a tap opens the login.
class _LockedTrackRow extends StatelessWidget {
  const _LockedTrackRow({required this.track, required this.onTap});

  final BilibiliSubtitleTrack track;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('bilibili-locked-track-${track.lan}-${track.label}'),
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white10),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          leading: const Icon(
            Icons.lock_outline,
            color: Colors.white24,
            size: 20,
          ),
          title: Row(
            children: [
              Flexible(
                child: Text(
                  track.label,
                  style: const TextStyle(color: Colors.white38, fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (track.isAi) ...[
                const SizedBox(width: 6),
                const Opacity(opacity: 0.5, child: BilibiliAiBadge()),
              ],
            ],
          ),
          subtitle: const Text(
            '登录后可加载',
            style: TextStyle(color: Colors.white24, fontSize: 11),
          ),
          onTap: onTap,
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({
    super.key,
    required this.leading,
    required this.text,
    this.color = Colors.white54,
    this.action,
    this.onTap,
  });

  final Widget leading;
  final String text;
  final Color color;

  /// A short word at the end of a tappable line (「去登录」).
  final String? action;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Row(
        children: [
          leading,
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(color: color, fontSize: 12)),
          ),
          if (action != null) ...[
            const SizedBox(width: 8),
            Text(
              action!,
              style: const TextStyle(
                color: Colors.lightBlueAccent,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
    final tap = onTap;
    if (tap == null) return row;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: tap,
        child: row,
      ),
    );
  }
}
