// Real-app root navigation probe, with private data/clipboard/prefs provided
// by isolated_app_startup_profile.dart. Build in Profile or Release mode.
// FLUENT_PERF_MEASUREMENT_ONLY=true keeps the owned process alive for the
// runner to terminate after FLUENT_ROOT_SWITCH_REPORT has been written.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_player_app/models/media_library_root_entry.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/widgets/media_library_entry_switcher.dart';
import 'package:video_player_app/widgets/media_library_root_surface_host.dart';

import 'isolated_app_startup_profile.dart' as isolated;

final _frames = <ui.FrameTiming>[];
final _samples = <Map<String, Object?>>[];
final _memory = <Map<String, int>>[];
final _inputMode =
    Platform.environment['FLUENT_ROOT_SWITCH_INPUT'] ?? 'callback';
final _paintAlphas = <int>[];

Element? _find(bool Function(Element) matches, [Element? root]) {
  root ??= WidgetsBinding.instance.rootElement;
  if (root?.widget case Offstage(offstage: true)) return null;
  if (root == null || matches(root)) return root;
  Element? found;
  root.visitChildElements((child) {
    found ??= _find(matches, child);
  });
  return found;
}

int? _surfaceAlpha(MediaLibraryRootEntry entry) {
  final host = _find((e) => e.widget is MediaLibraryRootSurfaceHost);
  if (host == null) return null;
  // Titles use the same entry keys for reorder; only inspect body surfaces.
  final surface = _find(
    (element) => element.widget.key == ValueKey(entry),
    host,
  );
  int? alpha;
  void visit(RenderObject object) {
    if (alpha != null) return;
    // Instrumentation only: observe the real composited layer in Release too.
    // ignore: invalid_use_of_protected_member
    final layer = object.layer;
    if (layer is OpacityLayer) {
      alpha = layer.alpha;
    } else {
      object.visitChildren(visit);
    }
  }

  final render = surface?.findRenderObject();
  if (render != null) visit(render);
  return alpha;
}

Future<void> _frame() => SchedulerBinding.instance.endOfFrame;

Future<void> _select(MediaLibraryRootEntry entry, int cycle) async {
  final switcher = _find((e) => e.widget is MediaLibraryEntrySwitcher);
  if (switcher == null) throw StateError('Missing entry switcher');
  final beforeAlpha = _surfaceAlpha(entry);
  final pointer = 730100 + _samples.length;
  final pointerInput = _inputMode != 'callback';
  final kind = _inputMode == 'touch'
      ? ui.PointerDeviceKind.touch
      : ui.PointerDeviceKind.mouse;
  var position = const Offset(-100, -100);
  if (pointerInput) {
    // Find the title inside this switcher, not a matching label in the body.
    final title = _find(
      (e) => e.widget is Text && (e.widget as Text).data == entry.label,
      switcher,
    );
    final box = title?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) {
      throw StateError('Missing title geometry for $entry');
    }
    position = box.localToGlobal(box.size.center(Offset.zero));
    final hit = HitTestResult();
    GestureBinding.instance.hitTestInView(
      hit,
      position,
      View.of(switcher).viewId,
    );
    if (!hit.path.any((hit) => identical(hit.target, box))) {
      _samples.add({
        'entry': entry.name,
        'diagnostic': 'title_not_hit',
        'x': position.dx,
        'y': position.dy,
        'width': box.size.width,
        'height': box.size.height,
        'currentRoute': ModalRoute.of(switcher)?.isCurrent,
        'hitTargets': hit.path.map((h) => '${h.target.runtimeType}').toList(),
      });
      throw StateError('Title is clipped or covered: ${entry.name}');
    }
  }
  final binding = GestureBinding.instance;
  binding.handlePointerEvent(
    PointerAddedEvent(device: pointer, kind: kind, position: position),
  );
  binding.handlePointerEvent(
    PointerDownEvent(
      pointer: pointer,
      device: pointer,
      kind: kind,
      buttons: kPrimaryButton,
      position: position,
    ),
  );
  // Let the press be rendered as for a real short click. Selection must still
  // wait for release so this probe exercises the production reorder arbiter.
  await Future<void>.delayed(const Duration(milliseconds: 40));
  final clock = Stopwatch()..start();
  _paintAlphas.clear();
  binding.handlePointerEvent(
    PointerUpEvent(
      pointer: pointer,
      device: pointer,
      kind: kind,
      position: position,
    ),
  );
  if (!pointerInput) {
    (switcher.widget as MediaLibraryEntrySwitcher).onSelected(entry);
  }
  final dispatchUs = clock.elapsedMicroseconds;
  int? firstVisibleUs;
  var frameworkFrames = 0;
  while (clock.elapsed < const Duration(seconds: 5)) {
    await _frame();
    frameworkFrames++;
    final alpha = _surfaceAlpha(entry) ?? 0;
    if (alpha > 0) firstVisibleUs ??= clock.elapsedMicroseconds;
    if (alpha == 255) break;
  }
  final fullyVisibleUs = clock.elapsedMicroseconds;
  binding.handlePointerEvent(
    PointerRemovedEvent(
      pointer: pointer,
      device: pointer,
      kind: kind,
      position: position,
    ),
  );
  if (firstVisibleUs == null || _surfaceAlpha(entry) != 255) {
    final selected =
        _find((e) => e.widget is MediaLibraryEntrySwitcher)?.widget
            as MediaLibraryEntrySwitcher?;
    throw StateError(
      'Entry did not become visible: $entry; '
      'selected=${selected?.selected}; alpha=${_surfaceAlpha(entry)}',
    );
  }
  _samples.add({
    'entry': entry.name,
    'cycle': cycle,
    'wasMounted': beforeAlpha != null,
    'firstVisibleFrameworkMs': firstVisibleUs / 1000,
    'fullyVisibleFrameworkMs': fullyVisibleUs / 1000,
    'frameworkFrames': frameworkFrames,
    'pointerDispatchMs': dispatchUs / 1000,
    'surfacePaints': _paintAlphas.length,
    'partialSurfacePaints': _paintAlphas.where((a) => a > 0 && a < 255).length,
  });
  // Give the unchanged 140 ms press animation and 150 ms prefs scheduling a
  // fixed quiet gap, so a faster transition does not shift unrelated work
  // into the next sample. This gap is outside the measured interval.
  await Future<void>.delayed(const Duration(milliseconds: 170));
}

Map<String, Object> _distribution(Iterable<num> samples) {
  final sorted = samples.toList()..sort();
  if (sorted.isEmpty) return {'count': 0};
  num at(double fraction) => sorted[((sorted.length - 1) * fraction).round()];
  return {
    'count': sorted.length,
    'p50Ms': at(.5),
    'p95Ms': at(.95),
    'p99Ms': at(.99),
    'maxMs': sorted.last,
  };
}

Future<void> main() async {
  final output = Platform.environment['FLUENT_ROOT_SWITCH_REPORT'];
  if (output == null || !File(output).isAbsolute) {
    throw ArgumentError('FLUENT_ROOT_SWITCH_REPORT must be absolute');
  }
  if (Platform.environment['FLUENT_PERF_MEASUREMENT_ONLY'] != 'true') {
    throw ArgumentError('Run with FLUENT_PERF_MEASUREMENT_ONLY=true');
  }
  final cycles =
      int.tryParse(Platform.environment['FLUENT_ROOT_SWITCH_CYCLES'] ?? '') ??
      10;
  if (cycles < 1 || cycles > 50) throw ArgumentError('Cycles must be 1..50');
  if (!{'callback', 'mouse', 'touch'}.contains(_inputMode)) {
    throw ArgumentError(
      'FLUENT_ROOT_SWITCH_INPUT must be callback/mouse/touch',
    );
  }
  final report = File(output);
  await isolated.main();
  final errors = <String>[];
  final previousErrorHandler = FlutterError.onError;
  FlutterError.onError = (details) {
    errors.add(details.exceptionAsString());
    previousErrorHandler?.call(details);
  };
  try {
    final ready = Stopwatch()..start();
    while (_find((e) => e.widget is MediaLibraryEntrySwitcher) == null ||
        !LibraryService().isInitialized) {
      if (ready.elapsed > const Duration(seconds: 30)) {
        throw StateError('Home did not become ready');
      }
      await _frame();
    }
    WidgetsBinding.instance.addTimingsCallback(_frames.addAll);
    // Instrument the same paint gate as widget tests, in an owned probe only.
    // ignore: invalid_use_of_visible_for_testing_member
    debugMediaLibrarySurfacePaintAlpha = _paintAlphas.add;
    final startupQuietMs =
        int.tryParse(
          Platform.environment['FLUENT_ROOT_SWITCH_STARTUP_QUIET_MS'] ?? '',
        ) ??
        0;
    if (startupQuietMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: startupQuietMs));
    }
    for (var cycle = 0; cycle < cycles; cycle++) {
      for (final entry in MediaLibraryRootEntry.values) {
        final switcher =
            _find((e) => e.widget is MediaLibraryEntrySwitcher)!.widget
                as MediaLibraryEntrySwitcher;
        if (switcher.selected != entry) await _select(entry, cycle);
      }
      if ((cycle + 1) % 10 == 0 || cycle == cycles - 1) {
        _memory.add({'cycle': cycle + 1, 'rssBytes': ProcessInfo.currentRss});
      }
    }
    // Engine timings are delivered in batches after raster completion.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final refreshRate =
        ui.PlatformDispatcher.instance.views.first.display.refreshRate;
    final budgetUs = 1000000 / (refreshRate > 0 ? refreshRate : 60);
    final reportData = {
      'status': errors.isEmpty ? 'timings_recorded' : 'failed',
      'product': const bool.fromEnvironment('dart.vm.product'),
      'profile': const bool.fromEnvironment('dart.vm.profile'),
      'inputGatesExercised': true,
      'inputMode': _inputMode,
      'mediaCount': LibraryService().storageVideos.length,
      'refreshRate': refreshRate,
      'samples': _samples,
      'firstVisibleFramework': _distribution(
        _samples.map((s) => s['firstVisibleFrameworkMs']! as num),
      ),
      'fullyVisibleFramework': _distribution(
        _samples.map((s) => s['fullyVisibleFrameworkMs']! as num),
      ),
      'pointerDispatch': _distribution(
        _samples.map((s) => s['pointerDispatchMs']! as num),
      ),
      'build': _distribution(
        _frames.map((f) => f.buildDuration.inMicroseconds / 1000),
      ),
      'raster': _distribution(
        _frames.map((f) => f.rasterDuration.inMicroseconds / 1000),
      ),
      'overBudgetFrames': _frames
          .where(
            (f) =>
                f.buildDuration.inMicroseconds > budgetUs ||
                f.rasterDuration.inMicroseconds > budgetUs,
          )
          .length,
      'frameCount': _frames.length,
      'rssCheckpoints': _memory,
      'errors': errors,
      'normalExitValidated': false,
      'note':
          'Production pages and isolated fixture data. Input mode is recorded '
          'above: mouse/touch hit-test the real title and dispatch down/up '
          'through GestureBinding; callback invokes onSelected directly. '
          'Times start immediately before pointer-up dispatch. '
          'Visibility is measured at Flutter frame completion, '
          'not physical display scanout. The runner terminates its owned '
          'process after this report; normal exit is not tested.',
    };
    await report.writeAsString(
      const JsonEncoder.withIndent('  ').convert(reportData),
      flush: true,
    );
  } catch (error, stack) {
    await report.writeAsString(
      jsonEncode({
        'status': 'failed',
        'error': '$error',
        'stack': '$stack',
        'errors': errors,
        'samples': _samples,
      }),
      flush: true,
    );
  } finally {
    WidgetsBinding.instance.removeTimingsCallback(_frames.addAll);
    // ignore: invalid_use_of_visible_for_testing_member
    debugMediaLibrarySurfacePaintAlpha = null;
    FlutterError.onError = previousErrorHandler;
  }
}
