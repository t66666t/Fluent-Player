import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player_app/services/bilibili/bilibili_cache_limit_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_history_service.dart';
import 'package:video_player_app/services/app_haptics.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';
import 'package:video_player_app/widgets/stable_width_label.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

Future<void> openBilibiliSettings(BuildContext context) {
  return pushAboveMediaLibrary(
    context,
    AppMaterialPageRoute<void>(builder: (_) => const BilibiliSettingsScreen()),
  );
}

/// Bilibili settings: account read-only mode, history recording and the
/// online cache cap. Every change is saved and broadcast right away, so the
/// Bilibili pages behind this one update without reopening.
class BilibiliSettingsScreen extends StatefulWidget {
  const BilibiliSettingsScreen({
    super.key,
    this.settings,
    this.history,
    this.cacheManager,
  });

  final SettingsService? settings;
  final BilibiliHistoryService? history;

  /// Defaults to [BilibiliCacheManager.instance]; the cache section is hidden
  /// when there is none.
  final BilibiliCacheManager? cacheManager;

  @override
  State<BilibiliSettingsScreen> createState() => _BilibiliSettingsScreenState();
}

class _BilibiliSettingsScreenState extends State<BilibiliSettingsScreen> {
  void _toggleSetting(String key, bool value) {
    unawaited(AppHaptics.selectionClick(_settings));
    unawaited(_settings.updateSetting<bool>(key, value));
  }

  late final SettingsService _settings = widget.settings ?? SettingsService();
  late final BilibiliHistoryService _history =
      widget.history ?? BilibiliHistoryService.instance;
  late final BilibiliCacheManager? _cache =
      widget.cacheManager ?? BilibiliCacheManager.instance;

  Future<BilibiliCacheUsage>? _usage;
  bool _clearingCache = false;
  String? _notice;

  @override
  void initState() {
    super.initState();
    unawaited(_history.ensureLoaded());
    _cache?.addListener(_refreshUsage);
    _usage = _cache?.usage();
  }

  @override
  void dispose() {
    _cache?.removeListener(_refreshUsage);
    super.dispose();
  }

  void _refreshUsage() {
    if (!mounted) return;
    final usage = _cache?.usage();
    setState(() {
      _usage = usage;
    });
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String action,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          DesktopButtonClickRegion(
            child: TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
          ),
          DesktopButtonClickRegion(
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppTokens.brandBilibili,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(action),
            ),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _clearSearchHistory() async {
    final ok = await _confirm(
      title: '清空搜索历史',
      message: '搜索框下保存的关键词会全部删除。',
      action: '清空',
    );
    if (!ok) return;
    await _history.clearSearch();
    if (mounted) setState(() => _notice = null);
  }

  Future<void> _clearWatchHistory() async {
    final ok = await _confirm(
      title: '清空观看历史',
      message: '只会删除观看历史记录，媒体库里的卡片不受影响。',
      action: '清空',
    );
    if (!ok) return;
    await _history.clearWatch();
    if (mounted) setState(() => _notice = null);
  }

  Future<void> _setCacheLimit(int bytes) async {
    await _settings.updateSetting<int>('bilibiliCacheLimitBytes', bytes);
    // The manager trims to the new cap on its own; show the result.
    final cache = _cache;
    if (cache != null) {
      await cache.trimNow();
      _refreshUsage();
    }
  }

  Future<void> _clearCache() async {
    final cache = _cache;
    if (cache == null || _clearingCache) return;
    if (cache.isPlaying()) {
      setState(() => _notice = '正在播放，请先停止后再清理');
      return;
    }
    final ok = await _confirm(
      title: '清理在线缓存',
      message: '在线播放留在本机的缓存会被删除，之后播放时会重新加载。已下载的视频、导入的媒体和卡片都不受影响。',
      action: '清理',
    );
    if (!ok || !mounted) return;
    setState(() => _clearingCache = true);
    try {
      final outcome = await cache.clearAll();
      if (mounted) {
        setState(() {
          _notice = outcome == BilibiliCacheClearOutcome.refusedWhilePlaying
              ? '正在播放，请先停止后再清理'
              : null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _notice = '清理失败，请稍后再试');
    } finally {
      if (mounted) setState(() => _clearingCache = false);
      _refreshUsage();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_settings, _history]),
      builder: (context, _) => BilibiliQuietTap(
        child: Scaffold(
          backgroundColor: AppTokens.bgBase,
          appBar: AppBar(
            backgroundColor: AppTokens.bgBase,
            foregroundColor: AppTokens.text1,
            elevation: 0,
            title: const Text('B 站设置', style: TextStyle(fontSize: 16)),
          ),
          body: SafeArea(
            top: false,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
              children: [
                if (_notice case final notice?)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      notice,
                      key: const ValueKey('bilibili-settings-notice'),
                      style: const TextStyle(
                        color: AppTokens.danger,
                        fontSize: 12,
                      ),
                    ),
                  ),
                const _SectionTitle('播放'),
                _card(
                  SwitchListTile.adaptive(
                    key: const ValueKey('bilibili-setting-auto-import'),
                    value: _settings.bilibiliAutoImportOnPlay,
                    activeThumbColor: AppTokens.brandBilibili,
                    contentPadding: _tilePadding,
                    title: const Text('播放时自动导入媒体库', style: _titleStyle),
                    subtitle: const _Description(
                      '关闭时只看不入库：从 B 站页播放的视频不进媒体库，关掉播放后自动清理，进度记在观看历史里。'
                      '开启后播放即按 BV 和分P 复用或新建媒体库卡片。',
                    ),
                    onChanged: (value) =>
                        _toggleSetting('bilibiliAutoImportOnPlay', value),
                  ),
                ),
                const _SectionTitle('历史记录'),
                _card(
                  Column(
                    children: [
                      SwitchListTile.adaptive(
                        key: const ValueKey('bilibili-setting-search-history'),
                        value: _settings.bilibiliRecordSearchHistory,
                        activeThumbColor: AppTokens.brandBilibili,
                        contentPadding: _tilePadding,
                        title: const Text('记录搜索历史', style: _titleStyle),
                        subtitle: const _Description(
                          '关闭后不再记录新的关键词，搜索框下也不再显示；已有记录保留，可在下方清空。',
                        ),
                        onChanged: (value) => _toggleSetting(
                          'bilibiliRecordSearchHistory',
                          value,
                        ),
                      ),
                      _actionTile(
                        key: const ValueKey('bilibili-setting-clear-search'),
                        title: '清空搜索历史',
                        detail: '${_history.searchHistory.length} 条',
                        onTap: _history.searchHistory.isEmpty
                            ? null
                            : _clearSearchHistory,
                      ),
                      const Divider(height: 1, color: AppTokens.lineSubtle),
                      SwitchListTile.adaptive(
                        key: const ValueKey('bilibili-setting-watch-history'),
                        value: _settings.bilibiliRecordWatchHistory,
                        activeThumbColor: AppTokens.brandBilibili,
                        contentPadding: _tilePadding,
                        title: const Text('记录观看历史', style: _titleStyle),
                        subtitle: const _Description(
                          '关闭后从 B 站页播放不再记录观看和进度，也不从上次的位置接着播；已有记录保留。',
                        ),
                        onChanged: (value) =>
                            _toggleSetting('bilibiliRecordWatchHistory', value),
                      ),
                      _actionTile(
                        key: const ValueKey('bilibili-setting-clear-watch'),
                        title: '清空观看历史',
                        detail: '${_history.watchHistory.length} 条',
                        onTap: _history.watchHistory.isEmpty
                            ? null
                            : _clearWatchHistory,
                      ),
                    ],
                  ),
                ),
                if (_cache != null) ...[
                  const _SectionTitle('在线缓存'),
                  _card(_buildCacheSection()),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCacheSection() {
    final limit = _settings.bilibiliCacheLimitBytes;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('在线缓存上限', style: _titleStyle),
          const SizedBox(height: 6),
          FutureBuilder<BilibiliCacheUsage>(
            future: _usage,
            builder: (context, snapshot) {
              final used = snapshot.data;
              final text = used == null
                  ? '正在统计占用…'
                  : '当前占用 ${formatBilibiliCacheSize(used.bytes)}'
                        ' / 上限 ${formatBilibiliCacheSize(limit)}';
              return Text(
                text,
                key: const ValueKey('bilibili-setting-cache-usage'),
                style: const TextStyle(color: AppTokens.text2, fontSize: 12),
              );
            },
          ),
          const SizedBox(height: 4),
          const _Description(
            '在线播放时留在本机的视频片段、转写音频和本地素材。超过上限时自动从最久没用的开始删除，正在播放的不删；'
            '已下载的视频、导入的媒体、卡片和登录信息不受影响。',
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in SettingsService.bilibiliCacheLimitOptions)
                ChoiceChip(
                  key: ValueKey('bilibili-cache-limit-$option'),
                  label: Text(formatBilibiliCacheSize(option)),
                  selected: option == limit,
                  showCheckmark: false,
                  backgroundColor: AppTokens.bgRaised,
                  selectedColor: AppTokens.brandBilibili.withValues(
                    alpha: 0.22,
                  ),
                  side: BorderSide(
                    color: option == limit
                        ? AppTokens.brandBilibili
                        : AppTokens.lineSubtle,
                  ),
                  labelStyle: TextStyle(
                    color: option == limit
                        ? AppTokens.brandBilibili
                        : AppTokens.text2,
                    fontSize: 13,
                  ),
                  onSelected: (_) => unawaited(_setCacheLimit(option)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: DesktopButtonClickRegion(
              child: OutlinedButton.icon(
                key: const ValueKey('bilibili-setting-clear-cache'),
                onPressed: _clearingCache ? null : _clearCache,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTokens.text1,
                  side: const BorderSide(color: AppTokens.text4),
                ),
                icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                label: StableWidthLabel(
                  _clearingCache ? '正在清理…' : '一键清理缓存',
                  variants: const ['一键清理缓存', '正在清理…'],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionTile({
    required Key key,
    required String title,
    required String detail,
    required VoidCallback? onTap,
  }) {
    return ListTile(
      key: key,
      contentPadding: _tilePadding,
      enabled: onTap != null,
      title: Text(
        title,
        style: TextStyle(
          color: onTap == null ? AppTokens.text3 : AppTokens.text1,
          fontSize: 15,
        ),
      ),
      trailing: Text(
        detail,
        style: const TextStyle(color: AppTokens.text3, fontSize: 12),
      ),
      onTap: onTap,
    );
  }

  Widget _card(Widget child) {
    return Material(
      color: AppTokens.bgCard,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

const EdgeInsets _tilePadding = EdgeInsets.symmetric(
  horizontal: 14,
  vertical: 4,
);

const TextStyle _titleStyle = TextStyle(color: AppTokens.text1, fontSize: 15);

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Text(
        text,
        style: const TextStyle(
          color: AppTokens.text2,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _Description extends StatelessWidget {
  const _Description(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        text,
        style: const TextStyle(
          color: AppTokens.text2,
          fontSize: 12,
          height: 1.4,
        ),
      ),
    );
  }
}
