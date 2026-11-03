import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/device_resource_snapshot.dart';
import 'package:video_player_app/features/model_center/inference_resource_governor.dart';
import 'package:video_player_app/models/ocr_compute_preferences.dart';
import 'package:video_player_app/services/ocr_compute_policy.dart';
import 'package:video_player_app/services/ocr_compute_service.dart';

const integrated = OcrComputeDevice(
  provider: 'DirectML',
  id: 0,
  key: 'intel-card',
  name: 'Intel GPU',
  dedicatedBytes: 128 * 1048576,
);
const discrete = OcrComputeDevice(
  provider: 'DirectML',
  id: 1,
  key: 'nvidia-card',
  name: 'NVIDIA GPU',
  dedicatedBytes: 8 * 1073741824,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('corrupt or older preferences retain the safe default', () {
    for (final value in [null, true, 99, <Object>[]]) {
      expect(OcrComputePreferences.fromJson(value).isDefault, isTrue);
    }
    final corrupt = OcrComputePreferences.fromJson({
      'mode': 'bogus',
      'provider': ['CUDA'],
      'deviceId': -1,
      'deviceKey': 22,
      'coreMLUnits': 'bogus',
    });
    expect(corrupt.isDefault, isTrue);
    const prefs = OcrComputePreferences(
      mode: OcrComputeMode.accelerated,
      provider: 'DirectML',
      deviceKey: 'nvidia-card',
      deviceId: 1,
    );
    expect(
      OcrComputePreferences.fromJson(
        jsonDecode(jsonEncode(prefs.toJson())),
      ).signature,
      prefs.signature,
    );
  });
  test(
    'Windows selects a real adapter and follows its identity after reordering',
    () {
      const caps = OcrComputeCapabilities(
        platform: 'windows',
        isolated: true,
        providers: ['CPU', 'DirectML'],
        devices: [integrated, discrete],
      );
      expect(
        planOcrCompute(const OcrComputePreferences(), caps).device,
        discrete,
      );
      final explicit = planOcrCompute(
        const OcrComputePreferences(
          mode: OcrComputeMode.accelerated,
          provider: 'DirectML',
          deviceId: 0,
          deviceKey: 'nvidia-card',
        ),
        caps,
      );
      expect(explicit.device?.id, 1);
      expect(explicit.hardwareFirst, isTrue);
      final missing = planOcrCompute(
        const OcrComputePreferences(
          mode: OcrComputeMode.accelerated,
          provider: 'DirectML',
          deviceKey: 'disconnected-card',
        ),
        caps,
      );
      expect(missing.device, isNull);
      expect(missing.note, contains('回退'));
    },
  );
  for (final platform in ['windows', 'linux', 'android', 'macos', 'ios']) {
    test(
      '$platform CPU mode excludes hardware even when a driver is available',
      () {
        final caps = OcrComputeCapabilities(
          platform: platform,
          isolated: true,
          providers: const ['CPU', 'XNNPACK', 'DirectML'],
          devices: const [discrete],
        );
        final cpu = planOcrCompute(
          const OcrComputePreferences(mode: OcrComputeMode.cpu),
          caps,
        );
        expect(cpu.device, isNull);
        expect(cpu.allowedProviders, ['CPU', 'XNNPACK']);
      },
    );
  }
  for (final platform in ['windows', 'linux', 'macos']) {
    test(
      '$platform keeps GPU drivers out of the player when helper is absent',
      () {
        final plan = planOcrCompute(
          const OcrComputePreferences(mode: OcrComputeMode.accelerated),
          OcrComputeCapabilities(
            platform: platform,
            providers: const ['CPU', 'DirectML'],
            devices: const [discrete],
          ),
        );
        expect(plan.device, isNull);
        expect(plan.note, contains('独立加速组件'));
      },
    );
  }
  for (final platform in ['android', 'ios']) {
    test(
      '$platform default stays on CPU while explicit hardware mode is supported',
      () {
        final provider = platform == 'android' ? 'NNAPI' : 'CoreML';
        final caps = OcrComputeCapabilities(
          platform: platform,
          isolated: platform == 'android',
          providers: ['CPU', provider],
          devices: [
            OcrComputeDevice(
              provider: provider,
              id: 0,
              key: '$provider:system',
              name: 'System accelerator',
            ),
          ],
        );
        expect(
          planOcrCompute(const OcrComputePreferences(), caps).device,
          isNull,
        );
        expect(
          planOcrCompute(
            const OcrComputePreferences(mode: OcrComputeMode.accelerated),
            caps,
          ).device?.provider,
          provider,
        );
      },
    );
  }
  test(
    'preferences and hardware quarantine survive restart and can be retried',
    () async {
      SharedPreferences.setMockInitialValues({});
      final service = OcrComputeService();
      await service.loadPreferences();
      const preference = OcrComputePreferences(mode: OcrComputeMode.cpu);
      await service.savePreferences(preference);
      await service.markFailed('model-revision', 'runtime:gpu', 'ALL');
      final restored = OcrComputeService();
      expect(
        (await restored.loadPreferences()).signature,
        preference.signature,
      );
      expect(restored.failed('model-revision', 'runtime:gpu', 'ALL'), isTrue);
      expect(restored.failed('other-revision', 'runtime:gpu', 'ALL'), isFalse);
      await restored.capabilities(refresh: true);
      expect(restored.failed('model-revision', 'runtime:gpu', 'ALL'), isFalse);
    },
  );
  test(
    'late allocation callbacks cannot leave a cancelled permit charged',
    () async {
      final refreshed = Completer<void>();
      var delayRefresh = false;
      final resources = InferenceResourceSession(
        InferenceResourceGovernor(
          DeviceResourceSnapshot(
            platform: 'android',
            processors: 8,
            capturedAt: DateTime.now(),
            memoryBytes: 8 * 1073741824,
            availableMemoryBytes: 700 * 1048576,
          ),
        ),
        refreshSnapshot: () =>
            delayRefresh ? refreshed.future : Future<void>.value(),
      );
      final permit = await resources.acquire(InferenceLane.ocr, requested: 2);
      delayRefresh = true;
      final allocation = resources.checkAllocation(
        300 * 1048576,
        permit: permit,
      );
      permit.release();
      refreshed.complete();
      await allocation;
      expect(resources.admitsAdditional(400 * 1048576), isTrue);
      permit.release();
      expect(resources.admitsAdditional(400 * 1048576), isTrue);
      await resources.close();
    },
  );
}
