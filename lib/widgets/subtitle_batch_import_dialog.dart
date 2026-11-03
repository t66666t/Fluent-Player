import 'package:video_player_app/widgets/dialog_keyboard_viewport.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../features/subtitle_search/subtitle_batch_matcher.dart';
import '../features/subtitle_search/subtitle_search_models.dart';
import '../features/subtitle_search/subtitle_search_service.dart';
import '../features/subtitle_search/subtitle_search_workspace.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

typedef SubtitleBatchImportCallback =
    Future<String> Function(
      String itemId,
      SubtitleSearchImportRequest request,
      String? existingPath,
    );

class SubtitleBatchImportDialog extends StatefulWidget {
  const SubtitleBatchImportDialog({
    super.key,
    required this.targets,
    required this.candidates,
    required this.session,
    required this.anchorTitle,
    required this.preferredName,
    required this.onImport,
  });
  final List<SubtitleBatchTarget> targets;
  final List<SubtitleBatchCandidate> candidates;
  final SubtitleSearchSession session;
  final String anchorTitle, preferredName;
  final SubtitleBatchImportCallback onImport;
  @override
  State<SubtitleBatchImportDialog> createState() =>
      _SubtitleBatchImportDialogState();
}

class _SubtitleBatchImportDialogState extends State<SubtitleBatchImportDialog> {
  final _candidates = <SubtitleBatchCandidate>[];
  List<SubtitleBatchMatch> _rows = [];
  final _selected = <String, SubtitleBatchCandidate>{};
  final _checked = <String>{};
  final _statuses = <String, String>{};
  final _supplemented = <String>{};
  bool _busy = false, _stopping = false, _saveOnly = false;
  String? _message;
  int _episodeOffset = 0;
  CancelToken? _token;
  static const accent = Color(0xFF7DE2CB);
  @override
  void initState() {
    super.initState();
    _candidates.addAll(widget.candidates);
    _match();
  }

  void _match() {
    _rows = const SubtitleBatchMatcher().match(
      targets: widget.targets,
      candidates: _candidates,
      anchorTitle: widget.anchorTitle,
      preferredName: widget.preferredName,
      episodeOffset: _episodeOffset,
      catalogId: widget.session.selected?.catalogId,
      seriesAliases: [
        widget.session.completedQuery?.text ?? '',
        widget.session.selected?.title ?? '',
        widget.session.selected?.release ?? '',
        ...?widget.session.work?.aliases,
      ],
    );
    for (final row in _rows) {
      if (!_selected.containsKey(row.target.id) &&
          row.confident &&
          row.options.isNotEmpty) {
        _selected[row.target.id] = row.options.first;
        if (!row.target.hasSubtitle && !_statuses.containsKey(row.target.id)) {
          _checked.add(row.target.id);
        }
      }
    }
  }

  void _stop() {
    setState(() {
      _stopping = true;
      _token?.cancel();
    });
  }

  Future<void> _supplement() async {
    setState(() {
      _busy = true;
      _stopping = false;
      _message = null;
    });
    final token = _token = CancelToken();
    final eligible = _rows
        .where(
          (r) =>
              r.options.isEmpty &&
              r.target.episode != null &&
              !r.reason.contains('已跳过'),
        )
        .toList();
    var missing = eligible
        .where((r) => !_supplemented.contains(r.target.id))
        .take(40)
        .toList();
    if (missing.isEmpty) {
      _supplemented.clear();
      missing = eligible.take(40).toList();
    }
    var failures = 0;
    try {
      for (final row in missing) {
        if (token.isCancelled || !mounted) break;
        _supplemented.add(row.target.id);
        final e = row.target.episode!;
        setState(() => _message = '正在查找 ${e.label} · ${row.target.title}');
        try {
          final result = await widget.session.workspace.service.search(
            SubtitleSearchSource.xunlei,
            SubtitleSearchQuery(
              text: widget.session.completedQuery!.text,
              language: widget.session.language,
              season: e.season,
              episode: e.number + _episodeOffset,
            ),
            const SubtitleSearchCredentials(),
            cancelToken: token,
          );
          final keys = _candidates.map((c) => c.key).toSet();
          for (final hit in result.hits) {
            for (final file in hit.files) {
              final candidate = SubtitleBatchCandidate(hit: hit, file: file);
              if (keys.add(candidate.key)) _candidates.add(candidate);
            }
          }
          if (mounted) setState(_match);
        } catch (_) {
          if (!token.isCancelled) failures++;
        }
        if (!token.isCancelled) {
          await Future<void>.delayed(const Duration(milliseconds: 180));
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _message = _stopping
              ? '已停止查找，已找到的字幕会保留'
              : '本轮补搜完成${failures > 0 ? '，$failures 集暂时未能查询' : ''}；多个版本请手动确认。每轮最多查找 40 集，可继续补搜。';
        });
      }
    }
  }

  Future<void> _import() async {
    final rows = _rows
        .where(
          (r) =>
              _checked.contains(r.target.id) &&
              _selected.containsKey(r.target.id),
        )
        .toList();
    if (rows.isEmpty) return;
    setState(() {
      _busy = true;
      _stopping = false;
      _message = null;
    });
    final token = _token = CancelToken();
    var saved = 0, failed = 0;
    try {
      for (final row in rows) {
        if (token.isCancelled || !mounted) break;
        final candidate = _selected[row.target.id]!;
        setState(() {
          _message = '正在导入 ${saved + failed + 1} / ${rows.length}';
          _statuses[row.target.id] = '正在读取…';
        });
        try {
          var document = candidate.document;
          if (document == null) {
            final key = '${candidate.hit.key}|${candidate.file.id}';
            var docs = widget.session.workspace.documents(key);
            if (docs == null) {
              docs = await widget.session.workspace.service.download(
                candidate.hit,
                candidate.file,
                widget.session.workspace.credentials[candidate.hit.source] ??
                    const SubtitleSearchCredentials(),
                cancelToken: token,
              );
              widget.session.workspace.cacheDocuments(key, docs);
            }
            if (token.isCancelled) break;
            if (docs.length == 1) {
              document = docs.single;
            } else {
              final matches = docs.where((d) {
                final e = SubtitleEpisode.parse(d.name),
                    target = row.target.episode;
                return e != null &&
                    target != null &&
                    e.number == target.number + _episodeOffset &&
                    (e.season == null ||
                        target.season == null ||
                        e.season == target.season);
              }).toList();
              if (matches.length != 1) {
                throw const SubtitleSearchException('字幕包内有多个版本，请先在预览中选择版本');
              }
              document = matches.single;
            }
          }
          final saveKey = 'batch:${row.target.id}:${candidate.key}';
          final path = await widget.onImport(
            row.target.id,
            SubtitleSearchImportRequest(
              hit: candidate.hit,
              document: document,
              role: _saveOnly
                  ? SubtitleSearchImportRole.saveOnly
                  : SubtitleSearchImportRole.primary,
            ),
            widget.session.savedPaths[saveKey],
          );
          widget.session.savedPaths[saveKey] = path;
          saved++;
          _checked.remove(row.target.id);
          _statuses[row.target.id] = _saveOnly ? '已保存到字幕库' : '已导入并设为主字幕';
        } catch (e) {
          if (token.isCancelled) break;
          failed++;
          _statuses[row.target.id] = e is StateError
              ? e.message.toString()
              : SubtitleSearchService.errorMessage(e);
        }
        if (mounted) setState(() {});
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _statuses.removeWhere((_, status) => status == '正在读取…');
          _message =
              '${_stopping ? '已停止 · ' : ''}成功 $saved 集${failed > 0 ? '，失败 $failed 集，可单独重试' : ''}';
        });
      }
    }
  }

  Future<void> _choose(SubtitleBatchMatch row) async {
    var query = '';
    final candidates = row.options.isNotEmpty ? row.options : _candidates;
    final chosen = await showDialog<SubtitleBatchCandidate>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) {
          final filtered = candidates
              .where((c) => c.name.toLowerCase().contains(query.toLowerCase()))
              .toList();
          return DialogKeyboardViewport(
            child: AlertDialog(
              title: Text(
                '为 ${row.target.episode?.label ?? row.target.title} 选择字幕',
              ),
              insetPadding: const EdgeInsets.all(16),
              content: SizedBox(
                width: 540,
                height: MediaQuery.sizeOf(ctx).height * .5,
                child: Column(
                  children: [
                    TextField(
                      decoration: const InputDecoration(hintText: '筛选字幕文件名'),
                      onChanged: (v) => update(() => query = v),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (_, i) => ListTile(
                          title: Text(
                            filtered[i].name,
                            style: const TextStyle(fontSize: 12),
                          ),
                          subtitle: Text(filtered[i].hit.source.label),
                          onTap: () => Navigator.pop(ctx, filtered[i]),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                DesktopButtonClickRegion(
                  child: TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('返回'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
    if (chosen != null && mounted) {
      setState(() {
        _selected[row.target.id] = chosen;
        _checked.add(row.target.id);
        _statuses.remove(row.target.id);
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: DialogKeyboardViewport(
      child: Dialog(
        insetAnimationDuration: Duration.zero,
        backgroundColor: const Color(0xFF111722),
        surfaceTintColor: Colors.transparent,
        insetPadding: MediaQuery.sizeOf(context).width < 600
            ? const EdgeInsets.all(8)
            : const EdgeInsets.all(24),
        child: SizedBox(
          width: 880,
          height: MediaQuery.sizeOf(context).height * .9,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 8, 8),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '批量匹配本文件夹',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 18,
                        ),
                      ),
                    ),
                    DesktopButtonClickRegion(
                      child: IconButton(
                        tooltip: '关闭批量匹配',
                        onPressed: _busy ? null : () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _rows.length + 1,
                  itemBuilder: (_, i) {
                    if (i == 0) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '${widget.targets.length} 个视频 · ${_candidates.length} 个字幕文件',
                            style: const TextStyle(color: accent, fontSize: 12),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            '已按集数与所选版本匹配。已有主字幕、多个版本或集数不明的项目不会自动勾选；确认后再导入。',
                            style: TextStyle(
                              color: Colors.white60,
                              height: 1.6,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            key: const ValueKey(
                              'subtitle-batch-episode-offset',
                            ),
                            initialValue: '0',
                            enabled: !_busy,
                            keyboardType: const TextInputType.numberWithOptions(
                              signed: true,
                            ),
                            inputFormatters: [
                              TextInputFormatter.withFunction(
                                (old, next) =>
                                    RegExp(r'^-?\d{0,4}$').hasMatch(next.text)
                                    ? next
                                    : old,
                              ),
                            ],
                            decoration: const InputDecoration(
                              labelText: '字幕话数偏移',
                              helperText:
                                  '字幕话数 = 视频集数 + 偏移。例如视频第 1 集对应字幕第 13 话，填 12。',
                              helperMaxLines: 4,
                              prefixIcon: Icon(Icons.swap_vert_rounded),
                            ),
                            onChanged: (value) {
                              final offset = int.tryParse(value);
                              if (offset == null) return;
                              setState(() {
                                _episodeOffset = offset;
                                _selected.clear();
                                _checked.clear();
                                _match();
                              });
                            },
                          ),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              DesktopButtonClickRegion(
                                child: TextButton.icon(
                                  onPressed: _busy ? null : _supplement,
                                  icon: const Icon(Icons.search, size: 17),
                                  label: const Text('按集补搜缺失字幕'),
                                ),
                              ),
                              FilterChip(
                                label: const Text('仅保存，不切换主字幕'),
                                selected: _saveOnly,
                                onSelected: _busy
                                    ? null
                                    : (v) => setState(() => _saveOnly = v),
                              ),
                            ],
                          ),
                          if (_message != null)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              child: Text(
                                _message!,
                                style: const TextStyle(
                                  color: accent,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          if (_busy)
                            const LinearProgressIndicator(minHeight: 2),
                          const SizedBox(height: 12),
                        ],
                      );
                    }
                    final row = _rows[i - 1],
                        candidate = _selected[row.target.id];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF192231),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Checkbox(
                            value: _checked.contains(row.target.id),
                            onChanged: _busy || candidate == null
                                ? null
                                : (v) => setState(() {
                                    if (v == true) {
                                      _checked.add(row.target.id);
                                    } else {
                                      _checked.remove(row.target.id);
                                    }
                                  }),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  row.target.title,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  _statuses[row.target.id] ?? row.reason,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color:
                                        _statuses[row.target.id]?.startsWith(
                                              '已',
                                            ) ==
                                            true
                                        ? accent
                                        : Colors.white54,
                                  ),
                                ),
                                DesktopButtonClickRegion(
                                  child: TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _choose(row),
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 8,
                                      ),
                                      alignment: Alignment.centerLeft,
                                    ),
                                    child: Text(
                                      candidate?.name ??
                                          (row.options.isNotEmpty
                                              ? '选择字幕版本（${row.options.length} 个）'
                                              : '手动指定字幕文件'),
                                      style: const TextStyle(
                                        fontSize: 11,
                                        height: 1.5,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(14),
                child: SizedBox(
                  width: double.infinity,
                  child: DesktopButtonClickRegion(
                    child: FilledButton.icon(
                      key: const ValueKey('subtitle-batch-apply'),
                      onPressed: _busy
                          ? _stop
                          : _checked.isEmpty
                          ? null
                          : _import,
                      icon: Icon(
                        _busy
                            ? Icons.stop_rounded
                            : Icons.playlist_add_check_rounded,
                      ),
                      label: Text(
                        _busy
                            ? (_stopping ? '正在停止…' : '停止')
                            : '导入选中的 ${_checked.length} 集',
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
