import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/media_library_root_entry.dart';
import '../../models/import_card_placement.dart';
import '../../services/settings_service.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/capsule_selector.dart';
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
        child: Scaffold(
          backgroundColor: AppTokens.bgBase,
          appBar: AppBar(
            backgroundColor: AppTokens.bgBase,
            surfaceTintColor: Colors.transparent,
            scrolledUnderElevation: 0,
            title: Text('使用前设置', style: const TextStyle(fontSize: 17)),
            leading: DesktopButtonClickRegion(
              child: IconButton(
                key: const ValueKey('onboarding-close'),
                tooltip: '关闭设置',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            actions: [
              DesktopButtonClickRegion(
                child: TextButton(
                  key: const ValueKey('onboarding-done'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('完成'),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: ListenableBuilder(
                  listenable: widget.settings,
                  builder: (context, _) {
                    final settings = widget.settings;
                    return ListView(
                      key: const PageStorageKey('onboarding-settings-list'),
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      children: [
                        if (_error != null) ...[
                          OperationStatus(
                            title: _error!,
                            kind: OperationStatusKind.error,
                            details: _details?.toString(),
                            actions: [
                              DesktopButtonClickRegion(
                                child: TextButton(
                                  onPressed: _retry,
                                  child: const Text('重试'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                        ],
                        const Text(
                          '以下项目均可跳过，修改后直接生效。',
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.6,
                            color: AppTokens.text2,
                          ),
                        ),
                        _section('网络与服务', [
                          _destination(
                            OnboardingDestination.network,
                            Icons.language_outlined,
                            '网络设置',
                            '按功能选择直连、系统代理或自定义代理。',
                          ),
                        ]),
                        _section('文件导入', [
                          _toggle(
                            'copyImportedMediaToPrivateStorage',
                            '导入时复制媒体到应用私有目录',
                            '开启会多占一份空间；关闭时请保留原文件。仅对新导入生效。',
                            settings.copyImportedMediaToPrivateStorage,
                          ),
                          _destination(
                            OnboardingDestination.importLocation,
                            Icons.folder_outlined,
                            '导入位置与整理',
                            settings.importCardPlacementMode.label,
                          ),
                        ]),
                        _section('播放与启动', [
                          _toggle(
                            'autoPlayOnPageEntry',
                            '进入播放页时自动播放',
                            '关闭后，手动点击播放。',
                            settings.autoPlayOnPageEntry,
                          ),
                          _toggle(
                            'mediaLibraryRestoreLastPage',
                            '打开时回到上次离开的页面',
                            '包括上次打开的文件夹。关闭后可选择固定的启动页面。',
                            settings.mediaLibraryRestoreLastPage,
                          ),
                          if (!settings.mediaLibraryRestoreLastPage)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(
                                16,
                                12,
                                16,
                                16,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const Text(
                                    '启动页面',
                                    style: TextStyle(
                                      color: AppTokens.text1,
                                      fontSize: 15,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  CapsuleDropdownButton<MediaLibraryRootEntry>(
                                    key: const ValueKey(
                                      'onboarding-startup-entry',
                                    ),
                                    isExpanded: true,
                                    value:
                                        MediaLibraryRootEntryX.tryParse(
                                          settings.mediaLibraryStartupEntry,
                                        ) ??
                                        MediaLibraryRootEntry.folders,
                                    items: [
                                      for (final entry
                                          in MediaLibraryRootEntry.values)
                                        DropdownMenuItem(
                                          value: entry,
                                          child: Text(entry.label),
                                        ),
                                    ],
                                    onChanged:
                                        _saving.contains(
                                          'mediaLibraryStartupEntry',
                                        )
                                        ? null
                                        : (entry) {
                                            if (entry != null) {
                                              _update(
                                                'mediaLibraryStartupEntry',
                                                entry.storageValue,
                                              );
                                            }
                                          },
                                  ),
                                ],
                              ),
                            ),
                        ]),
                        _section('字幕服务（可选）', [
                          _destination(
                            OnboardingDestination.subtitleServices,
                            Icons.subtitles_outlined,
                            '字幕识别与翻译',
                            '在模型中心配置在线服务或本地模型。',
                          ),
                        ]),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _section(String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 8),
          child: Text(
            title,
            style: const TextStyle(color: AppTokens.text2, fontSize: 13),
          ),
        ),
        Material(
          color: AppTokens.bgCard,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0)
                  const Divider(height: 1, color: AppTokens.lineSubtle),
                children[i],
              ],
            ],
          ),
        ),
      ],
    ),
  );

  Widget _toggle(String key, String title, String subtitle, bool value) =>
      SwitchListTile.adaptive(
        key: ValueKey(key),
        value: value,
        activeThumbColor: Colors.blueAccent,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        title: Text(
          title,
          style: const TextStyle(color: AppTokens.text1, fontSize: 15),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            subtitle,
            style: const TextStyle(
              color: AppTokens.text2,
              fontSize: 12,
              height: 1.5,
            ),
          ),
        ),
        onChanged: _saving.contains(key)
            ? null
            : (value) => _update(key, value),
      );

  Widget _destination(
    OnboardingDestination destination,
    IconData icon,
    String title,
    String subtitle,
  ) => ListTile(
    key: ValueKey('onboarding-${destination.name}'),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    leading: Icon(icon, color: AppTokens.text2, size: 22),
    title: Text(
      title,
      style: const TextStyle(color: AppTokens.text1, fontSize: 15),
    ),
    subtitle: Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        subtitle,
        style: const TextStyle(
          color: AppTokens.text2,
          fontSize: 12,
          height: 1.5,
        ),
      ),
    ),
    trailing: _opening == destination
        ? Icon(
            Icons.hourglass_empty,
            size: 20,
            color: AppTokens.text2,
            semanticLabel: '正在打开$title',
          )
        : const Icon(Icons.chevron_right, color: AppTokens.text2, size: 20),
    onTap: _opening == null ? () => _open(destination) : null,
  );
}
