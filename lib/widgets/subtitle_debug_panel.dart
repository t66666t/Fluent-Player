import 'package:flutter/material.dart';
import '../models/subtitle_debug_preset.dart';
import '../services/subtitle_debug_session.dart';
import 'subtitle_preset_chrome.dart';
import 'subtitle_preset_settings_dialog.dart';

class SubtitleDebugPanel extends StatefulWidget {
  final bool isGhostMode;
  const SubtitleDebugPanel({super.key, this.isGhostMode = false});
  @override
  State<SubtitleDebugPanel> createState() => _SubtitleDebugPanelState();
}

class _SubtitleDebugPanelState extends State<SubtitleDebugPanel> {
  final _session = SubtitleDebugSession.instance;
  late final _scroll = ScrollController(
    initialScrollOffset: _session.browserOffset,
  );
  late final _search = TextEditingController(text: _session.browserQuery);
  String? _editing;
  bool _filters = false;
  bool _categoriesOpen = false;
  static const _categoryTapGroup = Object();
  @override
  void initState() {
    super.initState();
    _scroll.addListener(_remember);
  }

  void _remember() {
    // Keep the catalog offset while the tuning page is on top; offstage
    // layout can clamp the list and would otherwise lose the browse position.
    if (_editing != null || !_scroll.hasClients) return;
    _session.browserOffset = _scroll.offset;
  }

  void _edit(String id) {
    if (_scroll.hasClients) _session.browserOffset = _scroll.offset;
    _session.select(_session.resolved(id));
    setState(() => _editing = id);
  }

  void _leaveTuning() {
    setState(() => _editing = null);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(
        _session.browserOffset.clamp(0.0, _scroll.position.maxScrollExtent),
      );
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  void _filterChanged() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() {});
  }

  List<String> get _categories => [
    '全部',
    ...subtitleDebugPresets.map((p) => p.category).toSet(),
  ];

  void _toggleCategories() {
    setState(() {
      _categoriesOpen = !_categoriesOpen;
      if (_categoriesOpen) _filters = false;
    });
  }

  void _toggleSearch() {
    setState(() {
      _filters = !_filters;
      if (_filters) _categoriesOpen = false;
    });
  }

  void _selectCategory(String category) {
    _session.browserCategory = category;
    _filterChanged();
  }

  void _locate(double extent, int columns) {
    _session.browserCategory = '全部';
    _session.browserQuery = '';
    _search.clear();
    _categoriesOpen = false;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final index = subtitleDebugPresets.indexWhere(
        (p) => p.id == _session.preset?.id,
      );
      _scroll.jumpTo(
        ((index ~/ columns) * (extent + 3)).clamp(
          0.0,
          _scroll.position.maxScrollExtent,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _session,
    builder: (context, _) {
      if (!_session.enabled) return const SizedBox.shrink();
      final filtered = subtitleDebugPresets
          .where(
            (p) =>
                (_session.browserCategory == '全部' ||
                    p.category == _session.browserCategory) &&
                '${p.name} ${p.fontSummary}'.toLowerCase().contains(
                  _session.browserQuery.toLowerCase(),
                ),
          )
          .toList();
      return LayoutBuilder(
        builder: (context, constraints) {
          final height = constraints.hasBoundedHeight
              ? constraints.maxHeight
              : MediaQuery.sizeOf(context).height;
          final chrome = SubtitlePresetChrome.of(constraints);
          final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
          final extent = chrome.cardExtent * scale.clamp(1, 3);
          final columns = chrome.columns;
          return SizedBox(
            height: height,
            child: Theme(
              data: ThemeData(
                brightness: Brightness.dark,
                fontFamily: 'Noto Sans SC',
              ),
              child: Material(
                color: const Color(0xFF17272D),
                child: IndexedStack(
                  index: _editing == null ? 0 : 1,
                  children: [
                    Column(
                      children: [
                        Padding(
                          padding: EdgeInsets.fromLTRB(chrome.pad, 0, 2, 0),
                          child: SizedBox(
                            height: chrome.rowHeight,
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '当前：${_session.preset?.name ?? "原样式"}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Colors.tealAccent,
                                      fontSize: chrome.bodySize,
                                      height: 1.1,
                                    ),
                                  ),
                                ),
                                TapRegion(
                                  groupId: _categoryTapGroup,
                                  child: SubtitlePresetIconButton(
                                    tooltip: _session.browserCategory == '全部'
                                        ? '选择分类'
                                        : '分类：${_session.browserCategory}',
                                    onPressed: _toggleCategories,
                                    icon: _categoriesOpen
                                        ? Icons.category
                                        : Icons.category_outlined,
                                    size: chrome.iconButton,
                                    iconSize: chrome.iconSize,
                                    color:
                                        _categoriesOpen ||
                                            _session.browserCategory != '全部'
                                        ? Colors.tealAccent
                                        : Colors.white70,
                                  ),
                                ),
                                SubtitlePresetIconButton(
                                  tooltip: '定位当前样式',
                                  onPressed: _session.preset == null
                                      ? null
                                      : () => _locate(extent, columns),
                                  icon: Icons.my_location,
                                  size: chrome.iconButton,
                                  iconSize: chrome.iconSize,
                                ),
                                SubtitlePresetIconButton(
                                  tooltip: '搜索',
                                  onPressed: _toggleSearch,
                                  icon: Icons.search,
                                  size: chrome.iconButton,
                                  iconSize: chrome.iconSize,
                                  color: _filters
                                      ? Colors.tealAccent
                                      : Colors.white70,
                                ),
                              ],
                            ),
                          ),
                        ),
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            chrome.pad,
                            0,
                            chrome.pad,
                            2,
                          ),
                          child: SizedBox(
                            height: chrome.rowHeight,
                            child: Row(
                              children: [
                                Expanded(
                                  child: SubtitlePresetTextAction(
                                    label: '使用原样式',
                                    onPressed: _session.useOriginal,
                                    fontSize: chrome.actionSize,
                                    height: chrome.rowHeight,
                                  ),
                                ),
                                if (_session.preset != null)
                                  Expanded(
                                    child: SubtitlePresetTextAction(
                                      label: '微调当前预设',
                                      icon: Icons.tune,
                                      onPressed: () =>
                                          _edit(_session.preset!.id),
                                      fontSize: chrome.actionSize,
                                      height: chrome.rowHeight,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        if (_categoriesOpen)
                          TapRegion(
                            groupId: _categoryTapGroup,
                            onTapOutside: (_) {
                              if (_categoriesOpen) {
                                setState(() => _categoriesOpen = false);
                              }
                            },
                            child: _SubtitlePresetCategoryMenu(
                              chrome: chrome,
                              categories: _categories,
                              selected: _session.browserCategory,
                              onSelected: _selectCategory,
                              onClose: () =>
                                  setState(() => _categoriesOpen = false),
                            ),
                          ),
                        if (_filters)
                          Padding(
                            padding: EdgeInsets.fromLTRB(
                              chrome.pad,
                              0,
                              chrome.pad,
                              4,
                            ),
                            child: TextField(
                              controller: _search,
                              style: TextStyle(fontSize: chrome.bodySize),
                              decoration: InputDecoration(
                                isDense: true,
                                hintText: '昵称 / 字体',
                                hintStyle: TextStyle(
                                  fontSize: chrome.captionSize,
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 6,
                                ),
                              ),
                              onChanged: (v) {
                                _session.browserQuery = v;
                                _filterChanged();
                              },
                            ),
                          ),
                        if (_session.saveError != null)
                          Text(
                            _session.saveError!,
                            style: const TextStyle(
                              color: Colors.orangeAccent,
                              fontSize: 11,
                            ),
                          ),
                        Expanded(
                          child: Scrollbar(
                            controller: _scroll,
                            thumbVisibility: true,
                            child: CustomScrollView(
                              key: const ValueKey(
                                'subtitle-preset-full-height-scroll',
                              ),
                              controller: _scroll,
                              slivers: [
                                SliverPadding(
                                  padding: const EdgeInsets.all(3),
                                  sliver: SliverGrid(
                                    gridDelegate:
                                        SliverGridDelegateWithFixedCrossAxisCount(
                                          crossAxisCount: columns,
                                          mainAxisExtent: extent,
                                          mainAxisSpacing: 3,
                                          crossAxisSpacing: 3,
                                        ),
                                    delegate: SliverChildBuilderDelegate((
                                      context,
                                      index,
                                    ) {
                                      final p = _session.resolved(
                                        filtered[index].id,
                                      );
                                      final selected =
                                          _session.preset?.id == p.id;
                                      return Material(
                                        key: ValueKey('preset-card-${p.id}'),
                                        color: selected
                                            ? const Color(0xFF245349)
                                            : const Color(0xFF202C30),
                                        borderRadius: BorderRadius.circular(6),
                                        child: InkWell(
                                          onTap: () => _session.select(p),
                                          child: Padding(
                                            padding: EdgeInsets.fromLTRB(
                                              chrome.pad,
                                              3,
                                              2,
                                              3,
                                            ),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.stretch,
                                              children: [
                                                Row(
                                                  children: [
                                                    Expanded(
                                                      child: FittedBox(
                                                        fit: BoxFit.scaleDown,
                                                        alignment: Alignment
                                                            .centerLeft,
                                                        child: Text(
                                                          '${selected ? "✓ " : ""}${p.name}',
                                                          maxLines: 1,
                                                          style: TextStyle(
                                                            fontSize:
                                                                chrome.bodySize,
                                                            fontWeight:
                                                                FontWeight.w600,
                                                            height: 1.1,
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                    SubtitlePresetIconButton(
                                                      tooltip: '微调${p.name}',
                                                      onPressed: () =>
                                                          _edit(p.id),
                                                      icon: Icons.tune,
                                                      size: chrome.iconButton,
                                                      iconSize: chrome.iconSize,
                                                    ),
                                                  ],
                                                ),
                                                Text(
                                                  p.primaryFont ==
                                                              'Noto Serif CJK SC' &&
                                                          _session
                                                                  .resolvedForDisplay(
                                                                    p.id,
                                                                  )
                                                                  .primaryFont ==
                                                              'Noto Sans SC'
                                                      ? '思源宋体需下载 · 当前使用思源黑体'
                                                      : p.fontSummary,
                                                  maxLines: chrome.isPhone
                                                      ? 1
                                                      : 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize:
                                                        chrome.captionSize,
                                                    height: 1.2,
                                                    color: Colors.white70,
                                                  ),
                                                ),
                                                const Spacer(),
                                                FittedBox(
                                                  fit: BoxFit.scaleDown,
                                                  alignment:
                                                      Alignment.centerLeft,
                                                  child: Text(
                                                    '风起时，我们再次相遇。',
                                                    maxLines: 1,
                                                    style: TextStyle(
                                                      fontFamily: _session
                                                          .resolvedForDisplay(
                                                            p.id,
                                                          )
                                                          .primaryFont,
                                                      fontWeight:
                                                          FontWeight.values[p
                                                                      .primaryWeight ~/
                                                                  100 -
                                                              1],
                                                      fontSize: chrome.isPhone
                                                          ? 13
                                                          : 15,
                                                      color: p.color,
                                                      height: 1.1,
                                                    ),
                                                  ),
                                                ),
                                                FittedBox(
                                                  fit: BoxFit.scaleDown,
                                                  alignment:
                                                      Alignment.centerLeft,
                                                  child: Text(
                                                    'When the wind rises, we meet again.',
                                                    maxLines: 1,
                                                    style: TextStyle(
                                                      fontFamily:
                                                          p.secondaryFont,
                                                      fontSize:
                                                          chrome.captionSize,
                                                      color: p.secondaryColor,
                                                      height: 1.1,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      );
                                    }, childCount: filtered.length),
                                  ),
                                ),
                                SliverToBoxAdapter(
                                  child: Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: Text(
                                      filtered.isEmpty
                                          ? '没有匹配的预设'
                                          : '${filtered.length} 套 · 点击即全局应用并自动保存',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Colors.white60,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_editing != null)
                      SubtitlePresetSettingsPanel(
                        key: ValueKey(_editing),
                        id: _editing!,
                        isGhostMode: widget.isGhostMode,
                        onBack: _leaveTuning,
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

/// Compact category chips that match the preset sidebar cards.
class _SubtitlePresetCategoryMenu extends StatelessWidget {
  const _SubtitlePresetCategoryMenu({
    required this.chrome,
    required this.categories,
    required this.selected,
    required this.onSelected,
    required this.onClose,
  });

  final SubtitlePresetChrome chrome;
  final List<String> categories;
  final String selected;
  final ValueChanged<String> onSelected;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(chrome.pad, 0, chrome.pad, 6),
      child: Material(
        key: const ValueKey('subtitle-preset-category-panel'),
        color: const Color(0xFF202C30),
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: EdgeInsets.fromLTRB(chrome.pad, 4, 2, chrome.pad),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: chrome.rowHeight,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '分类',
                        style: TextStyle(
                          color: Colors.tealAccent,
                          fontSize: chrome.bodySize,
                          fontWeight: FontWeight.w600,
                          height: 1.1,
                        ),
                      ),
                    ),
                    SubtitlePresetIconButton(
                      tooltip: '收起分类',
                      icon: Icons.expand_less,
                      size: chrome.iconButton,
                      iconSize: chrome.iconSize,
                      onPressed: onClose,
                    ),
                  ],
                ),
              ),
              Wrap(
                spacing: chrome.isPhone ? 4 : 6,
                runSpacing: chrome.isPhone ? 4 : 6,
                children: [
                  for (final category in categories)
                    _SubtitlePresetCategoryChip(
                      label: category,
                      selected: selected == category,
                      chrome: chrome,
                      onTap: () => onSelected(category),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SubtitlePresetCategoryChip extends StatelessWidget {
  const _SubtitlePresetCategoryChip({
    required this.label,
    required this.selected,
    required this.chrome,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final SubtitlePresetChrome chrome;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: ValueKey('subtitle-preset-category-$label'),
      color: selected ? const Color(0xFF245349) : const Color(0xFF17272D),
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: chrome.isPhone ? 8 : 10,
            vertical: chrome.isPhone ? 5 : 6,
          ),
          child: Text(
            label,
            maxLines: 1,
            style: TextStyle(
              color: selected ? Colors.tealAccent : Colors.white70,
              fontSize: chrome.captionSize,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              height: 1.1,
            ),
          ),
        ),
      ),
    );
  }
}
