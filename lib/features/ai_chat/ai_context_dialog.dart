import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/subtitle_model.dart';
import '../../services/app_haptics.dart';
import '../../services/settings_service.dart';
import 'ai_markdown.dart';
import 'ai_capsule_menu.dart';
import 'ai_chat_layout.dart';
import 'ai_chat_copy.dart';
import 'ai_video_context.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

String _time(Duration time) {
  final seconds = time.inSeconds.clamp(0, 359999);
  final h = seconds ~/ 3600;
  final m = seconds ~/ 60 % 60;
  final s = seconds % 60;
  return h == 0
      ? '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
      : '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

String _role(String value) => switch (value) {
  'primary' => '主字幕',
  'secondary' => '副字幕',
  _ => '其他字幕',
};

/// Selection controls use the same compact source rows as the subtitle tools.
class AiContextDialog extends StatefulWidget {
  const AiContextDialog({
    super.key,
    required this.videoContext,
    required this.selectedTrackIds,
    this.copy = const AiChatMediaCopy('视频'),
    this.onSeek,
    this.onReload,
    this.selectionIsAutomatic = false,
    this.generationInProgress = false,
  });
  final AiVideoContext videoContext;
  final Set<String> selectedTrackIds;
  final AiChatMediaCopy copy;
  final ValueChanged<Duration>? onSeek;
  final bool selectionIsAutomatic;
  final bool generationInProgress;
  final VoidCallback? onReload;
  @override
  State<AiContextDialog> createState() => _AiContextDialogState();
}

class _AiContextDialogState extends State<AiContextDialog> {
  late Set<String> _selected;
  late bool _automatic;
  late final List<AiSubtitleTrack> _tracks;
  AiSubtitleTrack? _previewTrack;
  bool _wide = false;

  @override
  void initState() {
    super.initState();
    _selected = Set.of(widget.selectedTrackIds);
    _automatic = widget.selectionIsAutomatic;
    int rank(AiSubtitleTrack t) => switch (t.role) {
      'primary' => 0,
      'secondary' => 1,
      _ => 2,
    };
    _tracks = List.of(widget.videoContext.tracks)
      ..sort((a, b) => rank(a).compareTo(rank(b)));
    for (final track in _tracks) {
      if (track.hasText &&
          (_previewTrack == null || _selected.contains(track.id))) {
        _previewTrack = track;
        if (_selected.contains(track.id)) break;
      }
    }
  }

  void _setSelection(Set<String> ids, {bool automatic = false}) {
    if (_automatic != automatic ||
        _selected.length != ids.length ||
        !_selected.containsAll(ids)) {
      unawaited(AppHaptics.selectionClick(SettingsService()));
    }
    setState(() {
      _automatic = automatic;
      _selected = ids;
    });
  }

  void _select(AiSubtitleTrack track, bool selected) {
    final ids = Set<String>.of(_selected);
    if (selected) {
      ids.add(track.id);
    } else {
      ids.remove(track.id);
    }
    _setSelection(ids);
  }

  void _preview(AiSubtitleTrack track) {
    if (!_wide || _previewTrack?.id != track.id || !track.hasText) {
      unawaited(AppHaptics.lightTap(SettingsService()));
    }
    if (_wide && track.hasText) {
      setState(() => _previewTrack = track);
      return;
    }
    showDialog<void>(
      context: context,
      builder: (context) => track.hasText
          ? AiTranscriptPreviewDialog(
              track: track,
              onSeek: widget.onSeek,
              currentPosition: widget.videoContext.position,
            )
          : AiAdaptiveDialog(
              title: Text(track.label),
              content: SingleChildScrollView(
                child: SelectableText(track.error ?? '此字幕没有可读取的文字。'),
              ),
              actions: [
                DesktopButtonClickRegion(child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('关闭'),
                )),
              ],
            ),
    );
  }

  Widget _metadata() {
    final metadata = widget.videoContext.metadata;
    final names = <String, String>{
      'title': '标题',
      'durationMs': '时长',
      'mediaType': '媒体类型',
      'codec': '编码',
      'positionMs': '当前文稿位置',
      'uploader': '上传者',
      'description': '简介',
      'source': '来源链接',
      'sourceType': '来源类型',
      'bvid': 'B 站视频编号',
      'page': '分 P',
      'cid': '视频分段编号',
      'channel': '频道',
      'uploadDate': '发布时间',
      'chapters': widget.copy.chapters,
    };
    String value(String key, dynamic data) {
      if (key == 'durationMs' || key == 'positionMs') {
        return data is num
            ? _time(Duration(milliseconds: data.toInt()))
            : data.toString();
      }
      if (key == 'mediaType') {
        return data == 'audio'
            ? '音频'
            : data == 'video'
            ? '视频'
            : data.toString();
      }
      if (key == 'chapters' && data is List) {
        return data
            .map((chapter) {
              if (chapter is! Map) return chapter.toString();
              final start = chapter['startMs'];
              return '${start is num ? '[${_time(Duration(milliseconds: start.toInt()))}] ' : ''}${chapter['title'] ?? ''}';
            })
            .join('\n');
      }
      if (data is Map || data is List) {
        return const JsonEncoder.withIndent('  ').convert(data);
      }
      return data?.toString() ?? '';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in metadata.entries)
          if (names.containsKey(entry.key) &&
              entry.value != null &&
              value(entry.key, entry.value).isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    names[entry.key]!,
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    value(entry.key, entry.value),
                    style: const TextStyle(fontSize: 13, height: 1.5),
                  ),
                ],
              ),
            ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('查看完整元信息', style: TextStyle(fontSize: 12)),
          children: [
            SelectableText(
              const JsonEncoder.withIndent('  ').convert(metadata),
              style: const TextStyle(fontSize: 11, height: 1.5),
            ),
          ],
        ),
      ],
    );
  }

  Widget _track(AiSubtitleTrack track) {
    final colors = Theme.of(context).colorScheme;
    final selected = _selected.contains(track.id);
    final summary = track.cues
        .where((cue) => cue.text.trim().isNotEmpty)
        .take(2)
        .map((cue) => cue.text.trim().replaceAll(RegExp(r'\s+'), ' '))
        .join(' ')
        .characters
        .take(90)
        .toString();
    return Material(
      color: _wide && _previewTrack?.id == track.id
          ? colors.surfaceContainerHighest.withValues(alpha: .35)
          : Colors.transparent,
      child: InkWell(
        onTap: () => _preview(track),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            children: [
              SizedBox(
                width: 40,
                child: Checkbox(
                  value: selected,
                  onChanged: track.hasText || selected
                      ? (value) => _select(track, value == true)
                      : null,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${_role(track.role)} · ${track.sourceDescription} · ${track.cues.length} 段',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    if (track.error != null)
                      Text(
                        track.error!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: colors.error),
                      )
                    else if (summary.isNotEmpty)
                      Text(
                        summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              DesktopButtonClickRegion(child: IconButton(
                key: ValueKey('ai-track-preview-${track.id}'),
                tooltip: track.hasText ? '预览文稿' : '查看读取问题',
                onPressed: () => _preview(track),
                icon: Icon(
                  track.hasText ? Icons.article_outlined : Icons.info_outline,
                  size: 19,
                ),
              )),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sources() => ListView(
    key: const ValueKey('ai-context-sources'),
    children: [
      Text(
        widget.videoContext.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      ),
      const SizedBox(height: 4),
      Text(
        _automatic ? '自动优先使用主、副字幕' : '使用勾选的文稿，不改变播放器字幕',
        style: TextStyle(
          fontSize: 11,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      Row(
        children: [
          Expanded(
            child: Text(
              '已选 ${_selected.length} 条',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          DesktopButtonClickRegion(child: TextButton.icon(
            key: const ValueKey('ai-context-recommend'),
            onPressed: () => _setSelection(
              recommendAiSubtitleTracks(widget.videoContext),
              automatic: true,
            ),
            icon: const Icon(Icons.playlist_add_check, size: 17),
            label: const Text('自动选择'),
          )),
          AiCapsuleIconMenu<String>(
            tooltip: '更多资料操作',
            icon: Icons.more_horiz,
            feedbackOnSelection: false,
            items: () => [
              const AiCapsuleChoice(value: 'all', label: '选择全部可用字幕'),
              AiCapsuleChoice(value: 'none', label: widget.copy.infoOnly),
              if (widget.onReload != null)
                const AiCapsuleChoice(value: 'reload', label: '重新读取资料'),
            ],
            onSelected: (value) {
              if (value == 'reload') {
                unawaited(AppHaptics.lightTap(SettingsService()));
                widget.onReload?.call();
                return;
              }
              _setSelection(
                value == 'all'
                    ? _tracks.where((t) => t.hasText).map((t) => t.id).toSet()
                    : {},
              );
            },
          ),
        ],
      ),
      if (_tracks.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Text(
            widget.copy.noTranscript,
            style: const TextStyle(fontSize: 13),
          ),
        ),
      for (var i = 0; i < _tracks.length; i++) ...[
        if (i == 0 ||
            (_tracks[i].role == 'other' && _tracks[i - 1].role != 'other'))
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: Text(
              _tracks[i].role == 'other' ? '其他文稿' : '播放器字幕',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        _track(_tracks[i]),
        const Divider(height: 1),
      ],
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text(widget.copy.info, style: const TextStyle(fontSize: 13)),
        subtitle: const Text(
          '标题、来源、简介等会随文稿一起提供',
          style: TextStyle(fontSize: 11),
        ),
        children: [_metadata()],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => AiAdaptiveDialog(
    maxWidth: 1100,
    title: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.copy.sources),
        if (widget.generationInProgress)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              '资料选择从下一次发送生效，当前回答继续使用原资料。',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.normal),
            ),
          ),
      ],
    ),
    content: LayoutBuilder(
      builder: (context, constraints) {
        _wide = constraints.maxWidth >= 760 && constraints.maxHeight >= 360;
        if (!_wide) return _sources();
        final track = _previewTrack;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 320, child: _sources()),
            const VerticalDivider(width: 25),
            Expanded(
              child: track == null
                  ? const Center(child: Text('选择一份文稿查看内容'))
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.label,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: AiTranscriptView(
                            key: ValueKey(track.id),
                            track: track,
                            onSeek: widget.onSeek,
                            currentPosition: widget.videoContext.position,
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        );
      },
    ),
    actions: [
      DesktopButtonClickRegion(child: TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      )),
      DesktopButtonClickRegion(child: FilledButton(
        onPressed: () => Navigator.pop(
          context,
          AiContextSelection(_selected, automatic: _automatic),
        ),
        child: const Text('应用'),
      )),
    ],
  );
}

class AiContextSelection {
  AiContextSelection(Set<String> ids, {required this.automatic})
    : ids = Set.unmodifiable(ids);
  final Set<String> ids;
  final bool automatic;
}

class AiTranscriptPreviewDialog extends StatelessWidget {
  const AiTranscriptPreviewDialog({
    super.key,
    required this.track,
    this.onSeek,
    this.currentPosition = Duration.zero,
  });
  final AiSubtitleTrack track;
  final ValueChanged<Duration>? onSeek;
  final Duration currentPosition;
  @override
  Widget build(BuildContext context) => AiAdaptiveDialog(
    maxWidth: 960,
    title: Text(track.label, maxLines: 2, overflow: TextOverflow.ellipsis),
    content: AiTranscriptView(
      track: track,
      onSeek: onSeek,
      currentPosition: currentPosition,
    ),
    actions: [
      DesktopButtonClickRegion(child: TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      )),
    ],
  );
}

class AiTranscriptView extends StatefulWidget {
  const AiTranscriptView({
    super.key,
    required this.track,
    this.onSeek,
    this.currentPosition = Duration.zero,
  });
  final AiSubtitleTrack track;
  final ValueChanged<Duration>? onSeek;
  final Duration currentPosition;
  @override
  State<AiTranscriptView> createState() => _AiTranscriptViewState();
}

class _AiTranscriptViewState extends State<AiTranscriptView> {
  final _search = TextEditingController();
  final _from = TextEditingController();
  final _to = TextEditingController();
  final _expanded = <int>{};
  Timer? _debounce;
  late List<int> _visible;
  String? _rangeError;
  bool _nearPosition = false;
  bool _showRange = false;

  @override
  void initState() {
    super.initState();
    _visible = List.generate(widget.track.cues.length, (i) => i);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  void _filter() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 180), _applyFilter);
  }

  void _applyFilter() {
    Duration? parse(String text) =>
        text.trim().isEmpty ? null : AiMarkdown.timestamp(text.trim());
    final from = parse(_from.text);
    final to = parse(_to.text);
    if ((_from.text.trim().isNotEmpty && from == null) ||
        (_to.text.trim().isNotEmpty && to == null) ||
        (from != null && to != null && from > to)) {
      setState(() => _rangeError = '时间格式为 mm:ss 或 hh:mm:ss；起始时间须早于结束时间');
      return;
    }
    final keyword = _search.text.trim().toLowerCase();
    final position = widget.currentPosition;
    final next = <int>[];
    for (var i = 0; i < widget.track.cues.length; i++) {
      final cue = widget.track.cues[i];
      if (keyword.isNotEmpty && !cue.text.toLowerCase().contains(keyword)) {
        continue;
      }
      if (from != null && cue.endTime < from) continue;
      if (to != null && cue.startTime > to) continue;
      if (_nearPosition &&
          (cue.endTime < position - const Duration(minutes: 2) ||
              cue.startTime > position + const Duration(minutes: 2))) {
        continue;
      }
      next.add(i);
    }
    setState(() {
      _visible = next;
      _rangeError = null;
    });
  }

  Widget _cue(int index) {
    final SubtitleItem cue = widget.track.cues[index];
    final expanded = _expanded.contains(index);
    final text = cue.text;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DesktopButtonClickRegion(child: TextButton.icon(
            onPressed: widget.onSeek == null
                ? null
                : () => widget.onSeek!(cue.startTime),
            icon: const Icon(Icons.play_circle_outline, size: 16),
            label: Text(
              '${_time(cue.startTime)} – ${_time(cue.endTime)}',
              style: const TextStyle(fontSize: 11),
            ),
          )),
          SelectableText(
            expanded ? text : text.characters.take(700).toString(),
            style: const TextStyle(fontSize: 13, height: 1.6),
          ),
          if (text.characters.length > 700)
            DesktopButtonClickRegion(child: TextButton(
              onPressed: () => setState(() {
                if (expanded) {
                  _expanded.remove(index);
                } else {
                  _expanded.add(index);
                }
              }),
              child: Text(expanded ? '收起本段' : '展开本段'),
            )),
          const Divider(height: 18),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final filters = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('ai-transcript-search'),
                  controller: _search,
                  decoration: const InputDecoration(
                    hintText: '搜索文稿',
                    prefixIcon: Icon(Icons.search, size: 18),
                  ),
                  onChanged: (_) => _filter(),
                ),
              ),
              DesktopButtonClickRegion(child: IconButton(
                tooltip: '筛选时间',
                isSelected: _showRange,
                onPressed: () => setState(() => _showRange = !_showRange),
                icon: const Icon(Icons.filter_list, size: 19),
              )),
              DesktopButtonClickRegion(child: IconButton(
                tooltip: '复制筛选后的文稿',
                icon: const Icon(Icons.copy_outlined, size: 18),
                onPressed: () => Clipboard.setData(
                  ClipboardData(
                    text: _visible
                        .map((i) {
                          final cue = widget.track.cues[i];
                          return '[${_time(cue.startTime)}] ${cue.text}';
                        })
                        .join('\n\n'),
                  ),
                ),
              )),
            ],
          ),
          if (_showRange)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _from,
                      onChanged: (_) => _filter(),
                      decoration: const InputDecoration(labelText: '起始 mm:ss'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _to,
                      onChanged: (_) => _filter(),
                      decoration: const InputDecoration(labelText: '结束 mm:ss'),
                    ),
                  ),
                ],
              ),
            ),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${_visible.length} / ${widget.track.cues.length} 段',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
              DesktopButtonClickRegion(child: TextButton.icon(
                onPressed: () {
                  _nearPosition = !_nearPosition;
                  _applyFilter();
                },
                icon: Icon(
                  _nearPosition ? Icons.check : Icons.my_location,
                  size: 15,
                ),
                label: const Text('当前位置', style: TextStyle(fontSize: 11)),
              )),
            ],
          ),
          if (_rangeError != null)
            Text(
              _rangeError!,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
        ],
      );
      return Column(
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: constraints.maxHeight * .55),
            child: SingleChildScrollView(child: filters),
          ),
          const Divider(height: 1),
          Expanded(
            child: _visible.isEmpty
                ? const Center(child: Text('没有匹配的文稿片段'))
                : ListView.builder(
                    key: const ValueKey('ai-transcript-cues'),
                    padding: const EdgeInsets.only(top: 8),
                    itemCount: _visible.length,
                    itemBuilder: (context, i) => _cue(_visible[i]),
                  ),
          ),
        ],
      );
    },
  );
}
