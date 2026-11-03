import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:convert';

import 'package:ffi/ffi.dart';
import 'package:crypto/crypto.dart';

import '../models/ocr_compute_preferences.dart';
import 'ocr_inference_engine.dart';
import 'ocr_native_accelerator.dart';

/// Desktop callers invoke this inside the OCR helper, never in the player.
/// A missing driver or an unavailable optional EP yields a CPU-only result.
OcrComputeCapabilities probeOcrDevices({
  bool isolated = false,
  bool probeMobileHardware = true,
  bool probeNativeHardware = true,
  String? onlyProvider,
}) {
  final providers = OcrInferenceEngine.availableBackends();
  final devices = <OcrComputeDevice>[];
  final runtime = OcrNativeAccelerator.instance;
  final mobileTag = Platform.isAndroid ? _androidOcrDeviceTag() : '';
  if (probeNativeHardware &&
      runtime != null &&
      (probeMobileHardware || !Platform.isAndroid)) {
    final candidates = Platform.isAndroid
        ? const ['OpenCL', 'Vulkan', 'QNN GPU', 'QNN HTP']
        : Platform.isIOS || Platform.isMacOS
        ? const ['Metal']
        : const ['Vulkan', 'OpenCL'];
    for (final provider in candidates) {
      if (onlyProvider != null && onlyProvider != provider) continue;
      try {
        if (runtime.probe(provider)) {
          final info = runtime.deviceInfo(provider);
          devices.add(
            OcrComputeDevice(
              provider: provider,
              id: 0,
              key:
                  '$provider:system:${runtime.version}:'
                  '${sha256.convert(utf8.encode('$mobileTag:$info'))}',
              name: switch (provider) {
                'QNN HTP' => '高通神经网络引擎',
                'QNN GPU' => '高通 Adreno 图形处理器',
                'Metal' => 'Apple 图形处理器',
                _ => info.isEmpty ? '图形处理器（系统选择）' : info.split('\n').first,
              },
            ),
          );
        }
      } catch (_) {
        // One broken vendor API must not hide the other routes.
      }
    }
  }
  if ((onlyProvider == null || onlyProvider == 'DirectML') &&
      Platform.isWindows &&
      providers.contains('DirectML')) {
    try {
      devices.addAll(_directMlDevices());
    } catch (_) {
      /* CPU stays available. */
    }
  }
  if ((onlyProvider == null ||
          onlyProvider == 'CUDA' ||
          onlyProvider == 'TensorRT') &&
      providers.any((p) => p == 'CUDA' || p == 'TensorRT')) {
    try {
      devices.addAll(_cudaDevices(providers));
    } catch (_) {
      /* No usable CUDA driver. */
    }
  }
  if ((onlyProvider == null || onlyProvider == 'MIGraphX') &&
      Platform.isLinux &&
      providers.contains('MIGraphX')) {
    try {
      devices.addAll(_hipDevices());
    } catch (_) {
      /* Optional AMD runtime. */
    }
  }
  if ((onlyProvider == null || onlyProvider == 'OpenVINO') &&
      providers.contains('OpenVINO')) {
    if (_hasOpenVinoGpu()) {
      devices.add(
        const OcrComputeDevice(
          provider: 'OpenVINO',
          id: 0,
          key: 'OpenVINO:GPU',
          name: 'Intel 图形设备（系统选择）',
        ),
      );
    }
  }
  if ((onlyProvider == null || onlyProvider == 'CoreML') &&
      (Platform.isIOS || Platform.isMacOS) &&
      providers.contains('CoreML')) {
    devices.add(
      const OcrComputeDevice(
        provider: 'CoreML',
        id: 0,
        key: 'CoreML:system',
        name: '系统图形与神经网络引擎',
      ),
    );
  }
  if ((onlyProvider == null || onlyProvider == 'NNAPI') &&
      Platform.isAndroid &&
      probeMobileHardware &&
      providers.contains('NNAPI')) {
    try {
      if (_hasNnapiHardware()) {
        devices.add(
          const OcrComputeDevice(
            provider: 'NNAPI',
            id: 0,
            key: 'NNAPI:system',
            name: '手机硬件加速（系统选择）',
          ),
        );
      }
    } catch (_) {
      /* Deprecated/absent NNAPI must not prevent OCR. */
    }
  }
  return OcrComputeCapabilities(
    platform: Platform.operatingSystem,
    providers: providers,
    devices: devices,
    isolated: isolated,
    note: Platform.isAndroid && runtime == null
        ? '当前安装缺少通用 GPU 组件；仍可使用 CPU 或设备提供的 NNAPI'
        : '',
  );
}

String _androidOcrDeviceTag() {
  try {
    final get = DynamicLibrary.open('libc.so')
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
          int Function(Pointer<Utf8>, Pointer<Utf8>)
        >('__system_property_get');
    final buffer = calloc<Uint8>(256);
    try {
      final values = <String>[];
      for (final property in const [
        'ro.soc.model',
        'ro.hardware',
        'ro.product.device',
        'ro.build.version.incremental',
      ]) {
        final name = property.toNativeUtf8();
        try {
          final length = get(name, buffer.cast());
          values.add(
            length > 0 && length < 256
                ? buffer.cast<Utf8>().toDartString(length: length)
                : '',
          );
        } finally {
          calloc.free(name);
        }
      }
      return values.join(':');
    } finally {
      calloc.free(buffer);
    }
  } catch (_) {
    return 'android';
  }
}

final class _OpenVinoDevices extends Struct {
  external Pointer<Pointer<Char>> names;
  @Size()
  external int size;
}

bool _hasOpenVinoGpu() {
  try {
    final library = DynamicLibrary.open(
      Platform.isWindows ? 'openvino_c.dll' : 'libopenvino_c.so',
    );
    final core = calloc<Pointer<Void>>(), devices = calloc<_OpenVinoDevices>();
    var listed = false;
    try {
      if (library.lookupFunction<
            Int32 Function(Pointer<Pointer<Void>>),
            int Function(Pointer<Pointer<Void>>)
          >('ov_core_create')(core) !=
          0) {
        return false;
      }
      if (library.lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<_OpenVinoDevices>),
            int Function(Pointer<Void>, Pointer<_OpenVinoDevices>)
          >('ov_core_get_available_devices')(core.value, devices) !=
          0) {
        return false;
      }
      listed = true;
      if (devices.ref.size < 0 || devices.ref.size > 128) return false;
      return List.generate(
        devices.ref.size,
        (i) => devices.ref.names[i].cast<Utf8>().toDartString(),
      ).any((name) => name == 'GPU' || name.startsWith('GPU.'));
    } finally {
      if (listed) {
        library.lookupFunction<
          Void Function(Pointer<_OpenVinoDevices>),
          void Function(Pointer<_OpenVinoDevices>)
        >('ov_available_devices_free')(devices);
      }
      if (core.value != nullptr) {
        library.lookupFunction<
          Void Function(Pointer<Void>),
          void Function(Pointer<Void>)
        >('ov_core_free')(core.value);
      }
      calloc.free(devices);
      calloc.free(core);
    }
  } catch (_) {
    return false;
  }
}

final class _Guid extends Struct {
  @Uint32()
  external int a;
  @Uint16()
  external int b;
  @Uint16()
  external int c;
  @Array(8)
  external Array<Uint8> d;
}

Pointer<_Guid> _guid(int a, int b, int c, List<int> d) {
  final result = calloc<_Guid>();
  result.ref
    ..a = a
    ..b = b
    ..c = c;
  for (var i = 0; i < 8; i++) {
    result.ref.d[i] = d[i];
  }
  return result;
}

final class _AdapterDescription extends Struct {
  @Array(128)
  external Array<Uint16> description;
  @Uint32()
  external int vendor;
  @Uint32()
  external int device;
  @Uint32()
  external int subsystem;
  @Uint32()
  external int revision;
  @UintPtr()
  external int dedicatedVideo;
  @UintPtr()
  external int dedicatedSystem;
  @UintPtr()
  external int sharedSystem;
  @Uint32()
  external int luidLow;
  @Int32()
  external int luidHigh;
  @Uint32()
  external int flags;
}

final class _VideoMemory extends Struct {
  @Uint64()
  external int budget;
  @Uint64()
  external int used;
  @Uint64()
  external int availableReservation;
  @Uint64()
  external int reservation;
}

Pointer<NativeFunction<T>> _method<T extends Function>(
  Pointer<Void> object,
  int index,
) => object.cast<Pointer<Pointer<NativeFunction<T>>>>().value[index];

void _release(Pointer<Void> object) {
  if (object != nullptr) {
    _method<Uint32 Function(Pointer<Void>)>(
      object,
      2,
    ).asFunction<int Function(Pointer<Void>)>()(object);
  }
}

List<OcrComputeDevice> _directMlDevices() {
  // The supported desktop helper architectures are x64 and arm64. Avoid
  // interpreting an x86 COM layout as the 64-bit adapter description.
  if (sizeOf<IntPtr>() != 8) return [];
  final factoryIid = _guid(0x770aae78, 0xf26f, 0x4dba, [
    0xa8,
    0x29,
    0x25,
    0x3c,
    0x83,
    0xd1,
    0xb3,
    0x87,
  ]);
  final adapter3Iid = _guid(0x645967a4, 0x1392, 0x4310, [
    0xa7,
    0x98,
    0x80,
    0x53,
    0xce,
    0x3e,
    0x93,
    0xfd,
  ]);
  final deviceIid = _guid(0x189819f1, 0x1db6, 0x4b57, [
    0xbe,
    0x54,
    0x18,
    0x21,
    0x33,
    0x9b,
    0x85,
    0xf7,
  ]);
  final factory = calloc<Pointer<Void>>(),
      adapter = calloc<Pointer<Void>>(),
      adapter3 = calloc<Pointer<Void>>();
  final description = calloc<_AdapterDescription>(),
      memory = calloc<_VideoMemory>();
  final result = <OcrComputeDevice>[];
  final occurrences = <String, int>{};
  try {
    final create = DynamicLibrary.open('dxgi.dll')
        .lookupFunction<
          Int32 Function(Pointer<_Guid>, Pointer<Pointer<Void>>),
          int Function(Pointer<_Guid>, Pointer<Pointer<Void>>)
        >('CreateDXGIFactory1');
    if (create(factoryIid, factory) < 0) return result;
    final supports = DynamicLibrary.open('d3d12.dll')
        .lookupFunction<
          Int32 Function(
            Pointer<Void>,
            Uint32,
            Pointer<_Guid>,
            Pointer<Pointer<Void>>,
          ),
          int Function(
            Pointer<Void>,
            int,
            Pointer<_Guid>,
            Pointer<Pointer<Void>>,
          )
        >('D3D12CreateDevice');
    final enumerate =
        _method<Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<Void>>)>(
              factory.value,
              12,
            )
            .asFunction<
              int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)
            >();
    for (var i = 0; i < 32; i++) {
      adapter.value = nullptr;
      if (enumerate(factory.value, i, adapter) < 0) break;
      try {
        final status =
            _method<
                  Int32 Function(Pointer<Void>, Pointer<_AdapterDescription>)
                >(adapter.value, 10)
                .asFunction<
                  int Function(Pointer<Void>, Pointer<_AdapterDescription>)
                >()(adapter.value, description);
        if (status < 0 ||
            description.ref.flags & 2 != 0 ||
            supports(adapter.value, 0xb000, deviceIid, nullptr) < 0) {
          continue;
        }
        final name = String.fromCharCodes([
          for (var c = 0; c < 128 && description.ref.description[c] != 0; c++)
            description.ref.description[c],
        ]);
        int? free;
        adapter3.value = nullptr;
        final query =
            _method<
                  Int32 Function(
                    Pointer<Void>,
                    Pointer<_Guid>,
                    Pointer<Pointer<Void>>,
                  )
                >(adapter.value, 0)
                .asFunction<
                  int Function(
                    Pointer<Void>,
                    Pointer<_Guid>,
                    Pointer<Pointer<Void>>,
                  )
                >();
        if (query(adapter.value, adapter3Iid, adapter3) >= 0) {
          try {
            final status =
                _method<
                      Int32 Function(
                        Pointer<Void>,
                        Uint32,
                        Int32,
                        Pointer<_VideoMemory>,
                      )
                    >(adapter3.value, 14)
                    .asFunction<
                      int Function(
                        Pointer<Void>,
                        int,
                        int,
                        Pointer<_VideoMemory>,
                      )
                    >()(adapter3.value, 0, 0, memory);
            if (status >= 0 && memory.ref.budget > 0) {
              free = math.max(0, memory.ref.budget - memory.ref.used);
            }
          } finally {
            _release(adapter3.value);
            adapter3.value = nullptr;
          }
        }
        // LUID changes after reboot. Keep different card models stable across
        // adapter reordering; equal cards are distinguished by their ordinal
        // within that hardware group rather than the global DXGI index.
        final fingerprint =
            '${description.ref.vendor}:${description.ref.device}:'
            '${description.ref.subsystem}:${description.ref.revision}';
        final occurrence = occurrences.update(
          fingerprint,
          (n) => n + 1,
          ifAbsent: () => 0,
        );
        result.add(
          OcrComputeDevice(
            provider: 'DirectML',
            id: i,
            key: 'DirectML:$fingerprint:$occurrence',
            name: name,
            dedicatedBytes: description.ref.dedicatedVideo,
            availableBytes: free,
          ),
        );
      } finally {
        _release(adapter.value);
        adapter.value = nullptr;
      }
    }
    result.sort((a, b) => b.dedicatedBytes.compareTo(a.dedicatedBytes));
    return result;
  } finally {
    _release(factory.value);
    calloc.free(factoryIid);
    calloc.free(adapter3Iid);
    calloc.free(deviceIid);
    calloc.free(factory);
    calloc.free(adapter);
    calloc.free(adapter3);
    calloc.free(description);
    calloc.free(memory);
  }
}

/// The DXGI budget is this process's OS residency allowance, not a claim about
/// globally free VRAM. Re-read it before allocating a hardware session.
int? ocrDirectMlHeadroom(int deviceId) {
  if (!Platform.isWindows) return null;
  return _directMlDevices()
      .where((d) => d.id == deviceId)
      .firstOrNull
      ?.availableBytes;
}

List<OcrComputeDevice> _cudaDevices(List<String> providers) {
  final lib = DynamicLibrary.open(
    Platform.isWindows ? 'nvcuda.dll' : 'libcuda.so.1',
  );
  final init = lib.lookupFunction<Int32 Function(Uint32), int Function(int)>(
    'cuInit',
  );
  if (init(0) != 0) return [];
  final count = calloc<Int32>(), device = calloc<Int32>();
  final name = calloc<Char>(256), bus = calloc<Char>(64), size = calloc<Size>();
  try {
    if (lib.lookupFunction<
          Int32 Function(Pointer<Int32>),
          int Function(Pointer<Int32>)
        >('cuDeviceGetCount')(count) !=
        0) {
      return [];
    }
    final result = <OcrComputeDevice>[];
    for (var i = 0; i < math.min(32, count.value); i++) {
      if (lib.lookupFunction<
            Int32 Function(Pointer<Int32>, Int32),
            int Function(Pointer<Int32>, int)
          >('cuDeviceGet')(device, i) !=
          0) {
        continue;
      }
      lib.lookupFunction<
        Int32 Function(Pointer<Char>, Int32, Int32),
        int Function(Pointer<Char>, int, int)
      >('cuDeviceGetName')(name, 256, device.value);
      lib.lookupFunction<
        Int32 Function(Pointer<Size>, Int32),
        int Function(Pointer<Size>, int)
      >('cuDeviceTotalMem_v2')(size, device.value);
      lib.lookupFunction<
        Int32 Function(Pointer<Char>, Int32, Int32),
        int Function(Pointer<Char>, int, int)
      >('cuDeviceGetPCIBusId')(bus, 64, device.value);
      for (final provider in providers.where(
        (p) => p == 'CUDA' || p == 'TensorRT',
      )) {
        final uuid = _gpuUuid(lib, 'cuDeviceGetUuid_v2', device.value);
        result.add(
          OcrComputeDevice(
            provider: provider,
            id: i,
            key: '$provider:${uuid ?? '${bus.cast<Utf8>().toDartString()}:$i'}',
            name: name.cast<Utf8>().toDartString(),
            dedicatedBytes: size.value,
          ),
        );
      }
    }
    return result;
  } finally {
    calloc.free(count);
    calloc.free(device);
    calloc.free(name);
    calloc.free(bus);
    calloc.free(size);
  }
}

List<OcrComputeDevice> _hipDevices() {
  final lib = DynamicLibrary.open('libamdhip64.so');
  final count = calloc<Int32>(),
      name = calloc<Char>(256),
      bus = calloc<Char>(64),
      size = calloc<Size>();
  try {
    if (lib.lookupFunction<
          Int32 Function(Pointer<Int32>),
          int Function(Pointer<Int32>)
        >('hipGetDeviceCount')(count) !=
        0) {
      return [];
    }
    final result = <OcrComputeDevice>[];
    for (var i = 0; i < math.min(32, count.value); i++) {
      lib.lookupFunction<
        Int32 Function(Pointer<Char>, Int32, Int32),
        int Function(Pointer<Char>, int, int)
      >('hipDeviceGetName')(name, 256, i);
      lib.lookupFunction<
        Int32 Function(Pointer<Size>, Int32),
        int Function(Pointer<Size>, int)
      >('hipDeviceTotalMem')(size, i);
      lib.lookupFunction<
        Int32 Function(Pointer<Char>, Int32, Int32),
        int Function(Pointer<Char>, int, int)
      >('hipDeviceGetPCIBusId')(bus, 64, i);
      result.add(
        OcrComputeDevice(
          provider: 'MIGraphX',
          id: i,
          key:
              'MIGraphX:${_gpuUuid(lib, 'hipDeviceGetUuid', i) ?? '${bus.cast<Utf8>().toDartString()}:$i'}',
          name: name.cast<Utf8>().toDartString(),
          dedicatedBytes: size.value,
        ),
      );
    }
    return result;
  } finally {
    calloc.free(count);
    calloc.free(name);
    calloc.free(bus);
    calloc.free(size);
  }
}

String? _gpuUuid(DynamicLibrary library, String symbol, int device) {
  final bytes = calloc<Uint8>(16);
  try {
    final status = library
        .lookupFunction<
          Int32 Function(Pointer<Uint8>, Int32),
          int Function(Pointer<Uint8>, int)
        >(symbol)(bytes, device);
    if (status != 0) return null;
    return bytes
        .asTypedList(16)
        .map((n) => n.toRadixString(16).padLeft(2, '0'))
        .join();
  } catch (_) {
    return null;
  } finally {
    calloc.free(bytes);
  }
}

bool _hasNnapiHardware() {
  final lib = DynamicLibrary.open('libneuralnetworks.so');
  final count = calloc<Uint32>(),
      device = calloc<Pointer<Void>>(),
      type = calloc<Int32>();
  try {
    if (lib.lookupFunction<
          Int32 Function(Pointer<Uint32>),
          int Function(Pointer<Uint32>)
        >('ANeuralNetworks_getDeviceCount')(count) !=
        0) {
      return false;
    }
    for (var i = 0; i < math.min(64, count.value); i++) {
      if (lib.lookupFunction<
            Int32 Function(Uint32, Pointer<Pointer<Void>>),
            int Function(int, Pointer<Pointer<Void>>)
          >('ANeuralNetworks_getDevice')(i, device) !=
          0) {
        continue;
      }
      if (lib.lookupFunction<
                Int32 Function(Pointer<Void>, Pointer<Int32>),
                int Function(Pointer<Void>, Pointer<Int32>)
              >('ANeuralNetworksDevice_getType')(device.value, type) ==
              0 &&
          (type.value == 3 || type.value == 4)) {
        return true;
      }
    }
    return false;
  } finally {
    calloc.free(count);
    calloc.free(device);
    calloc.free(type);
  }
}
