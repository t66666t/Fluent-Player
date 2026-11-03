import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../theme/app_tokens.dart';

/// Keep the playing surface's media environment stable during IME frames.
/// Only [AiKeyboardViewport] subscribes to the live inset. Other panels still
/// receive normal MediaQuery data when this boundary is disabled.
class AiPlaybackKeyboardBoundary extends StatelessWidget {
  const AiPlaybackKeyboardBoundary({
    super.key,
    required this.enabled,
    required this.child,
  });

  final bool enabled;
  final Widget child;

  /// Layout variants need the visibility transition, not every inset value.
  static bool isKeyboardVisibleOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_PlaybackKeyboardVisibility>()
          ?.visible ??
      MediaQuery.viewInsetsOf(context).bottom > 0;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return _AiPlaybackKeyboardInset(
      bottom: enabled ? media.viewInsets.bottom : null,
      child: _PlaybackKeyboardVisibility(
        visible: media.viewInsets.bottom > 0,
        child: MediaQuery(
          data: enabled
              ? media.copyWith(
                  viewInsets: media.viewInsets.copyWith(bottom: 0),
                  padding: media.padding.copyWith(
                    bottom: media.viewPadding.bottom,
                  ),
                )
              : media,
          child: child,
        ),
      ),
    );
  }
}

class _PlaybackKeyboardVisibility extends InheritedWidget {
  const _PlaybackKeyboardVisibility({
    required this.visible,
    required super.child,
  });

  final bool visible;

  @override
  bool updateShouldNotify(_PlaybackKeyboardVisibility oldWidget) =>
      visible != oldWidget.visible;
}

class _AiPlaybackKeyboardInset extends InheritedWidget {
  const _AiPlaybackKeyboardInset({required this.bottom, required super.child});

  final double? bottom;

  static double? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_AiPlaybackKeyboardInset>()
      ?.bottom;

  @override
  bool updateShouldNotify(_AiPlaybackKeyboardInset oldWidget) =>
      bottom != oldWidget.bottom;
}

/// Owns keyboard avoidance once, outside a non-resizing playback scaffold.
/// Mobile platform insets are followed directly, including large/coalesced
/// steps and interactive dismissal. Desktop single updates get a transition.
class AiKeyboardViewport extends StatefulWidget {
  const AiKeyboardViewport({
    super.key,
    required this.child,
    this.enabled = true,
    this.reservedBottomInset = 0,
  });

  final Widget child;
  final bool enabled;
  final double reservedBottomInset;

  @override
  State<AiKeyboardViewport> createState() => _AiKeyboardViewportState();
}

class _AiKeyboardViewportState extends State<AiKeyboardViewport>
    with SingleTickerProviderStateMixin {
  late final AnimationController _inset;
  double _target = 0;
  Duration? _lastMetricAt;
  bool _followingNativeFrames = false;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _inset = AnimationController.unbounded(vsync: this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateInset();
  }

  @override
  void didUpdateWidget(AiKeyboardViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled ||
        oldWidget.reservedBottomInset != widget.reservedBottomInset) {
      _updateInset();
    }
  }

  void _updateInset() {
    final raw =
        _AiPlaybackKeyboardInset.maybeOf(context) ??
        MediaQuery.viewInsetsOf(context).bottom;
    final target = widget.enabled
        ? (raw - widget.reservedBottomInset)
              .clamp(0.0, double.infinity)
              .toDouble()
        : 0.0;
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    // Android/iOS already animate the IME insets. Guessing from their step size
    // or cadence can start another animation after a delayed first frame, a
    // keyboard switch or a pause in interactive dismissal. It then lags behind
    // the IME and snaps back on the next update. Never synthesize mobile ticks.
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      _target = target;
      if (_inset.value != target) _inset.value = target;
      _initialized = true;
      return;
    }
    if (_initialized && (target - _target).abs() < .5) {
      if (disableAnimations && _inset.value != target) _inset.value = target;
      return;
    }
    final now = SchedulerBinding.instance.currentFrameTimeStamp;
    // Once a native transition is in progress, dropped/coalesced frames may
    // produce large inset steps. They still belong to that same transition;
    // starting our own easing on those steps makes the composer fall behind
    // and jump back to the native position on the next small step.
    final followsNativeFrames =
        (_inset.value == 0 && target > 0 && target < 72) ||
        (_lastMetricAt != null &&
            now - _lastMetricAt! < const Duration(milliseconds: 120) &&
            (_followingNativeFrames || (target - _target).abs() < 72));
    _followingNativeFrames = followsNativeFrames;
    _lastMetricAt = now;
    _target = target;
    if (!widget.enabled ||
        !_initialized ||
        followsNativeFrames ||
        (_inset.value == 0 && target < 72) ||
        disableAnimations) {
      _inset.value = target;
    } else {
      _inset.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
    _initialized = true;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => AnimatedBuilder(
      animation: _inset,
      // Keep content out of the animation builder and consume the inset here
      // so descendants cannot apply it a second time.
      child: MediaQuery.removeViewInsets(
        context: context,
        removeBottom: widget.enabled,
        child: RepaintBoundary(child: widget.child),
      ),
      builder: (context, child) => Padding(
        padding: EdgeInsets.only(
          bottom: _inset.value.clamp(0.0, constraints.maxHeight).toDouble(),
        ),
        child: child,
      ),
    ),
  );

  @override
  void dispose() {
    _inset.dispose();
    super.dispose();
  }
}

ThemeData aiChatTheme(ThemeData base) => base.copyWith(
  brightness: Brightness.dark,
  colorScheme:
      ColorScheme.fromSeed(
        seedColor: AppTokens.accent,
        brightness: Brightness.dark,
      ).copyWith(
        surface: AppTokens.bgBase,
        surfaceContainerLowest: AppTokens.bgBase,
        surfaceContainerLow: AppTokens.bgRaised,
        surfaceContainer: AppTokens.bgRaised,
        surfaceContainerHigh: AppTokens.bgOverlay,
        surfaceContainerHighest: AppTokens.bgCard,
        onSurface: AppTokens.text1,
        onSurfaceVariant: AppTokens.text2,
        outlineVariant: AppTokens.lineSubtle,
        primary: AppTokens.accent,
      ),
  scaffoldBackgroundColor: AppTokens.bgBase,
  textTheme: base.textTheme.apply(
    bodyColor: AppTokens.text1,
    displayColor: AppTokens.text1,
  ),
  iconTheme: const IconThemeData(color: AppTokens.text2, size: 20),
  visualDensity: VisualDensity.compact,
  dividerColor: AppTokens.lineSubtle,
  dialogTheme: base.dialogTheme.copyWith(
    backgroundColor: AppTokens.bgRaised,
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  ),
  inputDecorationTheme: InputDecorationThemeData(
    isDense: true,
    filled: true,
    fillColor: AppTokens.bgBase,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(6),
      borderSide: const BorderSide(color: AppTokens.lineSubtle),
    ),
  ),
  tabBarTheme: const TabBarThemeData(
    labelColor: AppTokens.text1,
    unselectedLabelColor: AppTokens.text2,
    indicatorColor: AppTokens.text1,
    labelStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
    unselectedLabelStyle: TextStyle(fontSize: 13),
    dividerHeight: 1,
  ),
);

/// Dense controls are scoped to settings surfaces; conversation text keeps its
/// own reading preference and still follows the system text scaler.
ThemeData aiChatDialogTheme(ThemeData base) {
  final theme = aiChatTheme(base);
  final buttons = ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(0, 32)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    ),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    visualDensity: VisualDensity.standard,
    textStyle: WidgetStatePropertyAll(
      theme.textTheme.labelLarge?.copyWith(fontSize: 12),
    ),
  );
  return theme.copyWith(
    textTheme: theme.textTheme.copyWith(
      bodyLarge: theme.textTheme.bodyLarge?.copyWith(
        fontSize: 13,
        height: 1.35,
      ),
      bodyMedium: theme.textTheme.bodyMedium?.copyWith(
        fontSize: 13,
        height: 1.4,
      ),
      bodySmall: theme.textTheme.bodySmall?.copyWith(
        fontSize: 11,
        height: 1.35,
      ),
      titleMedium: theme.textTheme.titleMedium?.copyWith(fontSize: 14),
      titleSmall: theme.textTheme.titleSmall?.copyWith(fontSize: 13),
      labelLarge: theme.textTheme.labelLarge?.copyWith(fontSize: 12),
    ),
    inputDecorationTheme: theme.inputDecorationTheme.copyWith(
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      labelStyle: const TextStyle(fontSize: 12),
      hintStyle: const TextStyle(fontSize: 12),
      helperStyle: const TextStyle(fontSize: 11, height: 1.3),
      errorStyle: const TextStyle(fontSize: 11, height: 1.3),
      prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      suffixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    ),
    textButtonTheme: TextButtonThemeData(style: buttons),
    outlinedButtonTheme: OutlinedButtonThemeData(style: buttons),
    filledButtonTheme: FilledButtonThemeData(style: buttons),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(32, 32),
        padding: const EdgeInsets.all(4),
        iconSize: 18,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
    listTileTheme: theme.listTileTheme.copyWith(
      dense: true,
      minTileHeight: 36,
      minVerticalPadding: 2,
      horizontalTitleGap: 8,
    ),
    switchTheme: theme.switchTheme.copyWith(
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    checkboxTheme: theme.checkboxTheme.copyWith(
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    chipTheme: theme.chipTheme.copyWith(
      labelStyle: theme.textTheme.labelMedium?.copyWith(fontSize: 12),
      labelPadding: const EdgeInsets.symmetric(horizontal: 6),
      padding: EdgeInsets.zero,
    ),
  );
}

/// Keep a small margin on phones and let short content choose its own height.
/// Long forms and lists stay bounded, with keyboard avoidance owned by Dialog.
class AiAdaptiveDialog extends StatelessWidget {
  const AiAdaptiveDialog({
    super.key,
    required this.title,
    required this.content,
    this.trailing,
    this.actions = const [],
    this.maxWidth = 760,
    this.maxHeight = 720,
    this.contentPadding = const EdgeInsets.all(8),
  });
  final Widget title;
  final Widget content;
  final Widget? trailing;
  final List<Widget> actions;
  final double maxWidth;
  final double maxHeight;
  final EdgeInsets contentPadding;

  @override
  Widget build(BuildContext context) => Theme(
    data: aiChatDialogTheme(Theme.of(context)),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final available =
            (constraints.maxHeight - MediaQuery.viewInsetsOf(context).bottom)
                .clamp(0.0, constraints.maxHeight)
                .toDouble();
        final compact = constraints.maxWidth < 600 || available < 480;
        final margin = compact ? 8.0 : 24.0;
        return Dialog(
          insetAnimationDuration: Duration.zero,
          backgroundColor: AppTokens.bgRaised,
          surfaceTintColor: Colors.transparent,
          insetPadding: EdgeInsets.all(margin),
          constraints: const BoxConstraints(minWidth: 0),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            key: const ValueKey('ai-adaptive-dialog-surface'),
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: SizedBox(
              width: maxWidth,
              child: LayoutBuilder(
                builder: (context, bodyConstraints) {
                  final height = bodyConstraints.maxHeight;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: height * .3),
                        child: SingleChildScrollView(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
                            child: Row(
                              children: [
                                Expanded(
                                  child: DefaultTextStyle.merge(
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: AppTokens.text1,
                                    ),
                                    child: title,
                                  ),
                                ),
                                ?trailing,
                              ],
                            ),
                          ),
                        ),
                      ),
                      const Divider(height: 1),
                      Flexible(
                        child: Padding(padding: contentPadding, child: content),
                      ),
                      if (actions.isNotEmpty) ...[
                        const Divider(height: 1),
                        ConstrainedBox(
                          constraints: BoxConstraints(maxHeight: height * .35),
                          child: SingleChildScrollView(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              child: Wrap(
                                alignment: WrapAlignment.end,
                                spacing: 4,
                                runSpacing: 2,
                                children: actions,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    ),
  );
}
