import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../debug/developer_log.dart' as developer;
import '../models/subtitle_position.dart';

const String kSubtitlePositionOverridesKey = 'subtitlePositionOverrides.v1';

/// Key-value surface used by the position queue. Tests supply a fake that can
/// delay or fail a write; production uses [SharedPreferences].
abstract class SubtitlePositionBackend {
  String? getString(String key);
  double? getDouble(String key);
  Future<bool> setString(String key, String value);
  Future<bool> setDouble(String key, double value);
}

class SharedPreferencesSubtitleBackend implements SubtitlePositionBackend {
  SharedPreferencesSubtitleBackend(this.prefs);

  final SharedPreferences prefs;

  @override
  String? getString(String key) => prefs.getString(key);

  @override
  double? getDouble(String key) => prefs.getDouble(key);

  @override
  Future<bool> setString(String key, String value) =>
      prefs.setString(key, value);

  @override
  Future<bool> setDouble(String key, double value) =>
      prefs.setDouble(key, value);
}

class _PresetSlot {
  Alignment? video;
  Alignment? audio;

  Map<String, dynamic>? toJson() {
    if (video == null && audio == null) return null;
    return <String, dynamic>{
      if (video != null) 'video': {'x': video!.x, 'y': video!.y},
      if (audio != null) 'audio': {'x': audio!.x, 'y': audio!.y},
    };
  }
}

class _Waiter {
  _Waiter(this.revision);
  final int revision;
  final Completer<PositionCommitResult> completer =
      Completer<PositionCommitResult>();
  Future<PositionCommitResult> get future => completer.future;

  void complete(PositionCommitResult result) {
    if (!completer.isCompleted) completer.complete(result);
  }
}

/// Serial merge queue for one storage key.
///
/// A write that has not started is replaced by the latest value. An in-flight
/// write is allowed to finish, then the latest value is written. Waiters
/// complete only when their revision, or a newer one, has actually been
/// persisted. A failed write leaves the lane dirty and does not poison later
/// commits.
class _RevisionLane<T> {
  _RevisionLane(this._write);

  final Future<bool> Function(T value) _write;
  T? _latest;
  int _clock = 0;
  int _dirtyRevision = 0;
  bool _draining = false;
  final List<_Waiter> _waiters = <_Waiter>[];

  int get revision => _clock;
  bool get dirty => _dirtyRevision != 0 || _draining;

  Future<PositionCommitResult> push(T value) {
    _latest = value;
    final int rev = ++_clock;
    _dirtyRevision = rev;
    final _Waiter waiter = _Waiter(rev);
    _waiters.add(waiter);
    _kick();
    return waiter.future;
  }

  Future<PositionCommitResult> flush() {
    if (_dirtyRevision == 0 && !_draining) {
      return Future<PositionCommitResult>.value(
        PositionCommitResult.success(_clock),
      );
    }
    final _Waiter waiter = _Waiter(_clock);
    _waiters.add(waiter);
    if (!_draining) _kick();
    return waiter.future;
  }

  void _kick() {
    if (_draining) return;
    _draining = true;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    var failedStop = false;
    try {
      while (_dirtyRevision != 0 && _latest != null) {
        final int rev = _dirtyRevision;
        final T value = _latest as T;
        _dirtyRevision = 0;
        bool ok = false;
        Object? error;
        try {
          ok = await _write(value);
          if (!ok) error = 'storage write returned false';
        } catch (caught, stack) {
          ok = false;
          error = caught;
          developer.log(
            'Subtitle position persist failed',
            name: 'subtitle_position',
            level: 900,
            error: caught,
            stackTrace: stack,
          );
        }
        if (_dirtyRevision != 0) {
          // A newer value arrived while this write was in flight. Do not
          // complete waiters on the stale payload, and do not let its
          // failure cancel the newer revision.
          continue;
        }
        if (!ok) {
          _dirtyRevision = rev;
          failedStop = true;
          _completeAll(
            PositionCommitResult.failure(revision: rev, message: '$error'),
          );
          break;
        }
        _completeAll(PositionCommitResult.success(rev));
      }
    } finally {
      _draining = false;
      // A commit that landed after the loop condition was checked still
      // needs a drain. A failed lane stays dirty until flush or the next
      // commit calls _kick, so it does not retry forever on its own.
      if (_dirtyRevision != 0 && !failedStop) _kick();
    }
  }

  void _completeAll(PositionCommitResult result) {
    final List<_Waiter> pending = List<_Waiter>.of(_waiters);
    _waiters.clear();
    for (final _Waiter waiter in pending) {
      waiter.complete(result);
    }
  }

  void dispose() {
    _completeAll(
      const PositionCommitResult.failure(
        revision: 0,
        message: 'position store disposed',
      ),
    );
  }
}

/// In-memory preset overrides plus the serial persist lanes.
///
/// Original video, audio and ghost alignments stay on [SettingsService]. This
/// store is the only writer of their queues and of the preset override document.
class SubtitlePositionStore {
  SubtitlePositionStore(this.backend) {
    _videoLane = _RevisionLane<Alignment>(
      (Alignment value) => _writeAlignment(
        jsonKey: 'subtitleAlignmentJson',
        legacyX: 'subtitleAlignX',
        legacyY: 'subtitleAlignY',
        value: value,
      ),
    );
    _audioLane = _RevisionLane<Alignment>(
      (Alignment value) => _writeAlignment(
        jsonKey: 'audioSubtitleAlignmentJson',
        legacyX: 'audioSubtitleAlignX',
        legacyY: 'audioSubtitleAlignY',
        value: value,
      ),
    );
    _ghostLane = _RevisionLane<Alignment>(
      (Alignment value) => _writeAlignment(
        jsonKey: 'ghostModeAlignmentJson',
        legacyX: 'ghostModeAlignX',
        legacyY: 'ghostModeAlignY',
        value: value,
      ),
    );
    _overrideLane = _RevisionLane<String>((String raw) async {
      final bool ok = await backend.setString(
        kSubtitlePositionOverridesKey,
        raw,
      );
      if (ok) _persistedOverrides = raw;
      return ok;
    });
  }

  final SubtitlePositionBackend backend;
  final Map<String, _PresetSlot> _presets = <String, _PresetSlot>{};
  bool overridesBlocked = false;
  String? blockedRaw;
  String? _persistedOverrides;
  String? lastError;

  late final _RevisionLane<Alignment> _videoLane;
  late final _RevisionLane<Alignment> _audioLane;
  late final _RevisionLane<Alignment> _ghostLane;
  late final _RevisionLane<String> _overrideLane;

  Alignment? videoOverride(String id) => _presets[id]?.video;
  Alignment? audioOverride(String id) => _presets[id]?.audio;

  /// Loads overrides. A newer document version is kept byte-for-byte and
  /// further override writes are refused so we cannot clobber it.
  void load() {
    _presets.clear();
    overridesBlocked = false;
    blockedRaw = null;
    final String? raw = backend.getString(kSubtitlePositionOverridesKey);
    _persistedOverrides = raw;
    if (raw == null || raw.isEmpty) return;
    Object? decoded;
    try {
      decoded = json.decode(raw);
    } catch (error) {
      developer.log(
        'Ignoring damaged subtitle position overrides',
        name: 'subtitle_position',
        level: 800,
        error: error,
      );
      return;
    }
    if (decoded is! Map) return;
    final int? version = (decoded['version'] as num?)?.toInt();
    if (version == null || version < 1) return;
    if (version > 1) {
      overridesBlocked = true;
      blockedRaw = raw;
      developer.log(
        'Subtitle position overrides version $version is newer than this build',
        name: 'subtitle_position',
        level: 800,
      );
      return;
    }
    final Object? table = decoded['presetOverrides'];
    if (table is! Map) return;
    table.forEach((key, value) {
      if (key is! String || key.isEmpty || value is! Map) return;
      // A bad axis is dropped. The sibling axis and other presets stay.
      final Alignment? video = value['video'] == null
          ? null
          : _readAxis(value['video']);
      final Alignment? audio = value['audio'] == null
          ? null
          : _readAxis(value['audio']);
      if (video == null && audio == null) return;
      _presets[key] = _PresetSlot()
        ..video = video
        ..audio = audio;
    });
  }

  Alignment? _readAxis(Object? raw) {
    if (raw == null) return null;
    if (raw is! Map) return null;
    final double? x = _finite(raw['x']);
    final double? y = _finite(raw['y']);
    if (x == null || y == null || !x.isFinite || !y.isFinite) return null;
    if (x < -1 || x > 1 || y < -1 || y > 1) return null;
    return Alignment(x, y);
  }

  double? _finite(Object? value) {
    if (value is! num) return null;
    final double number = value.toDouble();
    if (!number.isFinite) return null;
    return number;
  }

  Map<String, dynamic> exportOverrides() {
    return <String, dynamic>{
      'version': 1,
      'presetOverrides': <String, dynamic>{
        for (final MapEntry<String, _PresetSlot> entry in _presets.entries)
          if (entry.value.toJson() != null) entry.key: entry.value.toJson(),
      },
    };
  }

  /// Restores a snapshot export. Unknown version keeps the previous memory.
  bool replaceOverrides(Map<String, dynamic>? json) {
    if (json == null) return false;
    final int? version = (json['version'] as num?)?.toInt();
    if (version == null || version > 1) return false;
    _presets.clear();
    final Object? table = json['presetOverrides'];
    if (table is Map) {
      table.forEach((key, value) {
        if (key is! String || value is! Map) return;
        final Alignment? video = _readAxis(value['video']);
        final Alignment? audio = _readAxis(value['audio']);
        if (video == null && audio == null) return;
        _presets[key] = _PresetSlot()
          ..video = video
          ..audio = audio;
      });
    }
    overridesBlocked = false;
    return true;
  }

  Future<PositionCommitResult> commitAlignment({
    required SubtitlePositionChannel channel,
    required Alignment alignment,
    required Alignment current,
  }) {
    final Alignment next = clampSubtitleAlignment(alignment);
    if (next == current && !_lane(channel).dirty) {
      return Future<PositionCommitResult>.value(
        PositionCommitResult.success(_lane(channel).revision),
      );
    }
    return _lane(channel).push(next);
  }

  _RevisionLane<Alignment> _lane(SubtitlePositionChannel channel) {
    return switch (channel) {
      SubtitlePositionChannel.video => _videoLane,
      SubtitlePositionChannel.audio => _audioLane,
      SubtitlePositionChannel.ghost => _ghostLane,
    };
  }

  Future<PositionCommitResult> commitPreset({
    required String presetId,
    required bool audio,
    required Alignment? alignment,
  }) {
    if (overridesBlocked) {
      lastError = '字幕位置数据版本较新，本次没有覆盖原文件';
      return Future<PositionCommitResult>.value(
        PositionCommitResult.failure(revision: 0, message: lastError!),
      );
    }
    final _PresetSlot slot = _presets.putIfAbsent(presetId, _PresetSlot.new);
    final Alignment? next = alignment == null
        ? null
        : clampSubtitleAlignment(alignment);
    if (audio) {
      if (slot.audio == next && !_overrideLane.dirty) {
        return Future<PositionCommitResult>.value(
          PositionCommitResult.success(_overrideLane.revision),
        );
      }
      slot.audio = next;
    } else {
      if (slot.video == next && !_overrideLane.dirty) {
        return Future<PositionCommitResult>.value(
          PositionCommitResult.success(_overrideLane.revision),
        );
      }
      slot.video = next;
    }
    if (slot.video == null && slot.audio == null) {
      _presets.remove(presetId);
    }
    return _enqueueOverrides();
  }

  Future<PositionCommitResult> clearPreset(String presetId) {
    if (overridesBlocked) {
      lastError = '字幕位置数据版本较新，本次没有覆盖原文件';
      return Future<PositionCommitResult>.value(
        PositionCommitResult.failure(revision: 0, message: lastError!),
      );
    }
    if (!_presets.containsKey(presetId)) {
      return Future<PositionCommitResult>.value(
        PositionCommitResult.success(_overrideLane.revision),
      );
    }
    _presets.remove(presetId);
    return _enqueueOverrides();
  }

  Future<PositionCommitResult> _enqueueOverrides() {
    final String raw = json.encode(exportOverrides());
    if (raw == _persistedOverrides && !_overrideLane.dirty) {
      return Future<PositionCommitResult>.value(
        PositionCommitResult.success(_overrideLane.revision),
      );
    }
    return _overrideLane.push(raw).then((PositionCommitResult result) {
      if (!result.ok) lastError = result.message;
      return result;
    });
  }

  Future<bool> _writeAlignment({
    required String jsonKey,
    required String legacyX,
    required String legacyY,
    required Alignment value,
  }) async {
    final bool jsonOk = await backend.setString(
      jsonKey,
      json.encode(<String, dynamic>{'x': value.x, 'y': value.y}),
    );
    final bool xOk = await backend.setDouble(legacyX, value.x);
    final bool yOk = await backend.setDouble(legacyY, value.y);
    return jsonOk && xOk && yOk;
  }

  Future<PositionCommitResult> flush() async {
    final List<PositionCommitResult> results =
        await Future.wait(<Future<PositionCommitResult>>[
          _videoLane.flush(),
          _audioLane.flush(),
          _ghostLane.flush(),
          _overrideLane.flush(),
        ]);
    for (final PositionCommitResult result in results) {
      if (!result.ok) {
        lastError = result.message;
        return result;
      }
    }
    return results.last;
  }

  void dispose() {
    _videoLane.dispose();
    _audioLane.dispose();
    _ghostLane.dispose();
    _overrideLane.dispose();
  }
}
