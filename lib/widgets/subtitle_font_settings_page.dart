import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/subtitle_font.dart';
import '../models/subtitle_style.dart';
import '../services/subtitle_font_service.dart';
import '../utils/subtitle_util.dart';
import 'landscape_sidebar_layout.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class SubtitleFontSettingsPage extends StatefulWidget {
  final SubtitleTextStyle style;
  final ValueChanged<SubtitleTextStyle> onChanged;
  final VoidCallback onBack;
  final VoidCallback onClose;
  final String? primarySource;
  final String? secondarySource;
  final String? primaryLanguage;
  final String? secondaryLanguage;
  const SubtitleFontSettingsPage({
    super.key,
    required this.style,
    required this.onChanged,
    required this.onBack,
    required this.onClose,
    this.primarySource,
    this.secondarySource,
    this.primaryLanguage,
    this.secondaryLanguage,
  });
  @override
  State<SubtitleFontSettingsPage> createState() =>
      SubtitleFontSettingsPageState();
}

class SubtitleFontSettingsPageState extends State<SubtitleFontSettingsPage> {
  final service = SubtitleFontService.instance;
  late SubtitleTextStyle _style;
  late Future<List<SubtitleOnlineFont>> _catalog;
  final _search = TextEditingController();
  final _fontScrollController = ScrollController();
  final Map<String, Future<void>> _previews = {};
  String _page = 'settings', _target = '', _query = '', _language = '';
  SubtitleFontLicense? _license;
  bool _online = false;
  SubtitleFontAsset? _details;
  SubtitleOnlineFont? _onlineDetails;
  String? _error, _busy;
  double? _progress;
  CancelToken? _cancel;
  String? _sourceTarget;
  static const _popular = [
    'zh',
    'zh-Hans',
    'zh-Hant',
    'en',
    'ja',
    'ko',
    'fr',
    'de',
    'es',
    'ru',
    'ar',
    'th',
    'hi',
    'vi',
  ];

  @override
  void initState() {
    super.initState();
    _style = widget.style;
    _catalog = service.catalog();
    service.ready.then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(SubtitleFontSettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.style != widget.style) _style = widget.style;
  }

  @override
  void dispose() {
    _cancel?.cancel();
    _search.dispose();
    _fontScrollController.dispose();
    super.dispose();
  }

  void _update(SubtitleTextStyle style) {
    setState(() => _style = style);
    widget.onChanged(style);
  }

  void _go(String page) {
    setState(() {
      _page = page;
      _query = '';
      _search.clear();
      _error = null;
    });
  }

  void handleBack() => _back();
  void _back() {
    _cancel?.cancel();
    if (_page == 'settings') {
      widget.onBack();
    } else if (_page == 'details') {
      _go('picker');
    } else {
      _go('settings');
    }
  }

  SubtitleFontChoice get _selected => _target.isEmpty
      ? _style.defaultFont
      : _style.resolvedLanguageFonts[_target] ?? _style.defaultFont;
  void _choose(SubtitleFontChoice font) {
    if (_target.isEmpty) {
      _update(
        _style.copyWith(
          defaultFontFamily: font.family,
          defaultFontWeight: font.weight,
        ),
      );
    } else {
      _update(
        _style.copyWith(
          languageFonts: {..._style.resolvedLanguageFonts, _target: font},
        ),
      );
    }
  }

  Future<void> _use(SubtitleFontAsset font) async {
    try {
      await service.verifyFiles([font.id]);
      if (!mounted) return;
      final weight = font.weights.contains(_selected.weight)
          ? _selected.weight
          : font.weights.reduce(
              (a, b) => (a - 400).abs() <= (b - 400).abs() ? a : b,
            );
      _choose(SubtitleFontChoice(font.id, weight));
      _go('settings');
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _import() async {
    FocusScope.of(context).unfocus();
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['ttf', 'otf'],
      );
      final path = result?.files.single.path;
      if (path == null || !mounted) return;
      setState(() {
        _busy = '导入中';
        _error = null;
      });
      final font = await service.importFile(path);
      if (mounted) await _use(font);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _download(SubtitleOnlineFont font) async {
    if (_busy != null) return;
    FocusScope.of(context).unfocus();
    if (!font.directDownload) {
      await _open(font.sourceUrl);
      return;
    }
    final token = CancelToken();
    setState(() {
      _busy = font.name;
      _progress = null;
      _error = null;
      _cancel = token;
    });
    try {
      final installed = await service.download(
        font,
        cancel: token,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (mounted && !token.isCancelled) await _use(installed);
    } catch (e) {
      if (mounted && !token.isCancelled) setState(() => _error = '下载失败，可重试。$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = null;
          _cancel = null;
        });
      }
    }
  }

  Future<void> _open(String url) async {
    try {
      if (!await launchUrl(
            Uri.parse(url),
            mode: LaunchMode.externalApplication,
          ) &&
          mounted) {
        setState(() => _error = '无法打开链接');
      }
    } catch (_) {
      if (mounted) setState(() => _error = '无法打开链接');
    }
  }

  String _weightLabel(int weight) => switch (weight) {
    100 => '纤细',
    200 => '特细',
    300 => '细体',
    400 => '常规',
    500 => '中等',
    600 => '半粗',
    700 => '粗体',
    800 => '特粗',
    900 => '重体',
    _ => '$weight',
  };
  String _label(String code) => switch (code.toLowerCase()) {
    'zh' => '中文',
    'zh-hans' => '简体中文',
    'zh-hant' => '繁体中文',
    'en' => '英文',
    'ja' => '日文',
    'ko' => '韩文',
    _ => SubtitleUtil.getLanguageName(code),
  };

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final layout = LandscapeSidebarLayout.fromSize(constraints.biggest);
      final title = switch (_page) {
        'picker' => '选择字体',
        'languages' => '添加语言',
        'source' => '字幕语言',
        'details' => '字体授权',
        _ => '字体设置',
      };
      return Material(
        color: const Color(0xff1e1e1e),
        child: Theme(
          data: Theme.of(context).copyWith(
            brightness: Brightness.dark,
            colorScheme: Theme.of(context).colorScheme.copyWith(
              primary: Colors.blueAccent,
              secondary: Colors.blueAccent,
            ),
            textTheme: Theme.of(context).textTheme.apply(
              bodyColor: Colors.white70,
              displayColor: Colors.white,
            ),
            dividerColor: Colors.white12,
          ),
          child: Column(
            children: [
              SizedBox(
                height: layout.headerHeight,
                child: Row(
                  children: [
                    DesktopButtonClickRegion(
                      child: IconButton(
                        tooltip: '返回',
                        icon: const Icon(Icons.arrow_back, size: 19),
                        onPressed: _back,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(
                          fontSize: layout.titleSize,
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    DesktopButtonClickRegion(
                      child: IconButton(
                        tooltip: '关闭',
                        icon: const Icon(Icons.close, size: 19),
                        onPressed: widget.onClose,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              if (_busy != null) ...[
                LinearProgressIndicator(value: _progress),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _busy!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                      if (_cancel != null)
                        DesktopButtonClickRegion(
                          child: TextButton(
                            onPressed: () => _cancel?.cancel(),
                            child: const Text('取消'),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      color: Colors.orangeAccent,
                      fontSize: 11,
                    ),
                  ),
                ),
              Expanded(
                child: switch (_page) {
                  'settings' => _settings(layout),
                  'picker' => _picker(
                    layout,
                    short: constraints.maxHeight < 250,
                  ),
                  'languages' || 'source' => _languageList(),
                  'details' => _licenseDetails(),
                  _ => const SizedBox.shrink(),
                },
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _settings(LandscapeSidebarLayout layout) => ListView(
    padding: EdgeInsets.all(layout.horizontalPadding),
    children: [
      _fontRow('通用字体', '', _style.defaultFont),
      const Divider(height: 24),
      for (final item in _style.resolvedLanguageFonts.entries)
        _fontRow(_label(item.key), item.key, item.value),
      Align(
        alignment: Alignment.centerLeft,
        child: DesktopButtonClickRegion(
          child: TextButton.icon(
            onPressed: () {
              _sourceTarget = null;
              _go('languages');
            },
            icon: const Icon(Icons.add, size: 17),
            label: const Text('添加语言'),
          ),
        ),
      ),
      if (widget.primarySource != null || widget.secondarySource != null) ...[
        const Divider(height: 24),
        if (widget.primarySource != null)
          _sourceRow('主字幕语言', widget.primarySource!, widget.primaryLanguage),
        if (widget.secondarySource != null)
          _sourceRow(
            '副字幕语言',
            widget.secondarySource!,
            widget.secondaryLanguage,
          ),
      ],
    ],
  );
  Widget _fontRow(String label, String key, SubtitleFontChoice choice) {
    final font = service.find(choice.family);
    final weights = {...?font?.weights, choice.weight}.toList()..sort();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () {
                    _target = key;
                    _language = _popular.contains(key) ? key : '';
                    _go('picker');
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          service.nameOf(choice.family),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const Icon(Icons.chevron_right, size: 18, color: Colors.white38),
              if (key.isNotEmpty)
                DesktopButtonClickRegion(
                  child: IconButton(
                    tooltip: '恢复通用字体',
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    icon: const Icon(
                      Icons.remove_circle_outline,
                      size: 17,
                      color: Colors.white38,
                    ),
                    onPressed: () {
                      final next = {..._style.resolvedLanguageFonts}
                        ..remove(key);
                      _update(_style.copyWith(languageFonts: next));
                    },
                  ),
                ),
            ],
          ),
          Row(
            children: [
              const Text('字重', style: TextStyle(fontSize: 11)),
              const SizedBox(width: 12),
              Expanded(
                child: CapsuleDropdownButton<int>(
                  isExpanded: true,
                  isDense: true,
                  value: choice.weight,
                  dropdownColor: const Color(0xff292929),
                  underline: const SizedBox.shrink(),
                  items: weights
                      .map(
                        (w) => DropdownMenuItem(
                          value: w,
                          child: Text(
                            _weightLabel(w),
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (w) {
                    if (w != null) {
                      _target = key;
                      _choose(SubtitleFontChoice(choice.family, w));
                    }
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sourceRow(String title, String source, String? hint) {
    final current = service.manualLanguageForSource(source);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(title, style: const TextStyle(fontSize: 12)),
      subtitle: Text(
        current == null
            ? '自动${hint == null ? '' : ' · ${_label(hint)}'}'
            : _label(current),
        style: const TextStyle(fontSize: 11),
      ),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: () {
        _sourceTarget = source;
        _go('source');
      },
    );
  }

  Widget _searchField() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    child: TextField(
      controller: _search,
      style: const TextStyle(fontSize: 12),
      decoration: const InputDecoration(
        isDense: true,
        hintText: '搜索',
        prefixIcon: Icon(Icons.search, size: 18),
        prefixIconConstraints: BoxConstraints(minWidth: 32, minHeight: 32),
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
      onChanged: (q) => setState(() => _query = q.trim().toLowerCase()),
    ),
  );
  Widget _languageList() {
    final codes = [
      ..._popular,
      ...SubtitleUtil.languageCodes.where(
        (c) => !_popular.contains(c) && !c.startsWith('ai-'),
      ),
    ];
    return Column(
      children: [
        _searchField(),
        Expanded(
          child: ListView(
            children: [
              if (_page == 'source' && _query.isEmpty)
                ListTile(
                  title: const Text('自动'),
                  onTap: () => _setLanguage(''),
                ),
              for (final code in codes)
                if ((_page == 'source' ||
                        !_style.resolvedLanguageFonts.containsKey(code)) &&
                    ('${_label(code)} $code'.toLowerCase().contains(_query)))
                  ListTile(
                    dense: true,
                    title: Text(
                      _label(code),
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: Text(
                      code,
                      style: const TextStyle(
                        fontSize: 10,
                        color: Colors.white38,
                      ),
                    ),
                    onTap: () => _setLanguage(code),
                  ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _setLanguage(String language) async {
    if (_page == 'source') {
      await service.setSourceLanguage(_sourceTarget!, language);
    } else {
      _update(
        _style.copyWith(
          languageFonts: {
            ..._style.resolvedLanguageFonts,
            language: _style.defaultFont,
          },
        ),
      );
    }
    if (mounted) _go('settings');
  }

  Widget _picker(
    LandscapeSidebarLayout layout, {
    required bool short,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxHeight >= 160) {
        return _pickerBody(layout, short: short);
      }
      // A keyboard can leave less room than the fixed toolbar and search.
      // Scroll them with the results so a complete font action is reachable.
      return _fontScrollView(
        CustomScrollView(
          controller: _fontScrollController,
          slivers: [
            SliverToBoxAdapter(child: _pickerToolbar(short: true)),
            SliverToBoxAdapter(child: _searchField()),
            const SliverToBoxAdapter(child: SizedBox(height: 6)),
            _fontChoices(sliver: true),
          ],
        ),
      );
    },
  );

  Widget _pickerBody(LandscapeSidebarLayout layout, {required bool short}) =>
      Column(
        children: [
          _pickerToolbar(short: short),
          _searchField(),
          if (!short)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  Expanded(
                    child: CapsuleDropdownButton<String>(
                      isExpanded: true,
                      isDense: true,
                      value: _language,
                      underline: const SizedBox.shrink(),
                      items: [
                        const DropdownMenuItem(
                          value: '',
                          child: Text('所有语言', style: TextStyle(fontSize: 11)),
                        ),
                        for (final code in _popular)
                          DropdownMenuItem(
                            value: code,
                            child: Text(
                              _label(code),
                              style: const TextStyle(fontSize: 11),
                            ),
                          ),
                      ],
                      onChanged: (v) => setState(() => _language = v ?? ''),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: CapsuleDropdownButton<SubtitleFontLicense>(
                      isExpanded: true,
                      isDense: true,
                      value: _license,
                      hint: const Text('所有授权', style: TextStyle(fontSize: 11)),
                      underline: const SizedBox.shrink(),
                      items: [
                        const DropdownMenuItem<SubtitleFontLicense>(
                          value: null,
                          child: Text('所有授权', style: TextStyle(fontSize: 11)),
                        ),
                        for (final license in SubtitleFontLicense.values)
                          DropdownMenuItem(
                            value: license,
                            child: Text(
                              license.label,
                              style: const TextStyle(fontSize: 11),
                            ),
                          ),
                      ],
                      onChanged: (v) => setState(() => _license = v),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 6),
          Expanded(child: _fontChoices()),
        ],
      );

  Widget _pickerToolbar({required bool short}) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 10),
    child: Row(
      children: [
        for (final online in [false, true])
          DesktopButtonClickRegion(
            child: TextButton(
              style: short
                  ? TextButton.styleFrom(
                      minimumSize: const Size(0, 30),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    )
                  : null,
              onPressed: () => setState(() => _online = online),
              child: Text(
                online ? '在线' : '我的',
                style: TextStyle(
                  color: _online == online ? Colors.blueAccent : Colors.white54,
                ),
              ),
            ),
          ),
        const Spacer(),
        DesktopButtonClickRegion(
          child: TextButton.icon(
            style: short
                ? TextButton.styleFrom(
                    minimumSize: const Size(0, 30),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  )
                : null,
            onPressed: _busy == null ? _import : null,
            icon: const Icon(Icons.file_upload_outlined, size: 16),
            label: const Text('导入'),
          ),
        ),
      ],
    ),
  );

  Widget _fontChoices({bool sliver = false}) => _online
      ? FutureBuilder<List<SubtitleOnlineFont>>(
          future: _catalog,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return _fontPlaceholder(
                Center(
                  child: DesktopButtonClickRegion(
                    child: TextButton(
                      onPressed: () =>
                          setState(() => _catalog = service.catalog()),
                      child: const Text('目录读取失败，重试'),
                    ),
                  ),
                ),
                sliver: sliver,
              );
            }
            if (!snapshot.hasData) {
              return _fontPlaceholder(
                const Center(child: CircularProgressIndicator()),
                sliver: sliver,
              );
            }
            final fonts = snapshot.data!
                .where(
                  (f) =>
                      f.name.toLowerCase().contains(_query) &&
                      (_license == null || f.license == _license) &&
                      (_language.isEmpty ||
                          f.languages.any(
                            (l) =>
                                l.toLowerCase() == _language.toLowerCase() ||
                                l.split('-').first == _language ||
                                (['fr', 'de', 'es'].contains(_language) &&
                                    l == 'en'),
                          )),
                )
                .toList();
            return _fontList(
              fonts.length,
              (index) => _onlineRow(fonts[index]),
              sliver: sliver,
            );
          },
        )
      : ListenableBuilder(
          listenable: service,
          builder: (context, _) {
            final fonts = service.fonts
                .where(
                  (f) =>
                      ('${f.name} ${f.id}'.toLowerCase().contains(_query)) &&
                      (_license == null || f.license == _license) &&
                      _supportsLanguage(f, _language),
                )
                .toList();
            return _fontList(
              fonts.length,
              (index) => _installedRow(fonts[index]),
              sliver: sliver,
            );
          },
        );

  Widget _fontPlaceholder(Widget child, {required bool sliver}) =>
      sliver ? SliverToBoxAdapter(child: child) : child;

  bool _supportsLanguage(SubtitleFontAsset font, String language) {
    if (language.isEmpty) return true;
    final sample = switch (language.split('-').first) {
      'zh' => '字',
      'ja' => 'あ',
      'ko' => '한',
      'ru' => 'Я',
      'ar' => 'ع',
      'th' => 'ก',
      'hi' => 'अ',
      _ => 'A',
    };
    if (font.coverage.isNotEmpty) return font.supports(sample.runes.first);
    if (font.id == 'System') return true;
    if (['en', 'fr', 'de', 'es', 'vi'].contains(language)) return true;
    return language.startsWith('zh') &&
        [
          'MiSans',
          'Noto Sans SC',
          'Noto Serif CJK SC',
          'Swei Gothic CJK SC',
        ].contains(font.id);
  }

  Widget _fontList(
    int length,
    Widget Function(int) row, {
    bool sliver = false,
  }) {
    if (sliver) {
      return length == 0
          ? _fontPlaceholder(
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  '没有匹配的字体',
                  style: TextStyle(fontSize: 12, color: Colors.white38),
                ),
              ),
              sliver: true,
            )
          : SliverPadding(
              padding: const EdgeInsets.only(right: 14),
              sliver: SliverList.builder(
                itemCount: length,
                itemBuilder: (_, i) => row(i),
              ),
            );
    }
    return length == 0
        ? const Center(
            child: Text(
              '没有匹配的字体',
              style: TextStyle(fontSize: 12, color: Colors.white38),
            ),
          )
        : _fontScrollView(
            ListView.builder(
              controller: _fontScrollController,
              padding: const EdgeInsets.only(right: 14),
              itemCount: length,
              itemBuilder: (_, i) => row(i),
            ),
          );
  }

  Widget _fontScrollView(Widget child) => ScrollConfiguration(
    behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
    child: RawScrollbar(
      controller: _fontScrollController,
      thumbVisibility: true,
      interactive: true,
      pressDuration: Duration.zero,
      thickness: 10,
      minThumbLength: 56,
      radius: const Radius.circular(5),
      crossAxisMargin: 2,
      mainAxisMargin: 4,
      thumbColor: Colors.white54,
      scrollbarOrientation: ScrollbarOrientation.right,
      child: child,
    ),
  );
  Widget _installedRow(SubtitleFontAsset font) {
    Widget row({bool loaded = true, bool failed = false}) => _row(
      font.name,
      font.license,
      previewFamily: loaded && font.id != 'System' ? font.id : null,
      previewText: failed
          ? '字体文件不可用'
          : loaded
          ? null
          : '正在加载预览',
      selected: _selected.family == font.id,
      action: '使用',
      onUse: () => _use(font),
      onDetails: () {
        _details = font;
        _onlineDetails = null;
        _go('details');
      },
    );
    if (!font.id.startsWith('subtitle_font_')) return row();
    return FutureBuilder<void>(
      future: _previews.putIfAbsent(
        font.id,
        () => service.ensureLoaded(font.id),
      ),
      builder: (context, snapshot) => row(
        loaded:
            snapshot.connectionState == ConnectionState.done &&
            !snapshot.hasError,
        failed: snapshot.hasError,
      ),
    );
  }

  Widget _onlineRow(SubtitleOnlineFont font) {
    final installed = service.fonts
        .where((f) => f.sourceUrl == font.sourceUrl && f.path != null)
        .firstOrNull;
    return _row(
      font.name,
      font.license,
      previewFamily: installed?.id,
      showPreview: installed != null,
      previewText: installed == null
          ? (font.directDownload ? '下载后可预览' : '从官网获取后导入')
          : null,
      action: installed != null
          ? '使用'
          : font.directDownload
          ? '下载'
          : '去官网',
      onUse: () {
        if (installed != null) {
          _use(installed);
        } else {
          _download(font);
        }
      },
      onDetails: () {
        _details = null;
        _onlineDetails = font;
        _go('details');
      },
    );
  }

  Widget _row(
    String name,
    SubtitleFontLicense license, {
    String? previewFamily,
    String? previewText,
    bool showPreview = true,
    bool selected = false,
    required String action,
    required VoidCallback onUse,
    required VoidCallback onDetails,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    child: Row(
      children: [
        Expanded(
          child: InkWell(
            onTap: onDetails,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Colors.white),
                ),
                if (showPreview) const SizedBox(height: 3),
                if (showPreview)
                  Text(
                    previewText ??
                        (_language == 'ja' ? '字幕の見え方 Aa' : '字幕预览 Aa'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: previewFamily,
                      fontSize: previewText == null ? 14 : 11,
                      color: Colors.white60,
                    ),
                  ),
                const SizedBox(height: 3),
                Text(
                  license.label,
                  style: TextStyle(
                    fontSize: 10,
                    color: license == SubtitleFontLicense.commercial
                        ? Colors.greenAccent.shade100
                        : Colors.orangeAccent.shade100,
                  ),
                ),
              ],
            ),
          ),
        ),
        DesktopButtonClickRegion(
          child: TextButton(
            key: ValueKey('subtitle-font-use-$name'),
            onPressed: _busy == null ? onUse : null,
            child: Text(
              selected ? '已选' : action,
              style: const TextStyle(fontSize: 11),
            ),
          ),
        ),
      ],
    ),
  );
  Widget _licenseDetails() {
    final asset = _details, online = _onlineDetails;
    final source = asset?.sourceUrl ?? online?.sourceUrl ?? '';
    final licenseUrl = asset?.licenseUrl ?? online?.licenseFile ?? '';
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Text(
          asset?.name ?? online?.name ?? '',
          style: const TextStyle(color: Colors.white, fontSize: 15),
        ),
        const SizedBox(height: 10),
        Text(
          (asset?.license ?? online?.license ?? SubtitleFontLicense.unknown)
              .label,
        ),
        const SizedBox(height: 8),
        if ((asset?.verifiedOn ?? online?.verifiedOn ?? '').isNotEmpty)
          Text(
            '核验：${asset?.verifiedOn ?? online?.verifiedOn}',
            style: const TextStyle(fontSize: 11, color: Colors.white38),
          ),
        if (source.isNotEmpty)
          DesktopButtonClickRegion(
            child: TextButton(
              onPressed: () => _open(source),
              child: const Text('官方来源'),
            ),
          ),
        if (licenseUrl.isNotEmpty)
          DesktopButtonClickRegion(
            child: TextButton(
              onPressed: () => _open(licenseUrl),
              child: const Text('原始授权条款'),
            ),
          ),
        if (asset?.assetPath != null)
          FutureBuilder<String>(
            future: DefaultAssetBundle.of(
              context,
            ).loadString(asset!.assetPath!),
            builder: (context, snapshot) => SelectableText(
              snapshot.data ?? '',
              style: const TextStyle(fontSize: 11),
            ),
          ),
        if ((asset?.licenseText ?? '').isNotEmpty)
          SelectableText(
            asset!.licenseText,
            style: const TextStyle(fontSize: 11),
          ),
        if ((asset?.license ?? online?.license) == SubtitleFontLicense.unknown)
          const Text(
            '尚未核实此字体的使用授权，请查看随字体提供的许可文件。',
            style: TextStyle(fontSize: 12, height: 1.5),
          ),
      ],
    );
  }
}
