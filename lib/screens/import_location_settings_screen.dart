import 'package:flutter/material.dart';

import '../models/import_card_placement.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import '../theme/app_tokens.dart';
import '../widgets/library_folder_picker.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Edits a draft. Previewing a plan never creates or moves library folders.
class ImportLocationSettingsScreen extends StatefulWidget {
  const ImportLocationSettingsScreen({
    super.key,
    required this.settings,
    this.library,
  });
  final SettingsService settings;
  final LibraryService? library;

  @override
  State<ImportLocationSettingsScreen> createState() =>
      _ImportLocationSettingsScreenState();
}

class _ImportLocationSettingsScreenState
    extends State<ImportLocationSettingsScreen> {
  late ImportCardPlacement _preset;
  late ImportPlacementRules _rules;
  String _preview = ImportCardFeature.bilibiliDownload.storageValue;
  String _launch = 'folder';
  bool _saving = false;
  String? _error;
  final _expanded = <ImportCardGroup>{};

  static const _presets = [
    ImportCardPlacement.libraryRoot,
    ImportCardPlacement.currentFolder,
    ImportCardPlacement.sourceFolder,
    ImportCardPlacement.fixedFolder,
  ];

  @override
  void initState() {
    super.initState();
    _reset();
    widget.library?.addListener(_libraryChanged);
  }

  @override
  void dispose() {
    widget.library?.removeListener(_libraryChanged);
    super.dispose();
  }

  void _libraryChanged() {
    if (mounted) setState(() {});
  }

  void _reset() {
    _preset = widget.settings.importCardPlacementMode;
    _rules = ImportPlacementRules.decode(
      widget.settings.importPlacementRulesJson,
    );
    _error = null;
  }

  String _folderPath(String? id) {
    if (id == null) return '媒体库根目录';
    final library = widget.library;
    if (library == null) return '已选文件夹';
    final parts = <String>[];
    final visited = <String>{};
    String? cursor = id;
    while (cursor != null && visited.add(cursor)) {
      final folder = library.getCollection(cursor);
      if (folder == null || folder.isRecycled) return '目标已不可用，请重新选择';
      parts.insert(0, folder.name);
      cursor = folder.parentId;
    }
    return '媒体库 / ${parts.join(' / ')}';
  }

  ImportPlacementRule _groupRule(ImportCardGroup group) =>
      group.features.length == 1
      ? _rules.effectiveRule(group.features.single, _preset)
      : _rules.overrides[group.ruleKey] ??
            ImportPlacementRule(_preset, folderId: _rules.fixedFolderId);

  String _ruleSummary(ImportPlacementRule rule, ImportCardFeature feature) =>
      switch (rule.placement) {
        ImportCardPlacement.libraryRoot => '媒体库根目录',
        ImportCardPlacement.currentFolder => '发起时的文件夹，独立入口使用根目录',
        ImportCardPlacement.sourceFolder =>
          widget.settings.importSourceFolderId(feature) != null
              ? _folderPath(widget.settings.importSourceFolderId(feature))
              : '媒体库 / ${widget.settings.importSourceFolderName(feature)}',
        ImportCardPlacement.fixedFolder => _folderPath(rule.folderId),
        ImportCardPlacement.askEveryTime => '导入前选择，一批只选一次',
      };

  Future<LibraryFolderPick?> _pick(String? initial) async {
    final library = widget.library;
    if (library == null) {
      setState(() => _error = '媒体库尚未就绪，请返回媒体库后重试');
      return null;
    }
    return showLibraryFolderPicker(
      context,
      library: library,
      initialFolderId: initial,
      title: '选择默认导入位置',
      confirmLabel: '使用此位置',
      offerSetAsDefault: false,
    );
  }

  Future<void> _selectPreset(ImportCardPlacement mode) async {
    if (_saving) return;
    if (mode == ImportCardPlacement.fixedFolder && _preset != mode) {
      final pick = await _pick(_rules.fixedFolderId);
      if (pick == null || !mounted) return;
      _rules.fixedFolderId = pick.folderId;
    }
    if (mounted) {
      setState(() {
        _preset = mode;
        _error = null;
      });
    }
  }

  Future<void> _changeRule(String key, String value) async {
    if (value == 'inherit') {
      setState(() => _rules.overrides.remove(key));
      return;
    }
    final mode = ImportCardPlacementX.fromStorage(value);
    String? id;
    if (mode == ImportCardPlacement.fixedFolder) {
      final pick = await _pick(_rules.overrides[key]?.folderId);
      if (pick == null || !mounted) return;
      id = pick.folderId;
    }
    if (mounted) {
      setState(
        () => _rules.overrides[key] = ImportPlacementRule(mode, folderId: id),
      );
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.settings.saveImportPlacement(_preset, _rules);
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '保存失败，请重试';
        });
      }
    }
  }

  Widget _panel(Widget child) => Material(
    color: AppTokens.bgRaised,
    borderRadius: BorderRadius.circular(12),
    clipBehavior: Clip.antiAlias,
    child: child,
  );

  @override
  Widget build(BuildContext context) {
    final overrides = _rules.overrides.length;
    return Scaffold(
      backgroundColor: AppTokens.bgBase,
      appBar: AppBar(
        backgroundColor: AppTokens.bgBase,
        title: const Text('导入位置与整理', style: TextStyle(fontSize: 18)),
        actions: [
          DesktopButtonClickRegion(
            child: TextButton(
              onPressed: _saving ? null : () => setState(_reset),
              child: const Text('还原修改'),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _saving ? '正在保存…' : '仅影响新任务，历史内容和已排队任务保持原位',
                  style: const TextStyle(color: AppTokens.text2, fontSize: 12),
                ),
              ),
              const SizedBox(width: 12),
              DesktopButtonClickRegion(
                child: FilledButton(
                  key: const ValueKey('import-location-save'),
                  onPressed: _saving ? null : _save,
                  child: const Text('保存设置'),
                ),
              ),
            ],
          ),
        ),
      ),
      body: LayoutBuilder(
        builder: (context, viewport) => SingleChildScrollView(
          key: const ValueKey('import-location-scroll'),
          padding: const EdgeInsets.all(16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1280),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '下载、本地导入和网盘引用统一设置位置，之后由你整理。',
                    style: TextStyle(color: AppTokens.text2, fontSize: 13),
                  ),
                  const SizedBox(height: 14),
                  _presetChoices(),
                  const SizedBox(height: 10),
                  Text(
                    _preset.description,
                    style: const TextStyle(
                      color: AppTokens.text2,
                      fontSize: 12,
                    ),
                  ),
                  if (_preset == ImportCardPlacement.fixedFolder) ...[
                    const SizedBox(height: 8),
                    DesktopButtonClickRegion(
                      child: OutlinedButton.icon(
                        onPressed: _saving
                            ? null
                            : () async {
                                final pick = await _pick(_rules.fixedFolderId);
                                if (pick != null && mounted) {
                                  setState(
                                    () => _rules.fixedFolderId = pick.folderId,
                                  );
                                }
                              },
                        icon: const Icon(Icons.folder_outlined, size: 18),
                        label: Text(_folderPath(_rules.fixedFolderId)),
                      ),
                    ),
                  ],
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            overrides == 0
                                ? '各入口全部跟随方案'
                                : '$overrides 项单独设置，切换方案时保留',
                            style: const TextStyle(
                              color: AppTokens.text2,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        DesktopButtonClickRegion(
                          child: TextButton(
                            onPressed: overrides == 0 || _saving
                                ? null
                                : () => setState(_rules.overrides.clear),
                            child: const Text(
                              '清除单独设置',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        _error!,
                        style: const TextStyle(
                          color: AppTokens.danger,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  if (viewport.maxWidth >= 1050)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: _sources()),
                        const SizedBox(width: 16),
                        SizedBox(
                          width: 320,
                          child: _previewPanel(collapsible: false),
                        ),
                      ],
                    )
                  else ...[
                    _previewPanel(collapsible: true),
                    const SizedBox(height: 12),
                    _sources(),
                  ],
                  const SizedBox(height: 12),
                  _panel(
                    const Padding(
                      padding: EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '拖到哪里，就导入到哪里',
                            style: TextStyle(
                              fontSize: 13,
                              color: Color(0xFF8BD2B4),
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            '媒体、文件夹和压缩包始终遵循拖拽落点。本次手选位置同样优先。',
                            style: TextStyle(
                              color: AppTokens.text2,
                              fontSize: 12,
                            ),
                          ),
                          SizedBox(height: 7),
                          Text(
                            '文件夹、压缩包和导出包保留内部层级；已有条目下载离线内容时保持原位。',
                            style: TextStyle(
                              color: AppTokens.text2,
                              fontSize: 12,
                            ),
                          ),
                          SizedBox(height: 7),
                          Text(
                            '网盘的“加入媒体库”遵循网盘入口的规则；“选择入库位置…”仅覆盖本次操作。'
                            '网盘文件夹保留层级，缓存单独管理。',
                            style: TextStyle(
                              color: AppTokens.text2,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '这里设置媒体库中的位置。应用管理的大文件目录请在“媒体库设置 → 数据目录”中查看；支持迁移的平台可在那里更改位置。',
                    style: TextStyle(color: AppTokens.text2, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _presetChoices() => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 720 ? 4 : 2;
      final width = (constraints.maxWidth - 8 * (columns - 1)) / columns;
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final mode in _presets)
            SizedBox(
              width: width,
              child: Semantics(
                selected: mode == _preset,
                child: Material(
                  color: mode == _preset
                      ? AppTokens.accentSoft
                      : AppTokens.bgRaised,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(
                      color: mode == _preset
                          ? AppTokens.accent
                          : Colors.white12,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    key: ValueKey('importCardPlacement-${mode.storageValue}'),
                    onTap: _saving ? null : () => _selectPreset(mode),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 76),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              mode == ImportCardPlacement.libraryRoot
                                  ? (width < 170 ? '根目录 · 默认' : '全部放到根目录 · 默认')
                                  : mode.label,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: mode == _preset
                                    ? const Color(0xFFC8DCFF)
                                    : AppTokens.text1,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              switch (mode) {
                                ImportCardPlacement.libraryRoot =>
                                  '所有入口集中放置，自行整理',
                                ImportCardPlacement.currentFolder =>
                                  '跟随发起时的媒体库位置',
                                ImportCardPlacement.sourceFolder =>
                                  '每个来源使用各自的目录',
                                _ => '集中到指定文件夹，稍后归档',
                              },
                              style: const TextStyle(
                                color: AppTokens.text2,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );

  Widget _sources() => _panel(
    Column(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(14, 12, 14, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '各入口导入位置',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                ),
              ),
              Text(
                '点击展开',
                style: TextStyle(color: AppTokens.text2, fontSize: 12),
              ),
            ],
          ),
        ),
        for (final group in ImportCardGroup.values) ...[
          const Divider(height: 1, color: AppTokens.lineSubtle),
          ExpansionTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            key: PageStorageKey('import-location-group-${group.name}'),
            initiallyExpanded: _expanded.contains(group),
            onExpansionChanged: (open) {
              if (open) {
                _expanded.add(group);
              } else {
                _expanded.remove(group);
              }
            },
            tilePadding: const EdgeInsets.symmetric(horizontal: 14),
            childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            shape: const Border(),
            collapsedShape: const Border(),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    group.label,
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    group.features.length > 1 &&
                            group.features.any(
                              (feature) => _rules.overrides.containsKey(
                                feature.storageValue,
                              ),
                            )
                        ? '有入口单独设置'
                        : _groupRule(group).placement.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTokens.text2,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            subtitle: Text(
              '${group.description} · ${_ruleSummary(_groupRule(group), group.features.first)}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppTokens.text2, fontSize: 12),
            ),
            children: [
              _ruleEditor(group.ruleKey, '此来源的默认位置', '跟随预设方案'),
              const SizedBox(height: 10),
              for (final feature in group.features)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: _ruleEditor(
                    feature.storageValue,
                    feature.label,
                    '跟随此来源',
                  ),
                ),
            ],
          ),
        ],
      ],
    ),
  );

  Widget _ruleEditor(String key, String label, String inherited) {
    final rule = _rules.overrides[key];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              Expanded(
                child: Text(label, style: const TextStyle(fontSize: 13)),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: constraints.maxWidth < 380 ? 136 : 180,
                child: CapsuleDropdownButtonFormField<String>(
                  key: ValueKey(
                    'import-rule-$key-${rule?.placement.storageValue ?? 'inherit'}',
                  ),
                  initialValue: rule?.placement.storageValue ?? 'inherit',
                  isExpanded: true,
                  style: const TextStyle(color: AppTokens.text1, fontSize: 12),
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    DropdownMenuItem(value: 'inherit', child: Text(inherited)),
                    for (final mode in ImportCardPlacement.values)
                      DropdownMenuItem(
                        value: mode.storageValue,
                        child: Text(
                          mode == ImportCardPlacement.fixedFolder
                              ? '指定文件夹'
                              : mode.label,
                        ),
                      ),
                  ],
                  onChanged: _saving
                      ? null
                      : (value) {
                          if (value != null) _changeRule(key, value);
                        },
                ),
              ),
            ],
          ),
        ),
        if (rule?.placement == ImportCardPlacement.fixedFolder)
          Align(
            alignment: Alignment.centerRight,
            child: DesktopButtonClickRegion(
              child: TextButton.icon(
                onPressed: _saving
                    ? null
                    : () => _changeRule(
                        key,
                        ImportCardPlacement.fixedFolder.storageValue,
                      ),
                icon: const Icon(Icons.folder_outlined, size: 16),
                label: Text(
                  _folderPath(rule!.folderId),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _previewPanel({required bool collapsible}) => _panel(
    collapsible
        ? ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 14),
            title: const Text('试一下会放在哪里', style: TextStyle(fontSize: 14)),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                child: _previewBody(),
              ),
            ],
          )
        : Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '试一下会放在哪里',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 12),
                _previewBody(),
              ],
            ),
          ),
  );

  Widget _previewBody() {
    final feature =
        ImportCardFeatureX.tryParse(_preview) ?? ImportCardFeature.podcast;
    final existing = _preview.endsWith('Offline');
    final rule = _rules.effectiveRule(feature, _preset);
    final local = feature.group == ImportCardGroup.local;
    final path = existing
        ? '已有条目的原位置'
        : _launch == 'drop'
        ? '媒体库 / 课程 / 第三章'
        : _launch == 'chosen'
        ? '媒体库 / 项目 / 本周'
        : rule.placement == ImportCardPlacement.currentFolder
        ? (_launch == 'independent' ? '媒体库根目录' : '媒体库 / 学习 / 英语')
        : _ruleSummary(rule, feature);
    final structure = switch (feature) {
      ImportCardFeature.folder => '课程资料 / 第一章 / 第一课.mp4',
      ImportCardFeature.archive => '压缩包内容 / 第一章 / 第一课.mp4',
      ImportCardFeature.fluentPack => '导出包原有目录 / 第一课.mp4',
      ImportCardFeature.podcast => '播客频道 / 本期节目',
      _ => '新导入的媒体',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '导入入口 / 行为',
          style: TextStyle(color: AppTokens.text2, fontSize: 12),
        ),
        const SizedBox(height: 4),
        CapsuleDropdownButtonFormField<String>(
          key: const ValueKey('import-preview-feature'),
          initialValue: _preview,
          isExpanded: true,
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
          ),
          items: [
            for (final item in ImportCardFeature.values)
              DropdownMenuItem(
                value: item.storageValue,
                child: Text(item.label, style: const TextStyle(fontSize: 13)),
              ),
            const DropdownMenuItem(
              value: 'podcastOffline',
              child: Text('已有播客下载离线', style: TextStyle(fontSize: 13)),
            ),
            const DropdownMenuItem(
              value: 'cloudOffline',
              child: Text('已有网盘条目下载离线', style: TextStyle(fontSize: 13)),
            ),
          ],
          onChanged: (value) {
            if (value != null) {
              setState(() {
                _preview = value;
                if (_launch == 'drop' &&
                    ImportCardFeatureX.tryParse(value)?.group !=
                        ImportCardGroup.local) {
                  _launch = 'folder';
                }
              });
            }
          },
        ),
        const SizedBox(height: 12),
        if (!existing) ...[
          CapsuleDropdownButtonFormField<String>(
            key: ValueKey('import-preview-launch-$_launch-$local'),
            initialValue: _launch,
            isExpanded: true,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
            ),
            items: [
              const DropdownMenuItem(
                value: 'folder',
                child: Text('从「学习 / 英语」打开', style: TextStyle(fontSize: 13)),
              ),
              const DropdownMenuItem(
                value: 'independent',
                child: Text('独立打开功能页面', style: TextStyle(fontSize: 13)),
              ),
              const DropdownMenuItem(
                value: 'chosen',
                child: Text('本次手选「项目 / 本周」', style: TextStyle(fontSize: 13)),
              ),
              if (local)
                const DropdownMenuItem(
                  value: 'drop',
                  child: Text('拖入「课程 / 第三章」', style: TextStyle(fontSize: 13)),
                ),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _launch = value);
            },
          ),
          const SizedBox(height: 12),
        ],
        const Text(
          '最终导入位置',
          style: TextStyle(color: AppTokens.text2, fontSize: 12),
        ),
        const SizedBox(height: 6),
        Text(
          path,
          key: const ValueKey('import-preview-result'),
          style: const TextStyle(
            color: Color(0xFFC8DCFF),
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          existing
              ? '下载离线内容会补全原条目，保持原来的位置。'
              : _launch == 'drop' || _launch == 'chosen'
              ? '使用明确指定的位置，优先于预设和来源规则。'
              : '按照当前草案计算。保存后只用于新任务。',
          style: const TextStyle(color: AppTokens.text2, fontSize: 12),
        ),
        if (!existing)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.subdirectory_arrow_right,
                  size: 16,
                  color: AppTokens.text2,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    structure,
                    style: const TextStyle(
                      color: AppTokens.text2,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
