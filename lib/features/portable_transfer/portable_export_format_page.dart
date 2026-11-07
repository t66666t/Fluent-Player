import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';

import '../../services/app_haptics.dart';
import '../../services/library_service.dart';
import '../../utils/android_hardware_input_bridge.dart';
import '../../utils/app_toast.dart';
import '../../utils/hardware_keyboard_shortcuts.dart';
import '../../utils/page_shortcut_keys.dart';
import 'portable_export_settings_page.dart';
import 'portable_media_selection.dart';

class PortableExportEscapeScope extends StatefulWidget {
  const PortableExportEscapeScope({super.key, required this.child});

  final Widget child;

  @override
  State<PortableExportEscapeScope> createState() =>
      _PortableExportEscapeScopeState();
}

class _PortableExportEscapeScopeState extends State<PortableExportEscapeScope> {
  final AndroidHardwareKeyDeduplicator _deduplicator =
      AndroidHardwareKeyDeduplicator();

  @override
  void initState() {
    super.initState();
    AndroidHardwareInputBridge.addKeyListener(_onAndroidKey);
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
  }

  @override
  void dispose() {
    AndroidHardwareInputBridge.removeKeyListener(_onAndroidKey);
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    super.dispose();
  }

  void _onAndroidKey(AndroidHardwareKeyMessage message) {
    _handle(
      message.toKeyEvent(),
      fromAndroid: true,
      blocking: message.hasBlockingModifier,
    );
  }

  bool _onHardwareKey(KeyEvent event) =>
      _handle(event) == KeyEventResult.handled;

  KeyEventResult _handle(
    KeyEvent event, {
    bool fromAndroid = false,
    bool? blocking,
  }) {
    if (!supportsNativeHardwareKeyboardShortcuts) {
      return KeyEventResult.ignored;
    }
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return KeyEventResult.ignored;
    if (Platform.isAndroid &&
        !_deduplicator.shouldDispatch(event, fromNativeBridge: fromAndroid)) {
      return KeyEventResult.handled;
    }
    if (blocking ?? hasBlockingKeyboardModifier()) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    Navigator.of(context).maybePop();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class PortableExportFormatPage extends StatefulWidget {
  const PortableExportFormatPage({
    super.key,
    required this.library,
    required this.rootIds,
  });

  final LibraryService library;
  final List<String> rootIds;

  @override
  State<PortableExportFormatPage> createState() =>
      _PortableExportFormatPageState();
}

class _PortableExportFormatPageState extends State<PortableExportFormatPage> {
  late final int _mediaCount;
  late final int _folderCount;
  var _empty = false;

  @override
  void initState() {
    super.initState();
    final inclusion = PortableMediaSelection(
      widget.rootIds,
    ).resolveAgainstLibrary(widget.library);
    _mediaCount = inclusion.mediaCount;
    _folderCount = inclusion.folderCount;
    _empty = inclusion.isEmpty;
    if (_empty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        AppToast.show('没有可导出的媒体', type: AppToastType.error);
        Navigator.of(context).maybePop();
      });
    }
  }

  Future<void> _openSettings(PortableExportFormatChoice choice) async {
    final started = await Navigator.of(context).push<bool>(
      AppMaterialPageRoute<bool>(
        builder: (_) => PortableExportSettingsPage(
          library: widget.library,
          rootIds: widget.rootIds,
          format: choice,
          mediaCount: _mediaCount,
          folderCount: _folderCount,
        ),
      ),
    );
    if (started == true && mounted) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inheritedTheme = Theme.of(context);
    return PortableExportEscapeScope(
      child: Theme(
        data: inheritedTheme.copyWith(
          textTheme: inheritedTheme.textTheme.apply(fontFamily: 'Noto Sans SC'),
          primaryTextTheme: inheritedTheme.primaryTextTheme.apply(
            fontFamily: 'Noto Sans SC',
          ),
        ),
        child: Scaffold(
          backgroundColor: const Color(0xFF0F1014),
          appBar: AppBar(title: const Text('选择导出格式')),
          body: SafeArea(
            top: false,
            child: _empty
                ? const SizedBox.shrink()
                : ListView(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                    children: [
                      Text(
                        _summary(_mediaCount, _folderCount),
                        style: const TextStyle(
                          color: Colors.white54,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 16),
                      _FormatCard(
                        key: const ValueKey('export-format-fluentpack'),
                        icon: Icons.inventory_2_outlined,
                        title: 'Fluent Pack',
                        body: '迁移本地媒体到另一台设备，保留文件夹、字幕、笔记、弹幕和播放信息。',
                        onTap: () => _openSettings(
                          PortableExportFormatChoice.fluentPack,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _FormatCard(
                        key: const ValueKey('export-format-zip'),
                        icon: Icons.folder_zip_outlined,
                        title: 'Zip',
                        body: '按卡片名称整理本地媒体，可内嵌字幕和本地弹幕文件供其他播放器打开。',
                        onTap: () =>
                            _openSettings(PortableExportFormatChoice.zip),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

enum PortableExportFormatChoice { fluentPack, zip }

String _summary(int mediaCount, int folderCount) {
  if (mediaCount == 0) return '已选择 $folderCount 个文件夹';
  if (folderCount == 0) return '已选择 $mediaCount 个媒体';
  return '已选择 $mediaCount 个媒体、$folderCount 个文件夹';
}

class _FormatCard extends StatelessWidget {
  const _FormatCard({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String body;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF181A21),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: AppHaptics.wrap(onTap, light: true),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: const Color(0xFFAEB8FF)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      body,
                      style: const TextStyle(
                        color: Colors.white60,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: Colors.white38),
            ],
          ),
        ),
      ),
    );
  }
}
