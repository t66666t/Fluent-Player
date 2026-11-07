import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../services/app_haptics.dart';
import '../services/app_storage_service.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import '../services/storage_migration_coordinator.dart';
import 'dialog_keyboard_viewport.dart';
import 'operation_status.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

Future<void> showAppStorageSettingsDialog(BuildContext context) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          const DialogKeyboardViewport(child: _StorageSettingsDialog()),
    );

class _StorageSettingsDialog extends StatefulWidget {
  const _StorageSettingsDialog();
  @override
  State<_StorageSettingsDialog> createState() => _StorageSettingsDialogState();
}

class _StorageSettingsDialogState extends State<_StorageSettingsDialog> {
  String? _selected;
  String? _message;
  Object? _error;
  bool _busy = false, _restart = false;
  Future<void> _run({required bool organize}) async {
    final storage = AppStorageService.instance;
    setState(() {
      _busy = true;
      _error = null;
      _message = '正在检查目录并保存任务…';
    });
    try {
      await context.read<LibraryService>().saveProgress();
      final target = Directory(_selected ?? storage.dataDirectory.path);
      await StorageMigrationCoordinator(
        storage,
      ).migrate(target, organize: organize);
      if (!mounted) return;
      await context.read<SettingsService>().setLargeDataRootPath(target.path);
      if (!mounted) return;
      setState(() {
        _restart = true;
        _message = '重启后使用新位置，原文件保留。';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _message = e is StorageUnavailableException
            ? e.message
            : operationErrorSummary(e, fallback: '无法完成目录整理，请检查存储位置后重试。原文件仍保留。');
        _restart = StorageMigrationCoordinator.maintenance;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final storage = AppStorageService.instance;
    if (!storage.desktop) {
      return AlertDialog(
        title: const Text('大文件数据目录'),
        content: SizedBox(
          width: 540,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('存储位置由系统管理。手机和平板无需手动迁移或整理数据目录。'),
                const SizedBox(height: 16),
                const Text('当前目录'),
                const SizedBox(height: 8),
                SelectableText(storage.dataDirectory.path),
              ],
            ),
          ),
        ),
        actions: [
          DesktopButtonClickRegion(
            child: TextButton(
              onPressed: AppHaptics.wrap(
                () => Navigator.pop(context),
                light: true,
              ),
              child: const Text('关闭'),
            ),
          ),
        ],
      );
    }
    return PopScope(
      canPop: !_busy && !_restart,
      child: AlertDialog(
        title: const Text('大文件数据目录'),
        content: SizedBox(
          width: 540,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('当前目录'),
                const SizedBox(height: 6),
                SelectableText(storage.dataDirectory.path),
                const SizedBox(height: 16),
                const Text('新下载按来源保存。旧文件和任务继续使用已登记的位置；整理会复制并校验文件，原件保留。'),
                if (_selected != null) ...[
                  const SizedBox(height: 12),
                  Text('目标：$_selected'),
                ],
                if (_busy || _error != null) ...[
                  const SizedBox(height: 16),
                  OperationStatus(
                    title: _busy
                        ? (_restart ? '正在重新打开应用…' : '正在整理数据目录…')
                        : _message ?? '无法完成目录整理，请重试。',
                    kind: _busy
                        ? OperationStatusKind.progress
                        : OperationStatusKind.error,
                    details: _error == null
                        ? null
                        : safeOperationDiagnostic(_error!),
                  ),
                ] else if (_restart) ...[
                  const SizedBox(height: 16),
                  const Text('重启后使用新位置，原文件保留。'),
                ],
              ],
            ),
          ),
        ),
        actions: _restart
            ? [
                DesktopButtonClickRegion(
                  child: FilledButton(
                    onPressed: AppHaptics.wrap(
                      _busy
                          ? null
                          : () async {
                              setState(() => _busy = true);
                              try {
                                await restartAfterStorageChange();
                              } catch (error) {
                                if (mounted) {
                                  setState(() {
                                    _error = error;
                                    _message =
                                        '无法自动重新打开应用。请关闭应用后手动重新打开，数据和原文件已保留。';
                                  });
                                }
                              } finally {
                                if (mounted) setState(() => _busy = false);
                              }
                            },
                      light: true,
                    ),
                    child: const Text('重启并重新加载'),
                  ),
                ),
              ]
            : [
                DesktopButtonClickRegion(
                  child: TextButton(
                    onPressed: AppHaptics.wrap(
                      _busy ? null : () => Navigator.pop(context),
                      light: true,
                    ),
                    child: const Text('关闭'),
                  ),
                ),
                DesktopButtonClickRegion(
                  child: TextButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            AppHaptics.pulse(light: true);
                            final selected = await FilePicker.platform
                                .getDirectoryPath(dialogTitle: '选择数据目录');
                            if (selected != null && mounted) {
                              setState(() => _selected = selected);
                            }
                          },
                    child: const Text('选择目录'),
                  ),
                ),
                DesktopButtonClickRegion(
                  child: TextButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            AppHaptics.pulse(light: true);
                            final dir = await storage.defaultDataDirectory();
                            if (mounted) setState(() => _selected = dir.path);
                          },
                    child: const Text('使用默认位置'),
                  ),
                ),
                DesktopButtonClickRegion(
                  child: OutlinedButton(
                    onPressed: AppHaptics.wrap(
                      _busy ? null : () => _run(organize: true),
                      light: true,
                    ),
                    child: const Text('整理旧文件'),
                  ),
                ),
                if (_selected != null &&
                    !AppStorageService.samePath(
                      _selected!,
                      storage.dataDirectory.path,
                    ))
                  DesktopButtonClickRegion(
                    child: FilledButton(
                      onPressed: AppHaptics.wrap(
                        _busy ? null : () => _run(organize: false),
                        light: true,
                      ),
                      child: const Text('迁移到所选目录'),
                    ),
                  ),
              ],
      ),
    );
  }
}

Future<void> restartAfterStorageChange() async {
  if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) return;
  // Persistent participants have already flushed and closed. Launch only the
  // application executable, passing no shell command or user-supplied arguments.
  await Process.start(
    Platform.resolvedExecutable,
    const [],
    mode: ProcessStartMode.detached,
    workingDirectory: p.dirname(Platform.resolvedExecutable),
  );
  exit(0);
}

class StorageRecoveryScreen extends StatefulWidget {
  const StorageRecoveryScreen({
    super.key,
    required this.error,
    required this.onRetry,
  });
  final Object error;
  final Future<void> Function() onRetry;
  @override
  State<StorageRecoveryScreen> createState() => _StorageRecoveryScreenState();
}

class _StorageRecoveryScreenState extends State<StorageRecoveryScreen> {
  String? _error;
  bool _busy = false;
  final _path = TextEditingController();

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<void> _recover(String selected) async {
    if (_busy || selected.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final directory = Directory(selected.trim());
      if (!p.isAbsolute(directory.path)) {
        throw const StorageUnavailableException('请输入完整的绝对目录路径');
      }
      await AppStorageService.instance.recoverWithRoot(directory);
      await SettingsService().setLargeDataRootPath(directory.path);
      await widget.onRetry();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pick() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    String? selected;
    try {
      selected = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择原有数据目录',
      );
    } catch (e) {
      debugPrint('Storage directory chooser failed: $e');
      if (mounted) setState(() => _error = '无法打开目录选择窗口，请在下方输入原目录的完整路径。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && selected != null) await _recover(selected);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '需要恢复数据目录',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 16),
                  SelectableText(_error ?? '${widget.error}'),
                  const SizedBox(height: 12),
                  const Text('原文件和记录已保留。连接原磁盘后重试，或选择原有的数据目录。'),
                  if (widget.error case StorageSelectionRequiredException(
                    :final directories,
                  ))
                    for (final directory in directories)
                      DesktopButtonClickRegion(
                        child: TextButton.icon(
                          onPressed: _busy
                              ? null
                              : AppHaptics.wrap(
                                  () => _recover(directory.path),
                                  light: true,
                                ),
                          icon: const Icon(Icons.folder_open),
                          label: Text(directory.path),
                        ),
                      ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _path,
                    enabled: !_busy,
                    decoration: const InputDecoration(labelText: '原数据目录的完整路径'),
                    onSubmitted: _recover,
                  ),
                  DesktopButtonClickRegion(
                    child: TextButton(
                      onPressed: AppHaptics.wrap(
                        _busy ? null : () => _recover(_path.text),
                        light: true,
                      ),
                      child: const Text('使用此目录'),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      DesktopButtonClickRegion(
                        child: FilledButton(
                          onPressed: _busy
                              ? null
                              : () async {
                                  AppHaptics.pulse(light: true);
                                  setState(() => _busy = true);
                                  try {
                                    await widget.onRetry();
                                  } catch (e) {
                                    if (mounted) setState(() => _error = '$e');
                                  } finally {
                                    if (mounted) setState(() => _busy = false);
                                  }
                                },
                          child: const Text('重新读取'),
                        ),
                      ),
                      if (Platform.isWindows ||
                          Platform.isMacOS ||
                          Platform.isLinux)
                        DesktopButtonClickRegion(
                          child: OutlinedButton(
                            onPressed: AppHaptics.wrap(
                              _busy ? null : _pick,
                              light: true,
                            ),
                            child: const Text('选择原目录'),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
