import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/ocr_compute_preferences.dart';
import 'ocr_device_probe.dart';
import 'ocr_process_worker.dart';
import 'ocr_android_worker.dart';

class OcrComputeService {
  OcrComputeService({this.workerExecutable});
  final String? workerExecutable;
  static const preferencesKey = 'ocrComputePreferencesV1';
  static const _failuresKey = 'ocrComputeFailuresV1';
  OcrComputeCapabilities? _cached;
  Future<OcrComputeCapabilities>? _pending;
  final _failures = <String, String>{};

  String? get executable =>
      workerExecutable ?? ProcessOcrWorker.bundledExecutable();
  Future<OcrComputePreferences> loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final failures = jsonDecode(prefs.getString(_failuresKey) ?? '{}');
      if (failures is Map) {
        for (final entry in failures.entries) {
          final when = DateTime.tryParse(entry.value.toString());
          if (when != null && DateTime.now().difference(when).inDays < 14) {
            _failures[entry.key.toString()] = when.toUtc().toIso8601String();
          }
        }
      }
    } catch (_) {
      /* Corrupt optional history never blocks OCR. */
    }
    try {
      return OcrComputePreferences.fromJson(
        jsonDecode(prefs.getString(preferencesKey) ?? '{}'),
      );
    } catch (_) {
      return const OcrComputePreferences();
    }
  }

  Future<void> savePreferences(OcrComputePreferences value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(preferencesKey, jsonEncode(value.toJson()));
  }

  String _failureKey(String model, String device, String units) =>
      '$model|$device|$units';
  bool failed(String model, String device, String units) =>
      _failures.containsKey(_failureKey(model, device, units));
  Future<void> markFailed(String model, String device, String units) async {
    _failures[_failureKey(model, device, units)] = DateTime.now()
        .toUtc()
        .toIso8601String();
    while (_failures.length > 64) {
      _failures.remove(_failures.keys.first);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_failuresKey, jsonEncode(_failures));
  }

  Future<OcrComputeCapabilities> capabilities({bool refresh = false}) async {
    if (_pending != null) return _pending!;
    if (!refresh && _cached != null) return _cached!;
    if (refresh) {
      _failures.clear();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_failuresKey);
    }
    final pending = _probe();
    _pending = pending;
    try {
      return _cached = await pending;
    } finally {
      _pending = null;
    }
  }

  Future<void> waitForDetection() async {
    final pending = _pending;
    if (pending != null) await pending;
  }

  Future<OcrComputeCapabilities> _probe() async {
    try {
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        final path = executable;
        if (path != null) return await ProcessOcrWorker.probe(path);
        return OcrComputeCapabilities(
          platform: Platform.operatingSystem,
          note: '当前安装使用 CPU 兼容模式',
        );
      }
      if (Platform.isAndroid) return await AndroidOcrWorker.probe();
      return await Isolate.run(() => probeOcrDevices());
    } catch (_) {
      return OcrComputeCapabilities(
        platform: Platform.operatingSystem,
        note: '加速设备检测未完成，CPU 识别仍可使用',
      );
    }
  }
}
