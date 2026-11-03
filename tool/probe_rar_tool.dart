import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

Uint8List storeRar(String name, List<int> data) {
  List<int> vint(int value) {
    final out = <int>[];
    var rest = value;
    while (true) {
      var bite = rest & 0x7f;
      rest >>= 7;
      if (rest != 0) bite |= 0x80;
      out.add(bite);
      if (rest == 0) break;
    }
    return out;
  }

  int crc32(List<int> input) {
    var crc = 0xffffffff;
    for (final bite in input) {
      crc ^= bite;
      for (var i = 0; i < 8; i++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
      }
    }
    return (crc ^ 0xffffffff) & 0xffffffff;
  }

  List<int> u32(int value) => [
    value & 0xff,
    (value >> 8) & 0xff,
    (value >> 16) & 0xff,
    (value >> 24) & 0xff,
  ];
  List<int> block(List<int> fromType) {
    final covered = [...vint(fromType.length), ...fromType];
    return [...u32(crc32(covered)), ...covered];
  }

  final encodedName = utf8.encode(name);
  final file = block([
    ...vint(2),
    ...vint(0x0002),
    ...vint(data.length),
    ...vint(0x0004),
    ...vint(data.length),
    ...vint(0),
    ...u32(crc32(data)),
    ...vint(0),
    ...vint(0),
    ...vint(encodedName.length),
    ...encodedName,
  ]);
  return Uint8List.fromList([
    0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x01, 0x00,
    ...block([...vint(1), ...vint(0), ...vint(0)]),
    ...file,
    ...data,
    ...block([...vint(5), ...vint(0), ...vint(0)]),
  ]);
}

void main() {
  final bytes = storeRar(
    '01.srt',
    utf8.encode('1\n00:00:01,000 --> 00:00:03,000\nこんにちは。\n\n'),
  );
  final dir = Directory('build/subtitle_unrar/sample')..createSync(recursive: true);
  final rar = File('${dir.path}/sample.rar')..writeAsBytesSync(bytes);
  final out = Directory('${dir.path}/out')..createSync();
  final result = Process.runSync(
    'native/subtitle_archive/prebuilt/windows-x64/subtitle_unrar_tool.exe',
    [rar.path, out.path],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  stdout.writeln('exit ${result.exitCode}');
  stdout.writeln(result.stdout);
  stdout.writeln(result.stderr);
  for (final file in out.listSync()) {
    stdout.writeln('file ${file.path} ${file.statSync().size}');
  }
}
