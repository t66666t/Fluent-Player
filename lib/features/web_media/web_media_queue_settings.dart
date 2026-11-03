import 'dart:convert';

/// Browser downloads have their own policy, independent of other importers.
class WebMediaQueueSettings {
  const WebMediaQueueSettings({
    this.autoStart = true,
    this.parallelTasks = 3,
    this.connections = 32,
    this.bytesPerSecond = 0,
    this.retryLimit = 6,
    this.resumeOnStartup = false,
    this.autoRemoveAfterImport = false,
  });

  final bool autoStart, resumeOnStartup, autoRemoveAfterImport;
  final int parallelTasks, connections, bytesPerSecond, retryLimit;

  WebMediaQueueSettings copyWith({
    bool? autoStart,
    int? parallelTasks,
    int? connections,
    int? bytesPerSecond,
    int? retryLimit,
    bool? resumeOnStartup,
    bool? autoRemoveAfterImport,
  }) => WebMediaQueueSettings(
    autoStart: autoStart ?? this.autoStart,
    parallelTasks: (parallelTasks ?? this.parallelTasks).clamp(1, 8),
    connections: (connections ?? this.connections).clamp(1, 32),
    bytesPerSecond: (bytesPerSecond ?? this.bytesPerSecond).clamp(0, 1 << 40),
    retryLimit: (retryLimit ?? this.retryLimit).clamp(0, 10),
    resumeOnStartup: resumeOnStartup ?? this.resumeOnStartup,
    autoRemoveAfterImport: autoRemoveAfterImport ?? this.autoRemoveAfterImport,
  );

  Map<String, Object> toJson() => {
    'autoStart': autoStart,
    'parallelTasks': parallelTasks,
    'connections': connections,
    'bytesPerSecond': bytesPerSecond,
    'retryLimit': retryLimit,
    'resumeOnStartup': resumeOnStartup,
    'autoRemoveAfterImport': autoRemoveAfterImport,
  };

  static WebMediaQueueSettings decode(String? value, {int? legacyConnections}) {
    var result = const WebMediaQueueSettings().copyWith(
      connections: legacyConnections,
    );
    try {
      final json = jsonDecode(value ?? '{}') as Map;
      int? integer(String key) => json[key] is int ? json[key] as int : null;
      result = result.copyWith(
        autoStart: json['autoStart'] is bool ? json['autoStart'] as bool : null,
        parallelTasks: integer('parallelTasks'),
        connections: integer('connections'),
        bytesPerSecond: integer('bytesPerSecond'),
        retryLimit: integer('retryLimit'),
        resumeOnStartup: json['resumeOnStartup'] is bool
            ? json['resumeOnStartup'] as bool
            : null,
        autoRemoveAfterImport: json['autoRemoveAfterImport'] is bool
            ? json['autoRemoveAfterImport'] as bool
            : null,
      );
    } catch (_) {
      /* Keep usable defaults if preferences were damaged. */
    }
    return result;
  }
}
