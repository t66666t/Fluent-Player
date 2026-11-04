import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'device_resource_snapshot.dart';

abstract class ResourcePlatformProbe {
  Stream<Map<dynamic, dynamic>> get urgent => const Stream.empty();
  Future<void> start() async {}
  Future<DeviceResourceSnapshot> read(List<int> workerPids);
  Future<void> close() async {}
  static ResourcePlatformProbe create() => Platform.isWindows
      ? WindowsResourceProbe()
      : Platform.isLinux
      ? LinuxResourceProbe()
      : NativeResourceProbe();
}

class NativeResourceProbe extends ResourcePlatformProbe {
  bool _started = false;
  static const channel = MethodChannel(
    'com.example.video_player_app/model_resources',
  );
  static const events = EventChannel(
    'com.example.video_player_app/model_resources/events',
  );
  @override
  Stream<Map<dynamic, dynamic>> get urgent => !_started
      ? const Stream.empty()
      : events
            .receiveBroadcastStream()
            .where((e) => e is Map)
            .cast<Map<dynamic, dynamic>>();
  @override
  Future<void> start() async {
    try {
      await channel.invokeMethod<void>('start');
      _started = true;
    } on MissingPluginException {
      /* Older host. */
    }
  }

  @override
  Future<DeviceResourceSnapshot> read(List<int> workerPids) async {
    final result = await channel.invokeMapMethod<String, dynamic>('snapshot', {
      'pids': workerPids,
    });
    return DeviceResourceSnapshot.fromMap(
      result ?? const {},
      platform: Platform.operatingSystem,
      processors: Platform.numberOfProcessors,
    );
  }

  @override
  Future<void> close() async {
    try {
      if (_started) await channel.invokeMethod<void>('stop');
      _started = false;
    } on MissingPluginException {
      /* Older host. */
    }
  }
}

int countCpuList(String text) => _cpuIds(text).length;

int countProcessorMask(int mask, {int bits = 64}) {
  var count = 0;
  for (var bit = 0; bit < bits; bit++) {
    if (((mask >> bit) & 1) != 0) count++;
  }
  return count;
}

Set<int> _cpuIds(String text) {
  final ids = <int>{};
  for (final part in text.trim().split(',')) {
    final range = part.split('-').map(int.tryParse).toList();
    if (range.isEmpty || range.length > 2 || range.any((n) => n == null)) {
      continue;
    }
    final first = range.first!, last = range.length == 1 ? first : range.last!;
    if (first < 0 || last < first || last - first > 65536) continue;
    for (var id = first; id <= last; id++) {
      ids.add(id);
    }
  }
  return ids;
}

int? cpuQuota(String text) {
  final values = text.trim().split(RegExp(r'\s+'));
  if (values.length != 2 || values.first == 'max') return null;
  final quota = int.tryParse(values.first), period = int.tryParse(values.last);
  return quota != null && quota > 0 && period != null && period > 0
      ? math.max(1, (quota / period).ceil())
      : null;
}

class LinuxResourceProbe extends ResourcePlatformProbe {
  LinuxResourceProbe({
    this.procRoot = '/proc',
    this.cgroupRoot = '/sys/fs/cgroup',
  });
  final String procRoot, cgroupRoot;
  int? _physical;
  static Future<String?> _text(String path) async {
    try {
      return await File(path).readAsString();
    } on FileSystemException {
      return null;
    }
  }

  static int? _kb(String text, String key) {
    final value = RegExp(
      '^$key:\\s+(\\d+)\\s+kB',
      multiLine: true,
    ).firstMatch(text);
    return value == null ? null : int.parse(value[1]!) * 1024;
  }

  @override
  Future<DeviceResourceSnapshot> read(List<int> workerPids) async {
    final values = await Future.wait([
      _text('$procRoot/meminfo'),
      _text('$procRoot/self/status'),
      _text('$procRoot/self/cgroup'),
      _text('$procRoot/cpuinfo'),
    ]);
    final memory = values[0] ?? '',
        status = values[1] ?? '',
        groups = values[2] ?? '';
    final affinityLine = RegExp(
      r'^Cpus_allowed_list:\s*(.+)$',
      multiLine: true,
    ).firstMatch(status);
    final affinityIds = affinityLine == null ? null : _cpuIds(affinityLine[1]!);
    final topology = <String>{};
    for (final block in (values[3] ?? '').split('\n\n')) {
      final processor = RegExp(
        r'^processor\s*:\s*(\d+)',
        multiLine: true,
      ).firstMatch(block);
      if (affinityIds != null &&
          processor != null &&
          !affinityIds.contains(int.parse(processor[1]!))) {
        continue;
      }
      final physical = RegExp(
        r'^physical id\s*:\s*(\d+)',
        multiLine: true,
      ).firstMatch(block);
      final core = RegExp(
        r'^core id\s*:\s*(\d+)',
        multiLine: true,
      ).firstMatch(block);
      if (physical != null && core != null) {
        topology.add('${physical[1]}:${core[1]}');
      }
    }
    if (topology.isNotEmpty) _physical = topology.length;
    final allowed = RegExp(
      r'^Cpus_allowed_list:\s*(.+)$',
      multiLine: true,
    ).firstMatch(status);
    var cpus = allowed == null ? null : countCpuList(allowed[1]!);
    int? available = _kb(memory, 'MemAvailable'),
        total = _kb(memory, 'MemTotal');
    var pressure = ResourceMemoryPressure.normal;
    final v2 = RegExp(r'^0::(.*)$', multiLine: true).firstMatch(groups);
    if (v2 != null) {
      // cgroup namespaces may expose the current group at their mount root.
      final relative = p.posix
          .normalize(v2[1]!)
          .replaceFirst(RegExp(r'^/+'), '');
      final candidates = <String>{cgroupRoot};
      if (!relative.startsWith('..')) {
        var directory = p.join(cgroupRoot, relative);
        while (p.isWithin(cgroupRoot, directory)) {
          candidates.add(directory);
          directory = p.dirname(directory);
        }
      }
      for (final directory in candidates) {
        final limits = await Future.wait(
          [
            'cpu.max',
            'memory.max',
            'memory.current',
            'memory.pressure',
          ].map((name) => _text(p.join(directory, name))),
        );
        final quota = limits[0] == null ? null : cpuQuota(limits[0]!);
        if (quota != null) cpus = cpus == null ? quota : math.min(cpus, quota);
        final limit = int.tryParse((limits[1] ?? '').trim()),
            used = int.tryParse((limits[2] ?? '').trim());
        if (limit != null && limit > 0 && used != null) {
          final free = math.max(0, limit - used);
          available = available == null ? free : math.min(available, free);
          total = total == null ? limit : math.min(total, limit);
        }
        final stalled = RegExp(
          r'^full avg10=([\d.]+)',
          multiLine: true,
        ).firstMatch(limits[3] ?? '');
        if ((double.tryParse(stalled?[1] ?? '') ?? 0) > 10) {
          pressure = ResourceMemoryPressure.warning;
        }
      }
    } else {
      for (final line in groups.split('\n')) {
        final bits = line.split(':');
        if (bits.length != 3) continue;
        final relative = p.posix
            .normalize(bits[2])
            .replaceFirst(RegExp(r'^/+'), '');
        if (relative.startsWith('..')) continue;
        if (bits[1].split(',').contains('cpu')) {
          final dirs = [
            p.join(cgroupRoot, 'cpu', relative),
            p.join(cgroupRoot, 'cpu,cpuacct', relative),
          ];
          for (final dir in dirs) {
            final quota = await _text(p.join(dir, 'cpu.cfs_quota_us'));
            final period = await _text(p.join(dir, 'cpu.cfs_period_us'));
            final n = cpuQuota('${quota?.trim()} ${period?.trim()}');
            if (n != null) cpus = cpus == null ? n : math.min(cpus, n);
          }
        }
        if (bits[1].split(',').contains('memory')) {
          final dir = p.join(cgroupRoot, 'memory', relative);
          final limit = int.tryParse(
            (await _text(p.join(dir, 'memory.limit_in_bytes')) ?? '').trim(),
          );
          final used = int.tryParse(
            (await _text(p.join(dir, 'memory.usage_in_bytes')) ?? '').trim(),
          );
          if (limit != null && limit > 0 && used != null && limit < (1 << 60)) {
            final free = math.max(0, limit - used);
            available = available == null ? free : math.min(available, free);
            total = total == null ? limit : math.min(total, limit);
          }
        }
      }
    }
    if (available != null && available < 128 * 1024 * 1024) {
      pressure = ResourceMemoryPressure.critical;
    }
    var workers = 0, complete = true;
    for (final pid in workerPids) {
      final child = await _text('$procRoot/$pid/status');
      final bytes = child == null ? null : _kb(child, 'VmRSS');
      if (bytes == null) {
        complete = false;
      } else {
        workers += bytes;
      }
    }
    return DeviceResourceSnapshot(
      platform: 'linux',
      processors: Platform.numberOfProcessors,
      physicalProcessors: _physical,
      allowedProcessors: cpus == 0 ? null : cpus,
      capturedAt: DateTime.now(),
      memoryBytes: total,
      availableMemoryBytes: available,
      memoryScope: MemoryAvailabilityScope.system,
      processBytes: _kb(status, 'VmRSS'),
      workerBytes: workers,
      workerMemoryComplete: complete,
      memoryPressure: pressure,
      environment: Platform.operatingSystemVersion,
    );
  }
}

final class _MemoryStatus extends Struct {
  @Uint32()
  external int length;
  @Uint32()
  external int load;
  @Uint64()
  external int total;
  @Uint64()
  external int available;
  @Uint64()
  external int pageFile;
  @Uint64()
  external int availablePageFile;
  @Uint64()
  external int virtual;
  @Uint64()
  external int availableVirtual;
  @Uint64()
  external int extended;
}

final class _ProcessMemory extends Struct {
  @Uint32()
  external int size;
  @Uint32()
  external int faults;
  @UintPtr()
  external int peak;
  @UintPtr()
  external int working;
  @UintPtr()
  external int peakPaged;
  @UintPtr()
  external int paged;
  @UintPtr()
  external int peakNonPaged;
  @UintPtr()
  external int nonPaged;
  @UintPtr()
  external int pageFile;
  @UintPtr()
  external int peakPageFile;
  @UintPtr()
  external int privateUsage;
}

class WindowsResourceProbe extends ResourcePlatformProbe {
  final _kernel = DynamicLibrary.open('kernel32.dll');
  final _psapi = DynamicLibrary.open('psapi.dll');
  Pointer<Void>? _lowMemory;
  Timer? _pressureTimer;
  bool _low = false;
  int? _physical, _physicalAffinity;
  final _events = StreamController<Map<dynamic, dynamic>>.broadcast();
  @override
  Stream<Map<dynamic, dynamic>> get urgent => _events.stream;
  @override
  Future<void> start() async {
    _lowMemory = _kernel
        .lookupFunction<
          Pointer<Void> Function(Int32),
          Pointer<Void> Function(int)
        >('CreateMemoryResourceNotification')(0);
    _pressureTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_isLow() && !_low) {
        _low = true;
        _events.add({'memoryPressure': 'critical'});
      } else if (!_isLow()) {
        _low = false;
      }
    });
  }

  bool _isLow() {
    if (_lowMemory == null || _lowMemory == nullptr) return false;
    final flag = calloc<Int32>();
    try {
      final ok = _kernel
          .lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Int32>),
            int Function(Pointer<Void>, Pointer<Int32>)
          >('QueryMemoryResourceNotification')(_lowMemory!, flag);
      return ok != 0 && flag.value != 0;
    } finally {
      calloc.free(flag);
    }
  }

  int? _resident(Pointer<Void> handle) {
    final data = calloc<_ProcessMemory>();
    try {
      data.ref.size = sizeOf<_ProcessMemory>();
      final ok = _psapi
          .lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<_ProcessMemory>, Uint32),
            int Function(Pointer<Void>, Pointer<_ProcessMemory>, int)
          >('GetProcessMemoryInfo')(handle, data, data.ref.size);
      return ok == 0 ? null : data.ref.working;
    } finally {
      calloc.free(data);
    }
  }

  @override
  Future<DeviceResourceSnapshot> read(List<int> workerPids) async {
    final data = calloc<_MemoryStatus>();
    final current = _kernel
        .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
          'GetCurrentProcess',
        )();
    int? memory, available, allowed, affinity;
    try {
      data.ref.length = sizeOf<_MemoryStatus>();
      final ok = _kernel
          .lookupFunction<
            Int32 Function(Pointer<_MemoryStatus>),
            int Function(Pointer<_MemoryStatus>)
          >('GlobalMemoryStatusEx')(data);
      if (ok != 0) {
        memory = data.ref.total;
        available = data.ref.available;
      }
    } finally {
      calloc.free(data);
    }
    final mask = calloc<UintPtr>(), system = calloc<UintPtr>();
    try {
      final ok = _kernel
          .lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<UintPtr>, Pointer<UintPtr>),
            int Function(Pointer<Void>, Pointer<UintPtr>, Pointer<UintPtr>)
          >('GetProcessAffinityMask')(current, mask, system);
      if (ok != 0) {
        affinity = mask.value;
        allowed = countProcessorMask(affinity, bits: sizeOf<UintPtr>() * 8);
      }
    } finally {
      calloc.free(mask);
      calloc.free(system);
    }
    if (_physical == null || _physicalAffinity != affinity) {
      final bytes = calloc<Uint32>();
      try {
        final get = _kernel
            .lookupFunction<
              Int32 Function(Int32, Pointer<Uint8>, Pointer<Uint32>),
              int Function(int, Pointer<Uint8>, Pointer<Uint32>)
            >('GetLogicalProcessorInformationEx');
        get(0, nullptr, bytes);
        if (bytes.value > 0 && bytes.value < 16 * 1024 * 1024) {
          final buffer = calloc<Uint8>(bytes.value);
          try {
            if (get(0, buffer, bytes) != 0) {
              var count = 0;
              for (var at = 0; at + 8 <= bytes.value;) {
                final length = (buffer + at + 4).cast<Uint32>().value;
                if (length < 8 || at + length > bytes.value) break;
                var intersects = affinity == null;
                final groups = length >= 32
                    ? (buffer + at + 30).cast<Uint16>().value
                    : 0;
                final stride = sizeOf<UintPtr>() == 8 ? 16 : 12;
                for (
                  var g = 0;
                  g < groups && 32 + (g + 1) * stride <= length;
                  g++
                ) {
                  final bits = (buffer + at + 32 + g * stride)
                      .cast<UintPtr>()
                      .value;
                  if (affinity == null || (bits & affinity) != 0) {
                    intersects = true;
                  }
                }
                if (intersects || groups == 0) count++;
                at += length;
              }
              if (count > 0) {
                _physical = count;
                _physicalAffinity = affinity;
              }
            }
          } finally {
            calloc.free(buffer);
          }
        }
      } finally {
        calloc.free(bytes);
      }
    }
    var workers = 0, complete = true;
    for (final pid in workerPids) {
      final child = _kernel
          .lookupFunction<
            Pointer<Void> Function(Uint32, Int32, Uint32),
            Pointer<Void> Function(int, int, int)
          >('OpenProcess')(0x410, 0, pid);
      if (child == nullptr) {
        complete = false;
        continue;
      }
      try {
        final value = _resident(child);
        if (value == null) {
          complete = false;
        } else {
          workers += value;
        }
      } finally {
        _close(child);
      }
    }
    final power = calloc<Uint8>(12);
    var saving = false;
    try {
      final ok = _kernel
          .lookupFunction<
            Int32 Function(Pointer<Uint8>),
            int Function(Pointer<Uint8>)
          >('GetSystemPowerStatus')(power);
      if (ok != 0) saving = power[3] == 1;
    } finally {
      calloc.free(power);
    }
    return DeviceResourceSnapshot(
      platform: 'windows',
      processors: Platform.numberOfProcessors,
      capturedAt: DateTime.now(),
      physicalProcessors: _physical,
      allowedProcessors: allowed == 0 ? null : allowed,
      memoryBytes: memory,
      availableMemoryBytes: available,
      memoryScope: MemoryAvailabilityScope.system,
      processBytes: _resident(current),
      workerBytes: workers,
      workerMemoryComplete: complete,
      powerSaving: saving,
      memoryPressure: _isLow()
          ? ResourceMemoryPressure.critical
          : ResourceMemoryPressure.normal,
      environment: Platform.operatingSystemVersion,
    );
  }

  void _close(Pointer<Void> handle) =>
      _kernel.lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CloseHandle')(handle);
  @override
  Future<void> close() async {
    _pressureTimer?.cancel();
    if (_lowMemory != null && _lowMemory != nullptr) _close(_lowMemory!);
    _lowMemory = null;
    await _events.close();
  }
}
