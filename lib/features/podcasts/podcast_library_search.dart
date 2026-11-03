part of 'podcast_pages.dart';

/// Searches the subscribed catalog without issuing online discovery requests.
class PodcastLibrarySearchPage extends StatefulWidget {
  const PodcastLibrarySearchPage({super.key, required this.initialQuery});
  final String initialQuery;

  @override
  State<PodcastLibrarySearchPage> createState() =>
      _PodcastLibrarySearchPageState();
}

class _PodcastLibrarySearchPageState extends State<PodcastLibrarySearchPage> {
  late final _query = TextEditingController(text: widget.initialQuery);
  final _focus = FocusNode();
  final _entryWork = RouteTransitionWork();
  final _scroll = PlaybackScrollController();
  final _debounce = PodcastSearchDebounce();
  List<PodcastChannel> _channels = const [];
  List<PodcastEpisode> _episodes = const [];
  bool _scheduled = false, _searched = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _entryWork.bind(ModalRoute.of(context));
  }

  @override
  void dispose() {
    _debounce.dispose();
    _entryWork.dispose();
    _query.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _search() {
    final runtime = PodcastRuntime.instance;
    if (!runtime.ready) return;
    _debounce.dispose();
    final needle = _query.text.trim().toLowerCase();
    final channels = runtime.controller.channels;
    final channelTitles = <String, String>{
      for (final channel in channels)
        channel.id:
            '${runtime.channelTitle(channel)} ${channel.title} ${channel.author}'
                .toLowerCase(),
    };
    // Resolve once per query, rather than rescanning the catalog on every
    // playback progress tick from PodcastGate.
    final episodes =
        <PodcastEpisode>[
          if (needle.isNotEmpty)
            for (final channel in channels)
              for (final id in runtime.store.queryEpisodeIds(
                channelId: channel.id,
                query: channelTitles[channel.id]!.contains(needle)
                    ? ''
                    : needle,
              ))
                ?runtime.store.episode(id),
        ]..sort((a, b) {
          final date = b.publishedMs.compareTo(a.publishedMs);
          return date != 0 ? date : a.id.compareTo(b.id);
        });
    if (!mounted) return;
    setState(() {
      _searched = true;
      _channels = needle.isEmpty
          ? []
          : channels
                .where((c) => channelTitles[c.id]!.contains(needle))
                .toList();
      _episodes = episodes;
    });
  }

  void _submit() {
    _focus.unfocus();
    _entryWork.cancel('search');
    _search();
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Future<void> _openChannel(PodcastChannel channel) async {
    _focus.unfocus();
    await Navigator.of(context).push(
      AppMaterialPageRoute<void>(
        builder: (_) => PodcastChannelPage(channelId: channel.id),
      ),
    );
    if (mounted) _search();
  }

  Widget _section(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
    child: Text(
      text,
      style: const TextStyle(color: AppTokens.text2, fontSize: 13),
    ),
  );

  Widget _results(PodcastRuntime runtime) {
    if (!_scheduled) {
      _scheduled = true;
      _entryWork.schedule('search', _search);
    }
    if (!_searched) return const Center(child: CircularProgressIndicator());
    if (_channels.isEmpty && _episodes.isEmpty) {
      return PodcastEmpty(
        title: _query.text.trim().isEmpty ? '搜索已订阅的播客' : '没有找到匹配的频道或节目',
        message: '可以搜索频道名称、作者或节目名称。',
      );
    }
    return CustomScrollView(
      key: const ValueKey('podcast-library-search-results'),
      controller: _scroll,
      slivers: [
        if (_channels.isNotEmpty) ...[
          SliverToBoxAdapter(child: _section('频道 · ${_channels.length}')),
          SliverList.builder(
            itemCount: _channels.length,
            itemBuilder: (context, index) {
              final channel = _channels[index];
              return ListTile(
                leading: PodcastArtwork(
                  url: channel.imageUrl,
                  ownerKind: 'channel',
                  ownerId: channel.id,
                  size: 48,
                ),
                title: Text(
                  runtime.channelTitle(channel),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  channel.author,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right_rounded, size: 18),
                onTap: () => _openChannel(channel),
              );
            },
          ),
        ],
        if (_episodes.isNotEmpty) ...[
          SliverToBoxAdapter(child: _section('节目 · ${_episodes.length}')),
          SliverList.builder(
            itemCount: _episodes.length,
            itemBuilder: (_, index) => PodcastEpisodeTile(
              key: ValueKey(_episodes[index].id),
              episode: _episodes[index],
              queue: _episodes,
              onError: (message) => AppToast.show(message),
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => PodcastPageShortcuts(
    bindings: {
      LogicalKeyboardKey.keyS: _focus.requestFocus,
      LogicalKeyboardKey.keyR: _submit,
    },
    child: PodcastTypography(
      child: Scaffold(
        backgroundColor: AppTokens.bgBase,
        appBar: AppBar(title: const Text('搜索已订阅播客')),
        body: MediaLibrarySafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                    child: TextField(
                      key: const ValueKey('podcast-library-search-input'),
                      controller: _query,
                      focusNode: _focus,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _submit(),
                      onChanged: (value) =>
                          _debounce.submit(value, (_) => _search()),
                      onTapOutside: (_) => _focus.unfocus(),
                      decoration: InputDecoration(
                        hintText: '搜索频道、作者或节目',
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: DesktopButtonClickRegion(
                          child: IconButton(
                            tooltip: '搜索',
                            onPressed: _submit,
                            icon: const Icon(Icons.arrow_forward_rounded),
                          ),
                        ),
                        filled: true,
                        fillColor: AppTokens.bgCard,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  Expanded(child: PodcastGate(builder: _results)),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
