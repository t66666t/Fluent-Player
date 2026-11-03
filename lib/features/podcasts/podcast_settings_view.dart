part of 'podcast_settings_page.dart';

class _PodcastSettingsPageState extends State<PodcastSettingsPage>
    with WidgetsBindingObserver {
  String? _status;
  OperationStatusKind _statusKind = OperationStatusKind.info;
  bool _showPermissionAction = false;
  bool _busy = false;
  String? _storageStatusCategory;
  Future<void> Function()? _retryOperation;

  Future<void> _retry() async {
    final operation = _retryOperation;
    if (_busy || operation == null) return;
    setState(() => _status = null);
    try {
      await operation();
    } catch (_) {
      if (mounted) {
        setState(() {
          _status = '操作未完成，请重试。';
          _statusKind = OperationStatusKind.error;
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _showPermissionAction) {
      _refreshNotificationPermission();
    }
  }

  Future<void> _refreshNotificationPermission() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      final status = await permissions.Permission.notification.status;
      if (mounted && status.isGranted) {
        setState(() {
          _showPermissionAction = false;
          _statusKind = OperationStatusKind.info;
          _status = null;
          _retryOperation = null;
        });
      }
    } catch (_) {
      // Keep the recoverable explanation when the platform cannot be read.
    }
  }

  String _group = 'updates';
  static const _sections = <String, (String, IconData, String)>{
    'updates': ('更新', Icons.sync_rounded, '选择频道更新的时机与节奏。'),
    'notifications': (
      '提醒',
      Icons.notifications_none_rounded,
      '只在你希望的时候，提醒新节目的到来。',
    ),
    'playback': (
      '播放',
      Icons.play_circle_outline_rounded,
      '把倍速、跳转和连续播放调整到习惯的方式。',
    ),
    'cache': ('在线播放缓存', Icons.layers_outlined, '重复收听时复用已播放的音视频数据。'),
    'downloads': (
      '离线下载',
      Icons.download_for_offline_outlined,
      '管理自动下载、网络条件与保留规则。',
    ),
    'display': ('页面展示', Icons.space_dashboard_outlined, '调整节目列表与频道页面的呈现。'),
    'storage': ('存储空间', Icons.dns_outlined, '分别查看播放缓存与完整下载的占用。'),
    'advanced': ('搜索与备份', Icons.manage_search_rounded, '管理可选搜索源，保存订阅和收听记录。'),
  };

  Future<void> _change(String key, Object? value) async {
    if (_busy) return;
    setState(() {
      _status = null;
      _retryOperation = null;
      _storageStatusCategory = null;
      _showPermissionAction = false;
    });
    try {
      await PodcastRuntime.instance.setting(widget.channelId, key, value);
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) {
        setState(() {
          _status = error is FormatException ? error.message : '暂时无法保存设置，请重试。';
          _statusKind = OperationStatusKind.error;
          _retryOperation = () => _change(key, value);
          _showPermissionAction =
              key == 'notify' &&
              value == true &&
              (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);
        });
      }
    }
  }

  Future<bool> _confirm(String title, String message, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          title: Text(title, style: const TextStyle(fontSize: 16)),
          content: Text(message),
          actions: [
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
            ),
            DesktopButtonClickRegion(
              child: FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(action),
              ),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _resetOverrides() async {
    if (_busy || widget.channelId == null) return;
    _storageStatusCategory = null;
    final runtime = PodcastRuntime.instance;
    final count = runtime.store.overrides(widget.channelId!).length;
    if (count == 0) {
      setState(() {
        _status = null;
        _retryOperation = null;
        _statusKind = OperationStatusKind.info;
      });
      return;
    }
    setState(() => _busy = true);
    try {
      if (!await _confirm('恢复频道设置', '将此频道的 $count 项独立设置恢复为全局设置？', '恢复继承') ||
          !mounted) {
        return;
      }
      runtime.resetOverrides(widget.channelId!);
      setState(() {
        _showPermissionAction = false;
        _status = null;
        _retryOperation = null;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _status = '未能恢复频道设置，请重试。';
          _retryOperation = _resetOverrides;
          _statusKind = OperationStatusKind.error;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearPartialDownloads(PodcastRuntime runtime) async {
    if (_busy) return;
    final tasks = runtime.controller.downloads
        .where(
          (task) =>
              task.status.name != 'completed' &&
              (widget.channelId == null ||
                  runtime.store.episode(task.episodeId)?.channelId ==
                      widget.channelId),
        )
        .toList();
    if (tasks.isEmpty) {
      setState(() {
        _storageStatusCategory = 'partial';
        _status = null;
        _retryOperation = null;
        _statusKind = OperationStatusKind.info;
      });
      return;
    }
    final bytes = runtime.controller.mediaStore.storageBytes(
      'partial',
      channelId: widget.channelId,
    );
    setState(() => _busy = true);
    try {
      if (!await _confirm(
            '放弃未完成下载',
            '取消 ${tasks.length} 项并删除 ${podcastSize(bytes)} 下载分段，下次将从头下载。',
            '放弃并清理',
          ) ||
          !mounted) {
        return;
      }
      var failed = 0;
      setState(() {
        _showPermissionAction = false;
        _storageStatusCategory = 'partial';
        _statusKind = OperationStatusKind.progress;
        _status = '正在清理 ${tasks.length} 个未完成下载…';
      });
      for (final task in tasks) {
        try {
          await runtime.controller.cancel(
            task.episodeId,
            removeFile: true,
            preserveCompleted: true,
          );
        } catch (_) {
          failed++;
        }
      }
      if (mounted) {
        setState(() {
          _status = failed > 0 ? '有 $failed 个下载未能清理，请停止使用后重试。' : null;
          _retryOperation = failed > 0
              ? () => _clearPartialDownloads(runtime)
              : null;
          _statusKind = OperationStatusKind.error;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => PodcastPageShortcuts(
    child: PodcastTypography(
      child: Scaffold(
        backgroundColor: AppTokens.bgBase,
        appBar: AppBar(
          backgroundColor: AppTokens.bgBase,
          surfaceTintColor: Colors.transparent,
          title: Text(
            widget.channelId == null ? '播客设置' : '频道独立设置',
            style: PodcastType.label.copyWith(fontSize: 16),
          ),
          actions: [
            if (widget.channelId != null)
              DesktopButtonClickRegion(
                child: IconButton(
                  tooltip: '全部恢复继承',
                  icon: const Icon(Icons.restart_alt_rounded, size: 21),
                  onPressed: _busy ? null : _resetOverrides,
                ),
              ),
            const SizedBox(width: 12),
          ],
        ),
        body: MediaLibrarySafeArea(
          child: PodcastGate(
            builder: (runtime) {
              final effective = runtime.store.effective(widget.channelId);
              final section = _sections[_group]!;
              final definitions = podcastSettings
                  .where(
                    (setting) =>
                        setting.group.name == _group &&
                        (widget.channelId == null || !setting.deviceOnly),
                  )
                  .toList();
              final categories = _sections.entries
                  .where((e) => widget.channelId == null || e.key != 'advanced')
                  .toList();
              Widget content() => ListView(
                key: PageStorageKey(
                  'podcast-settings-$_group-${widget.channelId}',
                ),
                padding: const EdgeInsets.only(bottom: 60),
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: const Color(0x0AFFFFFF),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          section.$2,
                          color: AppTokens.text2,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              section.$1,
                              style: PodcastType.title.copyWith(
                                fontSize: 23,
                                height: 1.3,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              section.$3,
                              style: PodcastType.meta.copyWith(
                                color: AppTokens.text2,
                                fontSize: 12,
                                height: 1.7,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  if (_status != null &&
                      (_statusKind == OperationStatusKind.error ||
                          _statusKind == OperationStatusKind.progress) &&
                      !(_group == 'storage' && _storageStatusCategory != null))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 18),
                      child: OperationStatus(
                        title: _status!,
                        kind: _statusKind,
                        actions: [
                          if (_showPermissionAction) ...[
                            DesktopButtonClickRegion(
                              child: TextButton.icon(
                                onPressed: () async {
                                  try {
                                    final opened = await permissions
                                        .openAppSettings();
                                    if (!opened && mounted) {
                                      setState(
                                        () => _status =
                                            '无法打开系统设置，请在设备的应用设置中允许通知后返回。',
                                      );
                                    }
                                  } catch (_) {
                                    if (mounted) {
                                      setState(
                                        () => _status =
                                            '无法打开系统设置，请在设备的应用设置中允许通知后返回。',
                                      );
                                    }
                                  }
                                },
                                icon: const Icon(Icons.settings_outlined),
                                label: const Text('去系统设置'),
                              ),
                            ),
                          ],
                          if (_retryOperation != null && !_busy)
                            DesktopButtonClickRegion(
                              child: TextButton(
                                onPressed: _retry,
                                child: const Text('重试'),
                              ),
                            ),
                        ],
                      ),
                    ),
                  if (definitions.isNotEmpty)
                    Container(
                      key: ValueKey('podcast-setting-content-$_group'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0x07FFFFFF),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        children: [
                          for (var i = 0; i < definitions.length; i++) ...[
                            if (i > 0)
                              const Divider(
                                height: 1,
                                color: AppTokens.lineSubtle,
                              ),
                            _row(
                              definitions[i],
                              _shownValue(
                                runtime,
                                definitions[i],
                                effective.values,
                              ),
                              _explicit(runtime, definitions[i]),
                            ),
                          ],
                        ],
                      ),
                    ),
                  if (_group == 'storage') _storage(runtime),
                  if (_group == 'advanced') _advanced(runtime),
                  if (['updates', 'downloads', 'cache'].contains(_group))
                    const Padding(
                      padding: EdgeInsets.only(top: 20),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.info_outline_rounded,
                            size: 15,
                            color: AppTokens.text3,
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '后台运行时间由系统安排。部分播放缓存不等于完整离线下载，清理临时缓存会保留完整下载。',
                              style: TextStyle(
                                color: AppTokens.text3,
                                fontSize: 11,
                                height: 1.8,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              );
              Widget category(
                MapEntry<String, (String, IconData, String)> entry, {
                required bool rail,
              }) => DesktopButtonClickRegion(
                child: TextButton(
                  key: ValueKey('podcast-setting-group-${entry.key}'),
                  onPressed: () => setState(() {
                    _group = entry.key;
                    _status = null;
                  }),
                  style: TextButton.styleFrom(
                    foregroundColor: _group == entry.key
                        ? AppTokens.text1
                        : AppTokens.text2,
                    backgroundColor: _group == entry.key
                        ? const Color(0x12FFFFFF)
                        : Colors.transparent,
                    padding: EdgeInsets.symmetric(
                      horizontal: rail ? 14 : 12,
                      vertical: 15,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: rail ? MainAxisSize.max : MainAxisSize.min,
                    children: [
                      Icon(entry.value.$2, size: 18),
                      const SizedBox(width: 10),
                      if (rail)
                        Expanded(
                          child: Text(
                            entry.value.$1,
                            style: const TextStyle(fontSize: 13),
                          ),
                        )
                      else
                        Text(
                          entry.value.$1,
                          style: const TextStyle(fontSize: 12),
                        ),
                      if (rail && _group == entry.key)
                        const Icon(
                          Icons.chevron_right_rounded,
                          size: 16,
                          color: AppTokens.text3,
                        ),
                    ],
                  ),
                ),
              );
              return LayoutBuilder(
                builder: (context, bounds) {
                  final rail =
                      bounds.maxWidth >= 1000 && bounds.maxHeight >= 500;
                  final horizontal = bounds.maxWidth < 600 ? 20.0 : 32.0;
                  return Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1320),
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          horizontal,
                          16,
                          horizontal,
                          0,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (!rail) ...[
                              SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  children: [
                                    for (final entry in categories)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          right: 6,
                                        ),
                                        child: category(entry, rail: false),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 24),
                            ],
                            Expanded(
                              child: rail
                                  ? Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        SizedBox(
                                          width: 220,
                                          child: SingleChildScrollView(
                                            child: Column(
                                              children: [
                                                for (final entry in categories)
                                                  Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                          bottom: 4,
                                                        ),
                                                    child: category(
                                                      entry,
                                                      rail: true,
                                                    ),
                                                  ),
                                                const Padding(
                                                  padding: EdgeInsets.fromLTRB(
                                                    14,
                                                    28,
                                                    14,
                                                    20,
                                                  ),
                                                  child: Text(
                                                    '单项修改即时保存\n继承项目会跟随全局默认',
                                                    style: TextStyle(
                                                      color: AppTokens.text3,
                                                      fontSize: 11,
                                                      height: 1.8,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 30),
                                        const VerticalDivider(
                                          width: 1,
                                          color: AppTokens.lineSubtle,
                                        ),
                                        const SizedBox(width: 34),
                                        Expanded(child: content()),
                                      ],
                                    )
                                  : content(),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
    ),
  );

  Future<void> _clearTemporaryCache(PodcastRuntime runtime) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _showPermissionAction = false;
      _storageStatusCategory = 'cache';
      _status = '正在清理临时缓存…';
      _statusKind = OperationStatusKind.progress;
    });
    try {
      await runtime.controller.mediaStore.clean(
        channelId: widget.channelId,
        allTemporary: true,
      );
      if (mounted) {
        setState(() {
          _status = null;
          _retryOperation = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _status = '部分缓存未能清理，请停止使用后重试。';
          _statusKind = OperationStatusKind.error;
          _retryOperation = () => _clearTemporaryCache(runtime);
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _storage(PodcastRuntime runtime) => Column(
    children: [
      _storageCard(
        runtime,
        '播放缓存',
        'cache',
        Icons.layers_outlined,
        '只保留实际请求过的音视频数据。',
        action: '清理临时缓存',
        onPressed: _busy ? null : () => _clearTemporaryCache(runtime),
      ),
      const SizedBox(height: 12),
      _storageCard(
        runtime,
        '未完成下载',
        'partial',
        Icons.downloading_rounded,
        '保留分段可继续下载；清理会放弃当前进度，下次从头下载。',
        action: '清理未完成下载',
        onPressed: _busy ? null : () => _clearPartialDownloads(runtime),
      ),
      const SizedBox(height: 12),
      _storageCard(
        runtime,
        '完整离线下载',
        'downloads',
        Icons.offline_pin_outlined,
        '完整文件可离线播放，在节目菜单中逐项管理。',
      ),
    ],
  );

  Widget _storageCard(
    PodcastRuntime runtime,
    String label,
    String category,
    IconData icon,
    String description, {
    String? action,
    VoidCallback? onPressed,
  }) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: const Color(0x07FFFFFF),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 19, color: AppTokens.text2),
            const SizedBox(width: 10),
            Text(
              label,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          podcastSize(
            runtime.controller.mediaStore.storageBytes(
              category,
              channelId: widget.channelId,
            ),
          ),
          style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          description,
          style: const TextStyle(
            color: AppTokens.text2,
            fontSize: 12,
            height: 1.6,
          ),
        ),
        if (action != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: DesktopButtonClickRegion(
              child: TextButton.icon(
                onPressed: onPressed,
                icon: const Icon(Icons.cleaning_services_outlined, size: 17),
                label: Text(action, style: const TextStyle(fontSize: 12)),
              ),
            ),
          ),
        if (_storageStatusCategory == category &&
            _status != null &&
            (_statusKind == OperationStatusKind.error ||
                _statusKind == OperationStatusKind.progress)) ...[
          const SizedBox(height: 14),
          OperationStatus(
            title: _status!,
            kind: _statusKind,
            actions:
                _statusKind == OperationStatusKind.error &&
                    _retryOperation != null &&
                    !_busy
                ? [
                    DesktopButtonClickRegion(
                      child: TextButton(
                        onPressed: _retry,
                        child: const Text('重试'),
                      ),
                    ),
                  ]
                : const [],
          ),
        ],
      ],
    ),
  );

  Widget _advanced(PodcastRuntime runtime) => Container(
    decoration: BoxDecoration(
      color: const Color(0x07FFFFFF),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      children: [
        _tool(
          Icons.key_outlined,
          'Podcast Index 搜索凭据',
          '可选搜索源，凭据仅保存在本机',
          () => _credentials(),
        ),
        const Divider(
          height: 1,
          indent: 18,
          endIndent: 18,
          color: AppTokens.lineSubtle,
        ),
        _tool(
          Icons.file_upload_outlined,
          '导出 OPML 订阅列表',
          '在其他播客应用中继续订阅',
          () => savePodcastFile(
            'Fluent-Player-podcasts.opml',
            utf8.encode(runtime.controller.exportOpml()),
          ),
        ),
        const Divider(
          height: 1,
          indent: 18,
          endIndent: 18,
          color: AppTokens.lineSubtle,
        ),
        _tool(
          Icons.inventory_2_outlined,
          '导出订阅、进度与设置',
          '保存完整的个人播客记录',
          () => savePodcastFile(
            'Fluent-Player-podcasts.json',
            utf8.encode(runtime.controller.exportBundle()),
          ),
        ),
      ],
    ),
  );

  Widget _tool(
    IconData icon,
    String title,
    String description,
    Future<void> Function() onTap,
  ) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
    leading: Icon(icon, size: 21, color: AppTokens.text2),
    title: Text(title, style: const TextStyle(fontSize: 13)),
    subtitle: Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        description,
        style: const TextStyle(
          color: AppTokens.text2,
          fontSize: 11,
          height: 1.6,
        ),
      ),
    ),
    trailing: const Icon(
      Icons.chevron_right_rounded,
      size: 18,
      color: AppTokens.text3,
    ),
    onTap: () async {
      try {
        await onTap();
        if (mounted) setState(() => _status = null);
      } catch (_) {
        if (mounted) {
          setState(() {
            _status = '操作未完成，请稍后重试';
            _statusKind = OperationStatusKind.error;
            _retryOperation = onTap;
          });
        }
      }
    },
  );

  Object _shownValue(
    PodcastRuntime runtime,
    PodcastSetting definition,
    Map<String, dynamic> filled,
  ) {
    if (!EffectiveMediaPlaybackPreferences.universalKeys.contains(
      definition.key,
    )) {
      return filled[definition.key] as Object;
    }
    final resolved = definition.key == 'speed'
        ? const EffectiveMediaPlaybackPreferences().speed(
            globalRaw: runtime.store.read('settings', 'global') ?? {},
            channelRaw: widget.channelId == null
                ? null
                : runtime.store.overrides(widget.channelId!),
            software: SoftwarePlaybackDefaults.current(),
          )
        : const EffectiveMediaPlaybackPreferences().continuous(
            globalRaw: runtime.store.read('settings', 'global') ?? {},
            channelRaw: widget.channelId == null
                ? null
                : runtime.store.overrides(widget.channelId!),
            software: SoftwarePlaybackDefaults.current(),
          );
    return resolved.value;
  }

  bool _explicit(PodcastRuntime runtime, PodcastSetting definition) {
    final raw = widget.channelId == null
        ? runtime.store.read('settings', 'global') ?? {}
        : runtime.store.overrides(widget.channelId!);
    return raw.containsKey(definition.key);
  }

  Widget _row(PodcastSetting definition, Object value, bool overridden) {
    final runtime = PodcastRuntime.instance;
    final universal = EffectiveMediaPlaybackPreferences.universalKeys.contains(
      definition.key,
    );
    final resolved = definition.key == 'speed'
        ? const EffectiveMediaPlaybackPreferences().speed(
            globalRaw: runtime.store.read('settings', 'global') ?? {},
            channelRaw: widget.channelId == null
                ? null
                : runtime.store.overrides(widget.channelId!),
            software: SoftwarePlaybackDefaults.current(),
          )
        : const EffectiveMediaPlaybackPreferences().continuous(
            globalRaw: runtime.store.read('settings', 'global') ?? {},
            channelRaw: widget.channelId == null
                ? null
                : runtime.store.overrides(widget.channelId!),
            software: SoftwarePlaybackDefaults.current(),
          );
    final inherited = universal
        ? const EffectiveMediaPlaybackPreferences().caption(
            key: definition.key,
            channelScope: widget.channelId != null,
            explicitHere: overridden,
            resolved: resolved,
            software: SoftwarePlaybackDefaults.current(),
          )
        : widget.channelId == null
        ? definition.description
        : (overridden ? '独立设置' : '继承全局');
    final suffix = definition.description.isEmpty
        ? inherited
        : '$inherited · ${definition.description}';
    final reset = overridden && (widget.channelId != null || universal)
        ? DesktopButtonClickRegion(
            child: IconButton(
              icon: const Icon(Icons.restart_alt, size: 18),
              tooltip: widget.channelId == null ? '恢复跟随软件' : '恢复继承',
              onPressed: () => _change(definition.key, null),
            ),
          )
        : null;
    Widget control;
    if (value is bool) {
      control = Switch(
        value: value,
        onChanged: (v) => _change(definition.key, v),
        activeTrackColor: const Color(0xFF6C839F),
        activeThumbColor: const Color(0xFFF2F3F5),
        inactiveTrackColor: const Color(0x1AFFFFFF),
        inactiveThumbColor: AppTokens.text2,
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      );
    } else if (definition.options != null) {
      final options = definition.options!.entries.toList();
      control = PodcastMenuButton(
        title: definition.label,
        subtitle: widget.channelId == null
            ? '全局默认'
            : overridden
            ? '当前频道独立设置'
            : '当前继承全局',
        tooltip: definition.label,
        label: definition.options![value],
        icon: Icons.unfold_more_rounded,
        actions: [
          for (var index = 0; index < options.length; index++)
            PodcastMenuAction(
              '$index',
              options[index].value,
              Icons.tune_rounded,
              selected: options[index].key == value,
            ),
        ],
        onSelected: (index) =>
            _change(definition.key, options[int.parse(index)].key),
      );
    } else {
      control = DesktopButtonClickRegion(
        child: TextButton(
          style: TextButton.styleFrom(
            foregroundColor: AppTokens.text1,
            backgroundColor: const Color(0x09FFFFFF),
            minimumSize: const Size(60, 42),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          onPressed: () async {
            final editor = TextEditingController(text: value.toString());
            final result = await showDialog<num>(
              context: context,
              builder: (context) => DialogKeyboardViewport(
                child: AlertDialog(
                  backgroundColor: AppTokens.bgRaised,
                  surfaceTintColor: Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  title: Text(definition.label),
                  content: TextField(
                    controller: editor,
                    autofocus: true,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      helperText: '${definition.min} — ${definition.max}',
                    ),
                    onSubmitted: (_) {
                      final n = num.tryParse(editor.text);
                      if (n != null) Navigator.pop(context, n);
                    },
                  ),
                  actions: [
                    DesktopButtonClickRegion(
                      child: TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消'),
                      ),
                    ),
                    DesktopButtonClickRegion(
                      child: FilledButton(
                        onPressed: () {
                          final n = num.tryParse(editor.text);
                          if (n != null && n.isFinite) {
                            Navigator.pop(context, n);
                          }
                        },
                        child: const Text('保存'),
                      ),
                    ),
                  ],
                ),
              ),
            );
            editor.dispose();
            if (result != null) await _change(definition.key, result);
          },
          child: Text(
            value is double ? value.toStringAsFixed(2) : value.toString(),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 13),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow =
              constraints.maxWidth < 480 && definition.options != null;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          definition.label,
                          style: const TextStyle(fontSize: 13, height: 1.6),
                        ),
                        if (suffix.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              suffix,
                              style: const TextStyle(
                                fontSize: 11,
                                color: AppTokens.text3,
                                height: 1.5,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  ?reset,
                  if (!narrow) control,
                ],
              ),
              if (narrow)
                Align(alignment: Alignment.centerRight, child: control),
            ],
          );
        },
      ),
    );
  }

  Future<void> _credentials() async {
    const storage = FlutterSecureStorage();
    final key = TextEditingController(
      text: await storage.read(key: 'podcastIndexKey'),
    );
    final secret = TextEditingController(
      text: await storage.read(key: 'podcastIndexSecret'),
    );
    if (!mounted) {
      key.dispose();
      secret.dispose();
      return;
    }
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => DialogKeyboardViewport(
        child: AlertDialog(
          title: const Text('Podcast Index'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: key,
                  decoration: const InputDecoration(labelText: 'API Key'),
                ),
                TextField(
                  controller: secret,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'API Secret'),
                ),
              ],
            ),
          ),
          actions: [
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
            ),
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('保存'),
              ),
            ),
          ],
        ),
      ),
    );
    if (save == true) {
      await storage.write(key: 'podcastIndexKey', value: key.text.trim());
      await storage.write(key: 'podcastIndexSecret', value: secret.text.trim());
    }
    key.dispose();
    secret.dispose();
  }
}
