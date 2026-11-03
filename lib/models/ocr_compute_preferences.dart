enum OcrComputeMode { automatic, cpu, accelerated }

const ocrProviderNames = <String>{
  'CPU',
  'XNNPACK',
  'DirectML',
  'CUDA',
  'TensorRT',
  'CoreML',
  'NNAPI',
  'OpenVINO',
  'MIGraphX',
  'Vulkan',
  'OpenCL',
  'Metal',
  'QNN GPU',
  'QNN HTP',
};

/// A job captures this value once. Changing the next job's preference never
/// recreates sessions in an in-flight native call or changes model identities.
class OcrComputePreferences {
  const OcrComputePreferences({
    this.mode = OcrComputeMode.automatic,
    this.provider = 'auto',
    this.deviceId = 0,
    this.deviceKey,
    this.coreMLUnits = 'ALL',
  });
  final OcrComputeMode mode;
  final String provider;
  final int deviceId;
  final String? deviceKey;
  final String coreMLUnits;

  bool get isDefault =>
      mode == OcrComputeMode.automatic &&
      provider == 'auto' &&
      deviceId == 0 &&
      deviceKey == null &&
      coreMLUnits == 'ALL';
  String get label => switch (mode) {
    OcrComputeMode.automatic => '自动',
    OcrComputeMode.cpu => 'CPU',
    OcrComputeMode.accelerated => '硬件加速优先',
  };
  String get signature =>
      '${mode.name}:$provider:$deviceId:${deviceKey ?? ''}:$coreMLUnits';

  OcrComputePreferences copyWith({
    OcrComputeMode? mode,
    String? provider,
    int? deviceId,
    String? deviceKey,
    bool clearDevice = false,
    String? coreMLUnits,
  }) => OcrComputePreferences(
    mode: mode ?? this.mode,
    provider: provider ?? this.provider,
    deviceId: deviceId ?? this.deviceId,
    deviceKey: clearDevice ? null : deviceKey ?? this.deviceKey,
    coreMLUnits: coreMLUnits ?? this.coreMLUnits,
  );

  Map<String, Object?> toJson() => {
    'mode': mode.name,
    'provider': provider,
    'deviceId': deviceId,
    if (deviceKey != null) 'deviceKey': deviceKey,
    'coreMLUnits': coreMLUnits,
  };

  factory OcrComputePreferences.fromJson(Object? raw) {
    if (raw is! Map) return const OcrComputePreferences();
    final modes = OcrComputeMode.values.where(
      (value) => value.name == raw['mode'],
    );
    final mode = modes.isEmpty ? OcrComputeMode.automatic : modes.first;
    final provider = raw['provider'];
    final id = raw['deviceId'];
    final key = raw['deviceKey'];
    final units = raw['coreMLUnits'];
    return OcrComputePreferences(
      mode: mode,
      provider: provider is String && ocrProviderNames.contains(provider)
          ? provider
          : 'auto',
      deviceId: id is int && id >= 0 && id < 128 ? id : 0,
      deviceKey: key is String && key.isNotEmpty && key.length <= 512
          ? key
          : null,
      coreMLUnits:
          const ['ALL', 'CPUAndGPU', 'CPUAndNeuralEngine'].contains(units)
          ? units as String
          : 'ALL',
    );
  }
}

class OcrComputeDevice {
  const OcrComputeDevice({
    required this.provider,
    required this.id,
    required this.key,
    required this.name,
    this.dedicatedBytes = 0,
    this.availableBytes,
    this.software = false,
  });
  final String provider, key, name;
  final int id, dedicatedBytes;
  final int? availableBytes;
  final bool software;
  Map<String, Object?> toJson() => {
    'provider': provider,
    'id': id,
    'key': key,
    'name': name,
    'dedicatedBytes': dedicatedBytes,
    'availableBytes': availableBytes,
    'software': software,
  };
  factory OcrComputeDevice.fromJson(Map<String, dynamic> json) =>
      OcrComputeDevice(
        provider: json['provider'] as String,
        id: json['id'] as int,
        key: json['key'] as String,
        name: json['name'] as String,
        dedicatedBytes: json['dedicatedBytes'] as int? ?? 0,
        availableBytes: json['availableBytes'] as int?,
        software: json['software'] == true,
      );
}

class OcrComputeCapabilities {
  const OcrComputeCapabilities({
    required this.platform,
    this.providers = const ['CPU'],
    this.devices = const [],
    this.isolated = false,
    this.note = '',
  });
  final String platform;
  final List<String> providers;
  final List<OcrComputeDevice> devices;
  final bool isolated;
  final String note;
  List<OcrComputeDevice> get accelerators {
    final seen = <String>{};
    return devices
        .where(
          (d) =>
              !d.software &&
              d.provider != 'CPU' &&
              d.provider != 'XNNPACK' &&
              providers.contains(d.provider) &&
              seen.add(d.key),
        )
        .toList();
  }

  Map<String, Object?> toJson() => {
    'platform': platform,
    'providers': providers,
    'devices': devices.map((d) => d.toJson()).toList(),
    'isolated': isolated,
    'note': note,
  };
  factory OcrComputeCapabilities.fromJson(Map<String, dynamic> json) =>
      OcrComputeCapabilities(
        platform: json['platform'] as String,
        providers: List<String>.from(json['providers'] as List),
        devices: (json['devices'] as List)
            .map(
              (d) => OcrComputeDevice.fromJson(
                Map<String, dynamic>.from(d as Map),
              ),
            )
            .toList(),
        isolated: json['isolated'] == true,
        note: json['note'] as String? ?? '',
      );
}
