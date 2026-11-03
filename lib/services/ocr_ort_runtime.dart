import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
// The pinned package's generated C ABI and environment are Flutter-free. Its
// session wrapper imports rootBundle, preventing a crash-isolated executable.
// ignore: implementation_imports
import 'package:onnxruntime_v2/src/bindings/onnxruntime_bindings_generated.dart'
    as native;
// ignore: implementation_imports
import 'package:onnxruntime_v2/src/ort_env.dart';
// ignore: implementation_imports
import 'package:onnxruntime_v2/src/ort_status.dart';

// ignore: implementation_imports
export 'package:onnxruntime_v2/src/ort_env.dart';
// ignore: implementation_imports
export 'package:onnxruntime_v2/src/ort_provider.dart';
// ignore: implementation_imports
export 'package:onnxruntime_v2/src/ort_status.dart';

class OrtValue {
  OrtValue(this.ptr);
  Pointer<native.OrtValue> ptr;
  void release() {
    if (ptr == nullptr) return;
    OrtEnv.instance.ortApiPtr.ref.ReleaseValue
        .asFunction<void Function(Pointer<native.OrtValue>)>()(ptr);
    ptr = nullptr;
  }
}

class OrtValueTensor extends OrtValue {
  OrtValueTensor._(super.ptr);
  factory OrtValueTensor.createTensorWithDataList(
    Float32List values,
    List<int> shape,
  ) {
    if (shape.isEmpty ||
        shape.any((n) => n <= 0) ||
        shape.fold<int>(1, (n, v) => n * v) != values.length) {
      throw ArgumentError('OCR tensor dimensions do not match the input');
    }
    final api = OrtEnv.instance.ortApiPtr.ref;
    final dims = calloc<Int64>(shape.length);
    final tensor = calloc<Pointer<native.OrtValue>>();
    final data = calloc<Pointer<Void>>();
    try {
      dims.asTypedList(shape.length).setAll(0, shape);
      OrtStatus.checkOrtStatus(
        api.CreateTensorAsOrtValue.asFunction<
          native.OrtStatusPtr Function(
            Pointer<native.OrtAllocator>,
            Pointer<Int64>,
            int,
            int,
            Pointer<Pointer<native.OrtValue>>,
          )
        >()(OrtAllocator.instance.ptr, dims, shape.length, 1, tensor),
      );
      OrtStatus.checkOrtStatus(
        api.GetTensorMutableData.asFunction<
          native.OrtStatusPtr Function(
            Pointer<native.OrtValue>,
            Pointer<Pointer<Void>>,
          )
        >()(tensor.value, data),
      );
      data.value.cast<Float>().asTypedList(values.length).setAll(0, values);
      final result = OrtValueTensor._(tensor.value);
      tensor.value = nullptr;
      return result;
    } finally {
      if (tensor.value != nullptr) OrtValue(tensor.value).release();
      calloc.free(dims);
      calloc.free(tensor);
      calloc.free(data);
    }
  }
}

class OrtRunOptions {
  OrtRunOptions() {
    final out = calloc<Pointer<native.OrtRunOptions>>();
    try {
      OrtStatus.checkOrtStatus(
        OrtEnv.instance.ortApiPtr.ref.CreateRunOptions
            .asFunction<
              native.OrtStatusPtr Function(
                Pointer<Pointer<native.OrtRunOptions>>,
              )
            >()(out),
      );
      ptr = out.value;
    } finally {
      calloc.free(out);
    }
  }
  late Pointer<native.OrtRunOptions> ptr;
  void release() {
    if (ptr == nullptr) return;
    OrtEnv.instance.ortApiPtr.ref.ReleaseRunOptions
        .asFunction<void Function(Pointer<native.OrtRunOptions>)>()(ptr);
    ptr = nullptr;
  }
}

class OrtSession {
  OrtSession.fromAddress(int address) : _ptr = Pointer.fromAddress(address) {
    try {
      _inputNames = _names(true);
      _outputNames = _names(false);
    } catch (_) {
      _release();
      rethrow;
    }
  }
  Pointer<native.OrtSession> _ptr;
  int get address => _ptr.address;
  late final List<String> _inputNames, _outputNames;
  List<String> get inputNames => _inputNames;
  List<String> get outputNames => _outputNames;

  List<String> _names(bool input) {
    final api = OrtEnv.instance.ortApiPtr.ref;
    final count = calloc<Size>();
    final name = calloc<Pointer<Char>>();
    try {
      final counter = input
          ? api.SessionGetInputCount
          : api.SessionGetOutputCount;
      final getter = input ? api.SessionGetInputName : api.SessionGetOutputName;
      OrtStatus.checkOrtStatus(
        counter
            .asFunction<
              native.OrtStatusPtr Function(
                Pointer<native.OrtSession>,
                Pointer<Size>,
              )
            >()(_ptr, count),
      );
      final names = <String>[];
      for (var i = 0; i < count.value; i++) {
        OrtStatus.checkOrtStatus(
          getter
              .asFunction<
                native.OrtStatusPtr Function(
                  Pointer<native.OrtSession>,
                  int,
                  Pointer<native.OrtAllocator>,
                  Pointer<Pointer<Char>>,
                )
              >()(_ptr, i, OrtAllocator.instance.ptr, name),
        );
        try {
          names.add(name.value.cast<Utf8>().toDartString());
        } finally {
          OrtStatus.checkOrtStatus(
            api.AllocatorFree.asFunction<
              native.OrtStatusPtr Function(
                Pointer<native.OrtAllocator>,
                Pointer<Void>,
              )
            >()(OrtAllocator.instance.ptr, name.value.cast()),
          );
          name.value = nullptr;
        }
      }
      return names;
    } finally {
      calloc.free(count);
      calloc.free(name);
    }
  }

  List<OrtValue?> run(
    OrtRunOptions options,
    Map<String, OrtValueTensor> inputs,
  ) {
    if (_ptr == nullptr) throw StateError('OCR inference session is closed');
    final inNames = calloc<Pointer<Char>>(inputs.length);
    final inValues = calloc<Pointer<native.OrtValue>>(inputs.length);
    final outNames = calloc<Pointer<Char>>(outputNames.length);
    final outValues = calloc<Pointer<native.OrtValue>>(outputNames.length);
    try {
      var index = 0;
      for (final entry in inputs.entries) {
        inNames[index] = entry.key.toNativeUtf8().cast();
        inValues[index++] = entry.value.ptr;
      }
      for (var i = 0; i < outputNames.length; i++) {
        outNames[i] = outputNames[i].toNativeUtf8().cast();
      }
      OrtStatus.checkOrtStatus(
        OrtEnv.instance.ortApiPtr.ref.Run
            .asFunction<
              native.OrtStatusPtr Function(
                Pointer<native.OrtSession>,
                Pointer<native.OrtRunOptions>,
                Pointer<Pointer<Char>>,
                Pointer<Pointer<native.OrtValue>>,
                int,
                Pointer<Pointer<Char>>,
                int,
                Pointer<Pointer<native.OrtValue>>,
              )
            >()(
          _ptr,
          options.ptr,
          inNames,
          inValues,
          inputs.length,
          outNames,
          outputNames.length,
          outValues,
        ),
      );
      return List.generate(outputNames.length, (i) {
        final pointer = outValues[i];
        outValues[i] = nullptr;
        return pointer == nullptr ? null : OrtValue(pointer);
      });
    } finally {
      for (var i = 0; i < inputs.length; i++) {
        if (inNames[i] != nullptr) calloc.free(inNames[i]);
      }
      for (var i = 0; i < outputNames.length; i++) {
        if (outNames[i] != nullptr) calloc.free(outNames[i]);
        if (outValues[i] != nullptr) OrtValue(outValues[i]).release();
      }
      calloc.free(inNames);
      calloc.free(inValues);
      calloc.free(outNames);
      calloc.free(outValues);
    }
  }

  void _release() {
    if (_ptr == nullptr) return;
    OrtEnv.instance.ortApiPtr.ref.ReleaseSession
        .asFunction<void Function(Pointer<native.OrtSession>)>()(_ptr);
    _ptr = nullptr;
  }

  Future<void> release() async => _release();
}
