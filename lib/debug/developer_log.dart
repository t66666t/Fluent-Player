import 'dart:async';
import 'dart:developer' as developer;

import 'debug_log_buffer.dart';
import 'log_redaction.dart';

export 'dart:developer' hide log;

/// Same call shape as `developer.log`, and also copied into the debug ball.
///
/// The debug console shows these through the VM service. `debugPrint` never
/// sees them, so the ball has to record them here.
void log(
  String message, {
  DateTime? time,
  int? sequenceNumber,
  int level = 0,
  String name = '',
  Zone? zone,
  Object? error,
  StackTrace? stackTrace,
}) {
  message = redactSensitiveLogText(message);
  error = error == null ? null : redactSensitiveLogText(error.toString());
  final text = StringBuffer();
  if (name.isNotEmpty) text.write('[$name] ');
  text.write(message);
  if (error != null) text.write('\n$error');
  if (stackTrace != null &&
      !DebugLogBuffer.instance.stackOriginatesInOverlay(stackTrace)) {
    text.write('\n$stackTrace');
  }
  DebugLogBuffer.instance.add(text.toString());
  developer.log(
    message,
    time: time,
    sequenceNumber: sequenceNumber,
    level: level,
    name: name,
    zone: zone,
    error: error,
    stackTrace: stackTrace,
  );
}
