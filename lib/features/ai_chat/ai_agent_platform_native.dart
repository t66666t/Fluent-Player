import 'dart:ffi';
import 'dart:io';

String get aiAgentHostPlatform => Platform.operatingSystem;
String get aiAgentHostArchitecture => switch (Abi.current()) {
  Abi.windowsArm64 || Abi.macosArm64 || Abi.linuxArm64 => 'arm64',
  Abi.windowsX64 || Abi.macosX64 || Abi.linuxX64 => 'x64',
  _ => 'other',
};
