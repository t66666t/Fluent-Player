import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/local_asr_worker.dart';
import 'package:video_player_app/features/model_center/qwen_asr_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const helper = String.fromEnvironment('QWEN_POISON_HELPER');
  const root = String.fromEnvironment('QWEN_NATIVE_MODEL_ROOT');
  test(
    'a real GPU helper crash falls back to fresh native CPU inference',
    () async {
      final states = <Map<String, dynamic>>[];
      final scratch = await Directory.systemTemp.createTemp(
        'qwen-driver-fault-',
      );
      final decoder = QwenAsrDecoder(
        model: '$root/qwen3-asr-0.6b-f16/qwen3-asr-0.6b.gguf',
        identity: 'driver-fault-check',
        language: 'en',
        hotwords: '',
        threads: 2,
        mode: 'gpu',
        executable: helper,
        runtimeDirectory: scratch.path,
        onLoad: () {},
        onState: states.add,
      );
      try {
        final audio = decodeModelWave(
          await File('assets/models/asr/speech_probe.wav').readAsBytes(),
        );
        final result = await decoder.decode(audio, () {});
        expect(result['text'], isNotEmpty);
        expect(result['_backend'], 'CPU');
        expect(states.last['reason'], contains('回退 CPU'));
      } finally {
        await decoder.close();
      }
      expect(await scratch.list().toList(), isEmpty);
      await scratch.delete();
    },
    skip: !Platform.isWindows || helper.isEmpty || root.isEmpty,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
