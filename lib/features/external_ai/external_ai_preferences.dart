import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../../utils/app_data_paths.dart';
import '../../utils/app_branding.dart';

class ExternalAiPreferences {
  const ExternalAiPreferences({
    this.enabled = false,
    this.port = defaultPort,
    required this.token,
    this.scopeFolderId,
    this.includeConversations = false,
    this.allowTaskControl = false,
    this.allowSubtitleWrite = false,
    this.autoTaskDecisions = false,
    this.autoModelDownloads = false,
    this.autoRemoteProcessing = false,
    this.preferredClient,
  });

  static const defaultPort = kExternalAiDefaultPort;

  static bool get isDesktopSupported =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  static String generateToken() {
    final random = Random.secure();
    return base64Url
        .encode(List<int>.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }

  final bool enabled;
  final int port;
  final String token;

  /// Null authorizes the whole visible library after the user enables access.
  final String? scopeFolderId;
  final bool includeConversations;
  final bool allowTaskControl;
  final bool allowSubtitleWrite;
  final bool autoRemoteProcessing;
  final bool autoModelDownloads;
  final bool autoTaskDecisions;

  /// A UI choice only; changing it does not change access or restart the server.
  final String? preferredClient;

  ExternalAiPreferences copyWith({
    bool? enabled,
    int? port,
    String? token,
    String? scopeFolderId,
    bool clearScopeFolderId = false,
    bool? includeConversations,
    bool? allowTaskControl,
    bool? allowSubtitleWrite,
    bool? autoTaskDecisions,
    bool? autoModelDownloads,
    bool? autoRemoteProcessing,
    String? preferredClient,
  }) => ExternalAiPreferences(
    enabled: enabled ?? this.enabled,
    port: port ?? this.port,
    token: token ?? this.token,
    scopeFolderId: clearScopeFolderId
        ? null
        : scopeFolderId ?? this.scopeFolderId,
    includeConversations: includeConversations ?? this.includeConversations,
    allowTaskControl: allowTaskControl ?? this.allowTaskControl,
    allowSubtitleWrite: allowSubtitleWrite ?? this.allowSubtitleWrite,
    autoTaskDecisions: autoTaskDecisions ?? this.autoTaskDecisions,
    autoModelDownloads: autoModelDownloads ?? this.autoModelDownloads,
    autoRemoteProcessing: autoRemoteProcessing ?? this.autoRemoteProcessing,
    preferredClient: preferredClient ?? this.preferredClient,
  );

  Map<String, dynamic> toJson() => {
    'version': 1,
    'enabled': enabled,
    'port': port,
    'token': token,
    'scopeFolderId': scopeFolderId,
    'includeConversations': includeConversations,
    'allowTaskControl': allowTaskControl,
    'allowSubtitleWrite': allowSubtitleWrite,
    'autoTaskDecisions': autoTaskDecisions,
    'autoModelDownloads': autoModelDownloads,
    'autoRemoteProcessing': autoRemoteProcessing,
    if (preferredClient != null) 'preferredClient': preferredClient,
  };

  factory ExternalAiPreferences.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1 ||
        json['enabled'] is! bool ||
        json['port'] is! int ||
        (json['port'] as int) < 1 ||
        (json['port'] as int) > 65535 ||
        json['token'] is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43,128}$').hasMatch(json['token'] as String) ||
        (json['scopeFolderId'] != null && json['scopeFolderId'] is! String) ||
        (json['includeConversations'] != null &&
            json['includeConversations'] is! bool) ||
        (json['allowTaskControl'] != null &&
            json['allowTaskControl'] is! bool) ||
        (json['allowSubtitleWrite'] != null &&
            json['allowSubtitleWrite'] is! bool) ||
        (json['autoTaskDecisions'] != null &&
            json['autoTaskDecisions'] is! bool) ||
        (json['autoModelDownloads'] != null &&
            json['autoModelDownloads'] is! bool) ||
        (json['autoRemoteProcessing'] != null &&
            json['autoRemoteProcessing'] is! bool) ||
        (json['preferredClient'] != null &&
            json['preferredClient'] is! String)) {
      throw const FormatException('外部 AI 连接设置无法读取，原文件已保留。');
    }
    return ExternalAiPreferences(
      enabled: json['enabled'] as bool,
      port: json['port'] as int,
      token: json['token'] as String,
      scopeFolderId: json['scopeFolderId'] as String?,
      includeConversations: json['includeConversations'] as bool? ?? false,
      allowTaskControl: json['allowTaskControl'] == true,
      allowSubtitleWrite: json['allowSubtitleWrite'] == true,
      autoTaskDecisions: json['autoTaskDecisions'] == true,
      autoModelDownloads: json['autoModelDownloads'] == true,
      autoRemoteProcessing: json['autoRemoteProcessing'] == true,
      preferredClient: json['preferredClient'] as String?,
    );
  }
}

/// Stored separately from exportable AI settings: the local access token is
/// never sent to model providers or included in a conversation/settings export.
class ExternalAiPreferencesStore {
  ExternalAiPreferencesStore({this.root});

  final Directory? root;
  Future<void> _pending = Future.value();

  Future<File> _file() async => File(
    p.join(
      (root ?? await resolveAppDataDirectory()).path,
      'external_ai',
      '$kApplicationId.json',
    ),
  );

  Future<ExternalAiPreferences> load() async {
    await _pending;
    final file = await _file();
    if (!await file.exists()) {
      final preferences = ExternalAiPreferences(
        token: ExternalAiPreferences.generateToken(),
      );
      await save(preferences);
      return preferences;
    }
    try {
      return ExternalAiPreferences.fromJson(
        Map<String, dynamic>.from(jsonDecode(await file.readAsString()) as Map),
      );
    } catch (_) {
      // Preserve existing credentials and permissions on malformed input.
      throw const FormatException('外部 AI 连接设置无法读取，原文件已保留。');
    }
  }

  Future<void> save(ExternalAiPreferences preferences) {
    // Validate before serializing: never persist a partial/invalid access setup.
    ExternalAiPreferences.fromJson(preferences.toJson());
    final write = _pending.then((_) async {
      final file = await _file();
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      final backup = File('${file.path}.bak');
      await temporary.writeAsString(
        jsonEncode(preferences.toJson()),
        flush: true,
      );
      if (await file.exists()) {
        if (await backup.exists()) await backup.delete();
        await file.rename(backup.path);
      }
      try {
        await temporary.rename(file.path);
      } catch (_) {
        if (!await file.exists() && await backup.exists()) {
          await backup.rename(file.path);
        }
        rethrow;
      }
    });
    _pending = write.catchError((Object _) {});
    return write;
  }
}
