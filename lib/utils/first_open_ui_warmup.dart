import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'app_toast.dart';
import 'ui_idle_gate.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Key used by tests to locate the off-screen warmup surface while it exists.
@visibleForTesting
const Key kFirstOpenUiWarmupSurfaceKey = ValueKey<String>(
  'first-open-ui-warmup-surface',
);

/// Zero-size clip slot. Overlay theatres do not clip by default, so this is
/// what keeps the warmup tree from painting onto the visible screen.
@visibleForTesting
const Key kFirstOpenUiWarmupClipSlotKey = ValueKey<String>(
  'first-open-ui-warmup-clip-slot',
);

/// Whether deferred first-open warmup should run for this build.
///
/// Debug and widget tests skip it so startup work stays out of iteration loops.
/// Profile/Release on every mobile and desktop target keep it on.
@visibleForTesting
bool firstOpenUiWarmupEnabledByDefault() {
  if (kIsWeb) return false;
  if (kDebugMode) return false;
  return true;
}

/// Host that returns [child] unchanged and warms dialog/sheet shaders after
/// the first real frame.
///
/// The capture overlay is inserted into the existing navigator overlay, so
/// this widget never changes app layout, routes, focus, or semantics.
class FirstOpenUiWarmupHost extends StatefulWidget {
  const FirstOpenUiWarmupHost({
    super.key,
    required this.child,
    this.enabled,
    this.startDelay = const Duration(milliseconds: 180),
  });

  final Widget child;

  /// `null` uses [firstOpenUiWarmupEnabledByDefault].
  final bool? enabled;

  /// Idle gap after the first frame so home rendering is not competing.
  final Duration startDelay;

  @override
  State<FirstOpenUiWarmupHost> createState() => _FirstOpenUiWarmupHostState();
}

class _FirstOpenUiWarmupHostState extends State<FirstOpenUiWarmupHost> {
  OverlayEntry? _entry;
  final GlobalKey _boundaryKey = GlobalKey(debugLabel: 'FirstOpenUiWarmup');
  bool _started = false;
  UiIdleGate? _idleGate;

  bool get _enabled => widget.enabled ?? firstOpenUiWarmupEnabledByDefault();

  bool _isFlutterTestProcess() {
    if (kIsWeb) return false;
    try {
      return Platform.environment.containsKey('FLUTTER_TEST');
    } catch (_) {
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    if (!_enabled) return;
    _idleGate = UiIdleGate();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _started) return;
      _started = true;
      unawaited(_run());
    });
  }

  @override
  void dispose() {
    _idleGate?.dispose();
    _removeEntry();
    super.dispose();
  }

  Future<void> _run() async {
    try {
      if (widget.startDelay > Duration.zero) {
        await Future<void>.delayed(widget.startDelay);
      }
      if (!mounted) return;

      // Widget tests still exercise overlay capture. Canvas snapshots are
      // skipped there because picture.toImage is slow and GPU-dependent.
      if (!_isFlutterTestProcess()) {
        for (final phase in _FirstOpenWarmupPhase.values) {
          if (!await _waitUntilIdle()) return;
          await _FirstOpenShaderWarmUp(phase: phase).execute();
          // Give queued input events a chance to arrive before the next phase.
          await Future<void>.delayed(Duration.zero);
        }
      }

      if (!await _waitUntilIdle()) return;
      await _captureWidgetSurface();
    } catch (e) {
      debugPrint('First-open UI warmup failed: $e');
      _removeEntry();
    } finally {
      _idleGate?.dispose();
    }
  }

  Future<bool> _waitUntilIdle() async =>
      mounted && await (_idleGate?.waitUntilIdle() ?? Future.value(false));

  Future<void> _captureWidgetSurface() async {
    final overlay =
        AppToast.navigatorKey.currentState?.overlay ??
        Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    _entry = OverlayEntry(
      opaque: false,
      maintainState: false,
      builder: (context) {
        return _FirstOpenWarmupCapture(
          boundaryKey: _boundaryKey,
          child: const FirstOpenWarmupSurface(),
        );
      },
    );
    overlay.insert(_entry!);

    // Two display frames is enough for the off-screen dialog tree to layout.
    // A short delay also works under widget-test fake-async (driven by pump).
    await Future<void>.delayed(const Duration(milliseconds: 48));
    if (!await _waitUntilIdle()) {
      _removeEntry();
      return;
    }

    try {
      final renderObject = _boundaryKey.currentContext?.findRenderObject();
      if (renderObject is RenderRepaintBoundary) {
        // Rasterizing the layer compiles Impeller/Skia pipelines without
        // compositing the widgets onto the visible app surface.
        final image = await renderObject.toImage(pixelRatio: 1.0);
        image.dispose();
      }
    } finally {
      _removeEntry();
    }
  }

  void _removeEntry() {
    _entry?.remove();
    _entry = null;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Zero-size clipped capture hole.
///
/// Navigator [Overlay] uses a theatre with [Clip.none], so a 1px [OverflowBox]
/// still paints its 420×840 child onto the screen (Android tablets showed the
/// left-hand warmup chrome). Clip to 0×0 so nothing is composited, while the
/// inner [RepaintBoundary] can still rasterize for shader warmup.
class _FirstOpenWarmupCapture extends StatelessWidget {
  const _FirstOpenWarmupCapture({
    required this.boundaryKey,
    required this.child,
  });

  final GlobalKey boundaryKey;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      top: 0,
      width: 0,
      height: 0,
      child: IgnorePointer(
        child: ExcludeSemantics(
          child: TickerMode(
            enabled: false,
            child: ClipRect(
              key: kFirstOpenUiWarmupClipSlotKey,
              clipBehavior: Clip.hardEdge,
              child: OverflowBox(
                alignment: Alignment.topLeft,
                minWidth: 420,
                maxWidth: 420,
                minHeight: 840,
                maxHeight: 840,
                child: RepaintBoundary(
                  key: boundaryKey,
                  child: SizedBox(width: 420, height: 840, child: child),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Visual stand-in for first-open dialogs/sheets.
///
/// Mirrors radii, elevations, blur, barriers, and fonts used in search,
/// sleep timer, speed popover, toasts, and library sheets — without Focus,
/// TextField, Navigator, or service listeners.
@visibleForTesting
class FirstOpenWarmupSurface extends StatelessWidget {
  const FirstOpenWarmupSurface({super.key});

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: kFirstOpenUiWarmupSurfaceKey,
      child: Theme(
        data: Theme.of(context),
        child: const Material(
          type: MaterialType.transparency,
          child: ColoredBox(
            color: Color(0xFF121212),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                ColoredBox(color: Color(0x9F000000)),
                _WarmupAlertDialog(),
                Positioned(left: 12, top: 210, child: _WarmupSearchPanel()),
                Positioned(left: 12, top: 360, child: _WarmupBottomSheet()),
                Positioned(left: 12, top: 510, child: _WarmupSpeedPopover()),
                Positioned(left: 12, top: 680, child: _WarmupBlurToast()),
                Positioned(right: 8, top: 12, child: _WarmupControls()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WarmupAlertDialog extends StatelessWidget {
  const _WarmupAlertDialog();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: AlertDialog(
          backgroundColor: const Color(0xFF2C2C2C),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Text(
            '重命名',
            style: TextStyle(color: Colors.white, fontFamily: 'MiSans'),
          ),
          content: const Text(
            '输入新名称 睡眠定时 搜索媒体库',
            style: TextStyle(color: Colors.white70, fontFamily: 'MiSans'),
          ),
          actions: const <Widget>[
            DesktopButtonClickRegion(
              child: TextButton(onPressed: null, child: Text('取消')),
            ),
            DesktopButtonClickRegion(
              child: ElevatedButton(onPressed: null, child: Text('确定')),
            ),
          ],
        ),
      ),
    );
  }
}

class _WarmupSearchPanel extends StatelessWidget {
  const _WarmupSearchPanel();

  @override
  Widget build(BuildContext context) {
    return Transform.scale(
      scale: 0.985,
      child: Opacity(
        opacity: 0.96,
        child: Material(
          color: const Color(0xFF242426),
          elevation: 18,
          shadowColor: Colors.black.withValues(alpha: 0.48),
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
          ),
          child: const SizedBox(
            width: 396,
            height: 132,
            child: Padding(
              padding: EdgeInsets.fromLTRB(18, 16, 14, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '搜索媒体库',
                    style: TextStyle(
                      color: Colors.white,
                      fontFamily: 'Noto Sans SC',
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: 10),
                  InputDecorator(
                    decoration: InputDecoration(
                      hintText: '输入名称或关键词',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    child: Text(
                      '预热输入框',
                      style: TextStyle(
                        color: Colors.white70,
                        fontFamily: 'Noto Sans SC',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WarmupBottomSheet extends StatelessWidget {
  const _WarmupBottomSheet();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1E1E1E),
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.4),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SizedBox(
        width: 396,
        height: 132,
        child: Column(
          children: <Widget>[
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(16),
              child: Row(
                children: <Widget>[
                  Icon(Icons.tune, color: Colors.white),
                  SizedBox(width: 12),
                  Text(
                    '媒体库设置',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'MiSans',
                    ),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: LinearProgressIndicator(value: 0.45),
            ),
          ],
        ),
      ),
    );
  }
}

class _WarmupSpeedPopover extends StatelessWidget {
  const _WarmupSpeedPopover();

  @override
  Widget build(BuildContext context) {
    return Transform.scale(
      alignment: Alignment.bottomRight,
      scale: 0.94,
      child: Material(
        color: const Color(0xFF202124),
        elevation: 14,
        shadowColor: Colors.black87,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white.withValues(alpha: 0.09)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const SizedBox(
            width: 280,
            height: 150,
            child: Column(
              children: <Widget>[
                SizedBox(
                  height: 42,
                  child: Row(
                    children: <Widget>[
                      SizedBox(width: 11),
                      Icon(Icons.speed, size: 17, color: Colors.blueAccent),
                      SizedBox(width: 7),
                      Text(
                        '播放倍速',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: Color(0x12FFFFFF)),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        '1.0x  1.5x  2.0x',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WarmupBlurToast extends StatelessWidget {
  const _WarmupBlurToast();

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFF1E1F22).withValues(alpha: 0.78),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text(
              '已完成',
              style: TextStyle(color: Colors.white, fontFamily: 'Noto Sans SC'),
            ),
          ),
        ),
      ),
    );
  }
}

class _WarmupControls extends StatelessWidget {
  const _WarmupControls();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 160,
      child: Column(
        children: <Widget>[
          ShaderMask(
            shaderCallback: (Rect bounds) {
              return const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[
                  Colors.transparent,
                  Colors.white,
                  Colors.white,
                  Colors.transparent,
                ],
                stops: <double>[0, 0.08, 0.92, 1],
              ).createShader(bounds);
            },
            blendMode: BlendMode.dstIn,
            child: const Text(
              '歌词预热 Lyric',
              style: TextStyle(
                color: Colors.white,
                fontFamily: 'Inter',
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: const SizedBox(
              width: 72,
              height: 72,
              child: ColoredBox(color: Color(0xFF3A3A3A)),
            ),
          ),
          Switch(value: true, onChanged: null),
          Checkbox(value: true, onChanged: null),
          Slider(value: 0.4, onChanged: null),
          DesktopButtonClickRegion(
            child: OutlinedButton(onPressed: null, child: const Text('导入')),
          ),
          DesktopButtonClickRegion(
            child: FilledButton(onPressed: null, child: const Text('应用')),
          ),
        ],
      ),
    );
  }
}

enum _FirstOpenWarmupPhase { primitives, fontsMiSans, fontsNoto, fontsInter }

/// Canvas-level warmup so Skia/Impeller compile draw ops even if widget
/// capture is skipped on a given platform.
class _FirstOpenShaderWarmUp extends ShaderWarmUp {
  const _FirstOpenShaderWarmUp({required this.phase});

  final _FirstOpenWarmupPhase phase;

  @override
  ui.Size get size => const ui.Size(420, 840);

  @override
  Future<void> warmUpOnCanvas(ui.Canvas canvas) async {
    switch (phase) {
      case _FirstOpenWarmupPhase.primitives:
        _drawPrimitives(canvas);
      case _FirstOpenWarmupPhase.fontsMiSans:
        _drawFont(
          canvas,
          family: 'MiSans',
          weights: <FontWeight>[
            FontWeight.w300,
            FontWeight.w400,
            FontWeight.w500,
            FontWeight.w600,
          ],
        );
      case _FirstOpenWarmupPhase.fontsNoto:
        _drawFont(
          canvas,
          family: 'Noto Sans SC',
          weights: <FontWeight>[
            FontWeight.w300,
            FontWeight.w400,
            FontWeight.w500,
            FontWeight.w700,
          ],
        );
      case _FirstOpenWarmupPhase.fontsInter:
        _drawFont(
          canvas,
          family: 'Inter',
          weights: <FontWeight>[
            FontWeight.w400,
            FontWeight.w500,
            FontWeight.w600,
          ],
        );
    }
  }

  void _drawPrimitives(ui.Canvas canvas) {
    final bg = ui.Paint()..color = const Color(0xFF121212);
    canvas.drawRect(ui.Rect.fromLTWH(0, 0, size.width, size.height), bg);

    _drawScrim(canvas, 0.42);
    _drawScrim(canvas, 0.62);

    _drawRoundRect(
      canvas,
      rect: const ui.Rect.fromLTWH(24, 40, 372, 140),
      radius: 16,
      color: const Color(0xFF2C2C2C),
      elevation: 8,
    );
    _drawRoundRect(
      canvas,
      rect: const ui.Rect.fromLTWH(24, 200, 372, 120),
      radius: 18,
      color: const Color(0xFF242426),
      elevation: 18,
    );
    _drawRoundRect(
      canvas,
      rect: const ui.Rect.fromLTWH(24, 340, 372, 110),
      radius: 20,
      color: const Color(0xFF1E1E1E),
      elevation: 8,
    );
    _drawRoundRect(
      canvas,
      rect: const ui.Rect.fromLTWH(70, 470, 280, 150),
      radius: 12,
      color: const Color(0xFF202124),
      elevation: 14,
    );

    _drawBlurredLayer(
      canvas,
      rect: const ui.Rect.fromLTWH(40, 650, 220, 56),
      sigma: 18,
    );
    _drawBlurredLayer(
      canvas,
      rect: const ui.Rect.fromLTWH(280, 640, 96, 96),
      sigma: 24,
    );

    final gradientPaint = ui.Paint()
      ..shader = const LinearGradient(
        colors: <Color>[
          Color(0x662D435E),
          Color(0xAA152133),
          Color(0x66386384),
        ],
      ).createShader(const ui.Rect.fromLTWH(24, 760, 372, 48));
    canvas.drawRRect(
      ui.RRect.fromRectAndRadius(
        const ui.Rect.fromLTWH(24, 760, 372, 48),
        const ui.Radius.circular(22),
      ),
      gradientPaint,
    );

    final sweepPaint = ui.Paint()
      ..shader = const SweepGradient(
        colors: <Color>[
          Color(0xFF7C8CFF),
          Color(0xFF3A3A3A),
          Color(0xFF7C8CFF),
        ],
      ).createShader(const ui.Rect.fromLTWH(330, 470, 64, 64));
    canvas.drawCircle(const ui.Offset(362, 502), 28, sweepPaint);
  }

  void _drawScrim(ui.Canvas canvas, double alpha) {
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, size.width, size.height),
      ui.Paint()..color = Color.fromRGBO(0, 0, 0, alpha),
    );
  }

  void _drawRoundRect(
    ui.Canvas canvas, {
    required ui.Rect rect,
    required double radius,
    required Color color,
    required double elevation,
  }) {
    final rrect = ui.RRect.fromRectAndRadius(rect, ui.Radius.circular(radius));
    final path = ui.Path()..addRRect(rrect);
    canvas.drawShadow(path, const Color(0xFF000000), elevation, true);
    canvas.drawRRect(rrect, ui.Paint()..color = color);
    canvas.drawRRect(
      rrect,
      ui.Paint()
        ..color = const Color(0x1FFFFFFF)
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  void _drawBlurredLayer(
    ui.Canvas canvas, {
    required ui.Rect rect,
    required double sigma,
  }) {
    final paint = ui.Paint()
      ..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
    canvas.saveLayer(rect.inflate(sigma), paint);
    canvas.drawRRect(
      ui.RRect.fromRectAndRadius(rect, const ui.Radius.circular(18)),
      ui.Paint()..color = const Color(0xC71E1F22),
    );
    canvas.restore();
  }

  void _drawFont(
    ui.Canvas canvas, {
    required String family,
    required List<FontWeight> weights,
  }) {
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, size.width, size.height),
      ui.Paint()..color = const Color(0xFF121212),
    );
    var y = 24.0;
    for (final weight in weights) {
      final builder =
          ui.ParagraphBuilder(
              ui.ParagraphStyle(
                fontFamily: family,
                fontSize: 16,
                fontWeight: weight,
              ),
            )
            ..pushStyle(
              ui.TextStyle(
                color: const Color(0xFFFFFFFF),
                fontFamily: family,
                fontSize: 16,
                fontWeight: weight,
              ),
            )
            ..addText('搜索媒体库 睡眠定时 播放倍速 字幕 Fluent Player AaBb123');
      final paragraph = builder.build()
        ..layout(ui.ParagraphConstraints(width: size.width - 24));
      canvas.drawParagraph(paragraph, ui.Offset(12, y));
      y += 36;
    }
  }
}
