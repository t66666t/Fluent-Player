import '../models/ocr_compute_preferences.dart';

class OcrComputePlan {
  const OcrComputePlan({
    required this.preferences,
    required this.capabilities,
    this.device,
    this.note = '',
  });
  final OcrComputePreferences preferences;
  final OcrComputeCapabilities capabilities;
  final OcrComputeDevice? device;
  final String note;
  bool get hardwareFirst =>
      preferences.mode == OcrComputeMode.accelerated && device != null;
  List<String> get allowedProviders => [
    'CPU',
    if (capabilities.providers.contains('XNNPACK')) 'XNNPACK',
    if (device != null) device!.provider,
  ];
  List<OcrComputeDevice> get candidateDevices => device == null
      ? const []
      : preferences.provider != 'auto'
      ? [device!]
      : [
          device!,
          for (final provider in ocrProviderPriority(capabilities.platform))
            for (final d in capabilities.accelerators)
              if (d.provider == provider && d.key != device!.key) d,
        ];
  String get signature =>
      '${preferences.signature}:${device?.key ?? 'cpu'}:${capabilities.isolated}';
}

List<String> ocrProviderPriority(String platform) => switch (platform) {
  'windows' => const [
    'DirectML',
    'CUDA',
    'OpenVINO',
    'Vulkan',
    'OpenCL',
    'TensorRT',
  ],
  'android' => const ['Vulkan', 'OpenCL', 'QNN GPU', 'QNN HTP', 'NNAPI'],
  'macos' || 'ios' => const ['CoreML', 'Metal'],
  _ => const ['CUDA', 'MIGraphX', 'OpenVINO', 'Vulkan', 'OpenCL', 'TensorRT'],
};

OcrComputePlan planOcrCompute(
  OcrComputePreferences preferences,
  OcrComputeCapabilities capabilities,
) {
  OcrComputePlan cpu(String note) => OcrComputePlan(
    preferences: preferences,
    capabilities: capabilities,
    note: note,
  );
  if (preferences.mode == OcrComputeMode.cpu) return cpu('使用 CPU 优化识别');
  final desktop = const [
    'windows',
    'linux',
    'macos',
  ].contains(capabilities.platform);
  // Native Android GPU routes are tested only in the private OCR process.
  if (desktop && !capabilities.isolated) {
    return cpu('当前安装未提供独立加速组件，使用 CPU 优化识别');
  }
  if (!desktop &&
      preferences.mode == OcrComputeMode.automatic &&
      !(capabilities.platform == 'android' &&
          capabilities.isolated &&
          capabilities.accelerators.any(
            (d) => const ['OpenCL', 'Vulkan'].contains(d.provider),
          ))) {
    return cpu('自动使用适合手机的 CPU 优化，兼顾温度与内存');
  }
  final devices = capabilities.accelerators;
  if (devices.isEmpty) {
    return cpu(
      capabilities.note.isEmpty ? '未检测到可用的硬件加速，使用 CPU 优化识别' : capabilities.note,
    );
  }
  OcrComputeDevice? selected;
  if (preferences.provider != 'auto') {
    for (final d in devices) {
      if (d.provider == preferences.provider &&
          (preferences.deviceKey != null
              ? d.key == preferences.deviceKey
              : d.id == preferences.deviceId)) {
        selected = d;
        break;
      }
    }
    if (selected == null) return cpu('之前选择的设备不可用，已回退 CPU；可重新选择设备');
  } else {
    // DirectML covers all three major Windows GPU vendors. CUDA is preferred
    // over the potentially expensive TensorRT compilation on other desktops.
    final priority = ocrProviderPriority(capabilities.platform);
    for (final provider in priority) {
      final matches = devices.where((d) => d.provider == provider).toList()
        ..sort((a, b) => b.dedicatedBytes.compareTo(a.dedicatedBytes));
      if (matches.isNotEmpty) {
        selected = matches.first;
        break;
      }
    }
  }
  if (selected == null) return cpu('当前设备使用 CPU 优化识别');
  return OcrComputePlan(
    preferences: preferences,
    capabilities: capabilities,
    device: selected,
    note: preferences.mode == OcrComputeMode.automatic
        ? '先使用 CPU；识别过程中只采用校验通过且更快的加速方式'
        : '优先使用 ${selected.name}，不兼容时自动回退 CPU',
  );
}
