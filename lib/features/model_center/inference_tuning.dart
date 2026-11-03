import 'dart:convert';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import 'inference_resource_governor.dart';

/// Metadata only. Neither inputs nor inference outputs are persisted here.
class InferenceProbeResult {
  const InferenceProbeResult({
    required this.baselineMs,
    required this.candidateMs,
    required this.costMs,
    required this.valid,
    this.startupMs = 0,
  });
  final int baselineMs, candidateMs, costMs, startupMs;
  final bool valid;
}

String inferenceTuningSignature(
  InferenceResourceSession session,
  String modelIdentity,
  String runtime, {
  Object? environment,
  String configuration = '',
}) {
  final s = session.governor.snapshot;
  return sha256
      .convert(
        utf8.encode(
          jsonEncode([
            2,
            modelIdentity,
            runtime,
            s.platform,
            s.environment,
            environment,
            s.effectiveProcessors,
            s.memoryBytes,
            s.playing,
            configuration,
          ]),
        ),
      )
      .toString();
}

/// A bounded experiment ledger. Reservation is saved BEFORE a probe, so an OS
/// termination cannot repeatedly spend the daily budget. The limit is soft:
/// native calls are cooperatively cancelled and can exceed their estimate.
class InferenceTuner {
  InferenceTuner({
    required this.session,
    required this.records,
    required this.modelId,
    required this.signature,
    required this.save,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final InferenceResourceSession session;
  final Map<String, Map<String, dynamic>> records;
  final String modelId, signature;
  final Future<void> Function() save;
  final DateTime Function() _now;
  bool _busy = false;
  DateTime? _lastAttempt;
  String get key => '$modelId:$signature';
  Map<String, dynamic> get _record {
    final value = records.putIfAbsent(
      key,
      () => {
        'model': modelId,
        'signature': signature,
        'pairs': <String, dynamic>{},
      },
    );
    final tested = DateTime.tryParse(value['testedAt'] as String? ?? '');
    if (tested != null &&
        (_now().isBefore(tested) ||
            _now().difference(tested) > const Duration(days: 14))) {
      value['pairs'] = <String, dynamic>{};
      value.remove('preferredThreads');
      value.remove('testedAt');
    }
    return value;
  }

  String get _day => _now().toUtc().toIso8601String().substring(0, 10);
  int get dailySpentMs => records.values
      .where((v) => v['model'] == modelId && v['day'] == _day)
      .fold(
        0,
        (n, v) =>
            n +
            (v['spentMs'] is num
                ? (v['spentMs'] as num).toInt().clamp(0, 30000)
                : 0),
      );
  int get automaticCreditMs => math.max(
    0,
    math.min(
      30000 - dailySpentMs,
      session.productiveTime.inMilliseconds ~/ 20 - session.tuningTimeSpentMs,
    ),
  );
  int? get preferredThreads {
    final r = records[key];
    final date = DateTime.tryParse(r?['testedAt'] as String? ?? '');
    if (date == null ||
        date.isAfter(_now()) ||
        _now().difference(date) > const Duration(days: 14)) {
      return null;
    }
    final value = r?['preferredThreads'];
    return value is num && value.isFinite && value >= 1 && value <= 12
        ? value.toInt()
        : null;
  }

  List<int> candidates(int baseline, int maximum) {
    final values = <int>{
      1,
      2,
      4,
      6,
      8,
      12,
      baseline,
    }.where((v) => v <= maximum).toList()..sort();
    final index = values.indexOf(baseline);
    return [
      if (index + 1 < values.length) values[index + 1],
      if (index > 0) values[index - 1],
    ];
  }

  Future<int?> explore({
    required int baseline,
    required int maximum,
    required int estimatedCostMs,
    required int remainingProductiveMs,
    required Future<InferenceProbeResult> Function(int candidate) probe,
    bool manual = false,
  }) async {
    if (_busy ||
        !session.decision.allowTuning ||
        (!manual &&
            (_lastAttempt != null &&
                _now().difference(_lastAttempt!) <
                    const Duration(seconds: 30)))) {
      return null;
    }
    if (!manual &&
        (estimatedCostMs <= 0 || estimatedCostMs > automaticCreditMs)) {
      return null;
    }
    final pairs = Map<String, dynamic>.from(_record['pairs'] as Map? ?? {});
    final candidate = candidates(baseline, maximum)
        .where(
          (v) => ((pairs['$baseline:$v'] as Map?)?['count'] as num? ?? 0) < 2,
        )
        .firstOrNull;
    if (candidate == null) return null;
    _busy = true;
    _lastAttempt = _now();
    final oldSpent = _record['day'] == _day
        ? (_record['spentMs'] as num?)?.toInt() ?? 0
        : 0;
    final reservation = manual ? 0 : estimatedCostMs;
    var accounted = false;
    _record.addAll({'day': _day, 'spentMs': oldSpent + reservation});
    try {
      await save();
      final result = await probe(candidate);
      accounted = true;
      if (!manual) session.tuningTimeSpentMs += result.costMs;
      _record.addAll({
        'spentMs': oldSpent + (manual ? 0 : result.costMs),
        'lastCostMs': result.costMs,
        'peakResidentBytes': session.peakResidentBytes,
        'peakSlowFrameFraction': session.peakSlowFrameFraction,
      });
      if (!result.valid || !session.decision.allowTuning) return null;
      _record['testedAt'] = _now().toUtc().toIso8601String();
      final name = '$baseline:$candidate';
      final old = Map<String, dynamic>.from(pairs[name] as Map? ?? {});
      final count = ((old['count'] as num?)?.toInt() ?? 0) + 1;
      final baseMs =
          ((old['baselineMs'] as num?)?.toInt() ?? 0) + result.baselineMs;
      final nextMs =
          ((old['candidateMs'] as num?)?.toInt() ?? 0) + result.candidateMs;
      final startup = math.max(
        (old['startupMs'] as num?)?.toInt() ?? 0,
        result.startupMs,
      );
      pairs[name] = {
        'count': count,
        'baselineMs': baseMs,
        'candidateMs': nextMs,
        'startupMs': startup,
      };
      _record['pairs'] = pairs;
      final saving = baseMs > 0 ? 1 - nextMs / baseMs : 0;
      final netSaving = saving - startup / math.max(1, remainingProductiveMs);
      if (count >= 2 && netSaving >= .1) {
        _record['preferredThreads'] = candidate;
        return candidate;
      }
      // A tie must not promote a more expensive configuration.
      if (count >= 2 &&
          candidate < baseline &&
          saving.abs() < .03 &&
          startup < remainingProductiveMs * .01) {
        _record['preferredThreads'] = candidate;
        return candidate;
      }
      return null;
    } finally {
      if (!accounted && !manual) session.tuningTimeSpentMs += reservation;
      _busy = false;
      while (records.length > 96) {
        records.remove(records.keys.first);
      }
      await save();
    }
  }
}
