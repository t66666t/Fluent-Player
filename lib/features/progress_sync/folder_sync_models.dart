import 'dart:convert';

enum FolderSyncMode { smart, progressOnly, oneWay }

enum FolderSyncNodeKind { folder, media }

enum FolderSyncIssueKind {
  contentConflict,
  renameConflict,
  moveConflict,
  deleteConflict,
  blocked,
}

const _unspecified = Object();
const folderSyncMaxCounter = 9007199254740991;

class FolderSyncSettings {
  const FolderSyncSettings({
    this.mode = FolderSyncMode.smart,
    this.sourceDeviceId,
    this.syncDeletes = false,
    this.includeSidecars = true,
    this.shareProgressForSameContent = false,
    this.maxAutoTransferBytes = 0,
    this.minFreeBytes = 512 * 1024 * 1024,
    this.bytesPerSecondLimit = 0,
    this.excludedExtensions = const [],
    this.excludedPatterns = const [],
  });
  final FolderSyncMode mode;
  final String? sourceDeviceId;
  final bool syncDeletes, includeSidecars, shareProgressForSameContent;
  final int maxAutoTransferBytes, minFreeBytes, bytesPerSecondLimit;
  final List<String> excludedExtensions, excludedPatterns;
  FolderSyncSettings copyWith({
    FolderSyncMode? mode,
    Object? sourceDeviceId = _unspecified,
    bool? syncDeletes,
    bool? includeSidecars,
    bool? shareProgressForSameContent,
    int? maxAutoTransferBytes,
    int? minFreeBytes,
    int? bytesPerSecondLimit,
    List<String>? excludedExtensions,
    List<String>? excludedPatterns,
  }) => FolderSyncSettings.fromJson({
    ...toJson(),
    if (mode != null) 'mode': mode.name,
    if (!identical(sourceDeviceId, _unspecified))
      'sourceDeviceId': sourceDeviceId,
    'syncDeletes': ?syncDeletes,
    'includeSidecars': ?includeSidecars,
    'shareProgressForSameContent': ?shareProgressForSameContent,
    'maxAutoTransferBytes': ?maxAutoTransferBytes,
    'minFreeBytes': ?minFreeBytes,
    'bytesPerSecondLimit': ?bytesPerSecondLimit,
    'excludedExtensions': ?excludedExtensions,
    'excludedPatterns': ?excludedPatterns,
  });
  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'sourceDeviceId': sourceDeviceId,
    'syncDeletes': syncDeletes,
    'includeSidecars': includeSidecars,
    'shareProgressForSameContent': shareProgressForSameContent,
    'maxAutoTransferBytes': maxAutoTransferBytes,
    'minFreeBytes': minFreeBytes,
    'bytesPerSecondLimit': bytesPerSecondLimit,
    'excludedExtensions': List<String>.of(excludedExtensions),
    'excludedPatterns': List<String>.of(excludedPatterns),
  };
  factory FolderSyncSettings.fromJson(Map<String, dynamic> json) {
    final modeName = json['mode'] ?? 'smart';
    final mode = FolderSyncMode.values
        .where((v) => v.name == modeName)
        .firstOrNull;
    if (mode == null) throw const FormatException('目录同步模式无效');
    final source = json['sourceDeviceId'];
    if (source != null) folderSyncValidateId(source, 'sourceDeviceId');
    bool flag(String key, bool fallback) {
      final value = json[key];
      if (value == null) return fallback;
      if (value is! bool) throw FormatException('$key 无效');
      return value;
    }

    int number(String key, int fallback) {
      final value = json[key] ?? fallback;
      if (value is! int || value < 0 || value > folderSyncMaxCounter) {
        throw FormatException('$key 无效');
      }
      return value;
    }

    List<String> strings(String key, int length) {
      final value = json[key] ?? const [];
      if (value is! List || value.length > 64) {
        throw FormatException('$key 数量过多');
      }
      final result = <String>[];
      for (final item in value) {
        if (item is! String ||
            item.isEmpty ||
            item.length > length ||
            _control.hasMatch(item)) {
          throw FormatException('$key 无效');
        }
        if (!result.contains(item)) result.add(item);
      }
      return List.unmodifiable(result);
    }

    return FolderSyncSettings(
      mode: mode,
      sourceDeviceId: source as String?,
      syncDeletes: flag('syncDeletes', false),
      includeSidecars: flag('includeSidecars', true),
      shareProgressForSameContent: flag('shareProgressForSameContent', false),
      maxAutoTransferBytes: number('maxAutoTransferBytes', 0),
      minFreeBytes: number('minFreeBytes', 512 * 1024 * 1024),
      bytesPerSecondLimit: number('bytesPerSecondLimit', 0),
      excludedExtensions: strings('excludedExtensions', 32),
      excludedPatterns: strings('excludedPatterns', 512),
    );
  }
}

/// Logical library entry. Names are display labels, never filesystem paths.
/// Different IDs always remain different entries, including equal content/name.
class FolderSyncNode {
  const FolderSyncNode({
    required this.id,
    this.parentId,
    required this.kind,
    required this.name,
    this.contentKey,
    this.size = 0,
    this.extension = '',
  });
  final String id;
  final String? parentId;
  final FolderSyncNodeKind kind;
  final String name;
  final String? contentKey;
  final int size;
  final String extension;
  FolderSyncNode copyWith({
    String? id,
    Object? parentId = _unspecified,
    FolderSyncNodeKind? kind,
    String? name,
    Object? contentKey = _unspecified,
    int? size,
    String? extension,
  }) => FolderSyncNode.fromJson({
    ...toJson(),
    'id': ?id,
    if (!identical(parentId, _unspecified)) 'parentId': parentId,
    if (kind != null) 'kind': kind.name,
    'name': ?name,
    if (!identical(contentKey, _unspecified)) 'contentKey': contentKey,
    'size': ?size,
    'extension': ?extension,
  });
  Map<String, dynamic> toJson() => {
    'id': id,
    'parentId': parentId,
    'kind': kind.name,
    'name': name,
    'contentKey': contentKey,
    'size': size,
    'extension': extension,
  };
  String signature({bool deleted = false}) =>
      jsonEncode({...toJson(), 'deleted': deleted});
  void validate() {
    folderSyncValidateId(id, 'nodeId');
    if (parentId != null) folderSyncValidateId(parentId, 'parentId');
    folderSyncValidateName(name);
    if (size < 0 || size > folderSyncMaxCounter) {
      throw const FormatException('文件大小无效');
    }
    if (extension.isNotEmpty &&
        !RegExp(r'^\.[a-z0-9]{1,20}$').hasMatch(extension)) {
      throw const FormatException('文件类型无效');
    }
    if (kind == FolderSyncNodeKind.folder) {
      if (contentKey != null || size != 0 || extension.isNotEmpty) {
        throw const FormatException('文件夹内容标识无效');
      }
    } else if (contentKey != null) {
      final key = contentKey!;
      if (key.length > 512) throw const FormatException('内容标识过长');
      final sha = RegExp(r'^sha256:(\d{1,16}):[a-f0-9]{64}$').firstMatch(key);
      if (sha != null) {
        if (int.tryParse(sha.group(1)!) != size) {
          throw const FormatException('内容大小不一致');
        }
      } else if (!RegExp(
            r'^(bili|podcast):[A-Za-z0-9_:\-]{1,240}$',
          ).hasMatch(key) &&
          !RegExp(r'^cloud:[a-f0-9]{64}(?::[a-f0-9]{64})?$').hasMatch(key)) {
        throw const FormatException('内容标识无效');
      }
    }
  }

  factory FolderSyncNode.fromJson(Map<String, dynamic> json) {
    final kind = FolderSyncNodeKind.values
        .where((v) => v.name == json['kind'])
        .firstOrNull;
    if (kind == null ||
        json['id'] is! String ||
        json['name'] is! String ||
        (json['parentId'] != null && json['parentId'] is! String) ||
        (json['contentKey'] != null && json['contentKey'] is! String) ||
        (json['size'] != null && json['size'] is! int) ||
        (json['extension'] != null && json['extension'] is! String)) {
      throw const FormatException('目录条目无效');
    }
    final node = FolderSyncNode(
      id: json['id'] as String,
      parentId: json['parentId'] as String?,
      kind: kind,
      name: json['name'] as String,
      contentKey: json['contentKey'] as String?,
      size: json['size'] as int? ?? 0,
      extension: json['extension'] as String? ?? '',
    );
    node.validate();
    return node;
  }
}

class FolderSyncLocalEntry {
  const FolderSyncLocalEntry({
    required this.localId,
    this.parentLocalId,
    required this.kind,
    required this.name,
    this.contentKey,
    this.size = 0,
    this.extension = '',
  });
  final String localId;
  final String? parentLocalId;
  final FolderSyncNodeKind kind;
  final String name;
  final String? contentKey;
  final int size;
  final String extension;
}

class FolderSyncEvent {
  FolderSyncEvent({
    required this.id,
    required this.groupId,
    required this.deviceId,
    required Map<String, int> clock,
    required this.node,
    this.deleted = false,
    this.createdAtMs = 0,
    String? deviceName,
  }) : clock = Map.unmodifiable(clock),
       _deviceName = deviceName;
  final String id, groupId, deviceId;
  final Map<String, int> clock;
  final FolderSyncNode node;
  final bool deleted;
  final int createdAtMs;
  final String? _deviceName;
  String get eventId => id;
  String get deviceName =>
      _deviceName?.isNotEmpty == true ? _deviceName! : deviceId;
  String get fileName => node.name;
  int get bytes => node.size;
  DateTime? get modifiedAt => DateTime.fromMillisecondsSinceEpoch(createdAtMs);
  String get semanticSignature => node.signature(deleted: deleted);
  bool descendsFrom(FolderSyncEvent other) =>
      folderSyncClockAfter(clock, other.clock);
  Map<String, dynamic> toJson() => {
    'id': id,
    'groupId': groupId,
    'deviceId': deviceId,
    'clock': {for (final key in clock.keys.toList()..sort()) key: clock[key]},
    'node': node.toJson(),
    'deleted': deleted,
    'createdAtMs': createdAtMs,
    if (_deviceName != null) 'deviceName': _deviceName,
  };
  void validate() {
    folderSyncValidateId(id, 'eventId');
    folderSyncValidateId(groupId, 'groupId');
    folderSyncValidateId(deviceId, 'deviceId');
    folderSyncValidateClock(clock);
    if ((clock[deviceId] ?? 0) <= 0) throw const FormatException('事件缺少作者时钟');
    if (createdAtMs.abs() > 8640000000000000 ||
        (_deviceName != null &&
            (_deviceName.length > 100 || _control.hasMatch(_deviceName)))) {
      throw const FormatException('事件展示信息无效');
    }
    node.validate();
  }

  factory FolderSyncEvent.fromJson(Map<String, dynamic> json) {
    final rawClock = json['clock'];
    if (rawClock is! Map ||
        rawClock.length > 128 ||
        json['node'] is! Map ||
        json['id'] is! String ||
        json['groupId'] is! String ||
        json['deviceId'] is! String ||
        (json['deleted'] != null && json['deleted'] is! bool) ||
        (json['createdAtMs'] != null && json['createdAtMs'] is! int) ||
        (json['deviceName'] != null && json['deviceName'] is! String)) {
      throw const FormatException('目录事件无效');
    }
    final clock = <String, int>{};
    for (final entry in rawClock.entries) {
      if (entry.key is! String || entry.value is! int) {
        throw const FormatException('目录时钟无效');
      }
      clock[entry.key as String] = entry.value as int;
    }
    final event = FolderSyncEvent(
      id: json['id'] as String,
      groupId: json['groupId'] as String,
      deviceId: json['deviceId'] as String,
      clock: clock,
      node: FolderSyncNode.fromJson(
        Map<String, dynamic>.from(json['node'] as Map),
      ),
      deleted: json['deleted'] as bool? ?? false,
      createdAtMs: json['createdAtMs'] as int? ?? 0,
      deviceName: json['deviceName'] as String?,
    );
    event.validate();
    return event;
  }
}

class FolderSyncIssue {
  FolderSyncIssue({
    required this.groupId,
    required this.nodeId,
    required this.title,
    required this.reason,
    required List<FolderSyncEvent> choices,
  }) : choices = List.unmodifiable(choices);
  final String groupId, nodeId, title, reason;
  final List<FolderSyncEvent> choices;
  String get path => title;
  FolderSyncIssueKind get kind => switch (reason) {
    'concurrentDelete' => FolderSyncIssueKind.deleteConflict,
    'concurrentMove' => FolderSyncIssueKind.moveConflict,
    'concurrentRename' => FolderSyncIssueKind.renameConflict,
    'concurrentContent' ||
    'concurrentEdit' => FolderSyncIssueKind.contentConflict,
    _ => FolderSyncIssueKind.blocked,
  };
  String get message => reason == 'missingLocalFile'
      ? '本机文件暂不可用，可重新定位或等待其他设备补齐'
      : reason == 'settingsConflict'
      ? '两台设备修改了同步设置，请重新确认。'
      : switch (kind) {
          FolderSyncIssueKind.deleteConflict => '一端移除了条目，另一端有改动，请选择保留的版本',
          FolderSyncIssueKind.moveConflict => '条目在两端被移到了不同位置',
          FolderSyncIssueKind.renameConflict => '条目在两端使用了不同名称',
          FolderSyncIssueKind.contentConflict => '两端的条目内容不同，请选择保留的版本',
          FolderSyncIssueKind.blocked => '目录关系暂不完整，已暂停应用此条目',
        };
}

class FolderSyncAcknowledgement {
  FolderSyncAcknowledgement({
    required this.nodeId,
    required Map<String, int> clock,
    required this.metadataSignature,
    this.contentKey,
  }) : clock = Map.unmodifiable(clock);
  final String nodeId, metadataSignature;
  final String? contentKey;
  final Map<String, int> clock;
  Map<String, dynamic> toJson() => {
    'nodeId': nodeId,
    'clock': {for (final key in clock.keys.toList()..sort()) key: clock[key]},
    'metadataSignature': metadataSignature,
    'contentKey': contentKey,
  };
  factory FolderSyncAcknowledgement.fromJson(Map<String, dynamic> json) {
    folderSyncValidateId(json['nodeId'], 'nodeId');
    final signature = json['metadataSignature'];
    if (signature is! String ||
        signature.length > 8192 ||
        (json['contentKey'] != null &&
            (json['contentKey'] is! String ||
                (json['contentKey'] as String).length > 512)) ||
        json['clock'] is! Map) {
      throw const FormatException('确认记录无效');
    }
    final clock = Map<String, int>.from(json['clock'] as Map);
    folderSyncValidateClock(clock, allowEmpty: true);
    return FolderSyncAcknowledgement(
      nodeId: json['nodeId'] as String,
      clock: clock,
      metadataSignature: signature,
      contentKey: json['contentKey'] as String?,
    );
  }
}

final _control = RegExp(r'[\x00-\x1f\x7f]');
void folderSyncValidateName(String name) {
  if (name.trim().isEmpty ||
      name.length > 1024 ||
      name == '.' ||
      name == '..' ||
      _control.hasMatch(name)) {
    throw const FormatException('条目名称无效');
  }
}

void folderSyncValidateId(dynamic value, String label) {
  if (value is! String ||
      !RegExp(r'^[A-Za-z0-9_.:\-]{1,128}$').hasMatch(value)) {
    throw FormatException('$label 无效');
  }
}

void folderSyncValidateClock(
  Map<String, int> clock, {
  bool allowEmpty = false,
}) {
  if (clock.length > 128 || (!allowEmpty && clock.isEmpty)) {
    throw const FormatException('目录时钟数量无效');
  }
  for (final entry in clock.entries) {
    folderSyncValidateId(entry.key, 'clockDevice');
    if (entry.value < 0 || entry.value > folderSyncMaxCounter) {
      throw const FormatException('目录时钟范围无效');
    }
  }
}

bool folderSyncClockAfter(Map<String, int> a, Map<String, int> b) {
  var greater = false;
  for (final device in {...a.keys, ...b.keys}) {
    final left = a[device] ?? 0, right = b[device] ?? 0;
    if (left < right) return false;
    if (left > right) greater = true;
  }
  return greater;
}

Map<String, int> folderSyncMergeClocks(Iterable<Map<String, int>> clocks) {
  final result = <String, int>{};
  for (final clock in clocks) {
    for (final entry in clock.entries) {
      if ((result[entry.key] ?? 0) < entry.value) {
        result[entry.key] = entry.value;
      }
    }
  }
  return result;
}
