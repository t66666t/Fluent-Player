import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_haptics.dart';
import '../services/settings_service.dart';
import '../theme/app_tokens.dart';
import '../utils/app_toast.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

const clipboardDetectionLabel = '自动检测剪贴板链接';
const clipboardDetectionDisableLabel = '不再自动检测剪贴板链接';
const clipboardDetectionSettingsLocation = '媒体库设置 → 自动检测剪贴板链接';

void setClipboardDetectionEnabled(SettingsService settings, bool value) {
  unawaited(
    settings.updateSetting('clipboardLinkDetectionEnabled', value).catchError((
      Object error,
    ) {
      debugPrint('剪贴板检测设置保存失败: $error');
      AppToast.show('设置未能保存，请重试', type: AppToastType.error);
    }),
  );
}

/// Own only this prompt's route. Disabling detection underneath another page
/// must never pop that page, the settings sheet, or a second navigator.
/// Explicit drops set [automatic] to false; their prompt remains usable while
/// the checkbox controls only future automatic clipboard checks.
/// Confirming the checkbox retains this prompt for its current user choice.
Future<T?> showClipboardDetectionDialog<T>({
  required BuildContext context,
  required SettingsService settings,
  required WidgetBuilder builder,
  VoidCallback? onPresented,
  bool automatic = true,
  VoidCallback? onDisableConfirmed,
}) {
  if (automatic && !settings.clipboardLinkDetectionEnabled) {
    return Future<T?>.value();
  }
  final navigator = Navigator.of(context, rootNavigator: true);
  var closing = false;
  var keepCurrentPrompt = false;
  late final DialogRoute<T> route;
  bool retainForDisable() {
    if (closing || !route.isActive) return false;
    keepCurrentPrompt = true;
    onDisableConfirmed?.call();
    return true;
  }

  route = DialogRoute<T>(
    context: context,
    builder: (_) => _ClipboardPromptPresentation(
      settings: settings,
      onPresented: onPresented,
      builder: builder,
      automatic: automatic,
      retainForDisable: retainForDisable,
      isRetained: () => keepCurrentPrompt,
    ),
    themes: InheritedTheme.capture(from: context, to: navigator.context),
  );
  void changed() {
    if (settings.clipboardLinkDetectionEnabled) {
      keepCurrentPrompt = false;
      return;
    }
    if (!automatic || keepCurrentPrompt || closing) return;
    closing = true;
    // Settings notifications may arrive while Navigator is building or
    // handling another route. Defer the mutation, not the preference update.
    scheduleMicrotask(() {
      final owner = route.navigator;
      if (owner == null || !route.isActive) return;
      if (route.isCurrent) {
        owner.pop<T>();
      } else {
        owner.removeRoute(route);
      }
    });
  }

  settings.addListener(changed);
  void detach() => settings.removeListener(changed);
  try {
    final result = navigator.push<T>(route);
    unawaited(route.completed.then((_) => detach()));
    changed();
    return result.whenComplete(detach);
  } catch (_) {
    settings.removeListener(changed);
    rethrow;
  }
}

class _ClipboardPromptPresentation extends StatefulWidget {
  const _ClipboardPromptPresentation({
    required this.settings,
    required this.onPresented,
    required this.builder,
    required this.automatic,
    required this.retainForDisable,
    required this.isRetained,
  });
  final SettingsService settings;
  final VoidCallback? onPresented;
  final WidgetBuilder builder;
  final bool automatic;
  final bool Function() retainForDisable;
  final bool Function() isRetained;

  @override
  State<_ClipboardPromptPresentation> createState() =>
      _ClipboardPromptPresentationState();
}

class _ClipboardPromptPresentationState
    extends State<_ClipboardPromptPresentation> {
  var _presented = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_presented ||
        widget.onPresented == null ||
        ModalRoute.isCurrentOf(context) == false) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _presented ||
          (widget.automatic &&
              !widget.settings.clipboardLinkDetectionEnabled &&
              !widget.isRetained()) ||
          ModalRoute.isCurrentOf(context) == false) {
        return;
      }
      _presented = true;
      widget.onPresented?.call();
    });
  }

  @override
  Widget build(BuildContext context) => _ClipboardPromptScope(
    retainForDisable: widget.retainForDisable,
    child: Builder(builder: widget.builder),
  );
}

class _ClipboardPromptScope extends InheritedWidget {
  const _ClipboardPromptScope({
    required this.retainForDisable,
    required super.child,
  });
  final bool Function() retainForDisable;

  @override
  bool updateShouldNotify(_ClipboardPromptScope oldWidget) => false;
}

class ClipboardDetectionCheckbox extends StatefulWidget {
  const ClipboardDetectionCheckbox({super.key, required this.settings});
  final SettingsService settings;

  @override
  State<ClipboardDetectionCheckbox> createState() =>
      _ClipboardDetectionCheckboxState();
}

class _ClipboardDetectionCheckboxState
    extends State<ClipboardDetectionCheckbox> {
  bool _confirming = false;
  DialogRoute<bool>? _confirmation;

  @override
  void dispose() {
    final route = _confirmation;
    _confirmation = null;
    if (route != null) {
      // This checkbox belongs to the original prompt. If its owner is removed
      // externally, remove only its confirmation, even beneath another page.
      scheduleMicrotask(() {
        final owner = route.navigator;
        if (owner != null && owner.mounted && route.isActive) {
          owner.removeRoute(route);
        }
      });
    }
    super.dispose();
  }

  Future<void> _changed(bool? disabled) async {
    if (disabled == null || _confirming) return;
    if (!disabled) {
      setClipboardDetectionEnabled(widget.settings, true);
      return;
    }
    final prompt = context
        .getInheritedWidgetOfExactType<_ClipboardPromptScope>();
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<bool>(
      context: context,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        final dark = theme.brightness == Brightness.dark;
        return AlertDialog(
          key: const ValueKey('clipboard-detection-disable-confirmation'),
          scrollable: true,
          insetPadding: const EdgeInsets.all(16),
          constraints: const BoxConstraints(maxWidth: 420),
          backgroundColor: dark
              ? AppTokens.bgRaised
              : theme.colorScheme.surface,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          title: Text(
            '关闭自动检测？',
            style: theme.textTheme.titleMedium?.copyWith(
              fontSize: 16,
              height: 1.4,
              fontWeight: FontWeight.w600,
            ),
          ),
          content: Text(
            '之后可在「$clipboardDetectionSettingsLocation」重新开启。',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontSize: 13,
              height: 1.6,
            ),
          ),
          actionsOverflowButtonSpacing: 4,
          actions: [
            DesktopButtonClickRegion(
              child: TextButton(
                key: const ValueKey('clipboard-detection-disable-cancel'),
                onPressed: AppHaptics.wrap(
                  () => Navigator.pop(dialogContext, false),
                  light: true,
                ),
                style: TextButton.styleFrom(
                  minimumSize: const Size(64, 44),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                child: const Text('取消'),
              ),
            ),
            DesktopButtonClickRegion(
              child: FilledButton(
                key: const ValueKey('clipboard-detection-disable-confirm'),
                onPressed: AppHaptics.wrap(
                  () => Navigator.pop(dialogContext, true),
                  light: true,
                ),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                child: const Text('关闭自动检测'),
              ),
            ),
          ],
        );
      },
    );
    _confirmation = route;
    setState(() => _confirming = true);
    try {
      final confirmed = await navigator.push(route);
      if (!mounted || confirmed != true) return;
      if (prompt != null && !prompt.retainForDisable()) return;
      setClipboardDetectionEnabled(widget.settings, false);
    } finally {
      if (identical(_confirmation, route)) _confirmation = null;
      if (mounted) setState(() => _confirming = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.settings,
    builder: (context, _) => ListTileTheme(
      horizontalTitleGap: 0,
      minVerticalPadding: 0,
      child: CheckboxListTile.adaptive(
        key: const ValueKey('clipboard-detection-checkbox'),
        value: _confirming || !widget.settings.clipboardLinkDetectionEnabled,
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(
          clipboardDetectionDisableLabel,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            fontSize: 12,
            height: 1.4,
            color: Theme.of(context).brightness == Brightness.dark
                ? AppTokens.text2
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        onChanged: AppHaptics.wrapValue(_confirming ? null : _changed),
      ),
    ),
  );
}
