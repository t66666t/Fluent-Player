import 'package:flutter/material.dart';

import '../services/app_haptics.dart';
import '../services/library_service.dart';
import '../theme/app_tokens.dart';
import 'operation_status.dart';
import 'media_library_settings_controls.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class ClearPlaybackHistorySetting extends StatefulWidget {
  const ClearPlaybackHistorySetting({
    super.key,
    this.library,
    this.flat = false,
  });
  final LibraryService? library;
  final bool flat;
  @override
  State<ClearPlaybackHistorySetting> createState() =>
      _ClearPlaybackHistorySettingState();
}

class _ClearPlaybackHistorySettingState
    extends State<ClearPlaybackHistorySetting> {
  bool _busy = false, _cleared = false;
  String? _error;
  Object? _diagnostic;

  Future<void> _clear() async {
    final library = widget.library;
    if (_busy || library == null) return;
    AppHaptics.pulse(light: true);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        title: const Text('清除播放记录？', style: TextStyle(fontSize: 16)),
        content: const SingleChildScrollView(
          child: Text('观看记录和完成状态将被清除，媒体文件保留。'),
        ),
        actions: [
          DesktopButtonClickRegion(
            child: TextButton(
              onPressed: AppHaptics.wrap(
                () => Navigator.pop(dialog, false),
                light: true,
              ),
              child: const Text('取消'),
            ),
          ),
          DesktopButtonClickRegion(
            child: FilledButton(
              onPressed: AppHaptics.wrap(
                () => Navigator.pop(dialog, true),
                light: true,
              ),
              child: const Text('清除'),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _diagnostic = null;
    });
    try {
      final cleared = await library.clearPlaybackHistory();
      if (!mounted) return;
      setState(() {
        _cleared = cleared;
        if (!cleared) _error = '当前记录格式暂不支持清除，请使用兼容版本。';
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = operationErrorSummary(error, fallback: '播放记录未能清除，请重试。');
          _diagnostic = error;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _retrySave() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.library!.retryLibraryPersistence();
      if (mounted && !widget.library!.hasPersistenceFailure) {
        setState(() {
          _error = null;
          _diagnostic = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _diagnostic = error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.library ?? const AlwaysStoppedAnimation(0),
    builder: (context, _) {
      final pending = _cleared && widget.library!.hasPersistenceFailure;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: widget.flat ? Colors.transparent : AppTokens.bgCard,
            borderRadius: BorderRadius.circular(12),
            child: widget.flat
                ? MediaLibrarySettingsRow(
                    key: const ValueKey('clearPlaybackHistory'),
                    title: const Text('清除播放记录'),
                    description: const Text('清除观看记录和完成状态，保留媒体文件。'),
                    enabled: !_busy && widget.library != null,
                    onTap: _clear,
                  )
                : ListTile(
                    key: const ValueKey('clearPlaybackHistory'),
                    title: const Text('清除播放记录'),
                    subtitle: Padding(
                      padding: EdgeInsets.only(top: widget.flat ? 3 : 6),
                      child: Text(
                        '清除观看记录，保留媒体文件。',
                        style: TextStyle(
                          fontSize: widget.flat ? 12 : 13,
                          height: widget.flat ? 1.45 : 1.6,
                          color: widget.flat
                              ? AppTokens.text2
                              : AppTokens.text1,
                        ),
                      ),
                    ),
                    trailing: widget.flat
                        ? const Icon(Icons.chevron_right_rounded)
                        : null,
                    enabled: !_busy && widget.library != null,
                    onTap: _clear,
                  ),
          ),
          if (_busy || pending || _error != null) ...[
            const SizedBox(height: 12),
            OperationStatus(
              title: _busy ? '正在处理播放记录…' : _error ?? '记录已清除，保存尚未完成',
              message: pending ? '请保持存储位置可用后重试保存。' : null,
              kind: _busy
                  ? OperationStatusKind.progress
                  : OperationStatusKind.error,
              details:
                  _diagnostic?.toString() ??
                  (pending
                      ? widget.library!.lastPersistenceError?.toString()
                      : null),
              actions: [
                if (pending && !_busy)
                  DesktopButtonClickRegion(
                    child: TextButton(
                      onPressed: AppHaptics.wrap(_retrySave, light: true),
                      child: const Text('重试保存'),
                    ),
                  ),
                if (_error != null && !_busy)
                  DesktopButtonClickRegion(
                    child: TextButton(
                      onPressed: _clear,
                      child: const Text('重试'),
                    ),
                  ),
              ],
            ),
          ],
        ],
      );
    },
  );
}
