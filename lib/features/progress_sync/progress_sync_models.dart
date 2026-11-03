import 'dart:convert';
import 'folder_sync_models.dart';

class SyncLocalFolder {
  const SyncLocalFolder({
    required this.id,
    required this.name,
    required this.mediaCount,
  });
  final String id;
  final String name;
  final int mediaCount;
}

class SyncFolderBinding {
  const SyncFolderBinding({
    required this.groupId,
    required this.collectionId,
    required this.name,
    this.matchedCount = 0,
    this.lastSyncedAt,
    this.mode = FolderSyncMode.smart,
    this.status = '',
    this.pendingCount = 0,
    this.conflictCount = 0,
  });
  final String groupId;
  final String collectionId;
  final String name;
  final int matchedCount;
  final DateTime? lastSyncedAt;
  final FolderSyncMode mode;
  final String status;
  final int pendingCount, conflictCount;
}

/// The receiver's one-time choice. Both choices start the same relationship.
enum FolderSyncAcceptChoice { linkExisting, receiveNew }

/// A folder sync request that is stored separately from free-form sync options.
class FolderSyncProposal {
  const FolderSyncProposal({
    required this.proposalId,
    required this.peerId,
    required this.collectionId,
    required this.createdAtMs,
    this.schemaVersion = 1,
    this.groupId,
    this.peerCollectionId,
    this.choice,
    this.status = 'pending',
    this.expiresAtMs,
  });

  final int schemaVersion;
  final String proposalId;
  final String peerId;
  final String collectionId;
  final String? groupId;
  final String? peerCollectionId;
  final FolderSyncAcceptChoice? choice;
  final String status;
  final int createdAtMs;
  final int? expiresAtMs;

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'proposalId': proposalId,
    'peerId': peerId,
    'collectionId': collectionId,
    'groupId': groupId,
    'peerCollectionId': peerCollectionId,
    'choice': choice?.name,
    'status': status,
    'createdAtMs': createdAtMs,
    'expiresAtMs': expiresAtMs,
  };

  factory FolderSyncProposal.fromJson(Map<String, dynamic> json) {
    final version = json['schemaVersion'];
    if (version is int && version > 1) {
      throw const FormatException('同步请求来自更新的版本，请更新应用后继续');
    }
    final choiceName = json['choice'] as String?;
    return FolderSyncProposal(
      schemaVersion: version is int ? version : 1,
      proposalId: json['proposalId'] as String,
      peerId: json['peerId'] as String,
      collectionId: json['collectionId'] as String,
      groupId: json['groupId'] as String?,
      peerCollectionId: json['peerCollectionId'] as String?,
      choice: FolderSyncAcceptChoice.values.asNameMap()[choiceName],
      status: json['status'] as String? ?? 'pending',
      createdAtMs: json['createdAtMs'] as int? ?? 0,
      expiresAtMs: json['expiresAtMs'] as int?,
    );
  }
}

class SyncFolderInvitation {
  const SyncFolderInvitation({
    required this.groupId,
    required this.name,
    required this.fromDevice,
    this.mediaCount = 0,
  });
  final String groupId;
  final String name;
  final String fromDevice;
  final int mediaCount;
}

class SyncProgressValue {
  const SyncProgressValue({
    required this.positionMs,
    required this.completed,
    required this.continueEnrolled,
    required this.lastPlayedAtMs,
    required this.watchMs,
  });
  final int positionMs;
  final bool completed;
  final bool continueEnrolled;
  final int? lastPlayedAtMs;
  final int watchMs;
  Map<String, dynamic> toJson() => {
    'positionMs': positionMs,
    'completed': completed,
    'continueEnrolled': continueEnrolled,
    'lastPlayedAtMs': lastPlayedAtMs,
    'watchMs': watchMs,
  };
  factory SyncProgressValue.fromJson(Map<String, dynamic> json) =>
      SyncProgressValue(
        positionMs: _positive(json['positionMs']),
        completed: json['completed'] == true,
        continueEnrolled: json['continueEnrolled'] == true,
        lastPlayedAtMs: json['lastPlayedAtMs'] is num
            ? (json['lastPlayedAtMs'] as num).toInt()
            : null,
        watchMs: _positive(json['watchMs']),
      );
  String get signature => jsonEncode(toJson());
  static int _positive(Object? value) =>
      value is num ? value.toInt().clamp(0, 315576000000) : 0;
}

class SyncProgressEvent {
  const SyncProgressEvent({
    required this.id,
    required this.groupId,
    required this.mediaKey,
    required this.title,
    required this.deviceId,
    required this.deviceName,
    required this.clock,
    required this.value,
    required this.createdAtMs,
  });
  final String id;
  final String groupId;
  final String mediaKey;
  final String title;
  final String deviceId;
  final String deviceName;
  final Map<String, int> clock;
  final SyncProgressValue value;
  final int createdAtMs;
  Map<String, dynamic> toJson() => {
    'id': id,
    'groupId': groupId,
    'mediaKey': mediaKey,
    'title': title,
    'deviceId': deviceId,
    'deviceName': deviceName,
    'clock': clock,
    'value': value.toJson(),
    'createdAtMs': createdAtMs,
  };
  factory SyncProgressEvent.fromJson(Map<String, dynamic> j) {
    final clock = <String, int>{};
    for (final e in (j['clock'] as Map).entries) {
      if (e.key is String && e.value is num && (e.value as num) >= 0) {
        clock[e.key as String] = (e.value as num).toInt();
      }
    }
    return SyncProgressEvent(
      id: j['id'] as String,
      groupId: j['groupId'] as String,
      mediaKey: j['mediaKey'] as String,
      title: (j['title'] as String?) ?? '',
      deviceId: j['deviceId'] as String,
      deviceName: (j['deviceName'] as String?) ?? '另一台设备',
      clock: clock,
      value: SyncProgressValue.fromJson(
        Map<String, dynamic>.from(j['value'] as Map),
      ),
      createdAtMs: (j['createdAtMs'] as num?)?.toInt() ?? 0,
    );
  }
  bool descendsFrom(SyncProgressEvent other) {
    var greater = false;
    for (final key in {...clock.keys, ...other.clock.keys}) {
      final a = clock[key] ?? 0, b = other.clock[key] ?? 0;
      if (a < b) return false;
      if (a > b) greater = true;
    }
    return greater;
  }
}

class SyncProgressConflict {
  const SyncProgressConflict({
    required this.id,
    required this.title,
    required this.choices,
  });
  final String id;
  final String title;
  final List<SyncProgressEvent> choices;
}

/// Keeps causally newer changes; simultaneous watches remain explicit choices.
/// Device wall clocks and the furthest playback position never decide a winner.
List<SyncProgressEvent> syncProgressHeads(Iterable<SyncProgressEvent> input) {
  final unique = <String, SyncProgressEvent>{for (final e in input) e.id: e};
  final events = unique.values.toList();
  return events
      .where(
        (e) =>
            !events.any((other) => other.id != e.id && other.descendsFrom(e)),
      )
      .toList()
    ..sort((a, b) => a.id.compareTo(b.id));
}
