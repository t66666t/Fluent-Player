import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:onnxruntime_v2/onnxruntime_v2.dart';
// The pinned plugin's public file loader does not encode Windows paths correctly.
// ignore: implementation_imports
import 'package:onnxruntime_v2/src/bindings/onnxruntime_bindings_generated.dart'
    as native;

/// The pinned plugin's fromFile passes UTF-8 on Windows, whereas ORT requires
/// wchar_t there. Use the same API with the correct path encoding and release
/// all temporary allocations. Loading from a file also avoids copying large
/// alignment weights into both Dart and native byte buffers.
OrtSession openAsrOnnxSession(String path, int threads) {
  // ptr lazily creates one environment. Repeated init() overwrites its handle
  // and leaks an environment reference on every alignment model reload.
  final environment = OrtEnv.instance.ptr;
  final api = OrtEnv.instance.ortApiPtr.ref;
  final options = calloc<Pointer<native.OrtSessionOptions>>();
  final result = calloc<Pointer<native.OrtSession>>();
  final Pointer<Char> filename = Platform.isWindows
      ? path.toNativeUtf16().cast<Char>()
      : path.toNativeUtf8().cast<Char>();
  try {
    OrtStatus.checkOrtStatus(
      api.CreateSessionOptions.asFunction<
        native.OrtStatusPtr Function(Pointer<Pointer<native.OrtSessionOptions>>)
      >()(options),
    );
    OrtStatus.checkOrtStatus(
      api.SetIntraOpNumThreads.asFunction<
        native.OrtStatusPtr Function(Pointer<native.OrtSessionOptions>, int)
      >()(options.value, threads.clamp(1, 4)),
    );
    OrtStatus.checkOrtStatus(
      api.SetInterOpNumThreads.asFunction<
        native.OrtStatusPtr Function(Pointer<native.OrtSessionOptions>, int)
      >()(options.value, 1),
    );
    final key = 'session.intra_op.allow_spinning'.toNativeUtf8();
    final value = '0'.toNativeUtf8();
    try {
      OrtStatus.checkOrtStatus(
        api.AddSessionConfigEntry.asFunction<
          native.OrtStatusPtr Function(
            Pointer<native.OrtSessionOptions>,
            Pointer<Char>,
            Pointer<Char>,
          )
        >()(options.value, key.cast(), value.cast()),
      );
    } finally {
      calloc.free(key);
      calloc.free(value);
    }
    OrtStatus.checkOrtStatus(
      api.CreateSession.asFunction<
        native.OrtStatusPtr Function(
          Pointer<native.OrtEnv>,
          Pointer<Char>,
          Pointer<native.OrtSessionOptions>,
          Pointer<Pointer<native.OrtSession>>,
        )
      >()(environment, filename, options.value, result),
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
