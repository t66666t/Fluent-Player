import 'dart:convert';
import 'dart:math' as math;

/// How watch-time and duration-percent gates combine.
enum ContinueWatchCombineMode {
  /// Current product default: enroll at the easier of the two gates.
  shorter,
  both,
  either,
}

/// User-tunable "continue watching" rules. Defaults match the original
/// min(30s, 20% of duration) + hide completed items.
class ContinueWatchPolicy {
  const ContinueWatchPolicy({
    required this.combineMode,
    required this.minWatchMs,
    required this.minDurationFraction,
    required this.minProgressFraction,
    required this.minItemDurationMs,
    required this.hideRemainingBelowMs,
    required this.maxAgeDays,
    required this.excludeCompleted,
    required this.useProgressIfNoWatchClock,
  });

  static const ContinueWatchPolicy defaults = ContinueWatchPolicy(
    combineMode: ContinueWatchCombineMode.shorter,
    minWatchMs: 30000,
    minDurationFraction: 0.20,
    minProgressFraction: 0,
    minItemDurationMs: 0,
    hideRemainingBelowMs: 0,
    maxAgeDays: 0,
    excludeCompleted: true,
    useProgressIfNoWatchClock: true,
  );

  static const int minWatchMsMin = 0;
  static const int minWatchMsMax = 600000;
  static const double minDurationFractionMin = 0;
  static const double minDurationFractionMax = 0.80;
  static const double minProgressFractionMin = 0;
  static const double minProgressFractionMax = 0.90;
  static const int minItemDurationMsMax = 300000;
  static const int hideRemainingBelowMsMax = 300000;
  static const int maxAgeDaysMax = 3650;
  static const List<int> maxAgeDayChoices = <int>[0, 7, 14, 30, 90, 365];

  final ContinueWatchCombineMode combineMode;
  final int minWatchMs;
  final double minDurationFraction;
  final double minProgressFraction;
  final int minItemDurationMs;
  final int hideRemainingBelowMs;
  final int maxAgeDays;
  final bool excludeCompleted;
  final bool useProgressIfNoWatchClock;

  ContinueWatchPolicy copyWith({
    ContinueWatchCombineMode? combineMode,
    int? minWatchMs,
    double? minDurationFraction,
    double? minProgressFraction,
    int? minItemDurationMs,
    int? hideRemainingBelowMs,
    int? maxAgeDays,
    bool? excludeCompleted,
    bool? useProgressIfNoWatchClock,
  }) {
    return ContinueWatchPolicy(
      combineMode: combineMode ?? this.combineMode,
      minWatchMs: minWatchMs ?? this.minWatchMs,
      minDurationFraction: minDurationFraction ?? this.minDurationFraction,
      minProgressFraction: minProgressFraction ?? this.minProgressFraction,
      minItemDurationMs: minItemDurationMs ?? this.minItemDurationMs,
      hideRemainingBelowMs: hideRemainingBelowMs ?? this.hideRemainingBelowMs,
      maxAgeDays: maxAgeDays ?? this.maxAgeDays,
      excludeCompleted: excludeCompleted ?? this.excludeCompleted,
      useProgressIfNoWatchClock:
          useProgressIfNoWatchClock ?? this.useProgressIfNoWatchClock,
    );
  }

  /// Wall-clock needed when [combineMode] is [ContinueWatchCombineMode.shorter].
  int shorterThresholdMs(int? durationMs) {
    final timeNeed = math.max(0, minWatchMs);
    final percentNeed = _percentNeedMs(durationMs);
    if (timeNeed <= 0 && percentNeed <= 0) return 0;
    if (timeNeed <= 0) return percentNeed;
    if (percentNeed <= 0) return timeNeed;
    return math.min(timeNeed, percentNeed);
  }

  /// Actual watch time a clip of [durationMs] must accumulate to pass the gate.
  ///
  /// `shorter` and `either` both reduce to the easier of the two numbers;
  /// `both` requires the harder of the two.
  int watchNeedMsForDuration(int? durationMs) {
    final timeNeed = math.max(0, minWatchMs);
    final percentNeed = _percentNeedMs(durationMs);
    switch (combineMode) {
      case ContinueWatchCombineMode.shorter:
      case ContinueWatchCombineMode.either:
        return shorterThresholdMs(durationMs);
      case ContinueWatchCombineMode.both:
        if (timeNeed <= 0) return percentNeed;
        if (percentNeed <= 0) return timeNeed;
        return math.max(timeNeed, percentNeed);
    }
  }

  bool hasReachedWatchGate(int watchMs, int? durationMs) {
    final watched = math.max(0, watchMs);
    final timeOk = minWatchMs <= 0 || watched >= minWatchMs;
    final percentNeed = _percentNeedMs(durationMs);
    final percentOk = percentNeed <= 0 || watched >= percentNeed;
    switch (combineMode) {
      case ContinueWatchCombineMode.shorter:
        return watched >= shorterThresholdMs(durationMs);
      case ContinueWatchCombineMode.both:
        return timeOk && percentOk;
      case ContinueWatchCombineMode.either:
        if (minWatchMs <= 0 && percentNeed <= 0) return true;
        if (minWatchMs <= 0) return percentOk;
        if (percentNeed <= 0) return timeOk;
        return timeOk || percentOk;
    }
  }

  /// One-line switch subtitle. Keep it short; details live in the sheet.
  String get compactLabel {
    final parts = <String>[
      _gatePhrase(),
      if (excludeCompleted) '未看完',
      if (minProgressFraction > 0) '进度${_percentLabel(minProgressFraction)}',
      if (minItemDurationMs > 0) '片长≥${formatDurationMs(minItemDurationMs)}',
      if (hideRemainingBelowMs > 0)
        '剩>${formatDurationMs(hideRemainingBelowMs)}',
      if (maxAgeDays > 0) '近$maxAgeDays天',
    ];
    return parts.join(' · ');
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'combineMode': combineMode.name,
    'minWatchMs': minWatchMs,
    'minDurationFraction': minDurationFraction,
    'minProgressFraction': minProgressFraction,
    'minItemDurationMs': minItemDurationMs,
    'hideRemainingBelowMs': hideRemainingBelowMs,
    'maxAgeDays': maxAgeDays,
    'excludeCompleted': excludeCompleted,
    'useProgressIfNoWatchClock': useProgressIfNoWatchClock,
  };

  String toJsonString() => json.encode(toJson());

  factory ContinueWatchPolicy.fromJsonString(String raw) {
    if (raw.trim().isEmpty) return defaults;
    try {
      final decoded = json.decode(raw);
      if (decoded is! Map) return defaults;
      return ContinueWatchPolicy.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return defaults;
    }
  }

  factory ContinueWatchPolicy.fromJson(Map<String, dynamic> json) {
    return ContinueWatchPolicy(
      combineMode: _modeOf(json['combineMode']),
      minWatchMs: _clampInt(
        json['minWatchMs'],
        defaults.minWatchMs,
        minWatchMsMin,
        minWatchMsMax,
      ),
      minDurationFraction: _clampDouble(
        json['minDurationFraction'],
        defaults.minDurationFraction,
        minDurationFractionMin,
        minDurationFractionMax,
      ),
      minProgressFraction: _clampDouble(
        json['minProgressFraction'],
        defaults.minProgressFraction,
        minProgressFractionMin,
        minProgressFractionMax,
      ),
      minItemDurationMs: _clampInt(
        json['minItemDurationMs'],
        defaults.minItemDurationMs,
        0,
        minItemDurationMsMax,
      ),
      hideRemainingBelowMs: _clampInt(
        json['hideRemainingBelowMs'],
        defaults.hideRemainingBelowMs,
        0,
        hideRemainingBelowMsMax,
      ),
      maxAgeDays: _clampInt(
        json['maxAgeDays'],
        defaults.maxAgeDays,
        0,
        maxAgeDaysMax,
      ),
      excludeCompleted: json['excludeCompleted'] is bool
          ? json['excludeCompleted'] as bool
          : defaults.excludeCompleted,
      useProgressIfNoWatchClock: json['useProgressIfNoWatchClock'] is bool
          ? json['useProgressIfNoWatchClock'] as bool
          : defaults.useProgressIfNoWatchClock,
    );
  }

  int _percentNeedMs(int? durationMs) {
    if (durationMs == null || durationMs <= 0 || minDurationFraction <= 0) {
      return 0;
    }
    return (durationMs * minDurationFraction).floor();
  }

  String _gatePhrase() {
    final time = minWatchMs > 0 ? formatDurationMs(minWatchMs) : null;
    final percent = minDurationFraction > 0
        ? _percentLabel(minDurationFraction)
        : null;
    if (time == null && percent == null) return '不限观看时长';
    if (time == null) return percent!;
    if (percent == null) return time;
    switch (combineMode) {
      case ContinueWatchCombineMode.shorter:
        return '$time / $percent（较短）';
      case ContinueWatchCombineMode.both:
        return '$time且$percent';
      case ContinueWatchCombineMode.either:
        return '$time或$percent';
    }
  }

  static String _percentLabel(double fraction) => formatPercent(fraction);

  static String formatPercent(double fraction) {
    final pct = fraction * 100;
    if ((pct - pct.roundToDouble()).abs() < 0.05) return '${pct.round()}%';
    return '${pct.toStringAsFixed(1)}%';
  }

  static String formatDurationMs(int ms) {
    final totalSeconds = math.max(0, (ms / 1000).round());
    if (totalSeconds <= 0) return '0秒';
    if (totalSeconds < 60) return '$totalSeconds秒';
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    if (minutes < 60) {
      return seconds == 0 ? '$minutes分钟' : '$minutes分$seconds秒';
    }
    final hours = minutes ~/ 60;
    final remainMinutes = minutes % 60;
    if (remainMinutes == 0) return '$hours小时';
    return '$hours小时$remainMinutes分';
  }

  static ContinueWatchCombineMode _modeOf(Object? raw) {
    if (raw is String) {
      for (final mode in ContinueWatchCombineMode.values) {
        if (mode.name == raw) return mode;
      }
    }
    return ContinueWatchCombineMode.shorter;
  }

  static int _clampInt(Object? raw, int fallback, int min, int max) {
    final value = raw is num ? raw.round() : fallback;
    return value.clamp(min, max);
  }

  static double _clampDouble(
    Object? raw,
    double fallback,
    double min,
    double max,
  ) {
    final value = raw is num ? raw.toDouble() : fallback;
    if (value.isNaN || !value.isFinite) return fallback;
    return value.clamp(min, max);
  }

  /// Empty / 不限 / 0 → 0. Bare numbers are seconds. Also accepts `1:30`,
  /// `1分30秒`, `90s`. Null means the text is not a duration.
  static int? parseDurationMs(String raw, {required int maxMs}) {
    var text = raw.trim().toLowerCase();
    if (text.isEmpty || text == '不限' || text == '-' || text == 'off') {
      return 0;
    }
    text = text
        .replaceAll('小时', 'h')
        .replaceAll('钟头', 'h')
        .replaceAll('时', 'h')
        .replaceAll('分钟', 'm')
        .replaceAll('分', 'm')
        .replaceAll('秒钟', 's')
        .replaceAll('秒', 's')
        .replaceAll(RegExp(r'\s+'), '');

    final colon = RegExp(r'^(\d+):(\d{1,2})(?::(\d{1,2}))?$');
    final colonMatch = colon.firstMatch(text);
    if (colonMatch != null) {
      final a = int.parse(colonMatch.group(1)!);
      final b = int.parse(colonMatch.group(2)!);
      final cRaw = colonMatch.group(3);
      final seconds = cRaw == null
          ? a * 60 + b
          : a * 3600 + b * 60 + int.parse(cRaw);
      return (seconds * 1000).clamp(0, maxMs);
    }

    final unit = RegExp(r'^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$');
    final unitMatch = unit.firstMatch(text);
    if (unitMatch != null && text.contains(RegExp(r'[hms]'))) {
      final hours = int.tryParse(unitMatch.group(1) ?? '') ?? 0;
      final minutes = int.tryParse(unitMatch.group(2) ?? '') ?? 0;
      final secs = int.tryParse(unitMatch.group(3) ?? '') ?? 0;
      return ((hours * 3600 + minutes * 60 + secs) * 1000).clamp(0, maxMs);
    }

    final asNumber = num.tryParse(text.replaceAll('s', ''));
    if (asNumber == null || asNumber.isNaN || !asNumber.isFinite) return null;
    return (asNumber.round() * 1000).clamp(0, maxMs);
  }

  /// `20` / `20%` / `不限`. Null if unreadable. Stored as 0–1 fraction.
  static double? parsePercentFraction(
    String raw, {
    required double maxFraction,
  }) {
    var text = raw.trim().toLowerCase();
    if (text.isEmpty || text == '不限' || text == '-' || text == 'off') {
      return 0;
    }
    text = text.replaceAll('%', '').replaceAll('％', '').trim();
    final value = num.tryParse(text);
    if (value == null || value.isNaN || !value.isFinite) return null;
    return (value / 100).clamp(0.0, maxFraction);
  }

  static int? parseAgeDays(String raw) {
    var text = raw.trim().toLowerCase();
    if (text.isEmpty || text == '不限' || text == '-' || text == 'off') {
      return 0;
    }
    text = text.replaceAll('天', '').replaceAll('日', '').trim();
    final value = num.tryParse(text);
    if (value == null || value.isNaN || !value.isFinite) return null;
    return value.round().clamp(0, maxAgeDaysMax);
  }
}

/// Duration ticks for the policy sheet sliders.
///
/// Dense in the first minute (where people actually tune), then coarser.
/// Values that are not on a tick (typed in) sit between neighbors so the
/// thumb does not jump to a wrong named stop.
class ContinueWatchSliderSteps {
  ContinueWatchSliderSteps._();

  static final List<int> minWatchMs = buildTicks(
    maxMs: ContinueWatchPolicy.minWatchMsMax,
  );

  static final List<int> remainingOrItemMs = buildTicks(
    maxMs: ContinueWatchPolicy.minItemDurationMsMax,
  );

  static List<int> buildTicks({required int maxMs}) {
    final maxSec = math.max(0, (maxMs / 1000).round());
    final seconds = <int>{0};
    void addRange(int from, int toInclusive, int step) {
      for (var s = from; s <= toInclusive && s <= maxSec; s += step) {
        seconds.add(s);
      }
    }

    // 0–30s: 1s. 30–60s: 5s. 1–3min: 15s. 3min–max: 30s.
    addRange(1, 30, 1);
    addRange(35, 60, 5);
    addRange(75, 180, 15);
    addRange(210, maxSec, 30);
    seconds.add(maxSec);
    final list = seconds.toList()..sort();
    return list.map((s) => s * 1000).toList(growable: false);
  }

  static double sliderOf(int ms, List<int> steps) {
    if (steps.length <= 1) return 0;
    if (ms <= steps.first) return 0;
    if (ms >= steps.last) return 1;
    final last = steps.length - 1;
    for (var i = 1; i < steps.length; i++) {
      if (ms <= steps[i]) {
        final lo = steps[i - 1];
        final hi = steps[i];
        final local = hi == lo ? 0.0 : (ms - lo) / (hi - lo);
        return ((i - 1) + local) / last;
      }
    }
    return 1;
  }

  static int msOf(double t, List<int> steps) {
    if (steps.isEmpty) return 0;
    if (steps.length == 1) return steps.first;
    final last = steps.length - 1;
    final i = (t.clamp(0.0, 1.0) * last).round();
    return steps[i];
  }

  static int nearestIndex(int ms, List<int> steps) {
    var best = 0;
    var bestDelta = (ms - steps[0]).abs();
    for (var i = 1; i < steps.length; i++) {
      final delta = (ms - steps[i]).abs();
      if (delta < bestDelta) {
        best = i;
        bestDelta = delta;
      }
    }
    return best;
  }
}
