// Compile only for the native recovery test. Never bundled with the player.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:video_player_app/services/ocr_worker_protocol.dart';
import 'package:video_player_app/services/ocr_worker_server.dart';

Future<void> main(List<String> arguments) async {
  final markerPath = Platform.environment['OCR_TEST_FAULT_MARKER'];
  if (markerPath == null || markerPath.isEmpty) exit(2);
  final marker = File(markerPath);
  final startupMarkerPath =
      Platform.environment['OCR_TEST_STARTUP_FAULT_MARKER'];
  void send(Map<String, Object?> m) =>
      stdout.writeln('$ocrWorkerProtocol${jsonEncode(m)}');
  final admissions = <int, Completer<void>>{};
  var allocationId = 0;
  final server = OcrWorkerServer((bytes) async {
    final id = ++allocationId, pending = Completer<void>();
    admissions[id] = pending;
    send({'event': 'allocation', 'allocationId': id, 'bytes': bytes});
    try {
      await pending.future.timeout(const Duration(seconds: 30));
    } finally {
      admissions.remove(id);
    }
  });
  var chain = Future<void>.value();
  final done = Completer<void>();
  Future<void> handle(Map<String, dynamic> m) async {
    final id = m['id'];
    if (m['op'] == 'start' && startupMarkerPath != null) {
      final startupMarker = File(startupMarkerPath);
      if (!await startupMarker.exists()) {
        await startupMarker.parent.create(recursive: true);
        await startupMarker.writeAsString(
          'one process exit during startup',
          flush: true,
        );
        exit(139);
      }
    }
    if (m['op'] == 'frame' &&
        (m['command'] as Map)['atMs'] >= 6600 &&
        !await marker.exists()) {
      await marker.parent.create(recursive: true);
      await marker.writeAsString(
        'one native-process exit at 6600ms',
        flush: true,
      );
      // Simulate a fatal native exit: no Dart cleanup, error or response.
      exit(139);
    }
    try {
      send({'id': id, ...await server.request(m)});
    } catch (e) {
      send({'id': id, 'error': '$e'});
    }
  }

  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    final m = jsonDecode(line) as Map<String, dynamic>;
    if (m['op'] == 'allocationReply') {
      final pending = admissions[m['allocationId']];
      if (pending != null && !pending.isCompleted) {
        if (m['error'] == null) {
          pending.complete();
        } else {
          pending.completeError(StateError(m['error'] as String));
        }
      }
    } else {
      chain = chain.then((_) => handle(m));
    }
  }, onDone: done.complete);
  await done.future;
  await chain;
  await server.close();
}
