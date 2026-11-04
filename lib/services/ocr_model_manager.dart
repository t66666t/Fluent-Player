import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../features/model_center/model_center_service.dart';
import '../features/model_center/model_catalog.dart';
import '../features/model_center/model_download_sources.dart';
import '../models/ocr_subtitle_models.dart';
import '../models/ocr_accelerator_contract.dart';
import 'ocr_model_catalog.dart';
import 'settings_service.dart';
import '../models/ocr_model_files.dart';

export 'ocr_model_catalog.dart';
export '../models/ocr_model_files.dart';

/// OCR owns presets; transfers, receipts and leases use the application service.
class OcrModelManager {
  const OcrModelManager({this.rootOverride, ModelCenterService? center})
    : _center = center;
  final Directory? rootOverride;
  final ModelCenterService? _center;
  ModelCenterService get center => _center ?? ModelCenterService.instance;
  static Future<List<OcrModelPreset>>? _catalog;
  static Future<List<ModelArtifact>>? _identityCatalog;
  static final _migrations = Expando<Future<void>>();
  Future<List<OcrModelPreset>> presets() => _catalog ??= loadOcrPresets();
  Future<void> initialize() async {
    await center.initialize();
    final pending = _migrations[center] ??= migrateLegacy();
    try {
      await pending;
    } catch (_) {
      _migrations[center] = null;
      rethrow;
    }
  }

  bool isBundled(OcrSubtitleLanguage language) => false;
  int bundledModelCountFor(OcrSubtitleLanguage language) => 0;
  int get totalBundledOnnxModelCount => 0;
  Future<Directory> modelDirectory({bool create = false}) async {
    final root =
        rootOverride ?? await SettingsService().resolveLargeDataRootDir();
    return Directory(p.join(root.path, 'ocr_models', 'ppocr_v4_mobile'));
  }

  Future<OcrModelPreset> preset(String id) async =>
      (await presets()).firstWhere(
        (m) => m.id == id,
        orElse: () => throw StateError('OCR 模型组合不存在，请重新选择'),
      );
  bool ready(OcrModelPreset preset) =>
      preset.componentIds.every(center.installed);
  bool inUse(OcrModelPreset preset) => preset.componentIds.any(center.inUse);
  String identity(OcrModelPreset preset) => preset.identity(center.catalog);

  Future<void> migrateLegacy() async {
    if (center.ocrLegacyMigrationComplete) return;
    final directory = await modelDirectory();
    if (!await directory.exists()) {
      center.ocrLegacyMigrationComplete = true;
      await center.save();
      return;
    }
    for (final model in center.catalog.where(
      (m) => m.engine == 'ppocr-legacy',
    )) {
      if (center.installed(model.id) || center.inUse(model.id)) continue;
      var complete = true;
      for (final file in model.files) {
        final stat = await File(p.join(directory.path, file.name)).stat();
        if (stat.type != FileSystemEntityType.file || stat.size != file.bytes) {
          complete = false;
          break;
        }
      }
      if (complete) await center.importFiles(model.id, directory);
    }
    center.ocrLegacyMigrationComplete = true;
    await center.save();
  }

  Future<bool> isInstalled(
    OcrSubtitleLanguage language, {
    String modelId = '',
  }) async {
    await initialize();
    final model = await preset(
      modelId.isEmpty ? 'legacy-${language.name}' : modelId,
    );
    return model.supports(language) && ready(model);
  }

  Future<OcrSubtitleTrack> freeze(
    OcrSubtitleTrack track, {
    bool requireInstalled = true,
  }) async {
    final resolved = await resolveTrackIdentity(track);
    final model = await preset(resolved.modelId);
    if (requireInstalled && !ready(model)) {
      throw StateError('请在 OCR 模型页下载并选择${track.language.label}模型');
    }
    return resolved;
  }

  /// Uses catalog metadata only, including for models awaiting download.
  Future<OcrSubtitleTrack> resolveTrackIdentity(OcrSubtitleTrack track) async {
    track = migrateRetiredOcrTrack(track);
    final id = track.modelId.isEmpty
        ? 'legacy-${track.language.name}'
        : track.modelId;
    final model = await preset(id);
    if (!model.supports(track.language)) {
      throw StateError('${model.name} 不支持${track.language.label}');
    }
    final components = center.loaded
        ? center.catalog
        : await (_identityCatalog ??= loadModelCatalog());
    return track.copyWith(
      modelId: id,
      modelIdentity: model.identity(components),
    );
  }

  /// Downloads missing shared components before OCR takes an inference slot.
  /// Cancelling the OCR wait leaves the application-owned transfers available.
  Future<void> prepareTracks(
    List<OcrSubtitleTrack> tracks, {
    Future<void>? cancelSignal,
    void Function(double, String)? onProgress,
  }) async {
    tracks = tracks.map(migrateRetiredOcrTrack).toList();
    var cancelled = false;
    var finished = false;
    unawaited(
      cancelSignal?.then((_) {
        if (!finished) cancelled = true;
      }),
    );
    void checkCancelled() {
      if (cancelled) throw const OcrDownloadCancelled();
    }

    try {
      await initialize();
      checkCancelled();
      final components = <String>{};
      for (final track in tracks) {
        final frozen = await freeze(track, requireInstalled: false);
        final model = await preset(frozen.modelId);
        if (track.modelIdentity.isNotEmpty &&
            track.modelIdentity != frozen.modelIdentity) {
          throw StateError('OCR 模型版本已变化，请重新开始任务');
        }
        if (model.legacy && !ready(model)) {
          throw StateError('${model.name} 需要离线导入，请选择新版模型自动下载');
        }
        components.addAll(model.componentIds);
      }
      for (final id in components) {
        checkCancelled();
        if (center.installed(id)) continue;
        final phase = center.downloads[id]?.phase;
        if (phase != ModelDownloadPhase.queued &&
            phase != ModelDownloadPhase.downloading &&
            phase != ModelDownloadPhase.verifying) {
          await center.enqueue(id);
        }
      }
      final total = components.fold<int>(
        0,
        (sum, id) => sum + center.artifact(id)!.bytes,
      );
      while (components.any((id) => !center.installed(id))) {
        checkCancelled();
        final changed = Completer<void>();
        void onChanged() {
          if (!changed.isCompleted) changed.complete();
        }

        center.addListener(onChanged);
        try {
          final missing = components.where((id) => !center.installed(id));
          for (final id in missing) {
            final state = center.downloads[id];
            if (state == null ||
                state.phase == ModelDownloadPhase.failed ||
                state.phase == ModelDownloadPhase.paused) {
              throw StateError(
                '${center.artifact(id)!.name}：${state?.message ?? '模型下载已停止'}；请重试 OCR 识别',
              );
            }
          }
          final received = components.fold<int>(
            0,
            (sum, id) =>
                sum +
                (center.installed(id)
                    ? center.artifact(id)!.bytes
                    : (center.downloads[id]?.received ?? 0).clamp(
                        0,
                        center.artifact(id)!.bytes,
                      )),
          );
          final waiting = missing.first;
          final state = center.downloads[waiting]!;
          onProgress?.call(
            total == 0 ? 0 : (received / total).clamp(0, 1),
            '${center.artifact(waiting)!.name} · ${state.message.isEmpty ? state.label : state.message}'
            ' · ${modelBytes(received)} / ${modelBytes(total)}',
          );
          await Future.any<void>([changed.future, ?cancelSignal]);
        } finally {
          center.removeListener(onChanged);
        }
      }
      checkCancelled();
      onProgress?.call(1, 'OCR 模型已就绪');
    } finally {
      finished = true;
    }
  }

  Future<OcrModelFiles> filesFor(OcrSubtitleTrack track) async {
    final model = await preset(track.modelId);
    if (track.modelIdentity.isNotEmpty &&
        track.modelIdentity != identity(model)) {
      throw StateError('OCR 模型版本已变化，请重新开始任务');
    }
    final det = center.artifact(model.detection)!;
    final rec = center.artifact(model.recognition)!;
    final detDir = await center.modelDirectory(det);
    final recDir = await center.modelDirectory(rec);
    if (model.legacy) {
      final recognizer = rec.files.firstWhere((f) => f.name.contains('_rec_'));
      final dictionary = rec.files.firstWhere((f) => f.name.endsWith('.txt'));
      return OcrModelFiles(
        detection: p.join(detDir.path, det.files.first.name),
        recognition: p.join(recDir.path, recognizer.name),
        dictionary: p.join(recDir.path, dictionary.name),
        identity: identity(model),
      );
    }
    return OcrModelFiles(
      detection: p.join(detDir.path, 'inference.onnx'),
      recognition: p.join(recDir.path, 'inference.onnx'),
      dictionary: p.join(recDir.path, 'inference.yml'),
      detectionConfig: p.join(detDir.path, 'inference.yml'),
      identity: identity(model),
      legacy: false,
      acceleratorContract:
          ocrAcceleratorExports.contains(det.id) &&
              ocrAcceleratorExports.contains(rec.id)
          ? ocrAcceleratorContract
          : null,
    );
  }

  Future<OcrModelFiles> ensureInstalled(
    OcrSubtitleLanguage language, {
    void Function(double, String)? onProgress,
    bool Function()? isCancelled,
  }) async {
    await initialize();
    if (isCancelled?.call() == true) throw const OcrDownloadCancelled();
    return filesFor(
      await freeze(
        OcrSubtitleTrack(
          number: 1,
          region: const NormalizedOcrRegion.subtitleDefault(),
          language: language,
        ),
      ),
    );
  }

  Future<void> download(OcrModelPreset model) async {
    await initialize();
    if (model.legacy) throw StateError('旧版模型仅支持离线导入，请选择新版模型下载');
    for (final id in model.componentIds) {
      await center.enqueue(id);
    }
  }

  Future<void> pause(OcrModelPreset model) async {
    for (final id in model.componentIds) {
      await center.pause(id);
    }
  }

  Future<void> verify(OcrModelPreset model) async {
    for (final id in model.componentIds) {
      await center.verify(id);
    }
  }

  Future<void> importFiles(OcrModelPreset model, Directory source) async {
    await initialize();
    for (final id in model.componentIds) {
      final nested = Directory(p.join(source.path, id));
      await center.importFiles(id, await nested.exists() ? nested : source);
    }
  }

  Future<void> remove(OcrModelPreset model) async {
    if (inUse(model)) throw StateError('模型正在使用，请先停止任务');
    final all = await presets();
    // Recognition is unique to a preset. Remove it first so readiness no
    // longer makes this preset protect its own shared detector.
    for (final id in [
      model.recognition,
      if (model.detection != model.recognition) model.detection,
    ]) {
      final shared = all.any(
        (other) =>
            other.id != model.id &&
            other.componentIds.contains(id) &&
            (ready(other) ||
                (other.recognition != id &&
                    center.downloads[other.recognition] != null)),
      );
      if (!shared && center.installed(id)) await center.remove(id);
    }
  }

  Future<void> deleteLanguage(OcrSubtitleLanguage language) async =>
      remove(await preset('legacy-${language.name}'));
  Future<List<ModelSourceProbeResult>> probe(
    OcrModelPreset model,
    CancelToken cancel,
  ) async {
    final artifact = center.artifact(model.recognition)!;
    final file = artifact.files.firstWhere((f) => f.name.endsWith('.onnx'));
    return center.probeDownloadSources(artifact.id, file, cancel);
  }
}

class OcrDownloadCancelled implements Exception {
  const OcrDownloadCancelled();
}
