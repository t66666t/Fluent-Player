import 'dart:ffi';

import 'yt_dlp_runtime_arch.dart';

YtDlpRuntimeArch detectYtDlpRuntimeArch() {
  return switch (Abi.current()) {
    Abi.windowsX64 ||
    Abi.linuxX64 ||
    Abi.macosX64 ||
    Abi.androidX64 => YtDlpRuntimeArch.x64,
    Abi.windowsArm64 ||
    Abi.linuxArm64 ||
    Abi.macosArm64 ||
    Abi.androidArm64 => YtDlpRuntimeArch.arm64,
    Abi.windowsIA32 || Abi.linuxIA32 || Abi.androidIA32 => YtDlpRuntimeArch.x86,
    Abi.linuxArm || Abi.androidArm => YtDlpRuntimeArch.armv7,
    _ => YtDlpRuntimeArch.unsupported,
  };
}
