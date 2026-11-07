import 'package:flutter/material.dart';

/// Retired bundled fonts fall back to the available OFL-licensed CJK family.
/// User-imported font identifiers are preserved.
String normalizeBundledFontFamily(String family) => switch (family) {
  'MiSans' || 'Noto Serif CJK SC' => 'Noto Sans SC',
  '方正黑体' || '方正楷体' || '方正黑体简体' || '方正楷体简体' || 'OPPO Sans 4.0' => 'Noto Sans SC',
  _ => family,
};

/// A stable family identifier, independent of its display name or location.
class SubtitleFontChoice {
  final String family;
  final int weight;
  const SubtitleFontChoice(this.family, [this.weight = 400]);

  FontWeight get fontWeight =>
      FontWeight.values[((weight.clamp(100, 900) / 100).round() - 1).clamp(
        0,
        8,
      )];
  // FontWeight covers only nine fixed values. An explicit axis is needed for
  // intermediate values; fonts without this axis ignore the variation.
  List<FontVariation>? get fontVariations => weight == fontWeight.value
      ? null
      : [FontVariation.weight(weight.clamp(1, 1000).toDouble())];
  Map<String, Object> toJson() => {
    'family': normalizeBundledFontFamily(family),
    'weight': weight,
  };
  factory SubtitleFontChoice.fromJson(Map<String, dynamic> json) =>
      SubtitleFontChoice(
        normalizeBundledFontFamily(json['family'] as String? ?? 'System'),
        (json['weight'] as num?)?.toInt() ?? 400,
      );

  @override
  bool operator ==(Object other) =>
      other is SubtitleFontChoice &&
      other.family == family &&
      other.weight == weight;
  @override
  int get hashCode => Object.hash(family, weight);
}

enum SubtitleFontLicense {
  commercial('可商用'),
  personal('仅个人使用'),
  required('需另行授权'),
  unknown('授权未知');

  final String label;
  const SubtitleFontLicense(this.label);
}

class SubtitleFontAsset {
  final String id;
  final String name;
  final String internalFamily;
  final String? path;
  final String? assetPath;
  final List<String> facePaths;
  final List<String> faceHashes;
  final List<int> weights;
  final int? variableWeightMin;
  final int? variableWeightMax;
  final bool weightAxisChecked;
  final List<List<int>> coverage;
  final SubtitleFontLicense license;
  final String sourceUrl;
  final String licenseUrl;
  final String licenseText;
  final String verifiedOn;
  final String sha256;
  const SubtitleFontAsset({
    required this.id,
    required this.name,
    this.internalFamily = '',
    this.path,
    this.assetPath,
    this.facePaths = const [],
    this.faceHashes = const [],
    this.weights = const [400],
    this.variableWeightMin,
    this.variableWeightMax,
    this.weightAxisChecked = false,
    this.coverage = const [],
    this.license = SubtitleFontLicense.unknown,
    this.sourceUrl = '',
    this.licenseUrl = '',
    this.licenseText = '',
    this.verifiedOn = '',
    this.sha256 = '',
  });

  bool get hasVariableWeight =>
      variableWeightMin != null &&
      variableWeightMax != null &&
      variableWeightMin! >= 1 &&
      variableWeightMax! <= 1000 &&
      variableWeightMin! < variableWeightMax!;

  bool supports(int rune) => coverage.any((r) => rune >= r[0] && rune <= r[1]);

  SubtitleFontAsset withWeightAxis((int, int)? range) => SubtitleFontAsset(
    id: id,
    name: name,
    internalFamily: internalFamily,
    path: path,
    assetPath: assetPath,
    facePaths: facePaths,
    faceHashes: faceHashes,
    weights: weights,
    variableWeightMin: range?.$1,
    variableWeightMax: range?.$2,
    weightAxisChecked: true,
    coverage: coverage,
    license: license,
    sourceUrl: sourceUrl,
    licenseUrl: licenseUrl,
    licenseText: licenseText,
    verifiedOn: verifiedOn,
    sha256: sha256,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'internalFamily': internalFamily,
    'path': path,
    'weights': weights,
    if (weightAxisChecked) 'weightAxisChecked': true,
    if (variableWeightMin != null) 'variableWeightMin': variableWeightMin,
    if (variableWeightMax != null) 'variableWeightMax': variableWeightMax,
    'facePaths': facePaths,
    'faceHashes': faceHashes,
    'coverage': coverage,
    'license': license.name,
    'sourceUrl': sourceUrl,
    'licenseUrl': licenseUrl,
    'licenseText': licenseText,
    'verifiedOn': verifiedOn,
    'sha256': sha256,
  };
  factory SubtitleFontAsset.fromJson(Map<String, dynamic> json) =>
      SubtitleFontAsset(
        id: json['id'] as String,
        name: json['name'] as String,
        internalFamily: json['internalFamily'] as String? ?? '',
        path: json['path'] as String?,
        facePaths: (json['facePaths'] as List? ?? []).cast<String>(),
        faceHashes: (json['faceHashes'] as List? ?? []).cast<String>(),
        weights: (json['weights'] as List? ?? [400]).cast<int>(),
        variableWeightMin: (json['variableWeightMin'] as num?)?.toInt(),
        variableWeightMax: (json['variableWeightMax'] as num?)?.toInt(),
        weightAxisChecked: json['weightAxisChecked'] as bool? ?? false,
        coverage: (json['coverage'] as List? ?? [])
            .map((r) => (r as List).cast<int>())
            .toList(),
        license: SubtitleFontLicense.values.firstWhere(
          (v) => v.name == json['license'],
          orElse: () => SubtitleFontLicense.unknown,
        ),
        sourceUrl: json['sourceUrl'] as String? ?? '',
        licenseUrl: json['licenseUrl'] as String? ?? '',
        licenseText: json['licenseText'] as String? ?? '',
        verifiedOn: json['verifiedOn'] as String? ?? '',
        sha256: json['sha256'] as String? ?? '',
      );
}

class SubtitleOnlineFont {
  final String name;
  final List<String> languages;
  final List<String> files;
  final List<String> hashes;
  final List<int> weights;
  final String licenseFile;
  final String sourceUrl;
  final String verifiedOn;
  final SubtitleFontLicense license;
  const SubtitleOnlineFont({
    required this.name,
    this.languages = const [],
    this.files = const [],
    this.hashes = const [],
    this.weights = const [400],
    this.licenseFile = '',
    required this.sourceUrl,
    this.verifiedOn = '',
    this.license = SubtitleFontLicense.commercial,
  });
  bool get directDownload => files.isNotEmpty && licenseFile.isNotEmpty;
  factory SubtitleOnlineFont.fromJson(Map<String, dynamic> json) =>
      SubtitleOnlineFont(
        name: json['name'] as String,
        languages: (json['languages'] as List? ?? []).cast<String>(),
        files: (json['files'] as List? ?? []).cast<String>(),
        hashes: (json['hashes'] as List? ?? []).cast<String>(),
        weights: (json['weights'] as List? ?? [400]).cast<int>(),
        licenseFile: json['licenseFile'] as String? ?? '',
        sourceUrl: json['sourceUrl'] as String,
        verifiedOn: json['verifiedOn'] as String? ?? '',
        license: SubtitleFontLicense.values.firstWhere(
          (v) => v.name == json['license'],
          orElse: () => SubtitleFontLicense.unknown,
        ),
      );
}
