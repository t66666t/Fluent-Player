import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'ocr_ort_runtime.dart';
import 'ocr_native_accelerator.dart';
// Same pinned ABI and runtime as the existing ASR session adapter.
// ignore: implementation_imports
import 'package:onnxruntime_v2/src/bindings/onnxruntime_bindings_generated.dart'
    as native;
// ignore: implementation_imports
import 'package:onnxruntime_v2/src/bindings/bindings.dart';

OrtSession openOcrOnnxSession(
  String path,
  int threads,
  String provider, {
  int deviceId = 0,
  String coreMLUnits = 'ALL',
  int? gpuMemoryLimit,
  bool conservative = false,
}) {
  final env = OrtEnv.instance.ptr;
  final api = OrtEnv.instance.ortApiPtr.ref;
  final options = calloc<Pointer<native.OrtSessionOptions>>();
  final result = calloc<Pointer<native.OrtSession>>();
  final filename = Platform.isWindows
      ? path.toNativeUtf16().cast<Char>()
      : path.toNativeUtf8().cast<Char>();
  void check(native.OrtStatusPtr status) => OrtStatus.checkOrtStatus(status);
  void setting(String key, String value) {
    final k = key.toNativeUtf8(), v = value.toNativeUtf8();
    try {
      check(
        api.AddSessionConfigEntry.asFunction<
          native.OrtStatusPtr Function(
            Pointer<native.OrtSessionOptions>,
            Pointer<Char>,
            Pointer<Char>,
          )
        >()(options.value, k.cast(), v.cast()),
      );
    } finally {
      calloc.free(k);
      calloc.free(v);
    }
  }

  void appendOptions(String name, Map<String, String> entries) {
    final ep = name.toNativeUtf8();
    final keys = calloc<Pointer<Char>>(entries.length);
    final values = calloc<Pointer<Char>>(entries.length);
    try {
      var i = 0;
      for (final entry in entries.entries) {
        keys[i] = entry.key.toNativeUtf8().cast();
        values[i++] = entry.value.toNativeUtf8().cast();
      }
      check(
        api.SessionOptionsAppendExecutionProvider.asFunction<
          native.OrtStatusPtr Function(
            Pointer<native.OrtSessionOptions>,
            Pointer<Char>,
            Pointer<Pointer<Char>>,
            Pointer<Pointer<Char>>,
            int,
          )
        >()(options.value, ep.cast(), keys, values, entries.length),
      );
    } finally {
      for (var i = 0; i < entries.length; i++) {
        if (keys[i] != nullptr) calloc.free(keys[i]);
        if (values[i] != nullptr) calloc.free(values[i]);
      }
      calloc.free(ep);
      calloc.free(keys);
      calloc.free(values);
    }
  }

  void appendCuda() {
    final cuda = calloc<Pointer<native.OrtCUDAProviderOptionsV2>>();
    final entries = {
      'device_id': '$deviceId',
      'gpu_mem_limit': '${gpuMemoryLimit ?? 512 * 1024 * 1024}',
      'cudnn_conv_algo_search': 'HEURISTIC',
    };
    final keys = calloc<Pointer<Char>>(entries.length),
        values = calloc<Pointer<Char>>(entries.length);
    try {
      check(
        api.CreateCUDAProviderOptions.asFunction<
          native.OrtStatusPtr Function(
            Pointer<Pointer<native.OrtCUDAProviderOptionsV2>>,
          )
        >()(cuda),
      );
      var i = 0;
      for (final entry in entries.entries) {
        keys[i] = entry.key.toNativeUtf8().cast();
        values[i++] = entry.value.toNativeUtf8().cast();
      }
      check(
        api.UpdateCUDAProviderOptions.asFunction<
          native.OrtStatusPtr Function(
            Pointer<native.OrtCUDAProviderOptionsV2>,
            Pointer<Pointer<Char>>,
            Pointer<Pointer<Char>>,
            int,
          )
        >()(cuda.value, keys, values, entries.length),
      );
      check(
        api.SessionOptionsAppendExecutionProvider_CUDA_V2.asFunction<
          native.OrtStatusPtr Function(
            Pointer<native.OrtSessionOptions>,
            Pointer<native.OrtCUDAProviderOptionsV2>,
          )
        >()(options.value, cuda.value),
      );
    } finally {
      if (cuda.value != nullptr) {
        api.ReleaseCUDAProviderOptions.asFunction<
          void Function(Pointer<native.OrtCUDAProviderOptionsV2>)
        >()(cuda.value);
      }
      for (var i = 0; i < entries.length; i++) {
        if (keys[i] != nullptr) calloc.free(keys[i]);
        if (values[i] != nullptr) calloc.free(values[i]);
      }
      calloc.free(cuda);
      calloc.free(keys);
      calloc.free(values);
    }
  }

  void appendTensorRt() {
    final trt = calloc<Pointer<native.OrtTensorRTProviderOptionsV2>>();
    final entries = {
      'device_id': '$deviceId',
      'trt_max_workspace_size': '${gpuMemoryLimit ?? 256 * 1024 * 1024}',
      'trt_fp16_enable': '0',
      'trt_engine_cache_enable': '0',
    };
    final keys = calloc<Pointer<Char>>(entries.length),
        values = calloc<Pointer<Char>>(entries.length);
    try {
      check(
        api.CreateTensorRTProviderOptions.asFunction<
          native.OrtStatusPtr Function(
            Pointer<Pointer<native.OrtTensorRTProviderOptionsV2>>,
          )
        >()(trt),
      );
      var i = 0;
      for (final entry in entries.entries) {
        keys[i] = entry.key.toNativeUtf8().cast();
        values[i++] = entry.value.toNativeUtf8().cast();
      }
      check(
        api.UpdateTensorRTProviderOptions.asFunction<
          native.OrtStatusPtr Function(
            Pointer<native.OrtTensorRTProviderOptionsV2>,
            Pointer<Pointer<Char>>,
            Pointer<Pointer<Char>>,
            int,
          )
        >()(trt.value, keys, values, entries.length),
      );
      check(
        api.SessionOptionsAppendExecutionProvider_TensorRT_V2.asFunction<
          native.OrtStatusPtr Function(
            Pointer<native.OrtSessionOptions>,
            Pointer<native.OrtTensorRTProviderOptionsV2>,
          )
        >()(options.value, trt.value),
      );
    } finally {
      if (trt.value != nullptr) {
        api.ReleaseTensorRTProviderOptions.asFunction<
          void Function(Pointer<native.OrtTensorRTProviderOptionsV2>)
        >()(trt.value);
      }
      for (var i = 0; i < entries.length; i++) {
        if (keys[i] != nullptr) calloc.free(keys[i]);
        if (values[i] != nullptr) calloc.free(values[i]);
      }
      calloc.free(trt);
      calloc.free(keys);
      calloc.free(values);
    }
  }

  try {
    check(
      api.CreateSessionOptions.asFunction<
        native.OrtStatusPtr Function(Pointer<Pointer<native.OrtSessionOptions>>)
      >()(options),
    );
    check(
      api.SetIntraOpNumThreads.asFunction<
        native.OrtStatusPtr Function(Pointer<native.OrtSessionOptions>, int)
      >()(options.value, threads),
    );
    check(
      api.SetInterOpNumThreads.asFunction<
        native.OrtStatusPtr Function(Pointer<native.OrtSessionOptions>, int)
      >()(options.value, 1),
    );
    check(
      api.SetSessionExecutionMode.asFunction<
        native.OrtStatusPtr Function(Pointer<native.OrtSessionOptions>, int)
      >()(options.value, 0),
    );
    check(
      api.SetSessionGraphOptimizationLevel.asFunction<
        native.OrtStatusPtr Function(Pointer<native.OrtSessionOptions>, int)
      >()(options.value, conservative ? 1 : 99),
    );
    if (conservative) {
      check(
        api.DisableMemPattern.asFunction<
          native.OrtStatusPtr Function(Pointer<native.OrtSessionOptions>)
        >()(options.value),
      );
      check(
        api.DisableCpuMemArena.asFunction<
          native.OrtStatusPtr Function(Pointer<native.OrtSessionOptions>)
        >()(options.value),
      );
    }
    setting('session.intra_op.allow_spinning', '0');
    setting('session.inter_op.allow_spinning', '0');
    if (provider == 'CoreML') {
      if (coreMLUnits != 'ALL') {
        appendOptions('CoreML', {'MLComputeUnits': coreMLUnits});
      } else {
        check(
          onnxRuntimeBinding.OrtSessionOptionsAppendExecutionProvider_CoreML(
            options.value,
            0,
          ),
        );
      }
    } else if (provider == 'NNAPI') {
      check(
        onnxRuntimeBinding.OrtSessionOptionsAppendExecutionProvider_Nnapi(
          options.value,
          4, // Keep the slower NNAPI reference CPU out of the hardware path.
        ),
      );
    } else if (provider == 'DirectML') {
      check(
        api.DisableMemPattern.asFunction<
          native.OrtStatusPtr Function(Pointer<native.OrtSessionOptions>)
        >()(options.value),
      );
      final append = DynamicLibrary.open('onnxruntime.dll')
          .lookupFunction<
            native.OrtStatusPtr Function(
              Pointer<native.OrtSessionOptions>,
              Int32,
            ),
            native.OrtStatusPtr Function(Pointer<native.OrtSessionOptions>, int)
          >('OrtSessionOptionsAppendExecutionProvider_DML');
      check(append(options.value, deviceId));
    } else if (provider == 'CUDA') {
      appendCuda();
    } else if (provider == 'TensorRT') {
      appendTensorRt();
      appendCuda(); // CUDA handles graph portions unsupported by TensorRT.
    } else if (provider == 'OpenVINO') {
      // Use the pinned API-14 structure, not the newer OpenVINO V2 API.
      final ov = calloc<native.OrtOpenVINOProviderOptions>();
      final type = 'GPU_FP32'.toNativeUtf8();
      try {
        ov.ref.device_type = type.cast();
        check(
          api.SessionOptionsAppendExecutionProvider_OpenVINO.asFunction<
            native.OrtStatusPtr Function(
              Pointer<native.OrtSessionOptions>,
              Pointer<native.OrtOpenVINOProviderOptions>,
            )
          >()(options.value, ov),
        );
      } finally {
        calloc.free(type);
        calloc.free(ov);
      }
    } else if (provider == 'MIGraphX') {
      check(
        onnxRuntimeBinding.OrtSessionOptionsAppendExecutionProvider_MIGraphX(
          options.value,
          deviceId,
        ),
      );
    } else if (provider == 'XNNPACK') {
      final name = 'XNNPACK'.toNativeUtf8();
      final keys = calloc<Pointer<Char>>(1), values = calloc<Pointer<Char>>(1);
      keys[0] = 'intra_op_num_threads'.toNativeUtf8().cast();
      values[0] = '$threads'.toNativeUtf8().cast();
      try {
        check(
          api.SessionOptionsAppendExecutionProvider.asFunction<
            native.OrtStatusPtr Function(
              Pointer<native.OrtSessionOptions>,
              Pointer<Char>,
              Pointer<Pointer<Char>>,
              Pointer<Pointer<Char>>,
              int,
            )
          >()(options.value, name.cast(), keys, values, 1),
        );
      } finally {
        calloc.free(name);
        calloc.free(keys[0]);
        calloc.free(values[0]);
        calloc.free(keys);
        calloc.free(values);
      }
    }
    check(
      api.CreateSession.asFunction<
        native.OrtStatusPtr Function(
          Pointer<native.OrtEnv>,
          Pointer<Char>,
          Pointer<native.OrtSessionOptions>,
          Pointer<Pointer<native.OrtSession>>,
        )
      >()(env, filename, options.value, result),
    );
    return OrtSession.fromAddress(result.value.address);
  } finally {
    if (options.value != nullptr) {
      api.ReleaseSessionOptions.asFunction<
        void Function(Pointer<native.OrtSessionOptions>)
      >()(options.value);
    }
    calloc.free(filename);
    calloc.free(result);
    calloc.free(options);
  }
}

String? readOcrOnnxMetadata(OrtSession session, String key) {
  final api = OrtEnv.instance.ortApiPtr.ref;
  final metadata = calloc<Pointer<native.OrtModelMetadata>>();
  final value = calloc<Pointer<Char>>();
  final name = key.toNativeUtf8();
  try {
    OrtStatus.checkOrtStatus(
      api.SessionGetModelMetadata.asFunction<
        native.OrtStatusPtr Function(
          Pointer<native.OrtSession>,
          Pointer<Pointer<native.OrtModelMetadata>>,
        )
      >()(Pointer<native.OrtSession>.fromAddress(session.address), metadata),
    );
    OrtStatus.checkOrtStatus(
      api.ModelMetadataLookupCustomMetadataMap.asFunction<
        native.OrtStatusPtr Function(
          Pointer<native.OrtModelMetadata>,
          Pointer<native.OrtAllocator>,
          Pointer<Char>,
          Pointer<Pointer<Char>>,
        )
      >()(metadata.value, OrtAllocator.instance.ptr, name.cast(), value),
    );
    return value.value == nullptr
        ? null
        : value.value.cast<Utf8>().toDartString();
  } finally {
    if (value.value != nullptr) {
      OrtStatus.checkOrtStatus(
        api.AllocatorFree.asFunction<
          native.OrtStatusPtr Function(
            Pointer<native.OrtAllocator>,
            Pointer<Void>,
          )
        >()(OrtAllocator.instance.ptr, value.value.cast()),
      );
    }
    if (metadata.value != nullptr) {
      api.ReleaseModelMetadata.asFunction<
        void Function(Pointer<native.OrtModelMetadata>)
      >()(metadata.value);
    }
    calloc.free(name);
    calloc.free(value);
    calloc.free(metadata);
  }
}

/// Borrowed views remain valid only until the owning OrtValue is released.
/// This avoids boxing every detector probability / CTC class score in Dart.
class OcrFloatTensorView {
  OcrFloatTensorView(OrtValue value) {
    if (value is OcrAcceleratorTensor) {
      shape = value.shape;
      values = value.values;
      pointer = value.pointer;
      return;
    }
    final api = OrtEnv.instance.ortApiPtr.ref;
    final info = calloc<Pointer<native.OrtTensorTypeAndShapeInfo>>();
    final dimensions = calloc<Size>(),
        type = calloc<Int32>(),
        data = calloc<Pointer<Void>>();
    Pointer<Int64>? sizes;
    try {
      OrtStatus.checkOrtStatus(
        api.GetTensorTypeAndShape.asFunction<
          native.OrtStatusPtr Function(
            Pointer<native.OrtValue>,
            Pointer<Pointer<native.OrtTensorTypeAndShapeInfo>>,
          )
        >()(value.ptr, info),
      );
      OrtStatus.checkOrtStatus(
        api.GetTensorElementType.asFunction<
          native.OrtStatusPtr Function(
            Pointer<native.OrtTensorTypeAndShapeInfo>,
            Pointer<Int32>,
          )
        >()(info.value, type),
      );
      if (type.value != 1) throw StateError('OCR 输出必须为 Float32');
      OrtStatus.checkOrtStatus(
        api.GetDimensionsCount.asFunction<
          native.OrtStatusPtr Function(
            Pointer<native.OrtTensorTypeAndShapeInfo>,
            Pointer<Size>,
          )
        >()(info.value, dimensions),
      );
      sizes = calloc<Int64>(dimensions.value);
      OrtStatus.checkOrtStatus(
        api.GetDimensions.asFunction<
          native.OrtStatusPtr Function(
            Pointer<native.OrtTensorTypeAndShapeInfo>,
            Pointer<Int64>,
            int,
          )
        >()(info.value, sizes, dimensions.value),
      );
      shape = sizes.asTypedList(dimensions.value).toList(growable: false);
      final length = shape.fold<int>(1, (n, v) => n * v);
      if (length <= 0) throw StateError('OCR 输出尺寸无效');
      OrtStatus.checkOrtStatus(
        api.GetTensorMutableData.asFunction<
          native.OrtStatusPtr Function(
            Pointer<native.OrtValue>,
            Pointer<Pointer<Void>>,
          )
        >()(value.ptr, data),
      );
      pointer = data.value.cast<Float>();
      values = pointer.asTypedList(length);
    } finally {
      if (sizes != null) calloc.free(sizes);
      if (info.value != nullptr) {
        api.ReleaseTensorTypeAndShapeInfo.asFunction<
          void Function(Pointer<native.OrtTensorTypeAndShapeInfo>)
        >()(info.value);
      }
      calloc.free(info);
      calloc.free(dimensions);
      calloc.free(type);
      calloc.free(data);
    }
  }
  late final List<int> shape;
  late final Float32List values;
  late final Pointer<Float> pointer;
}
