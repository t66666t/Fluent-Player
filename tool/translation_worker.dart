// AOT-compiled by native/translation_worker.cmake. No Flutter, HTTP listener,
// user preferences, or UI; communicate only through private parent/child pipes.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:video_player_app/features/model_center/translation_inference.dart';
import 'package:video_player_app/features/model_center/inference_resource_governor.dart';

Future<void> main() async {
  if (Platform.isWindows) {
    // A driver access violation belongs to the worker; never open a blocking
    // Windows crash dialog while the player is waiting to retry on CPU.
    DynamicLibrary.open(
      'kernel32.dll',
    ).lookupFunction<Uint32 Function(Uint32), int Function(int)>(
      'SetErrorMode',
    )(0x8003);
  }
  final server = TranslationWorkerServer();
  void send(int id, Map<String, Object?> event) => stdout.writeln(
    '$translationWorkerProtocol${jsonEncode({'id': id, ...event})}',
  );
  try {
    await for (final line
        in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      var id = 0;
      try {
        final command = jsonDecode(line) as Map<String, dynamic>;
        id = command['id'] as int;
        send(
          id,
          await server.request(
            command,
            onDelta: (text) => send(id, {'event': 'delta', 'text': text}),
          ),
        );
      } catch (error) {
        send(id, {
          'event': 'error',
          'format': error is FormatException,
          'pressure': isTransientInferencePressure(error),
          'message': error is FormatException ? error.message : 'GPU 推理失败',
        });
      }
    }
  } finally {
    await server.close();
  }
}
