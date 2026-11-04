import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'ocr_onnx.dart';
import 'ocr_ort_runtime.dart';

/// Optional, OCR-only runtime. Never replaces the player's CPU/ASR runtime.
/// Each backend is used only after real device detection and CPU comparison.
const ocrNativeProviders = <String, int>{
  'Metal': 1,
  'OpenCL': 3,
  'Vulkan': 7,
  'QNN GPU': 100,
  'QNN HTP': 101,
};

class OcrNativeAccelerator {
  OcrNativeAccelerator._(this.library) {
    final abi = library.lookupFunction<Int32 Function(), int Function()>(
      'fluent_ocr_abi',
    )();
    if (abi != 1) throw StateError('OCR 加速组件版本不匹配');
  }
  final DynamicLibrary library;
  static OcrNativeAccelerator? _instance;
  static bool _attempted = false;
  static OcrNativeAccelerator? get instance {
    if (!_attempted) {
      _attempted = true;
      try {
        final name = Platform.isWindows
            ? 'fluent_ocr_accel.dll'
            : Platform.isMacOS
            ? 'libfluent_ocr_accel.dylib'
            : 'libfluent_ocr_accel.so';
        final override = Platform.environment['FLUENT_OCR_ACCEL_LIBRARY'];
        final library =
            override != null && !const bool.fromEnvironment('dart.vm.product')
            ? DynamicLibrary.open(override)
            : Platform.isIOS
            ? DynamicLibrary.process()
            : DynamicLibrary.open(
                Platform.isAndroid
                    ? name
                    : p.join(p.dirname(Platform.resolvedExecutable), name),
              );
        _instance = OcrNativeAccelerator._(library);
      } catch (_) {
        // Missing optional libraries are diagnosed by device discovery.
      }
    }
    return _instance;
  }

  String get version => library
      .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
        'fluent_ocr_version',
      )()
      .toDartString();
  String get error => library
      .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
        'fluent_ocr_error',
      )()
      .toDartString();

  bool probe(String provider) {
    final backend = ocrNativeProviders[provider];
    if (backend == null) return false;
    return library.lookupFunction<Int32 Function(Int32), int Function(int)>(
          'fluent_ocr_probe',
        )(backend) ==
        1;
  }

  String deviceInfo(String provider) => library
      .lookupFunction<
        Pointer<Utf8> Function(Int32),
        Pointer<Utf8> Function(int)
      >('fluent_ocr_device')(ocrNativeProviders[provider]!)
      .toDartString();

  /// Compilation cache of the same immutable ONNX revision, preserving FP32
  /// weights, preprocessing and dictionaries. No replacement model/download.
  Future<String> compiledModel(String source) async {
    final stat = await File(source).stat();
    if (stat.type != FileSystemEntityType.file) throw StateError('OCR 模型文件不存在');
    final directory = Directory('$source.fluent-mnn-3.6.1-fp32-v1');
    await directory.create(recursive: true);
    final lock = await File(
      p.join(directory.path, 'compile.lock'),
    ).open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.blockingExclusive);
      final output = File(p.join(directory.path, 'graph.mnn'));
      final receipt = File(p.join(directory.path, 'source.txt'));
      final identity =
          '$version\n${stat.size}\n${stat.modified.microsecondsSinceEpoch}';
      if (await output.exists() &&
          await receipt.exists() &&
          await receipt.readAsString() == identity &&
          await output.length() > 8) {
        return output.path;
      }
      final temporary = File(p.join(directory.path, 'graph.$pid.tmp'));
      final inputName = source.toNativeUtf8();
      final outputName = temporary.path.toNativeUtf8();
      try {
        final ok = library
            .lookupFunction<
              Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
              int Function(Pointer<Utf8>, Pointer<Utf8>)
            >('fluent_ocr_convert')(inputName, outputName);
        if (ok != 1 ||
            !await temporary.exists() ||
            await temporary.length() <= 8) {
          throw StateError('当前模型无法准备 GPU 加速：$error');
        }
        await temporary.rename(output.path);
        await receipt.writeAsString(identity, flush: true);
        return output.path;
      } finally {
        calloc.free(inputName);
        calloc.free(outputName);
        if (await temporary.exists()) await temporary.delete();
      }
    } finally {
      await lock.close();
    }
  }

  Future<OrtSession> open(String source, String provider, int threads) async {
    final backend = ocrNativeProviders[provider];
    if (backend == null) throw StateError('未接入的 OCR 加速路线');
    final path = provider.startsWith('QNN ')
        ? source
        : await compiledModel(source);
    final nativePath = path.toNativeUtf8();
    try {
      final session = library
          .lookupFunction<
            Pointer<Void> Function(Pointer<Utf8>, Int32, Int32),
            Pointer<Void> Function(Pointer<Utf8>, int, int)
          >('fluent_ocr_create')(nativePath, backend, threads);
      if (session == nullptr) throw StateError('无法初始化 $provider：$error');
      return _NativeSession(this, session);
    } finally {
      calloc.free(nativePath);
    }
  }
}

class OcrAcceleratorTensor extends OrtValue {
  OcrAcceleratorTensor(this.runtime, this.handle) : super(nullptr) {
    final rank = runtime.library
        .lookupFunction<
          Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('fluent_ocr_result_rank')(handle);
    if (rank < 1 || rank > 8) throw StateError('OCR 加速输出维度无效');
    shape = runtime.library
        .lookupFunction<
          Pointer<Int64> Function(Pointer<Void>),
          Pointer<Int64> Function(Pointer<Void>)
        >('fluent_ocr_result_shape')(handle)
        .asTypedList(rank)
        .toList(growable: false);
    final length = shape.fold<int>(1, (n, v) => n * v);
    if (shape.any((n) => n <= 0) || length > 8 * 1024 * 1024) {
      throw StateError('OCR 加速输出超出内存限制');
    }
    pointer = runtime.library
        .lookupFunction<
          Pointer<Float> Function(Pointer<Void>),
          Pointer<Float> Function(Pointer<Void>)
        >('fluent_ocr_result_data')(handle);
    values = pointer.asTypedList(length);
  }
  final OcrNativeAccelerator runtime;
  Pointer<Void> handle;
  late final List<int> shape;
  late final Pointer<Float> pointer;
  late final Float32List values;
  @override
  void release() {
    if (handle == nullptr) return;
    runtime.library.lookupFunction<
      Void Function(Pointer<Void>),
      void Function(Pointer<Void>)
    >('fluent_ocr_result_destroy')(handle);
    handle = nullptr;
  }
}

class _NativeSession implements OrtSession {
  _NativeSession(this.runtime, this.handle);
  final OcrNativeAccelerator runtime;
  Pointer<Void> handle;
  @override
  int get address => 0;
  @override
  List<String> inputNames = const ['x'];
  @override
  List<String> outputNames = const ['output'];
  @override
  List<OrtValue?> run(
    OrtRunOptions options,
    Map<String, OrtValueTensor> inputs,
  ) {
    if (handle == nullptr || inputs.length != 1) throw StateError('OCR 加速会话无效');
    final view = OcrFloatTensorView(inputs.values.single);
    final dimensions = calloc<Int64>(view.shape.length);
    try {
      dimensions.asTypedList(view.shape.length).setAll(0, view.shape);
      final result = runtime.library
          .lookupFunction<
            Pointer<Void> Function(
              Pointer<Void>,
              Pointer<Float>,
              Pointer<Int64>,
              Int32,
            ),
            Pointer<Void> Function(
              Pointer<Void>,
              Pointer<Float>,
              Pointer<Int64>,
              int,
            )
          >(
            'fluent_ocr_run',
          )(handle, view.pointer, dimensions, view.shape.length);
      if (result == nullptr) throw StateError('OCR 硬件加速失败：${runtime.error}');
      try {
        return [OcrAcceleratorTensor(runtime, result)];
      } catch (_) {
        runtime.library.lookupFunction<
          Void Function(Pointer<Void>),
          void Function(Pointer<Void>)
        >('fluent_ocr_result_destroy')(result);
        rethrow;
      }
    } finally {
      calloc.free(dimensions);
    }
  }

  @override
  Future<void> release() async {
    if (handle == nullptr) return;
    runtime.library.lookupFunction<
      Void Function(Pointer<Void>),
      void Function(Pointer<Void>)
    >('fluent_ocr_destroy')(handle);
    handle = nullptr;
  }
}
