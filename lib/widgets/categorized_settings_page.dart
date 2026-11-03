import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../theme/app_tokens.dart';
import 'experimental_layout_widgets.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// A flat, ordered settings surface. Boundaries supply search metadata only;
/// they never change the order or hide settings behind category navigation.
class CategorizedSettingsPage extends StatefulWidget {
  const CategorizedSettingsPage({
    super.key,
    required this.items,
    this.priorityLabels = const [],
  });
  final List<Widget> items;
  final List<String> priorityLabels;

  @override
  State<CategorizedSettingsPage> createState() =>
      _CategorizedSettingsPageState();
}

class _SettingSection {
  _SettingSection(this.label, this.keywords);
  final String label, keywords;
  final List<Widget> children = [];
  bool matches(String query) =>
      '$label $keywords'.toLowerCase().contains(query);
}

class _CategorizedSettingsPageState extends State<CategorizedSettingsPage> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _clearSearch() {
    _search.clear();
    setState(() => _query = '');
  }

  void _back() {
    if (_query.isNotEmpty) {
      _clearSearch();
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final sections = <_SettingSection>[];
    var current = _SettingSection('', '');
    sections.add(current);
    for (final item in widget.items) {
      if (item is SettingsCategoryBoundary) {
        current = _SettingSection(item.label ?? '', item.keywords);
        sections.add(current);
      } else {
        current.children.add(item);
      }
    }
    // Spacing-only sections occur when a platform-specific setting is absent.
    for (final section in sections) {
      while (section.children.isNotEmpty && section.children.last is SizedBox) {
        section.children.removeLast();
      }
    }
    final originalOrder = List<_SettingSection>.of(sections);
    int priority(_SettingSection section) {
      final index = widget.priorityLabels.indexOf(section.label);
      return index < 0
          ? widget.priorityLabels.length + originalOrder.indexOf(section)
          : index;
    }

    sections.sort((a, b) => priority(a).compareTo(priority(b)));
    final query = _query.trim().toLowerCase();
    final results = sections
        .where(
          (s) => s.children.isNotEmpty && (query.isEmpty || s.matches(query)),
        )
        .toList();
    final searchBarHeight =
        (MediaQuery.textScalerOf(context).scale(16) * 1.5 + 48).clamp(
          72.0,
          double.infinity,
        );
    return PopScope(
      canPop: _query.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        backgroundColor: AppTokens.bgBase,
        appBar: AppBar(
          title: const Text('媒体库设置'),
          leading: DesktopButtonClickRegion(
            child: BackButton(onPressed: _back),
          ),
          actions: [
            DesktopButtonClickRegion(
              child: IconButton(
                tooltip: '首页布局实验室',
                icon: const Icon(Icons.science_outlined),
                onPressed: () => showLayoutExperiment(context),
              ),
            ),
          ],
          bottom: PreferredSize(
            preferredSize: Size.fromHeight(searchBarHeight),
            child: Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: TextField(
                    key: const ValueKey('settings-search'),
                    controller: _search,
                    maxLines: 1,
                    onChanged: (value) => setState(() => _query = value),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: '搜索设置，例如缓存、字幕、通知',
                      suffixIcon: _query.isEmpty
                          ? null
                          : DesktopButtonClickRegion(
                              child: IconButton(
                                tooltip: '清除搜索',
                                onPressed: _clearSearch,
                                icon: const Icon(Icons.clear),
                              ),
                            ),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        body: SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              const gap = 12.0;
              final width = constraints.maxWidth - 32;
              // Keep controls readable with enlarged system text as well.
              final minColumnWidth =
                  440 * MediaQuery.textScalerOf(context).scale(14) / 14;
              final columns = ((width + gap) / (minColumnWidth + gap))
                  .floor()
                  .clamp(1, 3);
              return Scrollbar(
                controller: _scroll,
                child: SingleChildScrollView(
                  key: const PageStorageKey('media-library-all-settings'),
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  child: results.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Text('没有找到相关设置，请试试其他关键词。'),
                        )
                      : _SettingsFlow(
                          columns: columns,
                          gap: gap,
                          children: [
                            for (final section in results)
                              Semantics(
                                sortKey: OrdinalSortKey(
                                  results.indexOf(section).toDouble(),
                                ),
                                child: Material(
                                  color: const Color(0xFF292929),
                                  borderRadius: BorderRadius.circular(12),
                                  clipBehavior: Clip.antiAlias,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    mainAxisSize: MainAxisSize.min,
                                    children: section.children,
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
    );
  }
}

/// Place each setting in the next available column. A tall or expanded setting
/// must not reserve empty space beneath its neighbours. Children stay in source
/// order for traversal and retain their state when the column count changes.
class _SettingsFlow extends MultiChildRenderObjectWidget {
  const _SettingsFlow({
    required this.columns,
    required this.gap,
    required super.children,
  });
  final int columns;
  final double gap;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSettingsFlow(columns, gap);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSettingsFlow renderObject,
  ) {
    renderObject.configure(columns, gap);
  }
}

class _SettingsFlowParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderSettingsFlow extends RenderBox
    with
        ContainerRenderObjectMixin<
          RenderBox,
          ContainerBoxParentData<RenderBox>
        >,
        RenderBoxContainerDefaultsMixin<
          RenderBox,
          ContainerBoxParentData<RenderBox>
        > {
  _RenderSettingsFlow(this._columns, this._gap);
  int _columns;
  double _gap;

  void configure(int columns, double gap) {
    if (_columns == columns && _gap == gap) return;
    _columns = columns;
    _gap = gap;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! ContainerBoxParentData<RenderBox>) {
      child.parentData = _SettingsFlowParentData();
    }
  }

  @override
  void performLayout() {
    final width = constraints.maxWidth;
    final childWidth = (width - _gap * (_columns - 1)) / _columns;
    final bottoms = List<double>.filled(_columns, 0);
    var child = firstChild;
    while (child != null) {
      var column = 0;
      for (var i = 1; i < _columns; i++) {
        if (bottoms[i] < bottoms[column]) column = i;
      }
      child.layout(
        BoxConstraints.tightFor(width: childWidth),
        parentUsesSize: true,
      );
      final data = child.parentData! as ContainerBoxParentData<RenderBox>;
      data.offset = Offset(column * (childWidth + _gap), bottoms[column]);
      bottoms[column] += child.size.height + _gap;
      child = data.nextSibling;
    }
    final height = bottoms.reduce((a, b) => a > b ? a : b);
    size = constraints.constrain(Size(width, height > 0 ? height - _gap : 0));
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
