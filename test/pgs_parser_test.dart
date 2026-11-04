import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/pgs_parser.dart';

List<int> _u16(int n) => [n >> 8, n & 255];
List<int> _segment(int type, List<int> payload, {int pts = 90000}) => [
  0x50,
  0x47,
  (pts >> 24) & 255,
  (pts >> 16) & 255,
  (pts >> 8) & 255,
  pts & 255,
  0,
  0,
  0,
  0,
  type,
  ..._u16(payload.length),
  ...payload,
];
List<int> _ods(int id, int width, int height, List<int> rle) => [
  ..._u16(id),
  0,
  0xc0,
  0,
  0,
  rle.length + 4,
  ..._u16(width),
  ..._u16(height),
  ...rle,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  setUp(
    () async => temp = await Directory.systemTemp.createTemp('pgs-parser-'),
  );
  tearDown(() async => temp.delete(recursive: true));

  test(
    'composites multiple objects, crop rectangles and empty RLE rows',
    () async {
      final file = File('${temp.path}/multi.sup');
      await file.writeAsBytes([
        ..._segment(0x16, [
          ..._u16(3),
          ..._u16(2),
          0,
          0,
          0,
          0x80,
          0,
          0,
          2,
          ..._u16(1),
          0,
          0,
          ..._u16(0),
          ..._u16(0),
          ..._u16(2),
          0,
          0x80,
          ..._u16(2),
          ..._u16(1),
          ..._u16(1),
          ..._u16(0),
          ..._u16(1),
          ..._u16(1),
        ]),
        ..._segment(0x14, [0, 0, 1, 76, 255, 85, 255, 2, 150, 21, 44, 255]),
        // A first fragment has an 11-byte header; its continuation only has four.
        ..._segment(0x15, [..._u16(1), 0, 0x80, 0, 0, 9, 0, 1, 0, 2, 0, 0]),
        ..._segment(0x15, [..._u16(1), 0, 0x40, 1, 0, 0]),
        ..._segment(0x15, _ods(2, 2, 1, [1, 2, 0, 0])),
        ..._segment(0x80, []),
        ..._segment(0x16, [0, 3, 0, 2, 0, 0, 1, 0, 0, 0, 0], pts: 270000),
        ..._segment(0x80, [], pts: 270000),
      ]);
      final subtitles = await PgsParser.parse(file.path);
      expect(subtitles, hasLength(1));
      expect(subtitles.single.startTime, const Duration(seconds: 1));
      expect(subtitles.single.endTime, const Duration(seconds: 3));
      final bmp = (await subtitles.single.imageLoader!())!;
      final view = ByteData.sublistView(bmp);
      int pixel(int x, int y) =>
          view.getUint32(54 + (y * 3 + x) * 4, Endian.little);
      expect(pixel(0, 0), 0);
      expect(pixel(1, 0), 0);
      expect(pixel(2, 0), 0);
      expect((pixel(0, 1) >> 16) & 255, greaterThan(240));
      expect(pixel(1, 1), 0);
      expect((pixel(2, 1) >> 8) & 255, greaterThan(240));
    },
  );

  test('rejects impossible dimensions before allocating a bitmap', () {
    expect(
      () => PgsPcs.parse(
        ByteData.sublistView(
          Uint8List.fromList([255, 255, 255, 255, 0, 0, 0, 0, 0, 0, 0]),
        ),
        0,
      ),
      throwsFormatException,
    );
  });

  test(
    'reports truncated composition and object data as format errors',
    () async {
      expect(
        () => PgsPcs.parse(
          ByteData.sublistView(
            Uint8List.fromList([0, 3, 0, 2, 0, 0, 0, 0, 0, 0, 1]),
          ),
          0,
        ),
        throwsFormatException,
      );
      final file = File('${temp.path}/truncated.sup');
      await file.writeAsBytes(
        _segment(0x15, [0, 1, 0, 0xc0, 0, 0, 6, 0, 1, 0, 1, 1]),
      );
      await expectLater(PgsParser.parse(file.path), throwsFormatException);
    },
  );
}
