import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/utils/bilibili_text.dart';

void main() {
  test('source metadata survives copying and can be cleared explicitly', () {
    const source = MediaSourceRef(
      value: 'BV1xx411c7mD',
      kind: MediaSourceKind.bilibiliStream,
      cid: 1001,
      page: 1,
      bilibiliVideoTitle: '完整课程',
      bilibiliPartTitle: '课程介绍',
      bilibiliPartCount: 12,
    );
    final restored = MediaSourceRef.fromJson(
      source.toJson(),
    ).copyWith(cid: 1002);
    expect(restored.bilibiliVideoTitle, '完整课程');
    expect(restored.bilibiliPartTitle, '课程介绍');
    expect(restored.bilibiliPartCount, 12);
    final cleared = restored.copyWith(
      bilibiliVideoTitle: null,
      bilibiliPartTitle: null,
      bilibiliPartCount: null,
    );
    expect(cleared.toJson().containsKey('bilibiliVideoTitle'), isFalse);
    expect(cleared.toJson().containsKey('bilibiliPartTitle'), isFalse);
    expect(cleared.toJson().containsKey('bilibiliPartCount'), isFalse);
  });

  test('older source records need no title metadata', () {
    final source = MediaSourceRef.fromJson({
      'value': 'BV1xx411c7mD',
      'kind': 'bilibiliStream',
      'cid': 1001,
      'page': 1,
    });
    expect(source.bilibiliVideoTitle, isNull);
    expect(source.bilibiliPartTitle, isNull);
    expect(source.bilibiliPartCount, isNull);
    expect(source.cid, 1001);
    expect(source.page, 1);
    expect(source.toJson().containsKey('bilibiliPartCount'), isFalse);
  });

  test('multipart titles identify both the video and the selected part', () {
    expect(
      formatBilibiliMediaTitle(
        videoTitle: '完整课程',
        partTitle: '课程介绍',
        page: 1,
        partCount: 12,
      ),
      '完整课程 · P1 课程介绍',
    );
    expect(
      formatBilibiliMediaTitle(
        videoTitle: '完整课程',
        partTitle: '练习',
        page: 12,
        partCount: 12,
      ),
      '完整课程 · P12 练习',
    );
  });

  test('missing or duplicate part names still retain the part number', () {
    for (final title in ['', '  ', '完整课程']) {
      expect(
        formatBilibiliMediaTitle(
          videoTitle: '完整课程',
          partTitle: title,
          page: 2,
          partCount: 3,
        ),
        '完整课程 · P2',
      );
    }
    expect(
      formatBilibiliMediaTitle(
        videoTitle: ' ',
        partTitle: '课程介绍',
        page: 1,
        partCount: 3,
      ),
      'P1 课程介绍',
    );
  });

  test('a single-part video keeps its original title', () {
    expect(
      formatBilibiliMediaTitle(
        videoTitle: '视频原名 / 副标题',
        partTitle: '默认分P名',
        page: 1,
        partCount: 1,
      ),
      '视频原名 / 副标题',
    );
  });
}
