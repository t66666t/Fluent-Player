import 'dart:math' as math;

enum ResourceThermalState { unknown, normal, warm, moderate, severe }

enum ResourceMemoryPressure { unknown, normal, warning, critical }

enum MemoryAvailabilityScope { system, application, estimate, unknown }

/// Available bytes mean *additional* allocations, not installed RAM. In
/// particular iOS application headroom is not interchangeable with free RAM.
class DeviceResourceSnapshot {
  const DeviceResourceSnapshot({
    required this.platform,
    required this.processors,
    required this.capturedAt,
    this.physicalProcessors,
    this.allowedProcessors,
    this.memoryBytes,
    this.availableMemoryBytes,
    this.memoryScope = MemoryAvailabilityScope.unknown,
    this.processBytes,
    this.workerBytes = 0,
    this.workerMemoryComplete = true,
    this.thermal = ResourceThermalState.unknown,
    this.thermalSupported = false,
    this.memoryPressure = ResourceMemoryPressure.unknown,
    this.powerSaving = false,
    this.foreground = true,
    this.playing = false,
    this.interacting = false,
    this.slowFrameFraction = 0,
    this.frameCount = 0,
    this.frameWindow = 0,
    this.environment = '',
  });
  final String platform, environment;
  final int processors, workerBytes, frameCount, frameWindow;
  final int? physicalProcessors,
      allowedProcessors,
      memoryBytes,
      availableMemoryBytes,
      processBytes;
  final MemoryAvailabilityScope memoryScope;
  final ResourceThermalState thermal;
  final ResourceMemoryPressure memoryPressure;
  final bool thermalSupported,
      workerMemoryComplete,
      powerSaving,
      foreground,
      playing,
      interacting;
  final double slowFrameFraction;
  final DateTime capturedAt;
  bool get mobile => platform == 'android' || platform == 'ios';
  int get effectiveProcessors => math.max(
    1,
    [processors, ?physicalProcessors, ?allowedProcessors].reduce(math.min),
  );
  bool fresh(DateTime now) =>
      !now.isBefore(capturedAt) &&
      now.difference(capturedAt) <= const Duration(seconds: 8);
  bool get memoryKnown =>
      availableMemoryBytes != null && memoryBytes != null && memoryBytes! > 0;

  DeviceResourceSnapshot experience({
    required bool foreground,
    required bool playing,
    bool interacting = false,
    required double slowFrameFraction,
    required int frameCount,
    required int frameWindow,
    ResourceMemoryPressure? pressure,
  }) => DeviceResourceSnapshot(
    platform: platform,
    processors: processors,
    capturedAt: capturedAt,
    physicalProcessors: physicalProcessors,
    allowedProcessors: allowedProcessors,
    memoryBytes: memoryBytes,
    availableMemoryBytes: availableMemoryBytes,
    memoryScope: memoryScope,
    processBytes: processBytes,
    workerBytes: workerBytes,
    workerMemoryComplete: workerMemoryComplete,
    thermal: thermal,
    thermalSupported: thermalSupported,
    memoryPressure: pressure ?? memoryPressure,
    powerSaving: powerSaving,
    foreground: foreground,
    playing: playing,
    interacting: interacting,
    slowFrameFraction: slowFrameFraction,
    frameCount: frameCount,
    frameWindow: frameWindow,
    environment: environment,
  );

  factory DeviceResourceSnapshot.fromMap(
    Map<dynamic, dynamic> map, {
    required String platform,
    required int processors,
    DateTime? now,
  }) {
    int? number(String key) {
      final value = map[key];
      return value is num && value.isFinite && value >= 0
          ? value.toInt()
          : null;
    }

    T named<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.where((v) => v.name == name).firstOrNull ?? fallback;
    return DeviceResourceSnapshot(
      platform: platform,
      capturedAt: now ?? DateTime.now(),
      processors: (number('processors') ?? processors).clamp(1, 65536),
      physicalProcessors: number('physicalProcessors'),
      allowedProcessors: number('allowedProcessors'),
      memoryBytes: number('memoryBytes'),
      availableMemoryBytes: number('availableMemoryBytes'),
      processBytes: number('processBytes'),
      workerBytes: number('workerBytes') ?? 0,
      workerMemoryComplete: map['workerMemoryComplete'] != false,
      memoryScope: named(
        MemoryAvailabilityScope.values,
        map['memoryScope'],
        MemoryAvailabilityScope.unknown,
      ),
      thermal: named(
        ResourceThermalState.values,
        map['thermal'],
        ResourceThermalState.unknown,
      ),
      thermalSupported: map['thermalSupported'] == true,
      memoryPressure: named(
        ResourceMemoryPressure.values,
        map['memoryPressure'],
        ResourceMemoryPressure.unknown,
      ),
      powerSaving: map['powerSaving'] == true,
      environment: map['environment'] is String
          ? map['environment'] as String
          : '',
    );
  }
}
