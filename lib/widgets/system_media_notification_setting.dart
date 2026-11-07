import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/app_haptics.dart';
import '../services/settings_service.dart';
import '../services/system_media_session_service.dart';
import '../theme/app_tokens.dart';
import 'operation_status.dart';
import 'media_library_settings_controls.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class SystemMediaNotificationSetting extends StatefulWidget {
  const SystemMediaNotificationSetting({
    super.key,
    required this.settings,
    this.session,
    this.flat = false,
  });
  final SettingsService settings;
  final SystemMediaSessionService? session;
  final bool flat;
  @override
  State<SystemMediaNotificationSetting> createState() =>
      _SystemMediaNotificationSettingState();
}

class _SystemMediaNotificationSettingState
    extends State<SystemMediaNotificationSetting>
    with WidgetsBindingObserver {
  SystemMediaNotificationAvailability? _availability;
  bool _saving = false;
  bool _nativeRetrying = false;
  SystemMediaSessionService get _session =>
      widget.session ?? SystemMediaSessionService.instance;
  String? _error;
  Object? _details;
  Future<void> Function()? _retryAction;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final value = await SystemMediaNotificationGate.readAvailability();
    if (mounted) setState(() => _availability = value);
  }

  Future<void> _change(bool value) async {
    if (_saving || _nativeRetrying) return;
    setState(() {
      _saving = true;
      _error = null;
      _details = null;
    });
    try {
      await widget.settings.updateSetting('showSystemMediaNotification', value);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '媒体控件设置未能保存，请重试。';
          _details = error;
          _retryAction = () => _change(value);
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _retryNative() async {
    if (_saving || _nativeRetrying) return;
    setState(() {
      _nativeRetrying = true;
      _error = null;
      _details = null;
    });
    try {
      await _session.retryNotificationVisibility();
    } catch (error) {
      if (mounted && _session.notificationFailure.value == null) {
        setState(() {
          _error = '系统播放控件未能更新，请稍后重试。';
          _details = error;
          _retryAction = _retryNative;
        });
      }
    } finally {
      if (mounted) setState(() => _nativeRetrying = false);
    }
  }

  Future<void> _openSettings() async {
    final opened = await SystemMediaNotificationGate.openSystemSettings();
    if (opened && mounted) {
      setState(() {
        _error = null;
        _details = null;
      });
    }
    if (!opened && mounted) {
      setState(() {
        _error = '无法打开系统通知设置，请在系统设置中找到本应用的通知选项。';
        _retryAction = _openSettings;
      });
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.settings,
      _session.notificationFailure,
    ]),
    builder: (context, _) {
      final blocked = _availability?.channelBlocked == true;
      final nativeFailure = _session.notificationFailure.value;
      final ios = defaultTargetPlatform == TargetPlatform.iOS;
      final hasIssue =
          blocked || _error != null || nativeFailure != null || _nativeRetrying;
      return Material(
        color: widget.flat ? Colors.transparent : AppTokens.bgCard,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: MediaLibrarySettingsSwitchTile(
          key: const ValueKey('showSystemMediaNotification'),
          value: widget.settings.showSystemMediaNotification,
          onChanged: _saving || _nativeRetrying || blocked ? null : _change,
          title: Text(ios ? '显示锁屏与控制中心播放控件' : '显示媒体通知'),
          description: Text(ios ? '在锁屏和控制中心显示播放控件。' : '在通知栏和锁屏显示播放控件。'),
          feedback: hasIssue
              ? OperationStatus(
                  title:
                      _error ??
                      (_nativeRetrying
                          ? '正在重试系统播放控件…'
                          : blocked
                          ? '媒体播放通知已被系统关闭'
                          : nativeFailure!.requestedVisible
                          ? '系统播放控件未能显示'
                          : '系统播放控件未能隐藏'),
                  message: blocked ? '请在系统设置中开启媒体播放通知。' : null,
                  kind: _nativeRetrying
                      ? OperationStatusKind.progress
                      : OperationStatusKind.error,
                  details: _details?.toString() ?? nativeFailure?.diagnostic,
                  actions: [
                    if (nativeFailure != null && !blocked)
                      DesktopButtonClickRegion(
                        child: TextButton(
                          key: const ValueKey(
                            'retry-system-media-notification',
                          ),
                          onPressed: AppHaptics.wrap(
                            _nativeRetrying ? null : _retryNative,
                            light: true,
                          ),
                          child: const Text('重试'),
                        ),
                      ),
                    if (_error != null && nativeFailure == null && !blocked)
                      DesktopButtonClickRegion(
                        child: TextButton(
                          onPressed: AppHaptics.wrap(
                            _saving ? null : _retryAction,
                            light: true,
                          ),
                          child: const Text('重试'),
                        ),
                      ),
                    if (_availability?.canOpenSystemSettings == true)
                      DesktopButtonClickRegion(
                        child: TextButton(
                          onPressed: AppHaptics.wrap(_openSettings, light: true),
                          child: const Text('系统设置'),
                        ),
                      ),
                    if (blocked)
                      DesktopButtonClickRegion(
                        child: TextButton(
                          onPressed: AppHaptics.wrap(_refresh, light: true),
                          child: const Text('重新检查'),
                        ),
                      ),
                  ],
                )
              : null,
        ),
      );
    },
  );
}
