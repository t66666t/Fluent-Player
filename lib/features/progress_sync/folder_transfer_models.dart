enum FolderTransferDirection { send, receive }

enum FolderTransferPhase {
  waiting,
  offered,
  preparing,
  transferring,
  verifying,
  importing,
  linking,
  paused,
  needsAttention,
  completed,
  cancelled,
  failed,
}

/// One folder delivery. Byte progress describes the transfer itself; preparing,
/// verifying and importing have their own stages rather than invented weights.
class FolderTransferTask {
  FolderTransferTask({
    required this.id,
    required this.direction,
    required this.peerId,
    required this.peerName,
    required this.sourceCollectionId,
    required this.folderName,
    required this.createdAt,
    required this.phase,
    this.mediaCount = 0,
    this.estimatedBytes = 0,
    this.totalBytes = 0,
    this.completedBytes = 0,
    this.bytesPerSecond = 0,
    this.stageProgress,
    this.stageLabel,
    this.error,
    this.targetCollectionId,
    this.packagePath,
    this.checkpointPath,
    this.transportOffer,
    this.syncDescriptor,
    this.accepted = false,
    this.peerNotified = false,
    this.reportSequence = 0,
    this.lastRemoteSequence = 0,
    this.syncOptions = const {},
    this.importedStableIds = const {},
  });

  final String id;
  final FolderTransferDirection direction;
  final String peerId;
  String peerName;
  final String sourceCollectionId;
  final String folderName;
  final DateTime createdAt;
  FolderTransferPhase phase;
  int mediaCount;
  int estimatedBytes;
  int totalBytes;
  int completedBytes;
  double bytesPerSecond;
  double? stageProgress;
  String? stageLabel;
  String? error;
  String? targetCollectionId;
  String? packagePath;
  String? checkpointPath;
  Map<String, dynamic>? transportOffer;
  Map<String, dynamic>? syncDescriptor;
  bool accepted;
  bool peerNotified;
  int reportSequence;
  int lastRemoteSequence;
  Map<String, dynamic> syncOptions;
  Map<String, String> importedStableIds;

  bool get incoming => direction == FolderTransferDirection.receive;
  bool get isActive => switch (phase) {
    FolderTransferPhase.waiting ||
    FolderTransferPhase.offered ||
    FolderTransferPhase.preparing ||
    FolderTransferPhase.transferring ||
    FolderTransferPhase.verifying ||
    FolderTransferPhase.importing ||
    FolderTransferPhase.linking => true,
    _ => false,
  };
  bool get canCancel => isActive || phase == FolderTransferPhase.paused;
  bool get canRetry =>
      phase == FolderTransferPhase.paused ||
      phase == FolderTransferPhase.failed ||
      phase == FolderTransferPhase.needsAttention;
  double? get progress =>
      totalBytes > 0 ? (completedBytes / totalBytes).clamp(0.0, 1.0) : null;
  Duration? get remaining =>
      phase == FolderTransferPhase.transferring &&
          bytesPerSecond > 0 &&
          totalBytes > completedBytes
      ? Duration(
          seconds: ((totalBytes - completedBytes) / bytesPerSecond).ceil(),
        )
      : null;

  Map<String, dynamic> toJson() => {
    'id': id,
    'direction': direction.name,
    'peerId': peerId,
    'peerName': peerName,
    'sourceCollectionId': sourceCollectionId,
    'folderName': folderName,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'phase': phase.name,
    'mediaCount': mediaCount,
    'estimatedBytes': estimatedBytes,
    'totalBytes': totalBytes,
    'completedBytes': completedBytes,
    'targetCollectionId': targetCollectionId,
    'packagePath': packagePath,
    'checkpointPath': checkpointPath,
    'transportOffer': transportOffer,
    'syncDescriptor': syncDescriptor,
    'accepted': accepted,
    'peerNotified': peerNotified,
    'reportSequence': reportSequence,
    'lastRemoteSequence': lastRemoteSequence,
    'syncOptions': syncOptions,
    'importedStableIds': importedStableIds,
  };

  factory FolderTransferTask.fromJson(Map<String, dynamic> json) {
    final phase = FolderTransferPhase.values.byName(json['phase'] as String);
    return FolderTransferTask(
      id: json['id'] as String,
      direction: FolderTransferDirection.values.byName(
        json['direction'] as String,
      ),
      peerId: json['peerId'] as String,
      peerName: json['peerName'] as String,
      sourceCollectionId: json['sourceCollectionId'] as String,
      folderName: json['folderName'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int),
      phase: switch (phase) {
        FolderTransferPhase.waiting ||
        FolderTransferPhase.preparing ||
        FolderTransferPhase.transferring ||
        FolderTransferPhase.verifying ||
        FolderTransferPhase.importing ||
        FolderTransferPhase.linking => FolderTransferPhase.paused,
        _ => phase,
      },
      mediaCount: json['mediaCount'] as int? ?? 0,
      estimatedBytes: json['estimatedBytes'] as int? ?? 0,
      totalBytes: json['totalBytes'] as int? ?? 0,
      completedBytes: json['completedBytes'] as int? ?? 0,
      targetCollectionId: json['targetCollectionId'] as String?,
      packagePath: json['packagePath'] as String?,
      checkpointPath: json['checkpointPath'] as String?,
      transportOffer: (json['transportOffer'] as Map?)?.cast<String, dynamic>(),
      syncDescriptor: (json['syncDescriptor'] as Map?)?.cast<String, dynamic>(),
      accepted: json['accepted'] == true,
      peerNotified: json['peerNotified'] == true,
      reportSequence: json['reportSequence'] as int? ?? 0,
      lastRemoteSequence: json['lastRemoteSequence'] as int? ?? 0,
      syncOptions: Map<String, dynamic>.from(json['syncOptions'] as Map? ?? {}),
      importedStableIds: Map<String, String>.from(
        json['importedStableIds'] as Map? ?? {},
      ),
    );
  }
}
