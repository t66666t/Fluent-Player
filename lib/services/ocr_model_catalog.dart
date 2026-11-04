import 'dart:convert';

import 'package:flutter/services.dart';

import '../features/model_center/device_resource_snapshot.dart';
import '../features/model_center/model_catalog.dart';
import '../models/ocr_subtitle_models.dart';

class OcrModelPreset {
  const OcrModelPreset({
    required this.id,
    required this.name,
    required this.tier,
    required this.detection,
    required this.recognition,
    required this.groups,
    required this.languages,
    required this.parameters,
    required this.description,
    required this.suggestedRamGb,
    required this.license,
    this.legacy = false,
  });
  final String id,
      name,
      tier,
      detection,
      recognition,
      parameters,
      description,
      license;
  final List<String> groups, languages;
  final int suggestedRamGb;
  final bool legacy;
  Set<String> get componentIds => {detection, recognition};
  bool supports(OcrSubtitleLanguage language) => groups.contains(language.name);
  int bytes(Iterable<ModelArtifact> catalog) => catalog
      .where((m) => componentIds.contains(m.id))
      .fold(0, (n, m) => n + m.bytes);
  String identity(Iterable<ModelArtifact> catalog) =>
      '$id:${componentIds.map((id) => catalog.firstWhere((m) => m.id == id).identity).join('+')}';

  factory OcrModelPreset.fromJson(Map<String, dynamic> json) => OcrModelPreset(
    id: json['id'] as String,
    name: json['name'] as String,
    tier: json['tier'] as String,
    detection: json['detection'] as String,
    recognition: json['recognition'] as String,
    groups: List<String>.from(json['groups'] as List),
    languages: List<String>.from(json['languages'] as List),
    parameters: json['parameters'] as String,
    description: json['description'] as String,
    suggestedRamGb: json['suggestedRamGb'] as int,
    license: json['license'] as String,
    legacy: json['legacy'] == true,
  );
}

Future<List<OcrModelPreset>> loadOcrPresets() async {
  final raw =
      jsonDecode(await rootBundle.loadString('assets/models/ocr_catalog.json'))
          as Map;
  return (raw['presets'] as List)
      .map((p) => OcrModelPreset.fromJson(Map<String, dynamic>.from(p as Map)))
      .toList(growable: false);
}

/// Retiring a preset must also discard its pinned revision and timing identity.
OcrSubtitleTrack migrateRetiredOcrTrack(OcrSubtitleTrack track) =>
    track.modelId == 'ppocr-v6-tiny'
    ? track.copyWith(modelId: 'ppocr-v6-small', modelIdentity: '')
    : track;

/// A recommendation is never a selection and does not load a model.
String recommendedOcrPreset(
  DeviceResourceSnapshot? device,
  OcrSubtitleLanguage language, {
  Iterable<Map<String, dynamic>> measurements = const [],
}) {
  if (language == OcrSubtitleLanguage.korean) return 'ppocr-v5-korean';
  if (language == OcrSubtitleLanguage.english) return 'ppocr-v5-en';
  if (language == OcrSubtitleLanguage.latin) return 'ppocr-v5-latin';
  if (language == OcrSubtitleLanguage.japanese) return 'ppocr-v6-small';
  final enoughMemory = (device?.memoryBytes ?? 0) >= 6 * 1024 * 1024 * 1024;
  final headroom = device?.availableMemoryBytes;
  final configured =
      enoughMemory &&
          (device?.effectiveProcessors ?? 1) >= 4 &&
          (headroom == null || headroom >= 512 * 1024 * 1024)
      ? 'ppocr-v6-small'
      : 'ppocr-v5-mobile';
  // Only compare complete, sufficiently long runs of the same material and
  // runtime on this device. A short sample or a different video is no evidence
  // that changing the user's model would improve this workload.
  final comparable = <String, List<Map<String, dynamic>>>{};
  for (final record in measurements) {
    if (!ocrMeasurementMatches(record, device, language) ||
        ((record['mediaMs'] as num?) ?? 0) < 60000 ||
        record['reference'] is! String ||
        record['runtime'] is! String) {
      continue;
    }
    final key = '${record['reference']}:${record['runtime']}';
    comparable.putIfAbsent(key, () => []).add(record);
  }
  final groups =
      comparable.values
          .where((g) => g.map((r) => r['modelId']).toSet().length >= 2)
          .toList()
        ..sort(
          (a, b) => (b.last['testedAt'] as String).compareTo(
            a.last['testedAt'] as String,
          ),
        );
  for (final group in groups) {
    final baseline = group.where((r) => r['modelId'] == configured).firstOrNull;
    final baselineRate = (baseline?['realTimeFactor'] as num?)?.toDouble();
    if (baselineRate == null || baselineRate <= .5) continue;
    final faster = group
        .where(
          (r) =>
              r['modelId'] == 'ppocr-v5-mobile' &&
              (r['realTimeFactor'] as num).toDouble() < baselineRate * .75,
        )
        .firstOrNull;
    if (faster != null) return 'ppocr-v5-mobile';
  }
  return configured;
}

String ocrDeviceKey(DeviceResourceSnapshot device) =>
    '${device.platform}:${device.environment}:${device.effectiveProcessors}:${device.memoryBytes}';

bool ocrMeasurementMatches(
  Map<String, dynamic> record,
  DeviceResourceSnapshot? device,
  OcrSubtitleLanguage language,
) {
  final tested = DateTime.tryParse(record['testedAt'] as String? ?? '');
  final rate = record['realTimeFactor'];
  return device != null &&
      record['device'] == ocrDeviceKey(device) &&
      record['language'] == language.name &&
      tested != null &&
      !tested.isAfter(DateTime.now()) &&
      DateTime.now().difference(tested).inDays < 30 &&
      rate is num &&
      rate.isFinite &&
      rate > 0;
}
