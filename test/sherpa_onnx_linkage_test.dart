import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../tool/rebind_sherpa_onnx.dart';

void main() {
  for (final (is64, machine) in [
    (true, 183),
    (true, 62),
    (false, 40),
    (false, 3),
  ]) {
    test(
      'rebinds ELF${is64 ? 64 : 32} machine $machine without changing code',
      () {
        final consumer = _elf(is64: is64, machine: machine);
        final original = Uint8List.fromList(consumer);
        final provider = _elf(
          is64: is64,
          machine: machine,
          provider: true,
          version: 'VERS_1.23.2',
        );
        final before = OnnxElf(consumer).ortRequirements().single;
        final result = rebindSherpaOnnx(consumer, provider);
        final after = OnnxElf(result).ortRequirements().single;
        expect(after.name, 'VERS_1.23.2');
        expect(after.index, before.index);
        expect(
          OnnxElf(result).u32(after.hashOffset),
          elfVersionHash(after.name),
        );
        expect(
          OnnxElf(result).symbols()['OrtGetApiBase']?.version,
          after.index,
        );
        expect(
          consumer,
          original,
          reason: 'The Pub cache must remain unchanged',
        );
        for (var i = 0; i < result.length; i++) {
          if (i >= before.nameOffset &&
              i < before.nameOffset + before.name.length) {
            continue;
          }
          if (i >= before.hashOffset && i < before.hashOffset + 4) continue;
          expect(
            result[i],
            original[i],
            reason: 'Unexpected change at byte $i',
          );
        }
        expect(rebindSherpaOnnx(result, provider), result);
      },
    );
  }

  test(
    'rejects wrong architecture, unsupported versions and other ORT APIs',
    () {
      final consumer = _elf();
      for (final provider in [
        _elf(provider: true, machine: 62),
        _elf(provider: true, version: 'VERS_1.16.3'),
        _elf(provider: true, version: 'VERS_1.123.2'),
        _elf(provider: true, symbol: 'OtherApi'),
      ]) {
        expect(
          () => rebindSherpaOnnx(consumer, provider),
          throwsFormatException,
        );
      }
      final provider = _elf(provider: true, version: 'VERS_1.23.2');
      expect(
        () => rebindSherpaOnnx(_elf(version: 'VERS_1.18.1'), provider),
        throwsFormatException,
      );
      expect(
        () => rebindSherpaOnnx(_elf(symbol: 'OtherApi'), provider),
        throwsFormatException,
      );
      expect(() => OnnxElf(Uint8List(64)), throwsFormatException);
    },
  );

  test(
    'reads and rebinds the actual pinned Android prebuilts for all four ABIs',
    () {
      final config = File('.dart_tool/package_config.json').absolute.uri;
      final packages =
          jsonDecode(File.fromUri(config).readAsStringSync()) as Map;
      final package = (packages['packages'] as List).cast<Map>().singleWhere(
        (p) => p['name'] == 'sherpa_onnx_android',
      );
      final root = config.resolve('${package['rootUri']}/');
      for (final abi in ['arm64-v8a', 'armeabi-v7a', 'x86', 'x86_64']) {
        final directory = Directory.fromUri(
          root.resolve('android/src/main/jniLibs/$abi/'),
        );
        final nativeRuntime = File(
          '${directory.path}/libonnxruntime.so',
        ).readAsBytesSync();
        final runtime = OnnxElf(nativeRuntime);
        final provider = _elf(
          is64: runtime.is64,
          machine: runtime.machine,
          provider: true,
          version: 'VERS_1.23.2',
        );
        for (final name in [
          'libsherpa-onnx-c-api.so',
          'libsherpa-onnx-cxx-api.so',
        ]) {
          final source = File('${directory.path}/$name').readAsBytesSync();
          expect(rebindSherpaOnnx(source, nativeRuntime), source);
          final result = OnnxElf(rebindSherpaOnnx(source, provider));
          for (final requirement in result.ortRequirements()) {
            expect(requirement.name, 'VERS_1.23.2', reason: '$abi/$name');
            expect(
              result.u32(requirement.hashOffset),
              elfVersionHash(requirement.name),
            );
          }
        }
      }
    },
  );
}

/// Small real ELF section tables; no executable instructions are needed to
/// reproduce the versioned import/export mismatch in the shipped libraries.
Uint8List _elf({
  bool is64 = true,
  int machine = 183,
  bool provider = false,
  String version = 'VERS_1.17.1',
  String symbol = 'OrtGetApiBase',
}) {
  final sectionNames = <String>[
    '',
    '.shstrtab',
    '.dynstr',
    '.dynsym',
    '.gnu.version',
    provider ? '.gnu.version_d' : '.gnu.version_r',
  ];
  final names = ascii.encode('${sectionNames.join('\x00')}\x00');
  final strings = ascii.encode(
    '\x00libonnxruntime.so\x00$symbol\x00$version\x00',
  );
  final symbolName = strings.indexOf(symbol.codeUnitAt(0), 18);
  final versionName = strings.length - version.length - 1;
  final symbolStride = is64 ? 24 : 16;
  final symbols = ByteData(symbolStride * 2);
  symbols.setUint32(symbolStride, symbolName, Endian.little);
  symbols.setUint16(
    symbolStride + (is64 ? 6 : 14),
    provider ? 1 : 0,
    Endian.little,
  );
  final versions = ByteData(4)..setUint16(2, 2, Endian.little);
  final metadata = ByteData(provider ? 28 : 32);
  metadata.setUint16(0, 1, Endian.little);
  if (provider) {
    metadata.setUint16(4, 2, Endian.little);
    metadata.setUint16(6, 1, Endian.little);
    metadata.setUint32(8, elfVersionHash(version), Endian.little);
    metadata.setUint32(12, 20, Endian.little);
    metadata.setUint32(20, versionName, Endian.little);
  } else {
    metadata.setUint16(2, 1, Endian.little);
    metadata.setUint32(4, 1, Endian.little);
    metadata.setUint32(8, 16, Endian.little);
    metadata.setUint32(16, elfVersionHash(version), Endian.little);
    metadata.setUint16(22, 2, Endian.little);
    metadata.setUint32(24, versionName, Endian.little);
  }
  final payloads = [
    <int>[],
    names,
    strings,
    symbols.buffer.asUint8List(),
    versions.buffer.asUint8List(),
    metadata.buffer.asUint8List(),
  ];
  final headerSize = is64 ? 64 : 52;
  final sectionStride = is64 ? 64 : 40;
  final table = headerSize + payloads.fold<int>(0, (sum, p) => sum + p.length);
  final bytes = Uint8List(table + sectionStride * sectionNames.length);
  final data = ByteData.sublistView(bytes);
  void word(int at, int value) => is64
      ? data.setUint64(at, value, Endian.little)
      : data.setUint32(at, value, Endian.little);
  bytes.setRange(0, 6, [0x7f, 69, 76, 70, is64 ? 2 : 1, 1]);
  data.setUint16(18, machine, Endian.little);
  word(is64 ? 40 : 32, table);
  data.setUint16(is64 ? 58 : 46, sectionStride, Endian.little);
  data.setUint16(is64 ? 60 : 48, sectionNames.length, Endian.little);
  data.setUint16(is64 ? 62 : 50, 1, Endian.little);
  var cursor = headerSize;
  var nameOffset = 0;
  for (var i = 0; i < sectionNames.length; i++) {
    final at = table + i * sectionStride;
    data.setUint32(at, nameOffset, Endian.little);
    word(at + (is64 ? 24 : 16), cursor);
    word(at + (is64 ? 32 : 20), payloads[i].length);
    data.setUint32(at + (is64 ? 40 : 24), i == 4 ? 3 : 2, Endian.little);
    word(at + (is64 ? 56 : 36), i == 3 ? symbolStride : 0);
    bytes.setRange(cursor, cursor + payloads[i].length, payloads[i]);
    cursor += payloads[i].length;
    nameOffset += sectionNames[i].length + 1;
  }
  return bytes;
}
