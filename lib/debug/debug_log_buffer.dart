import 'dart:async';

import 'package:flutter/foundation.dart';

import 'log_redaction.dart';

/// One kept console line. Repeats that only differ by numbers share an entry.
class DebugLogEntry {
  DebugLogEntry(this.text, this.shape);

  String text;
  final String shape;
  int count = 1;

  String get display => count > 1 ? '$text ×$count' : text;
}

/// In-app copy of the debug console: `debugPrint`, `print`, and `developer.log`.
///
/// Parser traces that only differ by field numbers collapse into one line so
/// they do not crowd out the surrounding log.
class DebugLogBuffer extends ChangeNotifier {
  DebugLogBuffer._();

  static final DebugLogBuffer instance = DebugLogBuffer._();

  static const int maxEntries = 800;

  /// Same shape within this many trailing rows is treated as one burst.
  static const int _collapseWindow = 8;

  static final RegExp _number = RegExp(r'\d+(?:\.\d+)?');
  static final RegExp _firstFrame = RegExp(r'(?:^|\n)#0\s+[^\n]*');
  static final RegExp _thrownHeader = RegExp(r'^The following .+ was thrown\b');

  final List<DebugLogEntry> _entries = <DebugLogEntry>[];
  bool _installed = false;
  bool _panelVisible = false;
  bool _forwardingDebugPrint = false;
  int _suppressDepth = 0;
  Timer? _notifyTimer;

  List<DebugLogEntry> get entries => List<DebugLogEntry>.unmodifiable(_entries);

  String get displayText {
    if (_entries.isEmpty) return '';
    return _entries.map((entry) => entry.display).join('\n');
  }

  bool get isForwardingDebugPrint => _forwardingDebugPrint;

  void install() {
    if (_installed) return;
    _installed = true;
    debugPrint = (String? message, {int? wrapWidth}) {
      message = message == null ? null : redactSensitiveLogText(message);
      add(message);
      _forwardingDebugPrint = true;
      try {
        debugPrintSynchronously(message, wrapWidth: wrapWidth);
      } finally {
        _forwardingDebugPrint = false;
      }
    };
  }

  /// Drops console output whose stack begins in the debug ball itself.
  bool stackOriginatesInOverlay(StackTrace? stack) {
    if (stack == null) return false;
    return _firstFrameIsOwn(stack.toString());
  }

  void beginSuppressingOwnOutput() => _suppressDepth++;

  void endSuppressingOwnOutput() {
    if (_suppressDepth > 0) _suppressDepth--;
  }

  /// Release builds already print framework errors through [debugPrint].
  /// This only adds a one-line summary when that path stayed silent.
  void recordReleaseFrameworkError(Object error, StackTrace? stack) {
    if (!kReleaseMode) return;
    if (stackOriginatesInOverlay(stack)) return;
    final summary = _firstNonEmptyLine(error.toString());
    if (summary.isEmpty || _recentlyRecorded(summary)) return;
    add(summary);
  }

  void setPanelVisible(bool visible) {
    _panelVisible = visible;
    if (!visible) {
      _notifyTimer?.cancel();
      _notifyTimer = null;
    }
  }

  void add(String? message) {
    if (_suppressDepth > 0 || message == null) return;
    final raw = redactSensitiveLogText(message).trimRight();
    if (raw.trim().isEmpty) return;
    if (_firstFrameIsOwn(raw)) return;
    final stored = _isFlutterDump(raw) ? _summarizeDump(raw) : raw;
    if (stored.trim().isEmpty) return;
    _append(stored);
    _scheduleNotify();
  }

  @visibleForTesting
  void clear() {
    _entries.clear();
    _notifyTimer?.cancel();
    _notifyTimer = null;
  }

  void _append(String text) {
    final shape = _shape(text);
    for (var index = _entries.length - 1; index >= 0; index--) {
      if (_entries.length - index > _collapseWindow) break;
      if (_entries[index].shape != shape) continue;
      _entries[index].text = text;
      _entries[index].count += 1;
      return;
    }
    _entries.add(DebugLogEntry(text, shape));
    while (_entries.length > maxEntries) {
      _entries.removeAt(0);
    }
  }

  void _scheduleNotify() {
    if (!_panelVisible || _notifyTimer != null) return;
    _notifyTimer = Timer(const Duration(milliseconds: 100), () {
      _notifyTimer = null;
      if (_panelVisible) notifyListeners();
    });
  }

  bool _recentlyRecorded(String summary) {
    final start = _entries.length > 4 ? _entries.length - 4 : 0;
    for (var index = start; index < _entries.length; index++) {
      if (_entries[index].text.contains(summary)) return true;
    }
    return false;
  }

  static String _shape(String text) {
    if (text.contains('[Parser]')) return '[Parser]';
    return text.replaceAll(_number, '#');
  }

  static bool _firstFrameIsOwn(String text) {
    final match = _firstFrame.firstMatch(text);
    if (match == null) return false;
    final line = match.group(0)!;
    return line.contains('debug_log_overlay.dart') ||
        line.contains('debug_log_buffer.dart');
  }

  static bool _isFlutterDump(String message) {
    return message.contains('EXCEPTION CAUGHT BY') ||
        message.contains('Another exception was thrown') ||
        message.contains('widget tree') ||
        message.contains('Widget tree') ||
        message.contains('◢◤') ||
        message.contains('══');
  }

  static String _summarizeDump(String message) {
    final lines = message.split('\n');
    for (final raw in lines) {
      final line = raw.trim();
      const marker = 'Another exception was thrown:';
      final index = line.indexOf(marker);
      if (index < 0) continue;
      final summary = line.substring(index + marker.length).trim();
      if (summary.isNotEmpty) return summary;
    }
    for (var index = 0; index < lines.length; index++) {
      if (!_thrownHeader.hasMatch(lines[index].trim())) continue;
      for (var next = index + 1; next < lines.length; next++) {
        final line = lines[next].trim();
        if (line.isEmpty || _isDumpChrome(line)) continue;
        return line;
      }
    }
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty || _isDumpChrome(line)) continue;
      if (line.startsWith('The following ')) continue;
      return line;
    }
    return _firstNonEmptyLine(message);
  }

  static bool _isDumpChrome(String line) {
    if (line.startsWith('#')) return true;
    if (line.startsWith('══') || line.startsWith('═')) return true;
    if (line.startsWith('◢') || line.startsWith('◤')) return true;
    if (line.startsWith('└') ||
        line.startsWith('├') ||
        line.startsWith('│') ||
        line.startsWith('║')) {
      return true;
    }
    return line.startsWith('The relevant ') ||
        line.startsWith('When the exception') ||
        line.startsWith('The widget') ||
        line.startsWith('This was the widget');
  }

  static String _firstNonEmptyLine(String value) {
    for (final line in value.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return '';
  }
}
