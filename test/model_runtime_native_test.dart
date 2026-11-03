import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../tool/verify_model_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const root = String.fromEnvironment('MODEL_RUNTIME_ROOT');
  const sherpa = String.fromEnvironment('SHERPA_DLL');
  const ort = String.fromEnvironment('ORT_DLL');
  const asrOnly = bool.fromEnvironment('ASR_RUNTIME_ONLY');
  test(
    'real local ASR${asrOnly ? '' : ' and translation'} coexist with the OCR ONNX Runtime',
    () async {
      final result = await runModelRuntimeProbe([
        root,
        sherpa,
        ort,
        'assets/models/asr/speech_probe.wav',
      ], includeTranslation: !asrOnly);
      expect(result['asrText'], isNotEmpty);
      if (!asrOnly) {
        expect(result['translation'], matches(RegExp(r'[\u4e00-\u9fff]')));
      }
      expect(result['ocrProvidersAfterAsr'], result['ocrProviders']);
      await File(
        '.artifacts/model-center/runtime-probe.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(result));
    },
    skip: root.isEmpty || !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
