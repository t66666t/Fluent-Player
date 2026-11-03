import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

import 'model_catalog.dart';

final class _MemoryStatus extends Struct {
  @Uint32()
  external int length;
  @Uint32()
  external int load;
  @Uint64()
  external int physical;
  @Uint64()
  external int available;
  @Uint64()
  external int pageFile;
  @Uint64()
  external int availablePageFile;
  @Uint64()
  external int virtual;
  @Uint64()
  external int availableVirtual;
  @Uint64()
  external int extended;
}

/// Physical RAM is a screening hint, never a promise of available app memory.
class ModelDeviceInfo {
  const ModelDeviceInfo({
    this.memoryBytes,
    this.availableMemoryBytes,
    required this.processors,
  });
  final int? memoryBytes;
  final int? availableMemoryBytes;
  final int processors;
  int? get memoryGb =>
      memoryBytes == null ? null : (memoryBytes! / 1073741824).round();

  static Future<ModelDeviceInfo> load() async {
    int? memory, available;
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        final data = await const MethodChannel(
          'com.example.video_player_app/model_tasks',
        ).invokeMapMethod<String, dynamic>('deviceInfo');
        memory = (data?['memoryBytes'] as num?)?.toInt();
        available = (data?['availableMemoryBytes'] as num?)?.toInt();
        if (available == 0) available = null;
      } else if (Platform.isWindows) {
        final buffer = calloc<_MemoryStatus>();
        try {
          buffer.ref.length = sizeOf<_MemoryStatus>();
          final read = DynamicLibrary.open('kernel32.dll')
              .lookupFunction<
                Int32 Function(Pointer<_MemoryStatus>),
                int Function(Pointer<_MemoryStatus>)
              >('GlobalMemoryStatusEx');
          if (read(buffer) != 0) {
            memory = buffer.ref.physical;
            available = buffer.ref.available;
          }
        } finally {
          calloc.free(buffer);
        }
      } else if (Platform.isLinux) {
        final text = await File('/proc/meminfo').readAsString();
        final match = RegExp(
          r'^MemTotal:\s+(\d+)\s+kB',
          multiLine: true,
        ).firstMatch(text);
        if (match != null) memory = int.parse(match[1]!) * 1024;
        final free = RegExp(
          r'^MemAvailable:\s+(\d+)\s+kB',
          multiLine: true,
        ).firstMatch(text);
        if (free != null) available = int.parse(free[1]!) * 1024;
      } else if (Platform.isMacOS) {
        final result = await Process.run('/usr/sbin/sysctl', [
          '-n',
          'hw.memsize',
        ]);
        if (result.exitCode == 0) {
          memory = int.tryParse('${result.stdout}'.trim());
        }
      }
    } catch (_) {
      /* Unknown RAM keeps every model available for manual selection. */
    }
    return ModelDeviceInfo(
      memoryBytes: memory,
      availableMemoryBytes: available,
      processors: Platform.numberOfProcessors,
    );
  }

  List<ModelArtifact> recommend(List<ModelArtifact> catalog, String language) {
    final ram = memoryGb;
    final eligible = catalog
        .where((m) => ram == null || m.suggestedRamGb <= ram)
        .toList();
    ModelArtifact? choose(ModelPurpose purpose) {
      final matches = eligible
          .where(
            (m) =>
                m.purpose == purpose &&
                (purpose == ModelPurpose.translation ||
                    language == 'auto' ||
                    m.languages.contains(language)),
          )
          .toList();
      if (matches.isEmpty) return null;
      // Prefer the dedicated compact translator and a Chinese-capable ASR for
      // automatic language. European languages can use Parakeet on larger RAM.
      final preferred = purpose == ModelPurpose.translation
          ? 'hy-mt2-1.8b-q4'
          : language != 'auto' &&
                !const ['zh', 'yue', 'ja', 'ko'].contains(language) &&
                (ram ?? 0) >= 8
          ? 'parakeet-v3-int8'
          : 'sensevoice-small-int8';
      return matches.where((m) => m.id == preferred).firstOrNull ??
          (matches..sort((a, b) => a.bytes.compareTo(b.bytes))).first;
    }

    return [
      ?choose(ModelPurpose.transcription),
      ?choose(ModelPurpose.translation),
    ];
  }
}
