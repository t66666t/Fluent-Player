import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/model_center/asr_native_enhancer.dart';
import 'package:video_player_app/features/model_center/local_asr_worker.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';

import 'support/local_asr_smoke.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const root = String.fromEnvironment('LOCAL_ASR_MODEL_ROOT');
  test(
    'real community downloads, VAD, ASR, cancellation and checkpoint recovery',
    () async {
      DynamicLibrary.open(p.absolute('windows/runtime/onnxruntime.dll'));
      final configFile = File('.dart_tool/package_config.json').absolute;
      final config = jsonDecode(await configFile.readAsString()) as Map;
      final package = (config['packages'] as List).cast<Map>().singleWhere(
        (m) => m['name'] == 'sherpa_onnx_windows',
      );
      final libraries = p.join(
        configFile.uri.resolve(package['rootUri'] as String).toFilePath(),
        'windows',
      );
      final report = await runLocalAsrSmoke(
        modelRoot: p.absolute(root),
        libraryDirectory: libraries,
      );
      report['vadModelCenterProbe'] = await probeAsrEnhancement(
        'silero-vad',
        {asrVadModelId: p.absolute(root, asrVadModelId)},
        decodeModelWave(
          await File('assets/models/asr/speech_probe_zh.wav').readAsBytes(),
        ),
        libraryDirectory: libraries,
      );
      final output = File('.artifacts/local-asr-repair/windows-results.json');
      await output.parent.create(recursive: true);
      await output.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report),
      );
    },
    skip: root.isEmpty || !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
