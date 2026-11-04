import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/serial_task_queue.dart';

/// Persists the small, frequently updated resume snapshot without rewriting
/// the entire preferences file on the Windows/Linux UI isolate.
class PlaybackStateStore {
  PlaybackStateStore({
    TargetPlatform? platform,
    Future<Directory> Function()? directoryProvider,
    String storageFileName = fileName,
    String preferenceKey = legacyKey,
  }) : _platform = platform,
       _storageFileName = storageFileName,
       _preferenceKey = preferenceKey,
       _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  static final shared = PlaybackStateStore();
  static const legacyKey = 'playback_state_snapshot';
  static const fileName = 'playback_state_snapshot.json';

  final TargetPlatform? _platform;
  final String _storageFileName;
  final String _preferenceKey;
  final Future<Directory> Function() _directoryProvider;
  final _queue = SerialTaskQueue();

  bool get _usesFile =>
      !kIsWeb &&
      switch (_platform ?? defaultTargetPlatform) {
        TargetPlatform.windows || TargetPlatform.linux => true,
        _ => false,
      };

  Future<void> write(Map<String, dynamic> snapshot) {
    // Capture the value at submission time; queued writes must not observe a
    // later mutation of the caller's snapshot.
    final encoded = jsonEncode(snapshot);
    return _queue.enqueue(() async {
      if (!_usesFile) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_preferenceKey, encoded);
        return;
      }

      final directory = await _directoryProvider();
      await directory.create(recursive: true);
      final file = File(p.join(directory.path, _storageFileName));
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(encoded, flush: true);
      // Replace only after a complete write. Serialization prevents two saves
      // (seek, pause, periodic save) from racing over the temporary file.
      await temporary.rename(file.path);
    });
  }

  Future<Map<String, dynamic>?> read() => _queue.enqueue(() async {
    if (_usesFile) {
      final directory = await _directoryProvider();
      final file = File(p.join(directory.path, _storageFileName));
      if (await file.exists()) {
        return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      }
    }

    // Existing installations keep their resume point on the first launch.
    // Leave the legacy key untouched: even removing it would synchronously
    // rewrite the large preferences file in these desktop plugins.
    final prefs = await SharedPreferences.getInstance();
    final encoded = prefs.getString(_preferenceKey);
    if (encoded == null || encoded.isEmpty) return null;
    return jsonDecode(encoded) as Map<String, dynamic>;
  });
}
