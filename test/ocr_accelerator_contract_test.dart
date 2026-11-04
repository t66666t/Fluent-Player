import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/ocr_accelerator_contract.dart';
import 'package:video_player_app/models/ocr_compute_preferences.dart';
import 'package:video_player_app/models/ocr_model_files.dart';
import 'package:video_player_app/services/ocr_compute_policy.dart';

void main() {
  test('registered GPU exports refer to existing pinned components', () {
    final catalog =
        jsonDecode(File('assets/models/ocr_catalog.json').readAsStringSync())
            as Map;
    final components = {
      for (final c in catalog['components'] as List) c['id']: c as Map,
    };
    for (final id in ocrAcceleratorExports) {
      expect(components.containsKey(id), isTrue, reason: id);
      final files = (components[id]!['files'] as List).map((f) => f['name']);
      expect(
        files,
        containsAll(['inference.onnx', 'inference.yml']),
        reason: id,
      );
    }
    expect(ocrAcceleratorExports.any((id) => id.contains('legacy')), isFalse);
  });
  test('Android modern GPU routes work without NNAPI or Play services', () {
    final caps = OcrComputeCapabilities(
      platform: 'android',
      isolated: true,
      providers: const ['CPU', 'OpenCL', 'Vulkan', 'QNN GPU', 'QNN HTP'],
      devices: [
        for (final provider in ['QNN HTP', 'Vulkan', 'OpenCL', 'QNN GPU'])
          OcrComputeDevice(
            provider: provider,
            id: 0,
            key: provider,
            name: provider,
          ),
      ],
    );
    final automatic = planOcrCompute(const OcrComputePreferences(), caps);
    expect(automatic.device?.provider, 'Vulkan');
    expect(automatic.hardwareFirst, isFalse);
    final hardware = planOcrCompute(
      const OcrComputePreferences(mode: OcrComputeMode.accelerated),
      caps,
    );
    expect(hardware.candidateDevices.map((d) => d.provider), [
      'Vulkan',
      'OpenCL',
      'QNN GPU',
      'QNN HTP',
    ]);
    final explicit = planOcrCompute(
      const OcrComputePreferences(
        mode: OcrComputeMode.accelerated,
        provider: 'QNN HTP',
        deviceKey: 'QNN HTP',
      ),
      caps,
    );
    expect(explicit.candidateDevices.map((d) => d.provider), ['QNN HTP']);
  });
  test(
    'a detection failure is explained without claiming unsupported hardware',
    () {
      const caps = OcrComputeCapabilities(
        platform: 'android',
        isolated: true,
        note: '加速设备检测未完成，CPU 识别仍可使用',
      );
      final plan = planOcrCompute(
        const OcrComputePreferences(mode: OcrComputeMode.accelerated),
        caps,
      );
      expect(plan.note, caps.note);
    },
  );
  test('CPU-only and old worker messages preserve their previous contract', () {
    const old = OcrModelFiles(
      detection: 'det',
      recognition: 'rec',
      dictionary: 'dict',
    );
    expect(old.toMessage().containsKey('acceleratorContract'), isFalse);
    expect(
      OcrModelFiles.fromMessage(old.toMessage()).acceleratorContract,
      isNull,
    );
    for (final provider in [
      'OpenCL',
      'Vulkan',
      'Metal',
      'QNN GPU',
      'QNN HTP',
    ]) {
      final setting = OcrComputePreferences(
        mode: OcrComputeMode.accelerated,
        provider: provider,
      );
      expect(
        OcrComputePreferences.fromJson(setting.toJson()).provider,
        provider,
      );
    }
  });
}
