import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ffi';
import 'package:path/path.dart' as p;

import 'package:video_player_app/services/ocr_device_probe.dart';
import 'package:video_player_app/services/ocr_worker_server.dart';
import 'package:video_player_app/services/ocr_worker_protocol.dart';

/// No Flutter engine, network listener, shell commands, or arbitrary library
/// paths. The helper consumes only the app's framed local OCR protocol.
Future<void> main(List<String> arguments) async {
  // Preload the private runtime explicitly, including on hardened macOS where
  // DYLD environment search paths may be ignored. No app-wide DLL is replaced.
  final runtimeName = Platform.isWindows
      ? 'onnxruntime.dll'
      : Platform.isMacOS
      ? 'libonnxruntime.1.21.0.dylib'
      : 'libonnxruntime.so.1.22.0';
  final runtime = File(
    p.join(p.dirname(Platform.resolvedExecutable), runtimeName),
  );
  if (runtime.existsSync()) DynamicLibrary.open(runtime.path);
  void send(Map<String, Object?> message) =>
      stdout.writeln('$ocrWorkerProtocol${jsonEncode(message)}');
  if (arguments.length == 1 &&
      (arguments.single == '--capabilities' ||
          arguments.single.startsWith('--capabilities-provider='))) {
    try {
      final provider = arguments.single == '--capabilities'
          ? null
          : arguments.single.substring('--capabilities-provider='.length);
      send(
        probeOcrDevices(
          isolated: true,
          probeNativeHardware: provider != null,
          onlyProvider: provider,
        ).toJson(),
      );
    } catch (_) {
      send({
        'platform': Platform.operatingSystem,
        'providers': ['CPU'],
        'devices': [],
        'isolated': true,
      });
    }
    return;
  }
  var nextAllocation = 0;
  final allocations = <int, Completer<void>>{};
  Future<void> checkAllocation(int bytes) async {
    final id = ++nextAllocation, pending = Completer<void>();
    allocations[id] = pending;
    try {
      send({'event': 'allocation', 'allocationId': id, 'bytes': bytes});
      await pending.future.timeout(const Duration(seconds: 30));
    } finally {
      allocations.remove(id);
    }
  }

  var chain = Future<void>.value();
  final server = OcrWorkerServer(checkAllocation);
  final inputDone = Completer<void>();
  Future<void> handle(Map<String, dynamic> message) async {
    final id = message['id'];
    if (id is! int) return;
    try {
      send({'id': id, ...await server.request(message)});
    } catch (error) {
      send({'id': id, 'error': '$error'});
    }
  }

  // Admission replies bypass the serialized work queue: start/inference may
  // be waiting for them while the worker owns its native compute permit.
  stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        (line) {
          try {
            final message = jsonDecode(line) as Map<String, dynamic>;
            if (message['op'] == 'allocationReply') {
              final pending = allocations[message['allocationId']];
              if (pending != null && !pending.isCompleted) {
                if (message['error'] == null) {
                  pending.complete();
                } else {
                  pending.completeError(StateError(message['error'] as String));
                }
              }
            } else {
              chain = chain.then((_) => handle(message));
            }
          } catch (_) {
            /* Malformed messages never execute work. */
          }
        },
        onDone: inputDone.complete,
        onError: (Object _) => inputDone.complete(),
      );
  await inputDone.future;
  for (final request in allocations.values) {
    if (!request.isCompleted) {
      request.completeError(StateError('OCR controller disconnected'));
    }
  }
  await chain;
  await server.close();
}
