import 'package:video_player_app/widgets/dialog_keyboard_viewport.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../features/subtitle_search/subtitle_search_models.dart';
import '../features/subtitle_search/subtitle_search_service.dart';
import '../features/subtitle_search/subtitle_search_workspace.dart';
import '../features/subtitle_search/subtitle_batch_matcher.dart';
import 'subtitle_batch_import_dialog.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

const _accent = Color(0xFF7DE2CB);
const _surface = Color(0xFF111722);
const _card = Color(0xFF192231);
const _muted = Color(0xFF9CAEC3);

Future<void> showSubtitleSearchDialog(
  BuildContext context, {
  required String mediaKey,
  required String title,
  String filename = '',
  List<SubtitleBatchTarget> batchTargets = const [],
  SubtitleBatchImportCallback? onBatchImport,
  required Future<String> Function(
    SubtitleSearchImportRequest request,
    String? existingPath,
  )
  onImport,
  SubtitleSearchWorkspace? workspace,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: true,
  barrierLabel: '关闭字幕搜索',
  barrierColor: Colors.black.withValues(alpha: .68),
  transitionDuration: MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 220),
  pageBuilder: (_, _, _) => SubtitleSearchDialog(
    mediaKey: mediaKey,
    title: title,
    filename: filename,
    batchTargets: batchTargets,
    onBatchImport: onBatchImport,
    workspace: workspace,
    onImport: onImport,
  ),
  transitionBuilder: (_, animation, _, child) => FadeTransition(
    opacity: animation,
    child: SlideTransition(
      position: Tween(
        begin: const Offset(0, .025),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    ),
  ),
);

class SubtitleSearchDialog extends StatefulWidget {
  const SubtitleSearchDialog({
    super.key,
    required this.mediaKey,
    required this.title,
    required this.onImport,
    this.workspace,
    this.filename = '',
    this.batchTargets = const [],
    this.onBatchImport,
  });
  final String mediaKey, title;
  final String filename;
  final List<SubtitleBatchTarget> batchTargets;
  final SubtitleBatchImportCallback? onBatchImport;
  final SubtitleSearchWorkspace? workspace;
  final Future<String> Function(
    SubtitleSearchImportRequest request,
    String? existingPath,
  )
  onImport;
  @override
  State<SubtitleSearchDialog> createState() => _SubtitleSearchDialogState();
}

class _SubtitleSearchDialogState extends State<SubtitleSearchDialog> {
  late final workspace = widget.workspace ?? SubtitleSearchWorkspace.instance;
  late final session = workspace.acquire(
    widget.mediaKey,
    widget.title,
    filename: widget.filename,
  );
  late final _query = TextEditingController(text: session.text);
  late final _season = TextEditingController(text: session.season);
  late final _episode = TextEditingController(text: session.episode);
  late final _offset = TextEditingController(text: session.offset);
  late final _scroll = ScrollController(
    initialScrollOffset: session.scrollOffset,
  );
  final _queryFocus = FocusNode();
  final _filenameScroll = ScrollController(keepScrollOffset: false);
  late final _filename = TextEditingController(
    text: subtitleVisibleLabel(widget.filename).isEmpty
        ? subtitleVisibleLabel(widget.title)
        : subtitleVisibleLabel(widget.filename),
  );
  String _selectedName = '';
  bool _advanced = false, _importing = false, _wide = false;
  String? _success, _importError;
  SubtitleSearchImportRole _role = SubtitleSearchImportRole.primary;
  Duration get _motion => MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 180);

  @override
  void initState() {
    super.initState();
    session.addListener(_changed);
    workspace.addListener(_changed);
    _scroll.addListener(_rememberScroll);
    _filename.addListener(_nameSelectionChanged);
    unawaited(
      session.restored.then((_) {
        if (!mounted) return;
        _query.text = session.text;
        _season.text = session.season;
        _episode.text = session.episode;
        if (session.completedQuery == null &&
            session.work == null &&
            session.works.isEmpty &&
            !session.lookingUpWorks) {
          unawaited(session.lookupWorks());
        }
        setState(() {});
      }),
    );
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _rememberScroll() {
    if (_scroll.hasClients) session.scrollOffset = _scroll.offset;
  }

  @override
  void dispose() {
    session.removeListener(_changed);
    workspace.removeListener(_changed);
    workspace.release(session);
    _query.dispose();
    _season.dispose();
    _episode.dispose();
    _offset.dispose();
    _scroll.dispose();
    _queryFocus.dispose();
    _filename.dispose();
    _filenameScroll.dispose();
    super.dispose();
  }

  void _back() {
    if (_importing) return;
    if (!_wide && session.selected != null) {
      session.closeDetail();
    } else {
      Navigator.of(context).pop();
    }
  }

  void _search({bool refresh = true}) {
    FocusManager.instance.primaryFocus?.unfocus();
    _success = _importError = null;
    unawaited(session.search(force: refresh));
  }

  void _nameSelectionChanged() {
    final selection = _filename.selection;
    final selected = selection.isValid && !selection.isCollapsed
        ? selection.textInside(_filename.text).trim()
        : '';
    if (mounted && selected != _selectedName) {
      setState(() => _selectedName = selected);
    }
  }

  void _searchName(String value) {
    _query.text = value;
    session.updateText(value);
    _search();
  }

  void _chooseWork(SubtitleSearchWork value) {
    FocusManager.instance.primaryFocus?.unfocus();
    final request = session.chooseWork(value);
    _query.text = session.text;
    _season.text = session.season;
    _episode.text = session.episode;
    _success = _importError = null;
    unawaited(request);
  }

  Widget _nameSuggestions() {
    final suggestions =
        <String>{
          subtitleVisibleLabel(SubtitleSearchQuery.cleanTitle(widget.title)),
          subtitleVisibleLabel(SubtitleSearchQuery.cleanTitle(_filename.text)),
          ...SubtitleSearchQuery.cleanTitle(
            _filename.text,
          ).split(RegExp(r'\s[-|｜]\s|第\s*\d+\s*[集话話]|\s-\s\d+.*')),
        }..removeWhere(
          (s) => s.trim().runes.length < 2 || subtitleVisibleLabel(s).isEmpty,
        );
    return ExpansionTile(
      key: const PageStorageKey('subtitle-search-name-picker'),
      tilePadding: EdgeInsets.zero,
      title: const Text('从视频名快速选词', style: TextStyle(fontSize: 12)),
      subtitle: Text(
        _filename.text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: _muted, fontSize: 10),
      ),
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final value in suggestions.take(8))
              ActionChip(
                label: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 240),
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                onPressed: () => _searchName(value),
              ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('subtitle-search-filename'),
          controller: _filename,
          scrollController: _filenameScroll,
          readOnly: true,
          maxLines: null,
          decoration: const InputDecoration(
            helperText: '长按或拖选视频名的一部分，再点击下方搜索',
            helperMaxLines: 2,
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: DesktopButtonClickRegion(child: TextButton.icon(
            key: const ValueKey('subtitle-search-selected-name'),
            onPressed: _selectedName.isEmpty
                ? null
                : () => _searchName(_selectedName),
            icon: const Icon(Icons.search, size: 17),
            label: const Text('搜索选中的文字'),
          )),
        ),
      ],
    );
  }

  Future<void> _batch() async {
    final hit = session.selected, file = session.selectedFile;
    if (hit == null || file == null || widget.onBatchImport == null) return;
    if (session.documents.isEmpty) {
      await session.preview();
      if (!mounted || session.documents.isEmpty) return;
    }
    final candidates = <String, SubtitleBatchCandidate>{};
    void add(SubtitleBatchCandidate c) => candidates[c.key] = c;
    final documents = session.documents;
    if (documents.length > 1) {
      for (final doc in documents) {
        add(SubtitleBatchCandidate(hit: hit, file: file, document: doc));
      }
    } else {
      for (final f in session.availableFiles) {
        add(
          SubtitleBatchCandidate(
            hit: hit,
            file: f,
            document: f.id == file.id ? documents.firstOrNull : null,
          ),
        );
      }
    }
    if (hit.source == SubtitleSearchSource.xunlei) {
      for (final result in session.hits.where((h) => h.source == hit.source)) {
        for (final f in result.files) {
          add(SubtitleBatchCandidate(hit: result, file: f));
        }
      }
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: const ColorScheme.dark(
            primary: _accent,
            surface: _surface,
          ),
        ),
        child: SubtitleBatchImportDialog(
          targets: widget.batchTargets,
          candidates: candidates.values.toList(),
          session: session,
          anchorTitle: SubtitleEpisode.parse(widget.filename) == null
              ? widget.title
              : widget.filename,
          preferredName: session.document?.name ?? file.name,
          onImport: widget.onBatchImport!,
        ),
      ),
    );
  }

  Future<T?> _modal<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    bool barrierDismissible = true,
  }) => showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (ctx) => Theme(
      data: ThemeData.dark().copyWith(
        colorScheme: const ColorScheme.dark(
          primary: _accent,
          surface: _surface,
        ),
      ),
      child: builder(ctx),
    ),
  );

  Future<void> _openWebsite(Uri url) async {
    try {
      if (await launchUrl(url, mode: LaunchMode.externalApplication)) return;
    } catch (_) {}
    if (mounted) setState(() => _importError = '无法打开浏览器，请稍后重试');
  }

  Future<void> _import() async {
    final doc = session.document, hit = session.selected;
    final offset = int.tryParse(_offset.text.trim());
    if (doc == null || hit == null || offset == null || _importing) return;
    if (offset.abs() > 3600000) {
      setState(() => _importError = '时间偏移请控制在一小时以内');
      return;
    }
    final request = SubtitleSearchImportRequest(
      hit: hit,
      document: doc,
      role: _role,
      offsetMs: offset,
    );
    if (!doc.cues.any((cue) => cue.endTime.inMilliseconds + offset > 0)) {
      setState(() => _importError = '偏移后没有可用字幕，请减小提前量');
      return;
    }
    final key = '${session.documentKey}|${doc.name}|$offset';
    setState(() {
      _importing = true;
      _importError = _success = null;
    });
    try {
      final path = await widget.onImport(request, session.savedPaths[key]);
      session.savedPaths[key] = path;
      if (mounted) {
        setState(
          () => _success = switch (_role) {
            SubtitleSearchImportRole.primary => '已保存并设为主字幕',
            SubtitleSearchImportRole.secondary => '已保存并设为副字幕',
            SubtitleSearchImportRole.saveOnly => '已保存到当前视频的字幕库',
          },
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _importError = e is StateError
              ? e.message.toString()
              : SubtitleSearchService.errorMessage(e),
        );
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final textScaler = MediaQuery.textScalerOf(context);
    final fullscreen = size.width < 600 || size.height < 450;
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: _accent,
          secondary: _accent,
          surface: _surface,
          onPrimary: Color(0xFF09251F),
          onSurface: Colors.white,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: _card,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 14,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Colors.white12),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Colors.white12),
          ),
        ),
      ),
      child: SafeArea(
        child: Dialog(
          insetAnimationDuration: Duration.zero,
          backgroundColor: _surface,
          surfaceTintColor: Colors.transparent,
          insetPadding: fullscreen ? EdgeInsets.zero : const EdgeInsets.all(24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(fullscreen ? 0 : 24),
          ),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: 1100,
            height: fullscreen ? double.infinity : 820,
            child: LayoutBuilder(
              builder: (context, constraints) {
                _wide =
                    constraints.maxWidth >= 840 && textScaler.scale(1) < 1.6;
                final detailOnly = !_wide && session.selected != null;
                return PopScope(
                  canPop: !_importing && !detailOnly,
                  onPopInvokedWithResult: (didPop, _) {
                    if (!didPop && !_importing) session.closeDetail();
                  },
                  child: CallbackShortcuts(
                    bindings: {
                      const SingleActivator(LogicalKeyboardKey.escape): _back,
                      const SingleActivator(
                        LogicalKeyboardKey.keyF,
                        control: true,
                      ): () =>
                          _queryFocus.requestFocus(),
                      const SingleActivator(
                        LogicalKeyboardKey.keyF,
                        meta: true,
                      ): () =>
                          _queryFocus.requestFocus(),
                    },
                    child: Column(
                      children: [
                        _header(detailOnly),
                        if (session.searching)
                          const LinearProgressIndicator(
                            minHeight: 2,
                            color: _accent,
                            backgroundColor: _card,
                          ),
                        Expanded(
                          child: _wide
                              ? Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Expanded(flex: 11, child: _results()),
                                    const VerticalDivider(
                                      width: 1,
                                      color: Colors.white10,
                                    ),
                                    Expanded(
                                      flex: 10,
                                      child: session.selected == null
                                          ? _previewPlaceholder()
                                          : _detail(),
                                    ),
                                  ],
                                )
                              : AnimatedSwitcher(
                                  duration: _motion,
                                  switchInCurve: Curves.easeOutCubic,
                                  child: detailOnly
                                      ? KeyedSubtree(
                                          key: const ValueKey('detail'),
                                          child: _detail(),
                                        )
                                      : KeyedSubtree(
                                          key: const ValueKey('results'),
                                          child: _results(),
                                        ),
                                ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(bool detailOnly) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
    child: Row(
      children: [
        if (detailOnly)
          DesktopButtonClickRegion(child: IconButton(
            tooltip: '返回搜索结果',
            onPressed: _importing ? null : _back,
            icon: const Icon(Icons.arrow_back_rounded),
          ))
        else
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: _accent.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.subtitles_outlined,
              color: _accent,
              size: 23,
            ),
          ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                detailOnly ? '字幕预览' : '寻找好字幕',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                '保存目标：${subtitleVisibleLabel(widget.title).isEmpty ? '当前媒体' : widget.title}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: _muted),
              ),
            ],
          ),
        ),
        DesktopButtonClickRegion(child: IconButton(
          key: const ValueKey('subtitle-search-sources'),
          tooltip: '管理字幕来源',
          onPressed: _importing ? null : _connections,
          icon: Badge(
            isLabelVisible: workspace.connectedCount > 0,
            label: Text('${workspace.connectedCount}'),
            backgroundColor: _accent,
            textColor: _surface,
            child: const Icon(Icons.tune_rounded, size: 22),
          ),
        )),
        DesktopButtonClickRegion(child: IconButton(
          tooltip: '关闭字幕搜索',
          onPressed: _importing ? null : () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close_rounded),
        )),
      ],
    ),
  );

  Widget _results() {
    final visible = session.visibleHits.toList();
    return CustomScrollView(
      key: PageStorageKey('subtitle-search-list:${widget.mediaKey}'),
      controller: _scroll,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
          sliver: SliverToBoxAdapter(child: _searchForm()),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!workspace.ready)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),

                if (session.message != null)
                  _notice(session.message!, Icons.info_outline, _muted),
                if (_importError != null && session.selected == null)
                  _notice(
                    _importError!,
                    Icons.error_outline,
                    Colors.orangeAccent,
                  ),
                if (session.completedQuery != null) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${visible.length} 个字幕结果',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      if (!session.searching)
                        DesktopButtonClickRegion(child: IconButton(
                          tooltip: '重新搜索',
                          onPressed: () => _search(refresh: true),
                          icon: const Icon(Icons.refresh_rounded, size: 20),
                        )),
                    ],
                  ),
                  SingleChildScrollView(
                    key: const PageStorageKey('subtitle-search-source-filters'),
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _sourceChip(null),
                        ...SubtitleSearchSource.values
                            .where((s) => workspace.configured(s))
                            .map(_sourceChip),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: FilterChip(
                        label: const Text('只看整季 / 合集'),
                        selected: session.packsOnly,
                        onSelected: (value) =>
                            setState(() => session.packsOnly = value),
                        avatar: const Icon(
                          Icons.inventory_2_outlined,
                          size: 16,
                        ),
                      ),
                    ),
                  ),
                  if (session.pending.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        '正在查找 · ${session.pending.map((s) => s.label).join('、')}',
                        style: const TextStyle(fontSize: 12, color: _muted),
                      ),
                    ),
                  for (final error in session.errors.entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _notice(
                        '${error.key.label} · ${error.value}',
                        Icons.cloud_off_outlined,
                        Colors.orangeAccent,
                        action: DesktopButtonClickRegion(child: TextButton(
                          onPressed: session.searching
                              ? null
                              : () => session.search(
                                  force: true,
                                  retry: error.key,
                                ),
                          child: const Text('重试'),
                        )),
                      ),
                    ),
                  if (!session.searching && session.visibleHits.isEmpty)
                    _emptyResults(),
                ] else if (workspace.connectedCount > 0)
                  _startState(),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          sliver: SliverList.builder(
            itemCount: visible.length,
            itemBuilder: (_, i) => _resultCard(visible[i]),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              children: [
                if (session.more.isNotEmpty)
                  DesktopButtonClickRegion(child: OutlinedButton.icon(
                    onPressed: session.searching ? null : session.loadMore,
                    icon: const Icon(Icons.expand_more),
                    label: const Text('加载更多字幕'),
                  )),
                if (workspace.connectedCount > 0)
                  DesktopButtonClickRegion(child: TextButton.icon(
                    onPressed: _connections,
                    icon: const Icon(Icons.add_link_rounded, size: 17),
                    label: Text('默认来源直接可用 · 更多来源'),
                  )),
                const SizedBox(height: 4),
                const Text(
                  '字幕服务由各来源提供。不同发行版本可能需要调整时间。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: _muted),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _workPicker() {
    final selected = session.work;
    if (selected != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          decoration: BoxDecoration(
            color: _accent.withValues(alpha: .09),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _accent.withValues(alpha: .22)),
          ),
          child: Row(
            children: [
              const Icon(Icons.check_circle_outline, color: _accent, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      selected.title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: _accent,
                      ),
                    ),
                    Text(
                      '${selected.year} · ${selected.isMovie ? '电影' : '剧集 / 动漫'} · 已限定 SubHD 作品范围',
                      style: const TextStyle(fontSize: 10, color: _muted),
                    ),
                    if (!selected.isMovie && session.episode.isNotEmpty)
                      DesktopButtonClickRegion(child: TextButton(
                        onPressed: session.searching
                            ? null
                            : () {
                                session.episode = '';
                                _episode.clear();
                                session.edit();
                                _search();
                              },
                        child: const Text(
                          '浏览本季全部字幕',
                          style: TextStyle(fontSize: 11),
                        ),
                      )),
                  ],
                ),
              ),
              DesktopButtonClickRegion(child: IconButton(
                tooltip: '重新选择作品或季度',
                onPressed: () => session.updateText(session.text),
                icon: const Icon(Icons.swap_horiz_rounded, size: 20),
              )),
            ],
          ),
        ),
      );
    }
    if (session.lookingUpWorks) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                '正在识别作品和季度…',
                style: TextStyle(color: _muted, fontSize: 12),
              ),
            ),
          ],
        ),
      );
    }
    if (session.workError != null) {
      return _notice(
        session.workError!,
        Icons.info_outline,
        _muted,
        action: DesktopButtonClickRegion(child: TextButton(
          onPressed: session.lookupWorks,
          child: const Text('重试目录'),
        )),
      );
    }
    if (session.works.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('先选作品或季度', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          const Text(
            '向右浏览 · 选中后按作品查找，电影、各季和短篇分别显示',
            style: TextStyle(color: _muted, fontSize: 11),
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            key: const PageStorageKey('subtitle-search-work-catalog'),
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final work in session.works)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: SizedBox(
                      width: 216,
                      child: Material(
                        color: _card,
                        borderRadius: BorderRadius.circular(14),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          key: ValueKey('subtitle-work-${work.id}'),
                          onTap: () => _chooseWork(work),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      work.isMovie
                                          ? Icons.movie_outlined
                                          : Icons.video_library_outlined,
                                      color: _accent,
                                      size: 18,
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        '${work.year} · ${work.isMovie ? '电影' : '剧集 / 动漫'}',
                                        style: const TextStyle(
                                          color: _muted,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  work.title,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    height: 1.4,
                                  ),
                                ),
                                if (work.originalTitle.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 5),
                                    child: Text(
                                      work.originalTitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: _muted,
                                        fontSize: 10,
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
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _searchForm() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        '电影、剧集，或下一部想看的动画',
        style: TextStyle(color: _muted, fontSize: 12),
      ),
      const SizedBox(height: 10),
      TextField(
        key: const ValueKey('subtitle-search-query'),
        controller: _query,
        focusNode: _queryFocus,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => _search(),
        onChanged: (value) {
          session.updateText(value);
        },
        decoration: InputDecoration(
          hintText: '输入片名或视频文件名',
          prefixIcon: const Icon(Icons.search_rounded, color: _accent),
          suffixIcon: _query.text.isEmpty
              ? null
              : DesktopButtonClickRegion(child: IconButton(
                  tooltip: '清空片名',
                  onPressed: () {
                    _query.clear();
                    session.updateText('');
                    setState(() {});
                  },
                  icon: const Icon(Icons.close_rounded, size: 18),
                )),
        ),
      ),
      const SizedBox(height: 10),
      _expand(
        duration: _motion,
        alignment: Alignment.topCenter,
        child: _workPicker(),
      ),
      _nameSuggestions(),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final (value, label) in [
            ('', '全部语言'),
            ('zh-cn', '简中'),
            ('zh-tw', '繁中'),
            ('en', '英语'),
            ('ja', '日语'),
          ])
            ChoiceChip(
              label: Text(label),
              selected: session.language == value,
              showCheckmark: false,
              visualDensity: VisualDensity.compact,
              onSelected: (_) => setState(() {
                session.language = value;
                session.edit();
              }),
            ),
          DesktopButtonClickRegion(child: TextButton.icon(
            onPressed: () => setState(() => _advanced = !_advanced),
            icon: Icon(
              _advanced ? Icons.expand_less : Icons.filter_list_rounded,
              size: 17,
            ),
            label: Text(
              session.season.isEmpty && session.episode.isEmpty
                  ? '季 / 集'
                  : [
                      if (session.season.isNotEmpty) '第 ${session.season} 季',
                      if (session.episode.isNotEmpty) '第 ${session.episode} 集',
                    ].join(' · '),
            ),
          )),
        ],
      ),
      _expand(
        duration: _motion,
        alignment: Alignment.topCenter,
        child: !_advanced
            ? const SizedBox(width: double.infinity)
            : Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _season,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(3),
                            ],
                            decoration: const InputDecoration(
                              labelText: '第几季',
                              hintText: '可留空',
                            ),
                            onChanged: (v) {
                              if (session.work != null && v != session.season) {
                                session.work = null;
                                unawaited(session.lookupWorks());
                              }
                              session.season = v;
                              session.edit();
                              setState(() {});
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: _episode,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(4),
                            ],
                            onSubmitted: (_) => _search(),
                            decoration: const InputDecoration(
                              labelText: '第几集',
                              hintText: '可留空',
                            ),
                            onChanged: (v) {
                              session.episode = v;
                              session.edit();
                              setState(() {});
                            },
                          ),
                        ),
                      ],
                    ),
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        '动画可填写连续集数；部分来源未标注语言或季集，请同时核对文件名。',
                        style: TextStyle(color: _muted, fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
      ),
      const SizedBox(height: 12),
      DesktopButtonClickRegion(child: FilledButton.icon(
        key: const ValueKey('subtitle-search-submit'),
        onPressed: !workspace.ready
            ? null
            : session.searching
            ? session.cancelSearch
            : _search,
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 46),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(13),
          ),
        ),
        icon: Icon(
          session.searching ? Icons.stop_rounded : Icons.travel_explore_rounded,
          size: 20,
        ),
        label: Text(
          session.searching ? '停止搜索' : '搜索字幕',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      )),
    ],
  );

  Widget _sourceChip(SubtitleSearchSource? source) => Padding(
    padding: const EdgeInsets.only(right: 6),
    child: ChoiceChip(
      label: Text(source?.label ?? '全部来源'),
      selected: session.sourceFilter == source,
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
      onSelected: (_) => setState(() => session.sourceFilter = source),
    ),
  );

  Widget _expand({
    required Duration duration,
    required Alignment alignment,
    required Widget child,
  }) => duration == Duration.zero
      ? child
      : AnimatedSize(duration: duration, alignment: alignment, child: child);

  Widget _startState() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '从当前片名开始',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        const Text(
          '选择字幕语言，搜索后先看看内容，再设为主字幕或副字幕。',
          style: TextStyle(color: _muted, height: 1.6),
        ),
        if (workspace.recent.isNotEmpty) ...[
          const SizedBox(height: 24),
          const Text('最近搜索', style: TextStyle(color: _muted, fontSize: 12)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final text in workspace.recent)
                ActionChip(
                  label: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  onPressed: () {
                    _query.text = text;
                    session.text = text;
                    session.edit();
                    _search();
                  },
                ),
            ],
          ),
        ],
      ],
    ),
  );

  Widget _emptyResults() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Column(
      children: [
        const Icon(Icons.manage_search_rounded, color: _muted, size: 40),
        const SizedBox(height: 10),
        Text(
          session.errors.length == workspace.connectedCount
              ? '字幕来源暂时没有响应'
              : '还没找到合适的字幕',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        const Text(
          '试试作品原名、英文名，或去掉发行组与画质信息。也可以清空季集、切换语言或增加来源。',
          textAlign: TextAlign.center,
          style: TextStyle(color: _muted, height: 1.6, fontSize: 12),
        ),
      ],
    ),
  );

  Widget _resultCard(SubtitleSearchHit hit) {
    final active = session.selected?.key == hit.key;
    final info = hit.releaseInfo;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AnimatedContainer(
        duration: _motion,
        decoration: BoxDecoration(
          color: active ? const Color(0xFF1B3538) : _card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: active
                ? _accent.withValues(alpha: .6)
                : Colors.white.withValues(alpha: .055),
          ),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: _importing
                ? null
                : () {
                    _success = _importError = null;
                    _offset.text = '0';
                    session.select(hit);
                  },
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Icon(
                          Icons.closed_caption_outlined,
                          color: _accent,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          hit.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            height: 1.4,
                          ),
                        ),
                      ),
                      const Icon(
                        Icons.chevron_right_rounded,
                        color: _muted,
                        size: 20,
                      ),
                    ],
                  ),
                  if (hit.release.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        hit.release,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: _muted,
                          fontSize: 11,
                          height: 1.5,
                        ),
                      ),
                    ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      if (hit.mediaType != 'Movie')
                        _tag(
                          info.label,
                          info.episode != null || info.pack ? _accent : _muted,
                        ),
                      if (info.videoSource.isNotEmpty) _tag(info.videoSource),
                      _tag(hit.source.label, _accent),
                      _tag(subtitleLanguageLabel(hit.language)),
                      if (hit.format.isNotEmpty) _tag(hit.format),
                      if (hit.hearingImpaired) _tag('含音效说明'),
                      if (hit.downloads > 0) _tag('${hit.downloads} 次下载'),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _previewPlaceholder() => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: _accent.withValues(alpha: .06),
              borderRadius: BorderRadius.circular(28),
            ),
            child: const Icon(
              Icons.subtitles_outlined,
              size: 48,
              color: _accent,
            ),
          ),
          const SizedBox(height: 22),
          const Text(
            '先读几句，再开始观看',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          const Text(
            '选择左侧结果，在这里预览字幕\n并一键设为主字幕或副字幕',
            textAlign: TextAlign.center,
            style: TextStyle(color: _muted, height: 1.7),
          ),
        ],
      ),
    ),
  );

  Widget _detail() {
    final hit = session.selected!;
    final doc = session.document;
    final docs = session.documents;
    final offset = int.tryParse(_offset.text.trim());
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            key: ValueKey('preview-${session.documentKey}-${doc?.name}'),
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
            itemCount: 1 + (doc?.cues.length ?? 0),
            itemBuilder: (_, i) {
              if (i > 0) {
                final cue = doc!.cues[i - 1];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 58,
                        child: Text(
                          _clock(
                            cue.startTime + Duration(milliseconds: offset ?? 0),
                          ),
                          style: const TextStyle(color: _accent, fontSize: 11),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          cue.text,
                          style: const TextStyle(height: 1.65, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _tag(hit.source.label, _accent),
                      _tag(subtitleLanguageLabel(hit.language)),
                      if (hit.mediaType != 'Movie')
                        _tag(hit.releaseInfo.label, _accent),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    hit.title,
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                      height: 1.4,
                    ),
                  ),
                  if (hit.release.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: SelectableText(
                        hit.release,
                        style: const TextStyle(
                          color: _muted,
                          fontSize: 12,
                          height: 1.5,
                        ),
                      ),
                    ),
                  if (hit.detailUri != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: DesktopButtonClickRegion(child: TextButton.icon(
                        onPressed: () => _openWebsite(hit.detailUri!),
                        icon: const Icon(Icons.open_in_new_rounded, size: 15),
                        label: const Text('查看这条字幕的详情页'),
                      )),
                    )
                  else
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Text(
                        '该来源未提供字幕发布页地址',
                        style: TextStyle(fontSize: 11, color: _muted),
                      ),
                    ),
                  if (session.loadingFiles)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  if (session.availableFiles.isNotEmpty)
                    _fileButton(
                      session.selectedFile!.name,
                      session.selectedFile!.availabilityLabel,
                      () async {
                        final entries = session.selectedFile!.archiveEntries;
                        if (entries.isNotEmpty) {
                          final index = await _choose(
                            '选择包内字幕（含语言与版本目录）',
                            entries,
                          );
                          if (index == null || !mounted) return;
                          final name = entries[index];
                          await session.preview();
                          if (!mounted) return;
                          final chosen = session.documents.indexWhere(
                            (d) => d.name == name,
                          );
                          if (chosen >= 0) {
                            session.documentIndex = chosen;
                            session.changed();
                          }
                          return;
                        }
                        final index = await _choose(
                          '选择字幕文件',
                          session.availableFiles.map((f) => f.name).toList(),
                        );
                        if (index != null && mounted) {
                          _success = _importError = null;
                          _offset.text = '0';
                          session.chooseFile(session.availableFiles[index]);
                        }
                      },
                    ),
                  if (session.detailError != null)
                    _notice(
                      session.detailError!,
                      Icons.error_outline,
                      Colors.orangeAccent,
                      action: DesktopButtonClickRegion(child: TextButton(
                        onPressed: session.availableFiles.isEmpty
                            ? () {
                                session.closeDetail();
                                session.select(hit);
                              }
                            : session.preview,
                        child: const Text('重试'),
                      )),
                    ),
                  if (widget.batchTargets.length > 1 &&
                      widget.onBatchImport != null &&
                      session.selectedFile != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: DesktopButtonClickRegion(child: OutlinedButton.icon(
                        key: const ValueKey('subtitle-search-batch'),
                        onPressed: session.downloading || _importing
                            ? null
                            : _batch,
                        icon: const Icon(
                          Icons.playlist_add_check_rounded,
                          size: 19,
                        ),
                        label: Text(
                          '批量匹配本文件夹（${widget.batchTargets.length} 个视频）',
                        ),
                      )),
                    ),
                  if (doc == null && session.selectedFile != null) ...[
                    const SizedBox(height: 14),
                    DesktopButtonClickRegion(child: FilledButton.icon(
                      onPressed: session.downloading
                          ? session.cancelDownload
                          : session.preview,
                      icon: Icon(
                        session.downloading
                            ? Icons.close_rounded
                            : Icons.visibility_outlined,
                      ),
                      label: Text(session.downloading ? '取消读取' : '读取并预览字幕'),
                    )),
                    if (session.downloading)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            LinearProgressIndicator(
                              value: session.downloadProgress == 0
                                  ? null
                                  : session.downloadProgress,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              session.downloadProgress >= 1
                                  ? '正在检查并解析字幕'
                                  : '正在下载 ${(session.downloadProgress * 100).round()}%',
                              style: const TextStyle(
                                fontSize: 12,
                                color: _muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        hit.source.requiresKey
                            ? '读取会使用来源的下载额度。已读取的字幕会暂存，返回后无需重复下载。'
                            : '无需登录，直接读取。字幕会暂存，返回后无需重复下载。',
                        style: TextStyle(
                          color: _muted,
                          fontSize: 11,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                  if (doc != null) ...[
                    const SizedBox(height: 12),
                    if (docs.length > 1)
                      _fileButton(
                        doc.name,
                        '字幕包内有 ${docs.length} 个字幕',
                        () async {
                          final index = await _choose(
                            '选择字幕包内的文件',
                            docs.map((d) => d.name).toList(),
                          );
                          if (index != null && mounted) {
                            _success = _importError = null;
                            session.documentIndex = index;
                            session.changed();
                          }
                        },
                      ),
                    const SizedBox(height: 10),
                    _panel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '${doc.cues.length} 条字幕 · 至 ${_clock(doc.duration)}',
                            style: const TextStyle(fontSize: 12, color: _muted),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final role
                                  in SubtitleSearchImportRole.values)
                                ChoiceChip(
                                  label: Text(switch (role) {
                                    SubtitleSearchImportRole.primary => '主字幕',
                                    SubtitleSearchImportRole.secondary => '副字幕',
                                    SubtitleSearchImportRole.saveOnly => '仅保存',
                                  }),
                                  selected: _role == role,
                                  showCheckmark: false,
                                  onSelected: _importing
                                      ? null
                                      : (_) => setState(() {
                                          _role = role;
                                          _success = null;
                                        }),
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            key: const ValueKey('subtitle-search-offset'),
                            controller: _offset,
                            enabled: !_importing,
                            keyboardType: const TextInputType.numberWithOptions(
                              signed: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: '时间偏移（毫秒）',
                              helperText: '正数延后，负数提前。例如：-500',
                              helperMaxLines: 2,
                            ),
                            onChanged: (v) => setState(() {
                              session.offset = v;
                              _success = null;
                            }),
                          ),
                          if (offset == null)
                            const Padding(
                              padding: EdgeInsets.only(top: 8),
                              child: Text(
                                '请输入整数毫秒',
                                style: TextStyle(color: Colors.orangeAccent),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      '字幕内容',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const Divider(height: 24, color: Colors.white10),
                  ],
                ],
              );
            },
          ),
        ),
        if (doc != null)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: const BoxDecoration(
              color: _surface,
              border: Border(top: BorderSide(color: Colors.white10)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_importError != null || _success != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      _importError ?? _success!,
                      style: TextStyle(
                        color: _importError == null
                            ? _accent
                            : Colors.orangeAccent,
                        fontSize: 12,
                      ),
                    ),
                  ),
                DesktopButtonClickRegion(child: FilledButton.icon(
                  key: const ValueKey('subtitle-search-import'),
                  onPressed: _importing || offset == null ? null : _import,
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 46)),
                  icon: _importing
                      ? const SizedBox(
                          width: 17,
                          height: 17,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check_rounded, size: 20),
                  label: Text(
                    _importing
                        ? '正在保存…'
                        : switch (_role) {
                            SubtitleSearchImportRole.primary => '设为主字幕',
                            SubtitleSearchImportRole.secondary => '设为副字幕',
                            SubtitleSearchImportRole.saveOnly => '保存到字幕库',
                          },
                  ),
                )),
              ],
            ),
          ),
      ],
    );
  }

  Widget _fileButton(String name, String description, VoidCallback onTap) =>
      Material(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: _importing ? null : onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.all(13),
            child: Row(
              children: [
                const Icon(
                  Icons.description_outlined,
                  color: _accent,
                  size: 21,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        description,
                        style: const TextStyle(color: _muted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.unfold_more_rounded, color: _muted, size: 20),
              ],
            ),
          ),
        ),
      );

  Future<int?> _choose(String title, List<String> names) async {
    var query = '';
    return _modal<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) {
          final indices = [
            for (var i = 0; i < names.length; i++)
              if (names[i].toLowerCase().contains(query.toLowerCase())) i,
          ];
          return DialogKeyboardViewport(
            child: AlertDialog(
              backgroundColor: _surface,
              title: Text(title),
              insetPadding: const EdgeInsets.all(16),
              content: SizedBox(
                width: 520,
                height: math.max(100, MediaQuery.sizeOf(ctx).height * .55),
                child: Column(
                  children: [
                    TextField(
                      decoration: const InputDecoration(
                        hintText: '按文件名筛选',
                        prefixIcon: Icon(Icons.search),
                      ),
                      onChanged: (v) => update(() => query = v),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: indices.isEmpty
                          ? const Center(child: Text('没有匹配的文件'))
                          : ListView.builder(
                              itemCount: indices.length,
                              itemBuilder: (_, i) => ListTile(
                                title: Text(
                                  names[indices[i]],
                                  style: const TextStyle(fontSize: 12),
                                ),
                                trailing: const Icon(
                                  Icons.chevron_right,
                                  size: 18,
                                ),
                                onTap: () => Navigator.pop(ctx, indices[i]),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
              actions: [
                DesktopButtonClickRegion(child: TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('返回'),
                )),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _connections() async {
    await _modal<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _surface,
        insetPadding: const EdgeInsets.all(16),
        title: const Text('字幕来源'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'SubHD、Jimaku 与迅雷字幕直接可用，无需填写密钥。建议先选择作品和季度，再查找对应字幕。其他来源可按需添加。',
                  style: TextStyle(color: _muted, fontSize: 12, height: 1.6),
                ),
                const SizedBox(height: 16),
                for (final source in SubtitleSearchSource.values)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(source.label),
                    subtitle: Text(
                      source.description,
                      style: const TextStyle(fontSize: 11, color: _muted),
                    ),
                    trailing: const Icon(Icons.chevron_right, size: 20),
                    leading: Icon(
                      workspace.configured(source)
                          ? Icons.check_circle_rounded
                          : Icons.add_circle_outline,
                      color: workspace.configured(source) ? _accent : _muted,
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      if (source.requiresKey) {
                        _connect(source);
                      } else {
                        _openWebsite(source.website);
                      }
                    },
                  ),
              ],
            ),
          ),
        ),
        actions: [
          DesktopButtonClickRegion(child: TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('完成'),
          )),
        ],
      ),
    );
  }

  Future<void> _connect(SubtitleSearchSource source) async {
    final current =
        workspace.credentials[source] ?? const SubtitleSearchCredentials();
    final key = TextEditingController(text: current.apiKey);
    final username = TextEditingController(text: current.username);
    final password = TextEditingController(text: current.password);
    var visible = false, saving = false;
    String? error = workspace.connectionErrors[source];
    await _modal<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) {
          Future<void> save() async {
            if (saving) return;
            if (RegExp(r'[\r\n]').hasMatch(key.text.trim())) {
              update(() => error = '密钥不能包含换行');
              return;
            }
            update(() {
              saving = true;
              error = null;
            });
            final persisted = await workspace.saveCredentials(
              source,
              SubtitleSearchCredentials(
                apiKey: key.text.trim(),
                username: username.text.trim(),
                password: password.text,
              ),
            );
            if (!ctx.mounted) return;
            if (!persisted) {
              update(() {
                saving = false;
                error = '系统安全存储不可用，连接已供本次运行使用，重启后需重新输入。';
              });
            } else {
              Navigator.pop(ctx);
            }
          }

          return PopScope(
            canPop: !saving,
            child: DialogKeyboardViewport(
              child: AlertDialog(
                backgroundColor: _surface,
                insetPadding: const EdgeInsets.all(16),
                title: Text('连接 ${source.label}'),
                content: SizedBox(
                  width: 480,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          source.description,
                          style: const TextStyle(color: _muted, fontSize: 12),
                        ),
                        const SizedBox(height: 10),
                        DesktopButtonClickRegion(child: OutlinedButton.icon(
                          onPressed: saving
                              ? null
                              : () => _openWebsite(source.accountUrl),
                          icon: const Icon(Icons.open_in_new, size: 16),
                          label: const Text('前往来源网站获取密钥'),
                        )),
                        const SizedBox(height: 14),
                        TextField(
                          controller: key,
                          enabled: !saving,
                          obscureText: !visible,
                          enableSuggestions: false,
                          autocorrect: false,
                          decoration: InputDecoration(
                            labelText: source == SubtitleSearchSource.assrt
                                ? '访问密钥（Token）'
                                : '访问密钥（API Key）',
                            helperText: '清空并保存可断开连接',
                            helperMaxLines: 2,
                            suffixIcon: DesktopButtonClickRegion(child: IconButton(
                              tooltip: visible ? '隐藏密钥' : '显示密钥',
                              onPressed: () => update(() => visible = !visible),
                              icon: Icon(
                                visible
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                              ),
                            )),
                          ),
                        ),
                        if (source == SubtitleSearchSource.opensubtitles) ...[
                          const SizedBox(height: 16),
                          const Text(
                            '可选：登录自己的账户，使用账户下载额度',
                            style: TextStyle(color: _muted, fontSize: 11),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: username,
                            enabled: !saving,
                            decoration: const InputDecoration(
                              labelText: '用户名（可留空）',
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: password,
                            enabled: !saving,
                            obscureText: true,
                            enableSuggestions: false,
                            autocorrect: false,
                            decoration: const InputDecoration(
                              labelText: '密码（可留空）',
                            ),
                          ),
                        ],
                        if (source == SubtitleSearchSource.subdl)
                          const Padding(
                            padding: EdgeInsets.only(top: 12),
                            child: Text(
                              '请使用自己的 SubDL 密钥，搜索和下载计入你的账户额度。',
                              style: TextStyle(color: _muted, fontSize: 11),
                            ),
                          ),
                        if (error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(
                              error!,
                              style: const TextStyle(
                                color: Colors.orangeAccent,
                                fontSize: 12,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                actions: [
                  DesktopButtonClickRegion(child: TextButton(
                    onPressed: saving ? null : () => Navigator.pop(ctx),
                    child: const Text('返回'),
                  )),
                  DesktopButtonClickRegion(child: FilledButton(
                    onPressed: saving ? null : save,
                    child: Text(saving ? '保存中…' : '保存连接'),
                  )),
                ],
              ),
            ),
          );
        },
      ),
    );
    // The route's reverse transition still owns these controllers for a frame.
    await Future<void>.delayed(const Duration(milliseconds: 240));
    key.dispose();
    username.dispose();
    password.dispose();
  }

  Widget _panel({required Widget child}) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: _card,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Colors.white.withValues(alpha: .055)),
    ),
    child: child,
  );
  Widget _tag(String text, [Color color = _muted]) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(7),
    ),
    child: Text(
      text,
      style: TextStyle(color: color, fontSize: 10, height: 1.3),
    ),
  );
  Widget _notice(String text, IconData icon, Color color, {Widget? action}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: color.withValues(alpha: .08),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 18, color: color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      text,
                      style: TextStyle(color: color, height: 1.5, fontSize: 12),
                    ),
                  ),
                ],
              ),
              if (action != null)
                Align(alignment: Alignment.centerRight, child: action),
            ],
          ),
        ),
      );
  String _clock(Duration time) {
    final seconds = math.max(0, time.inSeconds);
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}
