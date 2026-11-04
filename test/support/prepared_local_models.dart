import 'dart:io';

import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';

import '../../tool/local_asr_probe_assets.dart';

/// Opt-in native probes bind usingModel/usingAsrModels to prepared fixtures.
/// They must not start production downloads into their disposable storage.
/// The real automatic-preparation path is tested by local_asr_native_smoke_test.
mixin PreparedLocalModels on ModelCenterService {
  @override
  Future<void> prepareModel(
    ModelJobSpec spec, {
    Future<void>? cancelSignal,
    void Function(String)? onProgress,
  }) => usingModel(spec.profile.model, (model, _) async {
    if (model.identity != spec.artifactIdentity) {
      throw StateError('Prepared model identity differs from the frozen task');
    }
  });

  @override
  Future<File> prepareAsrModels(
    ModelJobSpec spec, {
    Future<void>? cancelSignal,
    void Function(String)? onProgress,
  }) async {
    await prepareAsrEnhancements(
      spec,
      cancelSignal: cancelSignal,
      onProgress: onProgress,
    );
    return File(asrProbeVadPath());
  }
}
