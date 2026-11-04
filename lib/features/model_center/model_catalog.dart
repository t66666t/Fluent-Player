import 'dart:convert';

import 'package:flutter/services.dart';

import 'subtitle_segmentation.dart';
import 'asr_enhancement_options.dart';
import 'asr_acceleration.dart';
import 'model_adapters.dart';
import 'cloud_asr_types.dart';
export 'cloud_asr_types.dart';

enum ModelPurpose { transcription, translation, enhancement, acceleration, ocr }

// Fixed shared dependency; it used to be bundled with exactly these bytes.
// Keep it outside job snapshots so existing ASR checkpoints remain compatible.
const asrVadModelId = 'silero-vad-16k';
const asrVadFileName = 'silero_vad.onnx';

enum AsrExecutionMode { auto, lowMemory, pipeline }

class ModelFile {
  const ModelFile({
    required this.name,
    required this.bytes,
    required this.sha256,
    required this.sources,
  });
  final String name;
  final int bytes;
  final String sha256;
  final Map<String, String> sources;

  factory ModelFile.fromJson(Map<String, dynamic> json) {
    final name = json['name'] as String;
    final hash = json['sha256'] as String;
    if (name == '.' ||
        name == '..' ||
        json['bytes'] is! int ||
        (json['bytes'] as int) <= 0 ||
        !RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(name) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw const FormatException('模型文件清单无效');
    }
    return ModelFile(
      name: name,
      bytes: json['bytes'] as int,
      sha256: hash,
      sources: Map<String, String>.from(json['sources'] as Map),
    );
  }
}

class ModelArtifact {
  const ModelArtifact({
    required this.id,
    required this.name,
    required this.engine,
    required this.revision,
    required this.parameters,
    required this.quantization,
    required this.languages,
    required this.description,
    required this.license,
    required this.homepage,
    required this.purpose,
    required this.files,
    required this.suggestedRamGb,
    required this.memoryNote,
    this.retired = false,
  });
  final String id, name, engine, revision, parameters, quantization;
  final List<String> languages;
  final String description, license, homepage, memoryNote;
  final ModelPurpose purpose;

  /// Hidden from new selections/downloads, retained for frozen installed jobs.
  final bool retired;
  final List<ModelFile> files;

  /// A conservative recommendation, never a measured minimum.
  final int suggestedRamGb;
  int get bytes => files.fold(0, (sum, file) => sum + file.bytes);
  String get identity => '$id@$revision';

  factory ModelArtifact.fromJson(Map<String, dynamic> json) => ModelArtifact(
    id: json['id'] as String,
    name: json['name'] as String,
    engine: json['engine'] as String,
    revision: json['revision'] as String,
    parameters: json['parameters'] as String,
    quantization: json['quantization'] as String,
    languages: List<String>.from(json['languages'] as List),
    description: json['description'] as String,
    license: json['license'] as String,
    homepage: json['homepage'] as String,
    purpose: ModelPurpose.values.byName(json['purpose'] as String),
    suggestedRamGb: json['suggestedRamGb'] as int,
    memoryNote: json['memoryNote'] as String,
    retired: json['retired'] == true,
    files: (json['files'] as List)
        .map((e) => ModelFile.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(growable: false),
  );
}

Future<List<ModelArtifact>> loadModelCatalog({
  bool includeRetired = false,
}) async {
  final json =
      jsonDecode(await rootBundle.loadString('assets/models/catalog.json'))
          as Map;
  final ocr =
      jsonDecode(await rootBundle.loadString('assets/models/ocr_catalog.json'))
          as Map;
  final dependencies =
      jsonDecode(
            await rootBundle.loadString('assets/models/asr_dependencies.json'),
          )
          as Map;
  return [
        ...json['models'] as List,
        ...dependencies['models'] as List,
        ...ocr['components'] as List,
      ]
      .map((e) => ModelArtifact.fromJson(Map<String, dynamic>.from(e as Map)))
      .where((model) => includeRetired || !model.retired)
      .toList(growable: false);
}

String modelBytes(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1048576).toStringAsFixed(0)} MB';
  }
  return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
}

enum ModelDownloadPhase {
  queued,
  downloading,
  verifying,
  installed,
  paused,
  failed,
}

class ModelDownload {
  ModelDownload({
    required this.artifactId,
    this.phase = ModelDownloadPhase.queued,
    this.received = 0,
    this.message = '',
    this.bytesPerSecond = 0,
    this.fileState = const {},
    this.checkedAt,
    this.sourcePreference,
  });
  final String artifactId;
  ModelDownloadPhase phase;
  int received;
  String message;
  double bytesPerSecond;
  DateTime? checkedAt;
  String? sourcePreference;
  Map<String, dynamic> fileState;
  String get label => switch (phase) {
    ModelDownloadPhase.queued => '等待下载',
    ModelDownloadPhase.downloading => '正在下载',
    ModelDownloadPhase.verifying => '正在校验',
    ModelDownloadPhase.installed => '已安装',
    ModelDownloadPhase.paused => '已暂停',
    ModelDownloadPhase.failed => '需要处理',
  };
  Map<String, dynamic> toJson() => {
    'artifactId': artifactId,
    'phase': phase.name,
    'received': received,
    'message': message,
    'fileState': fileState,
    if (sourcePreference != null) 'sourcePreference': sourcePreference,
    if (checkedAt != null) 'checkedAt': checkedAt!.toIso8601String(),
  };
  factory ModelDownload.fromJson(Map<String, dynamic> json) => ModelDownload(
    artifactId: json['artifactId'] as String,
    phase: ModelDownloadPhase.values.firstWhere(
      (e) => e.name == json['phase'],
      orElse: () => ModelDownloadPhase.paused,
    ),
    received: (json['received'] as num?)?.toInt() ?? 0,
    message: json['message'] as String? ?? '',
    fileState: Map<String, dynamic>.from(json['fileState'] as Map? ?? {}),
    checkedAt: DateTime.tryParse(json['checkedAt'] as String? ?? ''),
    sourcePreference: json['sourcePreference'] as String?,
  );
}

enum TranscriptionServiceKind {
  gongyi,
  local,
  openai,
  tencent,
  aliyun,
  volcengine,
  elevenlabs,
  soniox,
  assemblyai,
  deepgram,
  gemini,
}

class ModelServiceProfile {
  const ModelServiceProfile({
    required this.id,
    required this.name,
    required this.kind,
    this.endpoint = '',
    this.model = '',
    this.language = 'auto',
    this.appId = '',
    this.cloudOptions,
    this.cloudCapabilities,
  });
  final String id, name, endpoint, model, language, appId;
  final TranscriptionServiceKind kind;
  final CloudAsrOptions? cloudOptions;
  final CloudAsrCapabilities? cloudCapabilities;
  CloudAsrProvider? get cloudProvider => CloudAsrProvider.values
      .where((value) => value.name == kind.name)
      .firstOrNull;
  bool get local => kind == TranscriptionServiceKind.local;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'endpoint': endpoint,
    'model': model,
    'language': language,
    'appId': appId,
    if (cloudProvider != null && cloudOptions != null)
      'cloudOptions': cloudOptions!.toJson(),
    if (cloudProvider != null && cloudCapabilities != null)
      'cloudCapabilities': cloudCapabilities!.toJson(),
  };
  factory ModelServiceProfile.fromJson(Map<String, dynamic> json) {
    final endpoint = json['endpoint'] as String? ?? '';
    final model = json['model'] as String? ?? '';
    var kind = TranscriptionServiceKind.values
        .where((value) => value.name == json['kind'])
        .firstOrNull;
    if (kind == null) {
      // Older built-in snapshots have no configurable endpoint or model.
      if (endpoint.isNotEmpty || model.isNotEmpty) {
        throw ArgumentError.value(json['kind'], 'kind', '不支持的转录服务类型');
      }
      kind = TranscriptionServiceKind.gongyi;
    }
    final builtin = kind == TranscriptionServiceKind.gongyi;
    return ModelServiceProfile(
      id: builtin ? 'gongyi' : json['id'] as String,
      name: builtin ? '公益接口' : json['name'] as String,
      kind: kind,
      endpoint: endpoint,
      model: model,
      language: json['language'] as String? ?? 'auto',
      appId: json['appId'] as String? ?? '',
      cloudOptions: json['cloudOptions'] is Map
          ? CloudAsrOptions.fromJson(
              Map<String, dynamic>.from(json['cloudOptions'] as Map),
            )
          : null,
      cloudCapabilities: json['cloudCapabilities'] is Map
          ? CloudAsrCapabilities.fromJson(
              Map<String, dynamic>.from(json['cloudCapabilities'] as Map),
            )
          : null,
    );
  }
}

enum TranslationAcceleration { auto, cpu, gpu }

/// Independent from ASR's thread budget. Zero threads means a bounded,
/// platform-aware automatic budget, rather than using every logical core.
class LocalTranslationOptions {
  const LocalTranslationOptions({
    this.acceleration = TranslationAcceleration.auto,
    this.threads = 0,
    this.batchSize = 8,
    this.gpuLayers = 999,
    this.backend = 'auto',
  });
  final TranslationAcceleration acceleration;
  final int threads;
  final int batchSize;

  /// 999 asks the runtime to offload all layers. Lower counts reduce VRAM use.
  final int gpuLayers;

  /// An omitted value preserves old queued-job JSON and fingerprints.
  final String backend;
  Map<String, Object> toJson() => {
    'acceleration': acceleration.name,
    'threads': threads,
    'batchSize': batchSize,
    if (gpuLayers != 999) 'gpuLayers': gpuLayers,
    if (backend != 'auto') 'backend': backend,
  };
  factory LocalTranslationOptions.fromJson(Map<String, dynamic> json) =>
      LocalTranslationOptions(
        acceleration: TranslationAcceleration.values.firstWhere(
          (v) => v.name == json['acceleration'],
          orElse: () => TranslationAcceleration.auto,
        ),
        threads: ((json['threads'] as num?)?.toInt() ?? 0).clamp(0, 12),
        batchSize: ((json['batchSize'] as num?)?.toInt() ?? 8).clamp(1, 12),
        gpuLayers: ((json['gpuLayers'] as num?)?.toInt() ?? 999).clamp(1, 999),
        backend:
            const {
              'auto',
              'vulkan',
              'opencl',
              'cuda',
              'metal',
            }.contains(json['backend'])
            ? json['backend'] as String
            : 'auto',
      );
  LocalTranslationOptions copyWith({
    TranslationAcceleration? acceleration,
    int? threads,
    int? batchSize,
    int? gpuLayers,
    String? backend,
  }) => LocalTranslationOptions(
    acceleration: acceleration ?? this.acceleration,
    threads: threads ?? this.threads,
    batchSize: batchSize ?? this.batchSize,
    gpuLayers: gpuLayers ?? this.gpuLayers,
    backend: backend ?? this.backend,
  );
}

/// No credentials or absolute paths. Every setting that changes a result is frozen.
class ModelJobSpec {
  const ModelJobSpec({
    required this.profile,
    this.artifactIdentity = '',
    this.threads = 2,
    this.asrCpuThreads,
    this.asrTokenTiming,
    this.asrTextProcessingVersion,
    this.translation = const LocalTranslationOptions(),
    this.subtitleSegmentation,
    this.asrEnhancements,
    this.enhancementModels = const {},
    this.asrExecution = AsrExecutionMode.auto,
    this.asrAcceleration,
    this.asrAccelerationModels = const {},
    this.allowModelDownload = true,
  });
  final ModelServiceProfile profile;

  /// Restricted automation must use already prepared weights. Omitted for old
  /// jobs so their serialized contracts and recognition identities stay intact.
  final bool allowModelDownload;
  final String artifactIdentity;
  final int threads;

  /// Null preserves old queued jobs; zero is automatic for new local jobs.
  final int? asrCpuThreads;

  /// New model IDs can freeze the family's timing format. Null preserves old
  /// task JSON and checkpoint identities, including the original Parakeet ID.
  final String? asrTokenTiming;

  /// Optional post-processing contract. Absent fields preserve old jobs exactly.
  final int? asrTextProcessingVersion;
  String? get _tokenTiming => profile.local
      ? asrTokenTiming ?? legacyAsrTokenTiming(profile.model)
      : null;
  int get requestedAsrThreads => asrCpuThreads ?? threads;
  final LocalTranslationOptions translation;
  // Null preserves the behavior and fingerprint of already queued v1 jobs.
  final SubtitleSegmentationOptions? subtitleSegmentation;
  final AsrEnhancementOptions? asrEnhancements;
  final Map<String, String> enhancementModels;
  final AsrExecutionMode asrExecution;
  // Null identifies old queued jobs: preserve their CPU behavior and JSON.
  final AsrAcceleration? asrAcceleration;
  final Map<String, String> asrAccelerationModels;
  Map<String, dynamic> toJson() => {
    ..._recognitionJson(),
    if (!allowModelDownload) 'allowModelDownload': false,
    if (profile.local && asrCpuThreads != null) 'asrCpuThreads': asrCpuThreads,
    if (profile.local && asrTokenTiming != null)
      'asrTokenTiming': asrTokenTiming,
    if (profile.local && asrTextProcessingVersion != null)
      'asrTextProcessingVersion': asrTextProcessingVersion,
    if (profile.local && asrAcceleration != null) ...{
      'asrAcceleration': asrAcceleration!.name,
      'asrAccelerationModels': asrAccelerationModels,
    },
    if (profile.local && asrExecution != AsrExecutionMode.auto)
      'asrExecution': asrExecution.name,
    if (subtitleSegmentation != null) ...{
      'version': 2,
      'subtitleSegmentation': subtitleSegmentation!.toJson(),
    },
    if (asrEnhancements != null) ...{
      'version': 3,
      'asrEnhancements': asrEnhancements!.toJson(),
      'enhancementModels': enhancementModels,
    },
  };
  Map<String, dynamic> _recognitionJson() => {
    'version': 1,
    'profile': profile.toJson(),
    'artifactIdentity': artifactIdentity,
    'threads': threads,
    'translation': translation.toJson(),
    'segmentation': 'vad-12s-overlap-v1',
  };
  String get fingerprint => jsonEncode(toJson());
  // Checkpoints hold raw ASR output. Display-only changes can regroup it without
  // running recognition again, while native model/language changes still miss.
  // Keep this independent of the full job JSON, which may also serialize
  // translation preferences. Such preferences must never invalidate ASR data.
  Map<String, dynamic> _recognitionIdentity({int? legacyThreads}) => {
    'version': profile.local && legacyThreads == null ? 2 : 1,
    'profile': profile.toJson(),
    'artifactIdentity': artifactIdentity,
    if (!profile.local || legacyThreads != null)
      'threads': legacyThreads ?? threads,
    'segmentation': 'vad-12s-overlap-v1',
    if (_tokenTiming != null) 'tokenTiming': _tokenTiming,
    if (asrEnhancements?.enabled == true) ...{
      'audioEnhancements': asrEnhancements!.audioJson,
      if (asrEnhancements!.denoise)
        'denoiserIdentity': enhancementModels[AsrEnhancementOptions.denoiserId],
    },
  };
  String get recognitionFingerprint => jsonEncode(_recognitionIdentity());
  String get enhancementFingerprint => jsonEncode({
    'version': 2,
    'naturalPunctuationContext': naturalPunctuationContext,
    'options': asrEnhancements?.toJson(),
    if (asrTextProcessingVersion != null)
      'asrTextProcessingVersion': asrTextProcessingVersion,
    'models': {
      for (final entry in enhancementModels.entries)
        if (!retiredAsrModelIds.contains(entry.key)) entry.key: entry.value,
    },
  });
  bool get naturalPunctuationContext =>
      asrEnhancements?.enabled == true &&
      asrEnhancements!.punctuation &&
      subtitleSegmentation?.enabled == true &&
      subtitleSegmentation!.naturalBreaks;
  // Some v1 snapshots included translation options, which do not affect ASR.
  // Read both formats so migrations also retain paid providers' remote task IDs.
  List<String> get recognitionCacheFingerprints => {
    recognitionFingerprint,
    if (profile.local)
      for (final oldThreads in {threads, 1, 2, 3, 4})
        jsonEncode(_recognitionIdentity(legacyThreads: oldThreads)),
    if (asrEnhancements?.enabled != true && _tokenTiming == null)
      for (final oldThreads
          in profile.local ? {threads, 1, 2, 3, 4} : {threads})
        jsonEncode({
          'version': 1,
          'profile': profile.toJson(),
          'artifactIdentity': artifactIdentity,
          'threads': oldThreads,
          'translation': translation.toJson(),
          'segmentation': 'vad-12s-overlap-v1',
        }),
  }.toList(growable: false);
  factory ModelJobSpec.fromJson(Map<String, dynamic> json) => ModelJobSpec(
    allowModelDownload: json['allowModelDownload'] != false,
    profile: ModelServiceProfile.fromJson(
      Map<String, dynamic>.from(json['profile'] as Map),
    ),
    artifactIdentity: json['artifactIdentity'] as String? ?? '',
    asrTokenTiming: json['asrTokenTiming'] as String?,
    asrTextProcessingVersion: json['asrTextProcessingVersion'] as int?,
    threads: (json['threads'] as int? ?? 2).clamp(1, 4),
    asrCpuThreads:
        json['profile'] is Map &&
            (json['profile'] as Map)['kind'] ==
                TranscriptionServiceKind.local.name &&
            json['asrCpuThreads'] is num
        ? (json['asrCpuThreads'] as num).toInt().clamp(0, 12)
        : null,
    translation: LocalTranslationOptions.fromJson(
      json['translation'] is Map
          ? Map<String, dynamic>.from(json['translation'] as Map)
          : const {},
    ),
    subtitleSegmentation: json['subtitleSegmentation'] is Map
        ? SubtitleSegmentationOptions.fromJson(json['subtitleSegmentation'])
        : null,
    asrEnhancements: json['asrEnhancements'] is Map
        ? AsrEnhancementOptions.fromJson(json['asrEnhancements'])
        : null,
    enhancementModels: Map<String, String>.from(
      json['enhancementModels'] as Map? ?? const {},
    ),
    asrExecution: AsrExecutionMode.values.firstWhere(
      (v) => v.name == json['asrExecution'],
      orElse: () => AsrExecutionMode.auto,
    ),
    asrAcceleration: json['asrAcceleration'] == null
        ? null
        : AsrAcceleration.values.firstWhere(
            (v) => v.name == json['asrAcceleration'],
            orElse: () => AsrAcceleration.cpu,
          ),
    asrAccelerationModels: Map<String, String>.from(
      json['asrAccelerationModels'] as Map? ?? const {},
    ),
  );
}
