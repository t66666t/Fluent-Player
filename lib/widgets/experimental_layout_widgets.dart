import 'package:flutter/material.dart';
export 'experimental_home_frame.dart';
import '../services/experimental_layout.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

const _surface = Color(0xff191919);
const _panel = Color(0xff222222);
const _accent = Color(0xff90b9ff);

Future<void> showLayoutExperiment(BuildContext context) async {
  final layout = ExperimentalLayout.instance;
  await layout.initialize();
  if (!context.mounted) return;
  final choice = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: const Text('布局实验室'),
      content: const Text('体验新的首页导航。媒体与偏好继续沿用，随时可以恢复原布局。'),
      actions: [
        DesktopButtonClickRegion(
          child: TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('关闭'),
          ),
        ),
        DesktopButtonClickRegion(
          child: FilledButton(
            onPressed: () => Navigator.pop(dialog, !layout.value),
            child: Text(layout.value ? '恢复原布局' : '体验新布局'),
          ),
        ),
      ],
    ),
  );
  if (choice == null) return;
  await layout.select(choice);
  if (context.mounted) Navigator.of(context).pop();
}

enum ExperimentalSettingsCategory {
  general('通用与外观', '启动页面、媒体库、导入、剪贴板', Icons.tune),
  playback('播放', '后台播放、播放队列、系统媒体控制', Icons.play_circle_outline),
  models('AI 与模型', '转录、翻译、本地模型与下载', Icons.auto_awesome_outlined),
  network('网络与同步', '网络连接、设备同步', Icons.language),
  storage('存储与数据', '空间占用、缓存、播放记录', Icons.storage_outlined),
  about('关于', '许可、隐私与布局实验室', Icons.info_outline);

  const ExperimentalSettingsCategory(this.label, this.description, this.icon);
  final String label;
  final String description;
  final IconData icon;
}

/// Nonvisual boundaries let both presentations share the exact same controls.
class SettingsCategoryBoundary extends StatelessWidget {
  const SettingsCategoryBoundary(
    this.category, {
    super.key,
    this.label,
    this.keywords = '',
  });
  final ExperimentalSettingsCategory category;
  final String? label;
  final String keywords;
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class ExperimentalSettingsPage extends StatefulWidget {
  const ExperimentalSettingsPage({super.key, required this.items});
  final List<Widget> items;
  @override
  State<ExperimentalSettingsPage> createState() =>
      _ExperimentalSettingsPageState();
}

class _ExperimentalSettingsPageState extends State<ExperimentalSettingsPage> {
  ExperimentalSettingsCategory? _selected;
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 760;
    final groups = {
      for (final c in ExperimentalSettingsCategory.values) c: <Widget>[],
    };
    var current = ExperimentalSettingsCategory.general;
    for (final item in widget.items) {
      if (item is SettingsCategoryBoundary) {
        current = item.category;
      } else {
        groups[current]!.add(item);
      }
    }
    final selected =
        _selected ?? (wide ? ExperimentalSettingsCategory.general : null);
    final matches = ExperimentalSettingsCategory.values
        .where((c) => '${c.label} ${c.description}'.contains(_query.trim()))
        .toList();
    Widget menu() => ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: TextField(
            onChanged: (value) => setState(() => _query = value),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: '查找设置分类',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        if (matches.isEmpty)
          const Padding(padding: EdgeInsets.all(16), child: Text('没有匹配的分类')),
        for (final category in matches)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              selected: selected == category,
              selectedColor: _accent,
              selectedTileColor: _accent.withValues(alpha: .12),
              leading: Icon(category.icon),
              title: Text(category.label),
              subtitle: wide ? null : Text(category.description),
              trailing: wide ? null : const Icon(Icons.chevron_right),
              onTap: () => setState(() => _selected = category),
            ),
          ),
      ],
    );
    Widget details(ExperimentalSettingsCategory category) => Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 880),
        child: ListView(
          key: PageStorageKey(category),
          padding: EdgeInsets.all(wide ? 32 : 16),
          children: [
            Text(
              category.label,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              category.description,
              style: const TextStyle(color: Colors.white70, height: 1.5),
            ),
            const SizedBox(height: 24),
            ...groups[category]!,
            if (category == ExperimentalSettingsCategory.about)
              ListTile(
                leading: const Icon(Icons.undo),
                title: const Text('恢复原布局'),
                onTap: () => showLayoutExperiment(context),
              ),
            const SizedBox(height: 96),
          ],
        ),
      ),
    );
    return PopScope(
      canPop: wide || _selected == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _selected = null);
      },
      child: Scaffold(
        backgroundColor: _surface,
        appBar: AppBar(
          backgroundColor: _surface,
          title: const Text('设置'),
          leading: DesktopButtonClickRegion(
            child: BackButton(
              onPressed: () {
                if (!wide && _selected != null) {
                  setState(() => _selected = null);
                } else {
                  Navigator.pop(context);
                }
              },
            ),
          ),
          actions: [
            DesktopButtonClickRegion(
              child: IconButton(
                tooltip: '布局实验室',
                icon: const Icon(Icons.science_outlined),
                onPressed: () => showLayoutExperiment(context),
              ),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: wide
              ? Row(
                  children: [
                    SizedBox(
                      width: 240,
                      child: Material(color: _panel, child: menu()),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: details(selected!)),
                  ],
                )
              : selected == null
              ? menu()
              : details(selected),
        ),
      ),
    );
  }
}
