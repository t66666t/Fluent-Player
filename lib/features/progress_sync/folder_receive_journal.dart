import 'dart:convert';
import 'dart:io';

/// Durable stages for one received resource.
///
/// The library database, the file rename and this journal are not one
/// transaction. Recovery trusts the last stage that was fully saved.
enum ReceiveAssetStage {
  planned,
  receiving,
  staged,
  fileCommitted,
  attached,
}

class ReceiveAssetRecord {
  const ReceiveAssetRecord({
    required this.assetId,
    required this.nodeIds,
    required this.role,
    required this.expectedLength,
    required this.stage,
    this.temporaryPath,
    this.permanentPath,
    this.cardId,
    this.contentIdentity,
    this.confirmedBytes = 0,
  });

  final String assetId;
  final List<String> nodeIds;
  final String role;
  final int expectedLength;
  final ReceiveAssetStage stage;
  final String? temporaryPath;
  final String? permanentPath;
  final String? cardId;
  final String? contentIdentity;
  final int confirmedBytes;

  bool get attached => stage == ReceiveAssetStage.attached;

  Map<String, dynamic> toJson() => {
    'assetId': assetId,
    'nodeIds': nodeIds,
    'role': role,
    'expectedLength': expectedLength,
    'stage': stage.name,
    'temporaryPath': temporaryPath,
    'permanentPath': permanentPath,
    'cardId': cardId,
    'contentIdentity': contentIdentity,
    'confirmedBytes': confirmedBytes,
  };

  factory ReceiveAssetRecord.fromJson(Map<String, dynamic> json) {
    final stageName = json['stage'] as String?;
    final stage = ReceiveAssetStage.values.asNameMap()[stageName];
    if (stage == null || json['assetId'] is! String) {
      throw const FormatException('接收记录损坏');
    }
    return ReceiveAssetRecord(
      assetId: json['assetId'] as String,
      nodeIds: (json['nodeIds'] as List? ?? const []).whereType<String>().toList(),
      role: json['role'] as String? ?? 'primary',
      expectedLength: json['expectedLength'] as int? ?? 0,
      stage: stage,
      temporaryPath: json['temporaryPath'] as String?,
      permanentPath: json['permanentPath'] as String?,
      cardId: json['cardId'] as String?,
      contentIdentity: json['contentIdentity'] as String?,
      confirmedBytes: json['confirmedBytes'] as int? ?? 0,
    );
  }
}

/// Per-transfer record of what was reserved, written and published.
///
/// Schema version is independent of the fluentpack and sync-store versions.
class FolderReceiveJournal {
  static const int schemaVersion = 1;

  const FolderReceiveJournal({
    required this.transferId,
    required this.groupId,
    required this.peerId,
    required this.manifestRevision,
    required this.assets,
    this.targetDirectory,
    this.targetRootId,
    this.ackDelivered = false,
  });

  final String transferId;
  final String groupId;
  final String peerId;
  final String manifestRevision;
  final String? targetDirectory;
  final String? targetRootId;
  final List<ReceiveAssetRecord> assets;
  final bool ackDelivered;

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'transferId': transferId,
    'groupId': groupId,
    'peerId': peerId,
    'manifestRevision': manifestRevision,
    'targetDirectory': targetDirectory,
    'targetRootId': targetRootId,
    'ackDelivered': ackDelivered,
    'assets': [for (final asset in assets) asset.toJson()],
  };

  factory FolderReceiveJournal.fromJson(Map<String, dynamic> json) {
    final version = json['schemaVersion'];
    if (version is! int) throw const FormatException('接收记录损坏');
    if (version > schemaVersion) {
      throw const FormatException('接收记录来自更新的版本，请更新应用后继续');
    }
    if (version < 1) throw const FormatException('接收记录损坏');
    final rawAssets = json['assets'];
    if (rawAssets is! List || json['transferId'] is! String) {
      throw const FormatException('接收记录损坏');
    }
    return FolderReceiveJournal(
      transferId: json['transferId'] as String,
      groupId: json['groupId'] as String? ?? '',
      peerId: json['peerId'] as String? ?? '',
      manifestRevision: json['manifestRevision'] as String? ?? '',
      targetDirectory: json['targetDirectory'] as String?,
      targetRootId: json['targetRootId'] as String?,
      ackDelivered: json['ackDelivered'] == true,
      assets: [
        for (final raw in rawAssets)
          if (raw is Map)
            ReceiveAssetRecord.fromJson(Map<String, dynamic>.from(raw)),
      ],
    );
  }

  /// Atomically replaces [file]. A failed replace leaves the previous journal.
  static Future<void> save(File file, FolderReceiveJournal journal) async {
    final encoded = jsonEncode(journal.toJson());
    final partial = File('${file.path}.next');
    await partial.parent.create(recursive: true);
    await partial.writeAsString(encoded, flush: true);
    try {
      await partial.rename(file.path);
    } catch (_) {
      if (await file.exists()) await file.delete();
      await partial.rename(file.path);
    }
  }

  /// Returns null when the file is missing or its bytes are not valid JSON
  /// for this schema. Callers must not resume partials in that case.
  /// A newer schema throws so the caller can keep the original bytes.
  static Future<FolderReceiveJournal?> load(File file) async {
    if (!await file.exists()) return null;
    final raw = jsonDecode(await file.readAsString());
    if (raw is! Map) throw const FormatException('接收记录损坏');
    return FolderReceiveJournal.fromJson(Map<String, dynamic>.from(raw));
  }
}
