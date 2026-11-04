// Real production entry point with isolated preferences, paths and clipboard.
// FLUENT_PERF_ROOT must contain data/library.json from the benchmark fixtures.
// flutter build windows --profile --no-pub
// -t scripts/isolated_app_startup_profile.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'package:video_player_app/main.dart' as application;
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/utils/app_toast.dart';

final _clock = Stopwatch()..start();
final _timings = <ui.FrameTiming>[];
File? _report;
Timer? _deadline;
int? _firstFrameUs, _homeFrameUs, _eventLoopUs, _miniFrameUs;
bool _finishing = false;

Map<String, Object> _distribution(Iterable<int> data) {
  final values = data.toList()..sort();
  if (values.isEmpty) return {'count': 0};
  double percentile(double value) =>
      values[((values.length - 1) * value).round()] / 1000;
  return {
    'count': values.length,
    'p50Ms': percentile(.5),
    'p95Ms': percentile(.95),
    'p99Ms': percentile(.99),
    'maxMs': values.last / 1000,
  };
}

Future<void> _finish({String? error}) async {
  if (_finishing) return;
  _finishing = true;
  _deadline?.cancel();
  final cache = PaintingBinding.instance.imageCache;
  await _report!.writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'status': error == null ? 'passed' : 'failed',
      'error': error,
      'platform': Platform.operatingSystem,
      'profile': const bool.fromEnvironment('dart.vm.profile'),
      'product': const bool.fromEnvironment('dart.vm.product'),
      'terminationPolicy':
          Platform.environment['FLUENT_PERF_MEASUREMENT_ONLY'] == 'true'
          ? 'Runner terminates this owned process after the completed report; normal exit is not validated'
          : 'Normal window close',
      'firstFlutterFrameMs': _firstFrameUs == null
          ? null
          : _firstFrameUs! / 1000,
      'homeFrameworkFrameMs': _homeFrameUs == null
          ? null
          : _homeFrameUs! / 1000,
      'homeEventLoopReadyMs': _eventLoopUs == null
          ? null
          : _eventLoopUs! / 1000,
      'restoredMiniFrameMs': _miniFrameUs == null ? null : _miniFrameUs! / 1000,
      'mediaCount': LibraryService().storageVideos.length,
      'rssBytes': ProcessInfo.currentRss,
      'maxRssBytes': ProcessInfo.maxRss,
      'decodedImageCacheBytes': cache.currentSizeBytes,
      'liveImages': cache.liveImageCount,
      'build': _distribution(
        _timings.map((f) => f.buildDuration.inMicroseconds),
      ),
      'raster': _distribution(
        _timings.map((f) => f.rasterDuration.inMicroseconds),
      ),
      'note':
          'Times start at the Dart entry point, not OS process launch. No saved playback fixture unless restoredMiniFrameMs is populated.',
    }),
    flush: true,
  );
  if (Platform.environment['FLUENT_PERF_MEASUREMENT_ONLY'] == 'true') return;
  if (Platform.isWindows) {
    // Use the regular WM_CLOSE path, including native window cleanup. Neither
    // direct process exit nor PostQuitMessage models closing the app window.
    await windowManager.close();
    return;
  }
  exit(error == null ? 0 : 1);
}

class _StartupBinding extends WidgetsFlutterBinding {
  @override
  BinaryMessenger createBinaryMessenger() =>
      _ClipboardIsolation(super.createBinaryMessenger());

  @override
  void drawFrame() {
    super.drawFrame();
    _firstFrameUs ??= _clock.elapsedMicroseconds;
    if (_report == null) return;
    if (MediaPlaybackService().shouldShowMiniPlaybackCard) {
      _miniFrameUs ??= _clock.elapsedMicroseconds;
    }
    if (_homeFrameUs == null &&
        AppToast.navigatorKey.currentState != null &&
        LibraryService().isInitialized) {
      _homeFrameUs = _clock.elapsedMicroseconds;
      Timer.run(() => _eventLoopUs ??= _clock.elapsedMicroseconds);
      Timer(const Duration(seconds: 4), () => unawaited(_finish()));
    }
  }
}

class _ClipboardIsolation extends BinaryMessenger {
  const _ClipboardIsolation(this.delegate);
  final BinaryMessenger delegate;
  static const codec = JSONMethodCodec();
  @override
  Future<ByteData?>? send(String channel, ByteData? message) {
    if (channel == 'flutter/platform' && message != null) {
      final method = codec.decodeMethodCall(message).method;
      if (method == 'Clipboard.getData') {
        return Future.value(codec.encodeSuccessEnvelope(null));
      }
      if (method == 'Clipboard.hasStrings') {
        return Future.value(codec.encodeSuccessEnvelope({'value': false}));
      }
    }
    return delegate.send(channel, message);
  }

  @override
  void setMessageHandler(String channel, MessageHandler? handler) =>
      delegate.setMessageHandler(channel, handler);
  @override
  Future<void> handlePlatformMessage(
    String channel,
    ByteData? data,
    ui.PlatformMessageResponseCallback? callback,
  ) {
    // ignore: deprecated_member_use
    return delegate.handlePlatformMessage(channel, data, callback);
  }
}

class _FixturePaths extends PathProviderPlatform {
  _FixturePaths(this.root);
  final Directory root;
  String path(String name) => p.join(root.path, name);
  @override
  Future<String?> getTemporaryPath() async => path('temporary');
  @override
  Future<String?> getApplicationSupportPath() async => path('support');
  @override
  Future<String?> getApplicationDocumentsPath() async => path('documents');
  @override
  Future<String?> getApplicationCachePath() async => path('cache');
  @override
  Future<String?> getLibraryPath() async => path('support');
  @override
  Future<String?> getDownloadsPath() async => path('downloads');
  @override
  Future<String?> getExternalStoragePath() async => path('external');
  @override
  Future<List<String>?> getExternalCachePaths() async => [
    path('external-cache'),
  ];
  @override
  Future<List<String>?> getExternalStoragePaths({
    StorageDirectory? type,
  }) async => [path('external')];
}

Future<void> main() async {
  // Top-level Dart variables are lazy; start the origin at main, not drawFrame.
  _clock.start();
  final rootPath =
      Platform.environment['FLUENT_PERF_ROOT'] ??
      const String.fromEnvironment('PERF_ROOT');
  final output =
      Platform.environment['FLUENT_PERF_REPORT'] ??
      const String.fromEnvironment('PERF_REPORT');
  if (!p.isAbsolute(rootPath) || !p.isAbsolute(output)) {
    throw ArgumentError('PERF_ROOT and PERF_REPORT must be absolute');
  }
  final root = Directory(rootPath);
  if (!await File(p.join(root.path, 'data', 'library.json')).exists()) {
    throw ArgumentError('Isolated data/library.json fixture is required');
  }
  _StartupBinding();
  _report = File(output);
  await _report!.parent.create(recursive: true);
  final paths = _FixturePaths(root);
  for (final name in [
    'support',
    'documents',
    'cache',
    'temporary',
    'downloads',
    'program',
    'external',
    'external-cache',
  ]) {
    await Directory(paths.path(name)).create(recursive: true);
  }
  PathProviderPlatform.instance = paths;
  // Dedicated benchmark process: never touch the user's native preferences.
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues({
    'largeDataRootPath': paths.path('data'),
    // Navigation probes must click the library, not a first-run login barrier.
    // This changes only the probe's private in-memory preferences.
    if (Platform.environment.containsKey('FLUENT_ROOT_SWITCH_INPUT'))
      'suppressBilibiliRestrictedDialog': true,
  });
  AppStorageService.instance = AppStorageService(
    locations: () async => StorageLocations(
      platform: StoragePlatform.values.byName(Platform.operatingSystem),
      support: Directory(paths.path('support')),
      documents: Directory(paths.path('documents')),
      cache: Directory(paths.path('cache')),
      defaultData: Directory(paths.path('data')),
      executable: Directory(paths.path('program')),
    ),
  );
  WidgetsBinding.instance.addTimingsCallback(
    (frames) => _timings.addAll(frames),
  );
  _deadline = Timer(
    const Duration(seconds: 45),
    () => unawaited(_finish(error: 'Home did not become ready')),
  );
  application.main();
}
