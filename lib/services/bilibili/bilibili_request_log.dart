import 'dart:collection';

import '../../debug/developer_log.dart' as developer;

/// One Bilibili request as seen by the diagnostics log. Holds no cookie,
/// csrf or key values: only whether they were present.
class BilibiliRequestRecord {
  const BilibiliRequestRecord({
    required this.method,
    required this.path,
    this.httpStatus,
    this.code,
    this.message = '',
    this.hasDeviceId = false,
    this.hasLogin = false,
    this.signed = false,
    this.attempt = 1,
  });

  final String method;
  final String path;
  final int? httpStatus;

  /// Bilibili's business code, when a JSON answer came back.
  final int? code;

  /// Bilibili's own message text, as returned.
  final String message;
  final bool hasDeviceId;
  final bool hasLogin;
  final bool signed;

  /// 2 for the automatic retry after risk control.
  final int attempt;

  String describe() {
    String flag(bool on) => on ? 'yes' : 'no';
    return '$method $path'
        '${httpStatus == null ? '' : ' http=$httpStatus'}'
        ' code=${code ?? '-'}'
        '${message.isEmpty ? '' : ' message="$message"'}'
        ' device=${flag(hasDeviceId)} login=${flag(hasLogin)}'
        ' signed=${flag(signed)}'
        '${attempt > 1 ? ' attempt=$attempt' : ''}';
  }
}

/// Local diagnostics of Bilibili requests: written to the in-app debug log
/// (on this device only) and kept in memory for the last [capacity]
/// requests. Records never contain cookie, csrf, buvid or key values; the
/// message text goes through the same redaction as every log line.
class BilibiliRequestLog {
  BilibiliRequestLog._();

  static final BilibiliRequestLog instance = BilibiliRequestLog._();

  static const int capacity = 200;

  final ListQueue<BilibiliRequestRecord> _records =
      ListQueue<BilibiliRequestRecord>();

  List<BilibiliRequestRecord> get records =>
      List<BilibiliRequestRecord>.unmodifiable(_records);

  void record(BilibiliRequestRecord record) {
    _records.addLast(record);
    while (_records.length > capacity) {
      _records.removeFirst();
    }
    developer.log(record.describe(), name: 'BilibiliRequest');
  }

  void clear() => _records.clear();

  /// Bilibili's code and message from a decoded JSON answer.
  static (int?, String) readCodeAndMessage(Object? payload) {
    if (payload is! Map) return (null, '');
    final raw = payload['code'];
    final code = raw is num ? raw.toInt() : int.tryParse('${raw ?? ''}');
    final message = (payload['message'] ?? payload['msg'] ?? '')
        .toString()
        .trim();
    return (code, message.length > 120 ? message.substring(0, 120) : message);
  }
}
