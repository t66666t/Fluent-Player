// Rebind the pinned sherpa prebuilt's ELF symbol version to the ORT selected
// by Gradle. ORT's GetApi(17) is backwards compatible, but its ELF export tag
// changes with every release. This edits generated copies, never the Pub cache.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class ElfSection {
  const ElfSection(
    this.name,
    this.offset,
    this.size,
    this.link,
    this.entrySize,
  );

  final String name;
  final int offset;
  final int size;
  final int link;
  final int entrySize;
}

class ElfSymbolVersion {
  const ElfSymbolVersion(
    this.name,
    this.index,
    this.hashOffset,
    this.nameOffset,
  );

  final String name;
  final int index;
  final int hashOffset;
  final int nameOffset;
}

/// Only the little-endian ELF32/ELF64 metadata used by the Android prebuilts.
class OnnxElf {
  OnnxElf(this.bytes) : data = ByteData.sublistView(bytes) {
    if (bytes.length < 52 ||
        bytes[0] != 0x7f ||
        ascii.decode(bytes.sublist(1, 4)) != 'ELF' ||
        ![1, 2].contains(bytes[4]) ||
        bytes[5] != 1) {
      throw const FormatException('Expected a little-endian ELF library');
    }
    is64 = bytes[4] == 2;
    final table = word(is64 ? 40 : 32);
    final stride = u16(is64 ? 58 : 46);
    final count = u16(is64 ? 60 : 48);
    final namesIndex = u16(is64 ? 62 : 50);
    if (count == 0 || namesIndex >= count || stride < (is64 ? 64 : 40)) {
      throw const FormatException('Invalid ELF section table');
    }
    check(table, stride * count);
    final namesAt = table + namesIndex * stride;
    final names = word(namesAt + (is64 ? 24 : 16));
    for (var i = 0; i < count; i++) {
      final at = table + i * stride;
      final section = ElfSection(
        string(names + u32(at)),
        word(at + (is64 ? 24 : 16)),
        word(at + (is64 ? 32 : 20)),
        u32(at + (is64 ? 40 : 24)),
        word(at + (is64 ? 56 : 36)),
      );
      sections.add(section);
    }
  }

  final Uint8List bytes;
  final ByteData data;
  late final bool is64;
  final List<ElfSection> sections = [];

  int get machine => u16(18);

  void check(int offset, int length) {
    if (offset < 0 || length < 0 || offset + length > bytes.length) {
      throw const FormatException('ELF metadata is outside the file');
    }
  }

  int u16(int at) {
    check(at, 2);
    return data.getUint16(at, Endian.little);
  }

  int u32(int at) {
    check(at, 4);
    return data.getUint32(at, Endian.little);
  }

  int word(int at) {
    check(at, is64 ? 8 : 4);
    return is64 ? data.getUint64(at, Endian.little) : u32(at);
  }

  String string(int at) {
    check(at, 1);
    final end = bytes.indexOf(0, at);
    if (end < 0) throw const FormatException('Unterminated ELF string');
    return ascii.decode(bytes.sublist(at, end));
  }

  ElfSection? section(String name) {
    for (final section in sections) {
      if (section.name == name) return section;
    }
    return null;
  }

  ElfSection strings(ElfSection section) {
    if (section.link >= sections.length) {
      throw const FormatException('Invalid ELF string table link');
    }
    return sections[section.link];
  }

  /// Version requirements associated specifically with libonnxruntime.so.
  List<ElfSymbolVersion> ortRequirements() {
    final ver = section('.gnu.version_r');
    if (ver == null) return [];
    final names = strings(ver).offset;
    final result = <ElfSymbolVersion>[];
    for (var at = ver.offset; at < ver.offset + ver.size;) {
      check(at, 16);
      if (string(names + u32(at + 4)) == 'libonnxruntime.so') {
        var aux = at + u32(at + 8);
        for (var i = 0; i < u16(at + 2); i++) {
          check(aux, 16);
          result.add(
            ElfSymbolVersion(
              string(names + u32(aux + 8)),
              u16(aux + 6) & 0x7fff,
              aux,
              names + u32(aux + 8),
            ),
          );
          aux += u32(aux + 12);
        }
      }
      final next = u32(at + 12);
      if (next == 0) break;
      at += next;
    }
    return result;
  }

  Map<int, String> definitions() {
    final ver = section('.gnu.version_d');
    if (ver == null) return {};
    final names = strings(ver).offset;
    final result = <int, String>{};
    for (var at = ver.offset; at < ver.offset + ver.size;) {
      check(at, 20);
      result[u16(at + 4) & 0x7fff] = string(names + u32(at + u32(at + 12)));
      final next = u32(at + 16);
      if (next == 0) break;
      at += next;
    }
    return result;
  }

  /// A symbol's version index and whether it is defined in this library.
  Map<String, ({int version, bool defined})> symbols() {
    final sym = section('.dynsym');
    final ver = section('.gnu.version');
    if (sym == null || ver == null || sym.entrySize < (is64 ? 24 : 16)) {
      throw const FormatException('Missing ELF dynamic symbol versions');
    }
    final names = strings(sym).offset;
    final result = <String, ({int version, bool defined})>{};
    for (var i = 0; i < sym.size ~/ sym.entrySize; i++) {
      final at = sym.offset + i * sym.entrySize;
      result[string(names + u32(at))] = (
        version: u16(ver.offset + i * 2) & 0x7fff,
        defined: u16(at + (is64 ? 6 : 14)) != 0,
      );
    }
    return result;
  }
}

int elfVersionHash(String value) {
  var hash = 0;
  for (final byte in ascii.encode(value)) {
    hash = (hash << 4) + byte;
    final high = hash & 0xf0000000;
    if (high != 0) hash ^= high >> 24;
    hash &= ~high;
  }
  return hash;
}

/// Return a new library with only the OrtGetApiBase requirement's version name
/// and ELF hash changed. Reject other ORT entry points and unknown source ABIs.
Uint8List rebindSherpaOnnx(Uint8List consumerBytes, Uint8List runtimeBytes) {
  final consumer = OnnxElf(consumerBytes);
  final runtime = OnnxElf(runtimeBytes);
  if (consumer.machine != runtime.machine || consumer.is64 != runtime.is64) {
    throw const FormatException('Sherpa and ONNX Runtime architectures differ');
  }
  final requirements = consumer.ortRequirements();
  if (requirements.isEmpty) return Uint8List.fromList(consumerBytes);
  if (requirements.length != 1) {
    throw const FormatException('Expected one sherpa ORT version requirement');
  }
  final requirement = requirements.single;
  final imports = consumer.symbols().entries.where(
    (entry) => !entry.value.defined && entry.value.version == requirement.index,
  );
  if (imports.length != 1 || imports.single.key != 'OrtGetApiBase') {
    throw const FormatException(
      'Only the stable OrtGetApiBase ABI may be rebound',
    );
  }
  final export = runtime.symbols()['OrtGetApiBase'];
  final version = export == null || !export.defined
      ? null
      : runtime.definitions()[export.version];
  if (version == null ||
      !RegExp(r'^VERS_1\.(\d+)\.\d+$').hasMatch(version) ||
      int.parse(version.split('.')[1]) < 17 ||
      version.length != requirement.name.length) {
    throw FormatException('Unsupported ONNX Runtime C API export: $version');
  }
  if (requirement.name != 'VERS_1.17.1' && requirement.name != version) {
    throw const FormatException('Expected the pinned sherpa ORT 1.17.1 ABI');
  }
  final result = Uint8List.fromList(consumerBytes);
  result.setRange(
    requirement.nameOffset,
    requirement.nameOffset + version.length,
    ascii.encode(version),
  );
  ByteData.sublistView(
    result,
  ).setUint32(requirement.hashOffset, elfVersionHash(version), Endian.little);
  return result;
}

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('Usage: rebind_sherpa_onnx.dart generatedJniDir ortJniDir');
    exitCode = 64;
    return;
  }
  final sherpa = Directory(args[0]);
  final runtime = Directory(args[1]);
  var count = 0;
  for (final library in sherpa.listSync(recursive: true).whereType<File>()) {
    if (!library.path.endsWith('.so')) continue;
    final abi = library.parent.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final provider = File('${runtime.path}/$abi/libonnxruntime.so');
    if (!provider.existsSync()) {
      throw StateError('ONNX Runtime is missing the $abi ABI');
    }
    final original = library.readAsBytesSync();
    final rebound = rebindSherpaOnnx(original, provider.readAsBytesSync());
    library.writeAsBytesSync(rebound, flush: true);
    count++;
  }
  if (count == 0) {
    throw StateError('No generated sherpa native libraries found');
  }
  stdout.writeln(
    'Validated ORT symbol versions in $count sherpa native libraries',
  );
}
