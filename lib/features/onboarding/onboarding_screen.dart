import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/media_library_root_entry.dart';
import '../../services/app_haptics.dart';
import '../../services/settings_service.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/media_library_settings_controls.dart';
import '../../widgets/media_library_settings_list.dart';
import '../../widgets/operation_status.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

enum OnboardingDestination {
  network,
  bilibili,
  importLocation,
  subtitleServices,
}

/// Real setup options backed by the same services as the regular settings pages.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.settings,
    required this.openDestination,
    this.preview = false,
  });

  final SettingsService settings;
  final Future<void> Function(BuildContext, OnboardingDestination)
  openDestination;
  final bool preview;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _saving = <String>{};
  OnboardingDestination? _opening;
  String? _error;
  Object? _details;
  VoidCallback? _retry;

  Future<void> _update<T>(String key, T value) async {
    if (_saving.contains(key)) return;
    setState(() {
      _saving.add(key);
      _error = null;
    });
    try {
      await widget.settings.updateSetting(key, value);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '当前选择未能保存，请重试。';
          _details = error;
          _retry = () => _update(key, value);
        });
      }
    } finally {
      if (mounted) setState(() => _saving.remove(key));
    }
  }

  Future<void> _open(OnboardingDestination destination) async {
    if (_opening != null) return;
    setState(() {
      _opening = destination;
      _error = null;
    });
    try {
      await widget.openDestination(context, destination);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '暂时无法打开，请稍后重试。';
          _details = error;
          _retry = () => _open(destination);
        });
      }
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
    },
    child: Actions(
      actions: {
        DismissIntent: CallbackAction<DismissIntent>(
          onInvoke: (_) {
            Navigator.of(context).maybePop();
            return null;
          },
        ),
      },
      child: Focus(
        autofocus: true,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = MediaQuery.sizeOf(context);
            final compact = constraints.maxHeight < 700;
            final inset = size.width < 600 ? 12.0 : 24.0;
            final width = math.min(
              960.0,
              math.max(0.0, size.width - inset * 2),
            );
            final headerInset = (size.width - width) / 2;
            final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
            final columns = width >= 680 * scale ? 2 : 1;
            return Scaffold(
              backgroundColor: AppTokens.bgBase,
              appBar: AppBar(
                backgroundColor: AppTokens.bgBase,
                surfaceTintColor: Colors.transparent,
                scrolledUnderElevation: 0,
                toolbarHeight: compact ? 56 : 64,
                titleSpacing: 0,
                title: const Text('使用前设置'),
                titleTextStyle: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(
                      color: AppTokens.text1,
                      fontSize: 20,
                      fontWeight: FontWeight.w500,
                    ),
                leadingWidth: headerInset + 40,
                leading: Padding(
                  padding: EdgeInsets.only(left: math.max(0, headerInset - 8)),
                  child: DesktopButtonClickRegion(
                    child: IconButton(
                      key: const ValueKey('onboarding-close'),
                      tooltip: '关闭设置',
                      icon: const Icon(Icons.close_rounded, size: 20),
                      onPressed: AppHaptics.wrap(
                        () => Navigator.of(context).pop(),
                        light: true,
                      ),
                    ),
                  ),
                ),
                actions: [
                  Padding(
                    padding: EdgeInsets.only(
                      right: math.max(0, headerInset - 8),
                    ),
                    child: DesktopButtonClickRegion(
                      child: TextButton(
                        key: const ValueKey('onboarding-done'),
                        onPressed: AppHaptics.wrap(
                          () => Navigator.of(context).pop(),
                          light: true,
                        ),
                        child: const Text('完成'),
                      ),
                    ),
                  ),
                ],
              ),
              body: SafeArea(
                top: false,
                child: ListenableBuilder(
                  listenable: widget.settings,
                  builder: (context, _) {
                    final settings = widget.settings;
                    final items = <Widget>[
                      _destination(
                        OnboardingDestination.network,
                        '网络设置',
                        '代理与连接方式',
                        compact,
                      ),

                      _toggle(
                        'copyImportedMediaToPrivateStorage',
                        '导入时保存副本',
                        '新导入存入私有目录，保留原文件',
                        settings.copyImportedMediaToPrivateStorage,
                        compact,
                      ),
                      MediaLibrarySettingsRow(
                        key: const ValueKey('onboarding-local-import-location'),
                        title: const Text('导入位置'),
                        description: const Text('首页导入时放入根目录'),
                        value: const Text('当前文件夹'),
                        compact: compact,
                      ),
                      _toggle(
                        'autoPlayOnPageEntry',
                        '进入播放页时自动播放',
                        '关闭后手动播放',
                        settings.autoPlayOnPageEntry,
                        compact,
                      ),
                      MediaLibrarySettingsSwitchTile(
                        key: const ValueKey('mediaLibraryRestoreLastPage'),
                        title: const Text('恢复上次页面'),
                        description: Text(
                          settings.mediaLibraryRestoreLastPage
                              ? '同时恢复文件夹位置'
                              : '固定启动页面',
                        ),
                        value: settings.mediaLibraryRestoreLastPage,
                        compact: compact,
                        valueControl: settings.mediaLibraryRestoreLastPage
                            ? null
                            : _startup(settings),
                        onChanged:
                            _saving.contains('mediaLibraryRestoreLastPage')
                            ? null
                            : (value) =>
                                  _update('mediaLibraryRestoreLastPage', value),
                      ),
                      _destination(
                        OnboardingDestination.subtitleServices,
                        '字幕识别与翻译',
                        '在线服务与本地模型',
                        compact,
                      ),
                    ];
                    return SingleChildScrollView(
                      key: const PageStorageKey('onboarding-settings-list'),
                      padding: EdgeInsets.fromLTRB(
                        inset,
                        8,
                        inset,
                        compact ? 8 : 16,
                      ),
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: SizedBox(
                          width: width,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (_error != null) ...[
                                OperationStatus(
                                  title: _error!,
                                  kind: OperationStatusKind.error,
                                  details: _details?.toString(),
                                  actions: [
                                    DesktopButtonClickRegion(
                                      child: TextButton(
                                        onPressed: AppHaptics.wrap(
                                          _retry,
                                          light: true,
                                        ),
                                        child: const Text('重试'),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                              ],
                              MediaLibrarySettingsList(
                                items: items,
                                columns: columns,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            );
          },
        ),
      ),
    ),
  );

  Widget _startup(SettingsService settings) {
    const entries = <MediaLibraryRootEntry>[
      MediaLibraryRootEntry.folders,
      MediaLibraryRootEntry.continueLearning,
      MediaLibraryRootEntry.recent,
      MediaLibraryRootEntry.podcasts,
    ];
    final selected = MediaLibraryRootEntryX.tryParse(
      settings.mediaLibraryStartupEntry,
    );
    return MediaLibrarySettingsDropdown<MediaLibraryRootEntry>(
      key: const ValueKey('onboarding-startup-entry'),
      value: entries.contains(selected)
          ? selected!
          : MediaLibraryRootEntry.folders,
      items: [
        for (final entry in entries)
          DropdownMenuItem(value: entry, child: Text(entry.label)),
      ],
      onChanged: _saving.contains('mediaLibraryStartupEntry')
          ? null
          : (entry) {
              if (entry != null) {
                _update('mediaLibraryStartupEntry', entry.storageValue);
              }
            },
    );
  }

  Widget _toggle(
    String key,
    String title,
    String description,
    bool value,
    bool compact,
  ) => MediaLibrarySettingsSwitchTile(
    key: ValueKey(key),
    title: Text(title),
    description: Text(description),
    value: value,
    compact: compact,
    onChanged: _saving.contains(key) ? null : (value) => _update(key, value),
  );

  Widget _destination(
    OnboardingDestination destination,
    String title,
    String description,
    bool compact, {
    Widget? value,
  }) => MediaLibrarySettingsRow(
    key: ValueKey('onboarding-${destination.name}'),
    title: Text(title),
    description: Text(description),
    value: value,
    compact: compact,
    trailing: _opening == destination
        ? Icon(
            Icons.hourglass_empty,
            size: 18,
            color: AppTokens.text2,
            semanticLabel: '正在打开$title',
          )
        : const Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: AppTokens.text2,
          ),
    onTap: _opening == null ? () => _open(destination) : null,
  );
}
