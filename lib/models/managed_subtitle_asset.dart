enum ManagedSubtitleAssetKind {
  ai,
  translated,
  imported,
  manual,
  embedded,
  downloaded,
  ocr,
  cached;

  static ManagedSubtitleAssetKind fromStorage(String? value) {
    return ManagedSubtitleAssetKind.values.firstWhere(
      (kind) => kind.name == value,
      orElse: () => ManagedSubtitleAssetKind.imported,
    );
  }
}

class ManagedSubtitleAsset {
  final String assetId;
  final String path;
  final String? wordTimingPath;
  Iterable<String> get allFilePaths sync* {
    yield path;
    if (wordTimingPath != null) yield wordTimingPath!;
  }

  final ManagedSubtitleAssetKind kind;
  final String displayName;
  final String? sourceAssetId;
  final String? language;
  final int createdAt;

  /// The provider marked this copy as machine-made. Absent in older JSON.
  final bool machineGenerated;

  final String? contentHash;
  final String? sourceLabel;
  final String? entryId;
  final int? offsetMs;

  const ManagedSubtitleAsset({
    required this.assetId,
    required this.path,
    this.wordTimingPath,
    required this.kind,
    required this.displayName,
    this.sourceAssetId,
    this.language,
    required this.createdAt,
    this.machineGenerated = false,
    this.contentHash,
    this.sourceLabel,
    this.entryId,
    this.offsetMs,
  });

  ManagedSubtitleAsset copyWith({
    String? path,
    String? wordTimingPath,
    bool clearWordTimingPath = false,
    String? displayName,
    String? sourceAssetId,
    String? language,
    bool? machineGenerated,
  }) {
    return ManagedSubtitleAsset(
      assetId: assetId,
      path: path ?? this.path,
      wordTimingPath: clearWordTimingPath
          ? null
          : wordTimingPath ?? this.wordTimingPath,
      kind: kind,
      displayName: displayName ?? this.displayName,
      sourceAssetId: sourceAssetId ?? this.sourceAssetId,
      language: language ?? this.language,
      createdAt: createdAt,
      machineGenerated: machineGenerated ?? this.machineGenerated,
      contentHash: contentHash,
      sourceLabel: sourceLabel,
      entryId: entryId,
      offsetMs: offsetMs,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'assetId': assetId,
    'path': path,
    if (wordTimingPath != null) 'wordTimingPath': wordTimingPath,
    'kind': kind.name,
    'displayName': displayName,
    'sourceAssetId': sourceAssetId,
    'language': language,
    'createdAt': createdAt,
    if (machineGenerated) 'machineGenerated': true,
    if (contentHash != null) 'contentHash': contentHash,
    if (sourceLabel != null) 'sourceLabel': sourceLabel,
    if (entryId != null) 'entryId': entryId,
    if (offsetMs != null) 'offsetMs': offsetMs,
  };

  factory ManagedSubtitleAsset.fromJson(Map<String, dynamic> json) {
    return ManagedSubtitleAsset(
      assetId: json['assetId']?.toString() ?? '',
      path: json['path']?.toString() ?? '',
      wordTimingPath: json['wordTimingPath']?.toString(),
      kind: ManagedSubtitleAssetKind.fromStorage(json['kind']?.toString()),
      displayName: json['displayName']?.toString() ?? '',
      sourceAssetId: json['sourceAssetId']?.toString(),
      language: json['language']?.toString(),
      createdAt: json['createdAt'] as int? ?? 0,
      machineGenerated: json['machineGenerated'] == true,
      contentHash: json['contentHash']?.toString(),
      sourceLabel: json['sourceLabel']?.toString(),
      entryId: json['entryId']?.toString(),
      offsetMs: json['offsetMs'] as int?,
    );
  }
}
