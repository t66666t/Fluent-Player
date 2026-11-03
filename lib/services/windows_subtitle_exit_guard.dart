import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

import '../utils/app_toast.dart';
import '../utils/deferred_subtitle_edits.dart';
import 'subtitle_editor_persistence.dart';

/// Keeps the engine alive until the last captured subtitle draft is saved.
class WindowsSubtitleExitGuard with WindowListener {
  static final _instance = WindowsSubtitleExitGuard._();
  WindowsSubtitleExitGuard._();

  bool _installed = false;
  bool _closing = false;

  static Future<void> install() async {
    if (_instance._installed) return;
    windowManager.addListener(_instance);
    try {
      await windowManager.setPreventClose(true);
      _instance._installed = true;
    } catch (_) {
      windowManager.removeListener(_instance);
      rethrow;
    }
  }

  @override
  void onWindowClose() async {
    if (_closing) return;
    _closing = true;
    try {
      var saved = await DeferredSubtitleEdits.flushPendingForExit();
      if (saved) {
        try {
          await SubtitleEditorPersistence.retryPendingForExit();
        } catch (error, stack) {
          saved = false;
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stack,
              library: 'subtitle editor',
              context: ErrorDescription('while retrying subtitles before exit'),
            ),
          );
        }
      }
      if (!saved) {
        AppToast.show(
          '字幕保存失败，修改仍保留。请重试保存后再关闭窗口。',
          type: AppToastType.error,
          duration: const Duration(seconds: 8),
        );
        return;
      }
      await windowManager.destroy();
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'Windows subtitle exit',
        ),
      );
      AppToast.show('关闭窗口失败，请重试', type: AppToastType.error);
    } finally {
      _closing = false;
    }
  }
}
