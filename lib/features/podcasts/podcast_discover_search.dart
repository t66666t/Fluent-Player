part of 'podcast_pages.dart';

extension _PodcastDiscoverySurface on _PodcastDiscoverPageState {
  Widget _discoveryNavigation() => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 960),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(20, 8, 20, 0),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: AppTokens.bgCard,
          borderRadius: BorderRadius.circular(16),
        ),
        child: LayoutBuilder(
          builder: (context, bounds) {
            final compact = bounds.maxWidth < 500;
            return Row(
              children: [
                for (final (index, label, icon) in const [
                  (0, '在线搜索', Icons.search_rounded),
                  (1, '链接导入', Icons.link_rounded),
                  (2, 'OPML / 备份', Icons.inventory_2_outlined),
                ])
                  Expanded(
                    child: Semantics(
                      selected: _tab == index,
                      child: DesktopButtonClickRegion(
                        child: TextButton(
                          key: ValueKey('podcast-discovery-tab-$index'),
                          onPressed: () => _focusInput(index),
                          style: TextButton.styleFrom(
                            foregroundColor: _tab == index
                                ? AppTokens.accent
                                : AppTokens.text2,
                            backgroundColor: _tab == index
                                ? AppTokens.accent.withValues(alpha: .12)
                                : Colors.transparent,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 12,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: compact
                              ? Text(
                                  label,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(fontSize: 12),
                                )
                              : Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(icon, size: 18),
                                    const SizedBox(width: 8),
                                    Flexible(
                                      child: Text(
                                        label,
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    ),
  );

  Widget _discoverySurface(PodcastRuntime runtime) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 960),
      child: LayoutBuilder(
        builder: (context, bounds) {
          if (_tab != 0) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: _importPanel(runtime),
            );
          }
          return Column(
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: bounds.maxHeight * .65),
                child: SingleChildScrollView(
                  primary: false,
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                  child: TextFieldTapRegion(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _discoveryInput(),
                        if (_queryFocus.hasFocus &&
                            runtime.store.searchHistory.isNotEmpty)
                          _searchHistory(runtime, bounds.maxHeight),
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: _searchFilters(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Expanded(child: _discoveryResults()),
            ],
          );
        },
      ),
    ),
  );

  Widget _discoveryInput() => Row(
    children: [
      Expanded(
        child: TextField(
          key: const ValueKey('podcast-search-input'),
          controller: _query,
          focusNode: _queryFocus,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _search(),
          onChanged: _queryChanged,
          onTapOutside: (_) => _queryFocus.unfocus(),
          style: PodcastType.label.copyWith(
            color: AppTokens.text1,
            fontSize: 14,
          ),
          decoration: InputDecoration(
            hintText: '搜索播客、作者',
            hintStyle: const TextStyle(color: AppTokens.text2, fontSize: 14),
            prefixIcon: const Icon(
              Icons.search_rounded,
              color: AppTokens.text2,
              size: 21,
            ),
            suffixIcon: _query.text.isEmpty
                ? null
                : DesktopButtonClickRegion(
                    child: IconButton(
                      tooltip: '清除搜索内容',
                      onPressed: _clearQuery,
                      icon: const Icon(
                        Icons.close_rounded,
                        color: AppTokens.text2,
                        size: 18,
                      ),
                    ),
                  ),
            filled: true,
            fillColor: AppTokens.bgCard,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 13,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(
                color: AppTokens.accent.withValues(alpha: .65),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(width: 4),
      DesktopButtonClickRegion(
        child: TextButton(
          key: const ValueKey('podcast-search-submit'),
          onPressed: _query.text.trim().isEmpty || _busy
              ? null
              : () => _search(),
          style: TextButton.styleFrom(
            foregroundColor: AppTokens.text1,
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.symmetric(horizontal: 10),
          ),
          child: const Text('搜索'),
        ),
      ),
    ],
  );

  Widget _searchHistory(PodcastRuntime runtime, double height) => Container(
    key: const ValueKey('podcast-search-history'),
    width: double.infinity,
    margin: const EdgeInsets.only(top: 8),
    constraints: BoxConstraints(maxHeight: min(220, height * .36)),
    decoration: BoxDecoration(
      color: AppTokens.bgOverlay,
      borderRadius: BorderRadius.circular(12),
    ),
    child: SingleChildScrollView(
      primary: false,
      padding: const EdgeInsets.fromLTRB(14, 2, 8, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '搜索历史',
                  style: TextStyle(color: AppTokens.text2, fontSize: 12),
                ),
              ),
              DesktopButtonClickRegion(
                child: TextButton(
                  onPressed: () =>
                      _updateDiscovery(runtime.store.clearSearchHistory),
                  child: const Text(
                    '清空历史',
                    style: TextStyle(color: AppTokens.text2, fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final value in runtime.store.searchHistory)
                InputChip(
                  label: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  labelStyle: PodcastType.label.copyWith(
                    color: AppTokens.text1,
                    fontSize: 12,
                  ),
                  backgroundColor: AppTokens.bgCard,
                  side: BorderSide.none,
                  onPressed: () => _searchFor(value),
                  onDeleted: () =>
                      _updateDiscovery(() => runtime.store.removeSearch(value)),
                  deleteButtonTooltipMessage: '删除搜索记录：$value',
                  deleteIcon: const Icon(
                    Icons.close_rounded,
                    size: 14,
                    color: AppTokens.text2,
                  ),
                ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _searchFilters() => Wrap(
    spacing: 12,
    runSpacing: 8,
    children: [
      _searchFilter(
        label: '搜索地区',
        value: _region,
        options: const {
          'CN': '中国大陆',
          'HK': '中国香港',
          'TW': '中国台湾',
          'US': '美国',
          'GB': '英国',
        },
        onChanged: (value) {
          _updateDiscovery(() => _region = value);
          if (_query.text.trim().isNotEmpty) _search(remember: false);
        },
      ),
      _searchFilter(
        label: '搜索目录',
        value: _provider,
        options: const {'apple': 'Apple Podcasts', 'index': 'Podcast Index'},
        onChanged: (value) {
          _updateDiscovery(() => _provider = value);
          if (_query.text.trim().isNotEmpty) _search(remember: false);
        },
      ),
    ],
  );

  Widget _searchFilter({
    required String label,
    required String value,
    required Map<String, String> options,
    required ValueChanged<String> onChanged,
  }) => Semantics(
    label: label,
    child: DropdownButtonHideUnderline(
      child: CapsuleDropdownButton<String>(
        value: value,
        isDense: true,
        dropdownColor: AppTokens.bgOverlay,
        style: PodcastType.label.copyWith(color: AppTokens.text2, fontSize: 12),
        icon: const Icon(
          Icons.expand_more_rounded,
          size: 18,
          color: AppTokens.text2,
        ),
        items: [
          for (final option in options.entries)
            DropdownMenuItem(value: option.key, child: Text(option.value)),
        ],
        onChanged: (value) {
          if (value != null) onChanged(value);
        },
      ),
    ),
  );

  Widget _discoveryResults() {
    if (_busy) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: PodcastLoadingNotice(
              message: _previewInput == null
                  ? '正在搜索播客…'
                  : _previewNotice ?? '正在加载播客…',
            ),
          ),
          if (_previewInput != null) ...[
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: _returnToResults,
                child: const Text('取消加载'),
              ),
            ),
          ],
          const Expanded(child: PodcastSkeleton(rows: 4)),
        ],
      );
    }
    if (_status != null) return _resultMessage(_status!, retry: true);
    if (_searchedQuery == null) return _resultMessage('搜索喜欢的播客');
    if (_results.isEmpty) return _resultMessage('没有找到相关播客，试试其他关键词');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
          child: Semantics(
            liveRegion: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '搜索结果 · ${_results.length}',
                  style: const TextStyle(color: AppTokens.text2, fontSize: 12),
                ),
                Text(
                  '来源：${_provider == 'index' ? 'Podcast Index' : 'Apple Podcasts / iTunes Search API'}',
                  style: const TextStyle(color: AppTokens.text2, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: ListView.separated(
            key: const ValueKey('podcast-search-results'),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
            itemCount: _results.length,
            separatorBuilder: (_, _) => const Divider(
              height: 1,
              indent: 82,
              endIndent: 12,
              color: AppTokens.lineSubtle,
            ),
            itemBuilder: (_, index) => _searchResult(_results[index]),
          ),
        ),
      ],
    );
  }

  Widget _searchResult(PodcastSearchResult result) => Material(
    key: ValueKey('podcast-search-result-${result.feedUrl}'),
    color: Colors.transparent,
    child: InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () {
        unawaited(AppHaptics.cardTap(SettingsService()));
        _queryFocus.unfocus();
        _resolve(result.feedUrl);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
        child: Row(
          children: [
            PodcastArtwork(
              url: result.imageUrl,
              ownerKind: 'search',
              ownerId: result.feedUrl,
              size: 56,
              radius: 9,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    result.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: PodcastType.title.copyWith(
                      color: AppTokens.text1,
                      fontSize: 15,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    result.author.isEmpty ? '播客频道' : result.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTokens.text2,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: AppTokens.text2,
            ),
          ],
        ),
      ),
    ),
  );

  Widget _resultMessage(String message, {bool retry = false}) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppTokens.text2,
              fontSize: 13,
              height: 1.7,
            ),
          ),
          if (retry && _previewInput != null) ...[
            DesktopButtonClickRegion(
              child: TextButton(
                key: const ValueKey('podcast-preview-retry'),
                onPressed: () {
                  final input = _previewInput;
                  if (input != null) _resolve(input);
                },
                child: const Text('重新加载'),
              ),
            ),
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: _returnToResults,
                child: const Text('返回搜索结果'),
              ),
            ),
          ] else if (retry)
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: () => _search(),
                child: const Text('重新搜索'),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _importPanel(PodcastRuntime runtime) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (_tab == 1) ...[
        const Text(
          '使用发布者 RSS、正规目录返回的 RSS，或网页明确声明的 RSS。离线收听须遵守来源的订阅和许可条件，RSS 不代表允许转载或分享音频。',
          style: TextStyle(color: AppTokens.text2, fontSize: 12, height: 1.6),
        ),
        const SizedBox(height: 12),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _url,
          builder: (context, value, _) => TextField(
            controller: _url,
            focusNode: _urlFocus,
            minLines: 1,
            maxLines: 3,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.go,
            style: PodcastType.label.copyWith(color: AppTokens.text1),
            decoration: InputDecoration(
              hintText: '粘贴 RSS、频道或节目分享链接',
              hintStyle: const TextStyle(color: AppTokens.text2, fontSize: 13),
              border: const OutlineInputBorder(),
              suffixIcon: value.text.isEmpty
                  ? null
                  : DesktopButtonClickRegion(
                      child: IconButton(
                        tooltip: '清除链接',
                        onPressed: () {
                          _url.clear();
                          _urlFocus.requestFocus();
                        },
                        icon: const Icon(Icons.close_rounded, size: 18),
                      ),
                    ),
            ),
            onSubmitted: _busy ? null : _resolve,
          ),
        ),
        const SizedBox(height: 16),
        DesktopButtonClickRegion(
          child: FilledButton.tonalIcon(
            onPressed: _busy ? null : () => _resolve(_url.text),
            icon: const Icon(Icons.link_rounded, size: 18),
            label: const Text('解析并预览'),
          ),
        ),
      ] else ...[
        const Text(
          '导入 OPML 订阅列表，或恢复 Fluent Player 播客备份。',
          style: TextStyle(color: AppTokens.text2, height: 1.7),
        ),
        const SizedBox(height: 16),
        DesktopButtonClickRegion(
          child: FilledButton.tonalIcon(
            onPressed: _busy ? null : _importOpml,
            icon: const Icon(Icons.file_open_outlined, size: 18),
            label: const Text('选择订阅列表或备份'),
          ),
        ),
      ],
      const SizedBox(height: 16),
      _importLocation(runtime),
      if (_busy && _status == null) ...[
        const SizedBox(height: 16),
        PodcastLoadingNotice(
          message: _previewNotice ?? (_tab == 1 ? '正在解析播客链接…' : '正在导入播客…'),
        ),
        if (_previewInput != null)
          DesktopButtonClickRegion(
            child: TextButton(
              onPressed: _returnToResults,
              child: const Text('取消加载'),
            ),
          ),
      ],
      if (_status != null) ...[
        const SizedBox(height: 16),
        SelectableText(
          _status!,
          style: const TextStyle(color: AppTokens.text2, height: 1.7),
        ),
        if (_previewInput != null)
          DesktopButtonClickRegion(
            child: TextButton(
              key: const ValueKey('podcast-preview-retry'),
              onPressed: () {
                final input = _previewInput;
                if (input != null) _resolve(input);
              },
              child: const Text('重新加载'),
            ),
          ),
      ],
    ],
  );

  Widget _importLocation(PodcastRuntime runtime) => DesktopButtonClickRegion(
    child: TextButton.icon(
      onPressed: runtime.library == null
          ? null
          : () async {
              final result = await showLibraryFolderPicker(
                context,
                library: runtime.library!,
                initialFolderId: _folderId,
                offerSetAsDefault: false,
                confirmLabel: '放在这里',
              );
              if (result != null && mounted) {
                _updateDiscovery(() {
                  _folderId = result.folderId;
                  _folderExplicit = true;
                });
              }
            },
      icon: const Icon(Icons.folder_outlined, size: 17),
      label: Text(
        _folderExplicit
            ? '本次位置：${_folderId == null ? '媒体库根目录' : runtime.library?.getCollection(_folderId!)?.name ?? '媒体库'}'
            : '导入位置：跟随统一设置',
        style: const TextStyle(fontSize: 12),
      ),
    ),
  );
}
