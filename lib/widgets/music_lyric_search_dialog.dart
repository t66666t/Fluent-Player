import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/lyrics/lyric_search_importer.dart';
import '../features/lyrics/lyric_media_metadata.dart';
import '../features/lyrics/lyric_search_models.dart';
import '../features/lyrics/lyric_search_service.dart';
import '../models/video_item.dart';
import '../services/library_service.dart';
import '../services/media_playback_service.dart';
import '../utils/app_toast.dart';
import 'dialog_keyboard_viewport.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

final _lyricSearchTheme = ThemeData.dark(useMaterial3: true).copyWith(
  colorScheme: ColorScheme.fromSeed(
    seedColor: _MusicLyricSearchDialogState.accent,
    brightness: Brightness.dark,
  ),
  textTheme: ThemeData.dark().textTheme.apply(
    fontFamily: 'Inter',
    fontFamilyFallback: const ['Noto Sans SC'],
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: Colors.white.withValues(alpha: 0.06),
    isDense: true,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    ),
  ),
);

class MusicLyricSearchDialog extends StatefulWidget {
  const MusicLyricSearchDialog({
    super.key,
    required this.item,
    required this.onImport,
    this.artist = '',
    this.mediaDuration = Duration.zero,
    this.service,
    this.autoSearch = true,
    this.metadata,
  });

  final VideoItem item;
  final String artist;
  final Duration mediaDuration;
  final LyricSearchService? service;
  final bool autoSearch;
  final Future<LyricMediaMetadata>? metadata;
  final Future<bool> Function(LyricImportRequest) onImport;

  @override
  State<MusicLyricSearchDialog> createState() => _MusicLyricSearchDialogState();
}

class _MusicLyricSearchDialogState extends State<MusicLyricSearchDialog> {
  static const accent = Color(0xFFFA586A);
  late final LyricSearchService _service =
      widget.service ?? LyricSearchService();
  late final String _filename = LyricMediaMetadata.filename(
    widget.item.path,
    widget.item.title,
  );
  late final TextEditingController _query = TextEditingController(
    text: LyricSearchQuery.clean(widget.item.title),
  );
  late final TextEditingController _filenameController = TextEditingController(
    text: _filename,
  );
  final _offset = TextEditingController(text: '0');
  late final _artist = TextEditingController(text: widget.artist);
  bool _useArtist = true;
  bool _artistEdited = false;
  bool _queryEdited = false;
  bool _readingMetadata = false;
  CancelToken? _searchToken;
  final Map<String, DownloadedLyrics> _lyricCache = {};
  final Map<LyricSource, _LyricSourceLoad> _sourceLoads = {};
  final Set<String> _readyTracks = {};
  final _results = ValueNotifier<LyricSearchResults?>(null);
  final _sourceStatuses = ValueNotifier<Map<LyricSource, LyricSourceStatus>>(
    const {},
  );
  LyricSearchResults? _snapshot;
  (String, String)? _activeQuery;
  int _generation = 0;
  LyricSource? _source;
  bool _searchComplete = false;
  DownloadedLyrics? _lyrics;
  String? _error;
  bool _searching = false;
  bool _importing = false;
  bool _includeTranslation = true;
  String _selectedFilename = '';

  @override
  void initState() {
    super.initState();
    _filenameController.addListener(_filenameSelectionChanged);
    if (widget.metadata != null) {
      _readingMetadata = true;
      _loadMetadata(widget.metadata!);
    } else if (widget.autoSearch && _query.text.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _search();
      });
    }
  }

  Future<void> _loadMetadata(Future<LyricMediaMetadata> pending) async {
    LyricMediaMetadata metadata;
    try {
      metadata = await pending;
    } catch (_) {
      metadata = const LyricMediaMetadata();
    }
    if (!mounted) return;
    setState(() {
      _readingMetadata = false;
      if (_generation == 0 && !_queryEdited && metadata.title.isNotEmpty) {
        _query.text = metadata.title;
      }
      if (!_artistEdited && _artist.text.isEmpty) {
        _artist.text = metadata.artist;
      }
    });
    if (_generation == 0 &&
        !_queryEdited &&
        !_artistEdited &&
        widget.autoSearch &&
        _query.text.isNotEmpty) {
      _search();
    }
  }

  void _filenameSelectionChanged() {
    final selection = _filenameController.selection;
    final value = selection.isValid && !selection.isCollapsed
        ? selection.textInside(_filename).trim()
        : '';
    if (value != _selectedFilename && mounted) {
      setState(() => _selectedFilename = value);
    }
  }

  @override
  void dispose() {
    _searchToken?.cancel();
    _sourceStatuses.dispose();
    _results.dispose();
    if (widget.service == null) _service.dispose();
    _query.dispose();
    _filenameController.dispose();
    _offset.dispose();
    _artist.dispose();
    super.dispose();
  }

  Future<void> _search([String? query]) async {
    if (_importing) return;
    if (query != null) _query.text = query;
    final text = _query.text.trim();
    if (text.isEmpty) {
      setState(() => _error = '请输入歌名或歌手');
      return;
    }
    final artist = _useArtist ? _artist.text.trim() : '';
    final queryKey = (text, artist);
    if (_searching && _activeQuery == queryKey) return;
    FocusScope.of(context).unfocus();
    final generation = ++_generation;
    _searchToken?.cancel();
    _sourceLoads.clear();
    _readyTracks.clear();
    _searchComplete = false;
    _sourceStatuses.value = const {};
    _snapshot = null;
    _activeQuery = queryKey;
    final token = _searchToken = CancelToken();
    setState(() {
      _searching = true;
      _error = null;
      _lyrics = null;
      _results.value = null;
    });
    try {
      final results = await _service.search(
        text,
        sources: LyricSource.values.toSet(),
        artist: artist,
        mediaDuration: widget.mediaDuration,
        cancelToken: token,
        onUpdate: (snapshot) {
          if (!mounted || generation != _generation) return;
          _acceptSnapshot(snapshot, generation, token);
        },
      );
      if (!mounted || generation != _generation) return;
      _acceptSnapshot(results, generation, token, complete: true);
      await Future.wait([
        for (final load in _sourceLoads.values)
          if (load.completion != null) load.completion!,
      ]);
    } catch (error) {
      if (!mounted || generation != _generation || token.isCancelled) return;
      setState(() => _error = LyricSearchService.errorMessage(error));
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _searching = false);
      }
    }
  }

  void _acceptSnapshot(
    LyricSearchResults snapshot,
    int generation,
    CancelToken token, {
    bool complete = false,
  }) {
    if (!mounted || generation != _generation || token.isCancelled) return;
    _snapshot = snapshot;
    _searchComplete = complete;
    for (final source in LyricSource.values) {
      final tracks = snapshot.tracks
          .where((track) => track.source == source)
          .toList();
      if (tracks.isEmpty) continue;
      final load = _sourceLoads.putIfAbsent(
        source,
        () => _LyricSourceLoad(source),
      );
      for (final track in tracks) {
        if (load.keys.add(track.key)) load.tracks.add(track);
      }
      _startSourceWorkers(load, generation, token);
    }
    _publishStatuses();
    _publishResults();
  }

  void _publishStatuses() {
    final statuses = {...?_snapshot?.statuses};
    for (final load in _sourceLoads.values) {
      final source = load.source;
      if (load.checked < load.tracks.length) {
        statuses[source] = LyricSourceStatus(
          source: source,
          phase: LyricSourcePhase.loadingLyrics,
          trackCount: load.tracks.length,
          checkedCount: load.checked,
        );
        continue;
      }
      final searchPhase = statuses[source]?.phase;
      if (!_searchComplete &&
          searchPhase != null &&
          searchPhase != LyricSourcePhase.ready &&
          searchPhase != LyricSourcePhase.failed) {
        continue;
      }
      final count = load.tracks
          .where((track) => _readyTracks.contains(track.key))
          .length;
      statuses[source] = LyricSourceStatus(
        source: source,
        phase: load.failed > 0 && count == 0
            ? LyricSourcePhase.failed
            : LyricSourcePhase.ready,
        trackCount: count,
        message: load.unavailable == 0 && load.failed == 0
            ? null
            : [
                if (load.unavailable > 0) '已过滤 ${load.unavailable} 首无同步歌词的歌曲',
                if (load.failed > 0) '${load.failed} 首获取失败，可重新搜索重试',
              ].join(' · '),
      );
    }
    _sourceStatuses.value = statuses;
  }

  void _publishResults() {
    final snapshot = _snapshot;
    if (snapshot == null) return;
    _results.value = LyricSearchResults([
      for (final track in snapshot.tracks)
        if (_readyTracks.contains(track.key)) track,
    ], errors: snapshot.errors);
  }

  void _startSourceWorkers(
    _LyricSourceLoad load,
    int generation,
    CancelToken token,
  ) {
    // QQ overlaps more of its endpoint and background decoding waits.
    final concurrency = load.source == LyricSource.qqMusic ? 4 : 2;
    while (mounted &&
        generation == _generation &&
        !token.isCancelled &&
        load.workers < concurrency &&
        load.next < load.tracks.length) {
      if (load.workers == 0) load.idle = Completer<void>();
      load.workers++;
      unawaited(_loadSourceLyrics(load, generation, token));
    }
  }

  /// Each worker publishes verified songs immediately. Supplemental search
  /// matches can fill idle slots without waiting for a slow in-flight song.
  Future<void> _loadSourceLyrics(
    _LyricSourceLoad load,
    int generation,
    CancelToken token,
  ) async {
    bool current() =>
        mounted && generation == _generation && !token.isCancelled;

    try {
      while (current() && load.next < load.tracks.length) {
        final track = load.tracks[load.next++];
        try {
          final lyrics =
              _lyricCache[track.key] ??
              await _service.fetch(track, cancelToken: token);
          if (!current()) return;
          if (lyrics.original.isEmpty) {
            load.unavailable++;
          } else {
            _lyricCache[track.key] = lyrics;
            _readyTracks.add(track.key);
            _publishResults();
          }
        } catch (error) {
          if (!current()) return;
          if (error is LyricUnavailableException) {
            load.unavailable++;
          } else {
            load.failed++;
          }
        }
        load.checked++;
        _publishStatuses();
      }
    } finally {
      load.workers--;
      if (load.workers == 0) load.idle!.complete();
    }
  }

  void _preview(LyricSearchTrack track) {
    final lyrics = _lyricCache[track.key];
    if (lyrics == null || _importing) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _lyrics = lyrics;
      _includeTranslation = lyrics.hasChineseTranslation;
      _offset.text = '0';
      _error = null;
    });
  }

  int? get _offsetMs => int.tryParse(_offset.text.trim());

  Future<void> _import() async {
    final lyrics = _lyrics;
    final offset = _offsetMs;
    if (lyrics == null || offset == null || _importing) return;
    setState(() {
      _importing = true;
      _error = null;
    });
    try {
      final applied = await widget.onImport(
        LyricImportRequest(
          lyrics,
          includeTranslation: _includeTranslation,
          offset: Duration(milliseconds: offset),
        ),
      );
      if (!mounted) return;
      // Allow this successful programmatic close through PopScope.
      setState(() => _importing = false);
      Navigator.of(context).pop();
      AppToast.show(applied ? '歌词已导入并应用' : '歌词已保存，可在原歌曲的字幕管理中选择');
    } catch (error) {
      if (mounted) {
        setState(() {
          _importing = false;
          _error = error is StateError
              ? error.message
              : LyricSearchService.errorMessage(error);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final lyrics = _lyrics;
    return Theme(
      data: _lyricSearchTheme,
      child: DialogKeyboardViewport(
        child: PopScope(
          canPop: !_importing,
          child: Dialog(
            key: const ValueKey('music-lyric-search-dialog'),
            backgroundColor: const Color(0xFF222226),
            insetAnimationDuration: Duration.zero,
            insetPadding: const EdgeInsets.all(16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            child: SizedBox(
              width: 740,
              height: 720,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
                    child: Row(
                      children: [
                        if (lyrics != null)
                          DesktopButtonClickRegion(
                            child: IconButton(
                              tooltip: '返回搜索结果',
                              onPressed: _importing
                                  ? null
                                  : () => setState(() {
                                      _lyrics = null;
                                      _error = null;
                                    }),
                              icon: const Icon(
                                CupertinoIcons.chevron_back,
                                size: 20,
                              ),
                            ),
                          ),
                        Expanded(
                          child: Text(
                            lyrics == null ? '搜索歌词' : '歌词预览',
                            style: const TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        DesktopButtonClickRegion(
                          child: IconButton(
                            key: const ValueKey('music-lyric-search-close'),
                            tooltip: '关闭歌词搜索',
                            onPressed: _importing
                                ? null
                                : () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_searching || _importing || _readingMetadata)
                    const LinearProgressIndicator(minHeight: 2, color: accent),
                  Expanded(
                    child: lyrics == null
                        ? _searchBody()
                        : _previewBody(lyrics),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                      child: Text(
                        _error!,
                        key: const ValueKey('lyric-search-error'),
                        style: const TextStyle(color: Color(0xFFFFB4AB)),
                      ),
                    ),
                  if (lyrics != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                      child: SizedBox(
                        width: double.infinity,
                        child: DesktopButtonClickRegion(
                          child: FilledButton.icon(
                            key: const ValueKey('lyric-search-import'),
                            onPressed: _importing || _offsetMs == null
                                ? null
                                : _import,
                            icon: const Icon(Icons.download_rounded),
                            label: Text(_importing ? '正在导入…' : '导入并应用歌词'),
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
    );
  }

  List<LyricSearchTrack> _visibleTracks(LyricSearchResults? results) => [
    for (final track in results?.tracks ?? const <LyricSearchTrack>[])
      if (_source == null || track.source == _source) track,
  ];

  Widget _searchBody() => ValueListenableBuilder<LyricSearchResults?>(
    valueListenable: _results,
    builder: (context, results, _) => _searchResultsBody(results),
  );

  Widget _searchResultsBody(LyricSearchResults? results) {
    final tracks = _visibleTracks(results);
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('lyric-search-query'),
                        controller: _query,
                        onChanged: (_) => _queryEdited = true,
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _search(),
                        decoration: const InputDecoration(
                          hintText: '歌名、歌手或文件名片段',
                          prefixIcon: Icon(Icons.search),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    DesktopButtonClickRegion(
                      child: FilledButton(
                        onPressed: () => _search(),
                        child: const Text('搜索'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('lyric-search-artist'),
                        controller: _artist,
                        onChanged: (_) => _artistEdited = true,
                        onSubmitted: (_) => _search(),
                        textInputAction: TextInputAction.search,
                        decoration: const InputDecoration(
                          hintText: '作者 / 歌手（可选，可修改）',
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilterChip(
                      key: const ValueKey('lyric-search-use-artist'),
                      label: Text(_useArtist ? '结合作者' : '仅搜歌名'),
                      selected: _useArtist,
                      onSelected: (selected) {
                        setState(() => _useArtist = selected);
                        _search();
                      },
                    ),
                  ],
                ),
                if (_readingMetadata)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      '正在读取文件中的歌名和作者信息…',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      const Text(
                        '来源：',
                        style: TextStyle(color: Colors.white60),
                      ),
                      CapsuleDropdownButton<LyricSource?>(
                        key: const ValueKey('lyric-search-source'),
                        value: _source,
                        underline: const SizedBox.shrink(),
                        items: [
                          const DropdownMenuItem(
                            value: null,
                            child: Text('全部来源'),
                          ),
                          for (final source in LyricSource.values)
                            DropdownMenuItem(
                              value: source,
                              child: Text(source.label),
                            ),
                        ],
                        onChanged: (source) {
                          setState(() => _source = source);
                        },
                      ),
                      const SizedBox(width: 16),
                      const Text(
                        '优先逐字 · 至少逐句',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                ExpansionTile(
                  key: const ValueKey('lyric-search-filename-options'),
                  tilePadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('从文件名选词', style: TextStyle(fontSize: 13)),
                  subtitle: Text(
                    _filename,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final query in {
                          ...LyricSearchQuery.suggestions(widget.item.title),
                          ...LyricSearchQuery.suggestions(_filename),
                        })
                          ActionChip(
                            label: Text(query),
                            onPressed: () => _search(query),
                          ),
                      ],
                    ),
                    TextField(
                      key: const ValueKey('lyric-search-filename'),
                      controller: _filenameController,
                      readOnly: true,
                      maxLines: null,
                      decoration: const InputDecoration(
                        helperText: '拖选或长按文件名中的一部分，再点击下方搜索',
                      ),
                    ),
                    DesktopButtonClickRegion(
                      child: TextButton(
                        onPressed: _selectedFilename.isEmpty
                            ? null
                            : () => _search(_selectedFilename),
                        child: const Text('搜索选中的文字'),
                      ),
                    ),
                  ],
                ),
                ValueListenableBuilder<Map<LyricSource, LyricSourceStatus>>(
                  valueListenable: _sourceStatuses,
                  builder: (context, statuses, _) => Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final source in LyricSource.values)
                          if (statuses[source] != null)
                            Text(
                              statuses[source]!.summary,
                              style: TextStyle(
                                color:
                                    statuses[source]!.phase ==
                                        LyricSourcePhase.failed
                                    ? const Color(0xFFFFB4AB)
                                    : Colors.white60,
                                fontSize: 12,
                              ),
                            ),
                      ],
                    ),
                  ),
                ),
                if (results != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      '${tracks.length} 个可用歌词版本 · ${widget.mediaDuration > Duration.zero ? '按时长差排序' : '按匹配度排序'}',
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 12,
                      ),
                    ),
                  ),
                if (widget.mediaDuration > Duration.zero)
                  Text(
                    '当前文件 ${_time(widget.mediaDuration)}.${(widget.mediaDuration.inMilliseconds % 1000).toString().padLeft(3, '0')}',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                if (results != null &&
                    _sourceStatuses.value.isEmpty &&
                    results.errors.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      results.errors.entries
                          .map((e) => '${e.key.label}：${e.value}')
                          .join('\n'),
                      style: const TextStyle(
                        color: Color(0xFFFFB4AB),
                        fontSize: 12,
                      ),
                    ),
                  ),
                if (results != null && tracks.isEmpty && !_searching)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      '未找到可用结果。试试只搜索歌名，或切换歌词来源。',
                      style: TextStyle(color: Colors.white60),
                    ),
                  ),
                if (results == null && !_searching)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      '已从文件名提取搜索词，可修改后搜索。',
                      style: TextStyle(color: Colors.white60),
                    ),
                  ),
              ],
            ),
          ),
        ),
        SliverList.builder(
          itemCount: tracks.length,
          itemBuilder: (context, index) {
            final track = tracks[index];
            final delta =
                widget.mediaDuration > Duration.zero &&
                    track.duration > Duration.zero
                ? (widget.mediaDuration - track.duration).inMilliseconds.abs() /
                      1000
                : null;
            return ListTile(
              key: ValueKey('lyric-result-${track.key}'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              leading: const Icon(CupertinoIcons.music_note, color: accent),
              title: Text(
                track.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    [
                      track.artist,
                      track.album,
                      '${track.source.label} · ${_time(track.duration)}',
                      if (delta != null) '时长差 ${delta.toStringAsFixed(2)} 秒',
                      if (track.duration <= Duration.zero) '来源未提供时长',
                    ].where((s) => s.isNotEmpty).join('\n'),
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                  const SizedBox(height: 6),
                  _lyricMarks(track),
                ],
              ),
              trailing: const Icon(CupertinoIcons.chevron_right, size: 16),
              onTap: _importing ? null : () => _preview(track),
            );
          },
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
      ],
    );
  }

  Widget _previewBody(DownloadedLyrics lyrics) {
    final offset = Duration(milliseconds: _offsetMs ?? 0);
    final original = lyrics.shifted(lyrics.original, offset);
    final translation = _includeTranslation
        ? lyrics.shifted(lyrics.translation, offset)
        : const [];
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      children: [
        Text(
          lyrics.track.title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        Text(
          '${lyrics.track.artist} · ${lyrics.track.source.label}',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            Chip(label: Text(lyrics.hasWordTiming ? '逐字时间轴' : '逐句时间轴')),
            Chip(label: Text('${lyrics.original.length} 句')),
            Chip(
              label: Text(lyrics.hasChineseTranslation ? '有中文翻译' : '来源未提供中文翻译'),
            ),
          ],
        ),
        if (widget.mediaDuration > Duration.zero &&
            lyrics.track.duration > Duration.zero &&
            (widget.mediaDuration - lyrics.track.duration).inSeconds.abs() > 5)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              '此版本与当前文件时长不同，请核对是否为现场、翻唱或剪辑版本。',
              style: TextStyle(color: Color(0xFFFFD59A), fontSize: 12),
            ),
          ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('同时导入中文翻译', style: TextStyle(fontSize: 14)),
          value: _includeTranslation,
          onChanged: !lyrics.hasChineseTranslation || _importing
              ? null
              : (value) => setState(() => _includeTranslation = value ?? false),
        ),
        TextField(
          key: const ValueKey('lyric-search-offset'),
          controller: _offset,
          enabled: !_importing,
          keyboardType: const TextInputType.numberWithOptions(signed: true),
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: '时间偏移（毫秒）',
            helperText: '正数延后，负数提前；原文和翻译同步移动',
            errorText: _offsetMs == null ? '请输入整数毫秒' : null,
          ),
        ),
        const SizedBox(height: 16),
        for (final cue in original)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _time(cue.startTime),
                  style: const TextStyle(fontSize: 11, color: accent),
                ),
                const SizedBox(height: 4),
                Text(
                  cue.text,
                  style: const TextStyle(fontSize: 16, height: 1.4),
                ),
              ],
            ),
          ),
        if (translation.isNotEmpty) ...[
          const Divider(),
          const Text(
            '中文翻译 · 保留来源时间轴',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          for (final cue in translation)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                '${_time(cue.startTime)}  ${cue.text}',
                style: const TextStyle(color: Colors.white70, height: 1.4),
              ),
            ),
        ],
      ],
    );
  }

  Widget _lyricMarks(LyricSearchTrack track) {
    final lyrics = _lyricCache[track.key]!;
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        _mark(lyrics.hasWordTiming ? '逐字时间轴' : '逐句时间轴'),
        _mark(lyrics.hasChineseTranslation ? '有中文翻译' : '无中文翻译'),
      ],
    );
  }

  Widget _mark(String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      label,
      style: const TextStyle(color: Colors.white70, fontSize: 11),
    ),
  );

  String _time(Duration duration) =>
      '${duration.inMinutes.toString().padLeft(2, '0')}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
}

class _LyricSourceLoad {
  _LyricSourceLoad(this.source);

  final LyricSource source;
  final tracks = <LyricSearchTrack>[];
  final keys = <String>{};
  int next = 0;
  int checked = 0;
  int unavailable = 0;
  int failed = 0;
  int workers = 0;
  Completer<void>? idle;
  Future<void>? get completion => idle?.future;
}

Future<void> showMusicLyricSearchDialog(
  BuildContext context, {
  String artist = '',
  VideoItem? item,
}) async {
  final playback = context.read<MediaPlaybackService>();
  final library = context.read<LibraryService>();
  final target = item ?? playback.currentItem;
  if (target == null) return;
  // 只有正在播放的这部媒体才用播放器时长；其它卡片用资料里的时长。
  final duration =
      playback.currentItem?.id == target.id && playback.duration > Duration.zero
      ? playback.duration
      : Duration(milliseconds: target.durationMs);
  final metadata = LyricMediaMetadataProbe.probe(target.path);
  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭歌词搜索',
    barrierColor: Colors.black.withValues(alpha: 0.38),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (context, animation, secondaryAnimation) =>
        MusicLyricSearchDialog(
          item: target,
          artist: artist,
          metadata: metadata,
          mediaDuration: duration,
          onImport: (request) => const LyricSearchImporter().import(
            itemId: target.id,
            request: request,
            library: library,
            playback: playback,
          ),
        ),
    transitionBuilder: (context, animation, secondaryAnimation, child) =>
        FadeTransition(
          opacity: CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          ),
          child: child,
        ),
  );
}
