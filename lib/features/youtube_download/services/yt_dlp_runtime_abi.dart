import 'yt_dlp_runtime_abi_stub.dart'
    if (dart.library.ffi) 'yt_dlp_runtime_abi_native.dart';
import 'yt_dlp_runtime_arch.dart';

export 'yt_dlp_runtime_arch.dart';

YtDlpRuntimeArch currentYtDlpRuntimeArch() => detectYtDlpRuntimeArch();
