import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/cloud_drive/presentation/cloud_drive_screen.dart';
import '../features/cloud_drive/services/cloud_drive_runtime.dart';
import '../features/cloud_drive/services/cloud_drive_subtitle_tracks.dart';
import '../models/video_item.dart';
import '../services/library_service.dart';
import '../utils/app_toast.dart';
import 'bilibili_subtitle_tracks_section.dart';

/// Official cloud subtitles for [item], or null for a local card.
CloudDriveSubtitleTracks? cloudDriveSubtitleTracksFor(
  BuildContext context,
  VideoItem? item,
) {
  if (!CloudDriveSubtitleTracks.covers(item)) return null;
  final override = CloudDriveSubtitleTracks.overrideForTesting;
  if (override != null) return override;
  final runtime = CloudDriveRuntime.instance;
  if (runtime == null) return null;
  try {
    return CloudDriveSubtitleTracks.forApp(
      library: context.read<LibraryService>(),
      runtime: runtime,
    );
  } on ProviderNotFoundException {
    return null;
  }
}

/// The provider subtitle group. Saved tracks keep the local-file row. A track that
/// is not a file yet is fetched on tap and handed to [onPick] once.
class CloudDriveSubtitleTracksSection extends StatefulWidget {
  const CloudDriveSubtitleTracksSection({
    super.key,
    required this.itemId,
    required this.tracks,
    required this.onPick,
    required this.savedRow,
    this.openLogin,
  });

  final String itemId;
  final CloudDriveSubtitleTracks tracks;
  final ValueChanged<String> onPick;
  final Widget Function(CloudDriveListedSubtitle track) savedRow;
  final Future<void> Function(BuildContext context)? openLogin;

  @override
  State<CloudDriveSubtitleTracksSection> createState() =>
      _CloudDriveSubtitleTracksSectionState();
}

class _CloudDriveSubtitleTracksSectionState
    extends State<CloudDriveSubtitleTracksSection> {
  @override
  void initState() {
    super.initState();
    widget.tracks.addListener(_tracksChanged);
    _ask();
  }

  @override
  void didUpdateWidget(CloudDriveSubtitleTracksSection oldWidget) {
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

  void _tracksChanged() {
    if (widget.tracks.needsAsking(widget.itemId)) _ask();
  }

  void _retry() => unawaited(widget.tracks.reload(widget.itemId));

  Future<void> _login() async {
    final open = widget.openLogin ?? _openCloudLogin;
    await open(context);
    if (!mounted) return;
    _retry();
  }

  Future<void> _openCloudLogin(BuildContext context) async {
    final runtime = CloudDriveRuntime.instance;
    final item = widget.tracks.store.itemOf(widget.itemId);
    final providerId = item?.sourceRef?.cloudDrive?.providerId;
    final provider = providerId == null ? null : runtime?.providers[providerId];
    if (runtime == null || provider == null) {
      AppToast.show('请先在网盘里登录对应账号', type: AppToastType.info);
      return;
    }
    await Navigator.of(context).push(
      CloudDriveLoginRoute(provider: provider, accounts: runtime.accounts),
    );
  }

  Future<void> _pick(CloudDriveListedSubtitle track) async {
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
        final providerId = widget.tracks.store
            .itemOf(widget.itemId)
            ?.sourceRef
            ?.cloudDrive
            ?.providerId;
        final providerName = switch (providerId) {
          'baidu' => '百度网盘',
          'quark' => '夸克网盘',
          'uc' => 'UC网盘',
          'aliyun' => '阿里云盘',
          _ => '网盘',
        };
        return Column(
          key: const ValueKey('cloud-drive-subtitle-tracks'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 4, top: 4),
              child: Text(
                '$providerName字幕',
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            for (final track in list.tracks)
              track.isSaved
                  ? widget.savedRow(track)
                  : _RemoteTrackRow(
                      track: track,
                      loading: widget.tracks.isLoading(widget.itemId, track),
                      failed: widget.tracks.hasFailed(widget.itemId, track),
                      onTap: () => _pick(track),
                    ),
            if (list.loading)
              _Note(
                key: const ValueKey('cloud-subtitles-loading'),
                text: '正在获取$providerName字幕…',
                leading: const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.8),
                ),
              ),
            if (empty != null)
              const _Note(
                key: ValueKey('cloud-subtitles-empty'),
                text: '这个视频没有官方字幕',
                leading: Icon(
                  Icons.subtitles_off_outlined,
                  color: Colors.white38,
                  size: 16,
                ),
              ),
            if (list.unsupported)
              _Note(
                key: const ValueKey('cloud-subtitles-unsupported'),
                text: '暂未接入$providerName的官方／AI字幕',
                leading: const Icon(
                  Icons.info_outline,
                  color: Colors.white38,
                  size: 16,
                ),
              ),
            if (failure != null)
              _Note(
                key: const ValueKey('cloud-subtitles-retry'),
                text: failure,
                color: Colors.orangeAccent,
                leading: const Icon(
                  Icons.refresh,
                  color: Colors.orangeAccent,
                  size: 16,
                ),
                onTap: _retry,
              ),
            if (login != null)
              _Note(
                key: const ValueKey('cloud-subtitles-login'),
                text: login,
                leading: const Icon(
                  Icons.lock_outline,
                  color: Colors.white38,
                  size: 16,
                ),
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

  final CloudDriveListedSubtitle track;
  final bool loading;
  final bool failed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('cloud-track-${track.id}'),
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white12),
      ),
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
    return InkWell(onTap: tap, child: row);
  }
}
