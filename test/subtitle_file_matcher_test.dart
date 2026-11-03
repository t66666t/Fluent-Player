import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/subtitle_file_matcher.dart';

void main() {
  SubtitleFileNameAnalysis check(String videoStem, String subtitleStem) {
    return SubtitleFileMatcher.analyzeStems(
      videoStem: videoStem,
      subtitleStem: subtitleStem,
    );
  }

  group('基础同名匹配', () {
    test('完全同名自动匹配', () {
      expect(check('Movie', 'Movie').isAuto, isTrue);
      expect(check('Movie', 'movie').isAuto, isTrue);
      expect(check('Star.Wars', 'Star Wars').isAuto, isTrue);
    });

    test('不同扩展名不影响匹配（扩展名由服务层过滤）', () {
      expect(check('Movie', 'Movie').isAuto, isTrue);
    });
  });

  group('装饰符号前缀（用户核心痛点）', () {
    test('中括号/括号/中文括号前缀被容忍', () {
      expect(check('Movie', '【字幕组】Movie').isAuto, isTrue);
      expect(check('Movie', '[VCB-Studio] Movie').isAuto, isTrue);
      expect(check('Movie', '（搬运）Movie.chs').isAuto, isTrue);
      expect(check('Movie', '[A][B] Movie.en').isAuto, isTrue);
    });

    test('视频名自带发布组前缀时同样可配到无前缀字幕', () {
      expect(check('[VCB-Studio] Movie', 'Movie').isAuto, isTrue);
      expect(check('[VCB-Studio] Movie', '[VCB-Studio] Movie.cht').isAuto, isTrue);
    });

    test('整名都写在括号里时要求逐字一致', () {
      expect(check('[REC]', '[REC]').isAuto, isTrue);
      expect(check('[REC]', '[ABC]').isRejected, isTrue);
    });
  });

  group('语言标记与语言权重', () {
    test('中文/英文等语言后缀可匹配', () {
      expect(check('Movie', 'Movie.zh-CN').isAuto, isTrue);
      expect(check('Movie', 'Movie.chs').isAuto, isTrue);
      expect(check('Movie', 'Movie.cht').isAuto, isTrue);
      expect(check('Movie', 'Movie [English]').isAuto, isTrue);
      expect(check('Movie', 'Movie.en.sdh').isAuto, isTrue);
    });

    test('语言权重：简体 > 繁体 > 无标记 > 英文 > 其它', () {
      expect(
        check('Movie', 'Movie.zh').languageRank,
        lessThan(check('Movie', 'Movie').languageRank),
      );
      expect(
        check('Movie', 'Movie').languageRank,
        lessThan(check('Movie', 'Movie.en').languageRank),
      );
      expect(
        check('Movie', 'Movie.zh').languageCode,
        'zh-Hans',
      );
      expect(
        check('Movie', 'Movie.cht').languageCode,
        'zh-Hant',
      );
    });

    test('标题中恰好出现语言单词不误判（仅剥离最尾部标记）', () {
      expect(check('The English Patient', 'The English Patient.en').isAuto,
          isTrue);
      expect(check('The English Patient', 'The English Patient').isAuto,
          isTrue);
    });
  });

  group('发布信息/年份', () {
    test('字幕省略视频发布后缀被接受', () {
      expect(
        check(
          'Movie.2024.1080p.BluRay.x264-GRP',
          'Movie',
        ).isAuto,
        isTrue,
      );
      expect(
        check(
          'Movie.2024.1080p.BluRay.x264-AMIABLE',
          'Movie.chs',
        ).isAuto,
        isTrue,
      );
    });

    test('两侧年份一致可匹配', () {
      expect(check('Movie.2024', 'Movie.2024').isAuto, isTrue);
      expect(
        check('Movie (2024)', 'Movie (2024).chs').isAuto,
        isTrue,
      );
    });

    test('年份冲突/单侧年份硬性拒绝', () {
      expect(check('Movie', 'Movie.1977').isRejected, isTrue);
      expect(check('Movie.2024', 'Movie.1977').isRejected, isTrue);
      expect(check('Star Wars', 'Star Wars 1977').isRejected, isTrue);
    });
  });

  group('防误匹配（衍生/续集/其它视频）', () {
    test('罗马数字/阿拉伯数字续集绝不允许自动', () {
      expect(check('Star Wars', 'Star Wars II').isAuto, isFalse);
      expect(check('Movie', 'Movie 2').isAuto, isFalse);
      expect(check('Movie', 'Movie.Part.2').isAuto, isFalse);
    });

    test('字符粘连不成词不匹配', () {
      expect(check('Movie', 'MovieBook').isRejected, isTrue);
      expect(check('Movie', 'MovieTrailer').isRejected, isTrue);
      expect(check('Movie', 'Movie2').isRejected, isTrue);
    });

    test('其它电影的无关字幕被拒绝', () {
      expect(check('Movie', 'Other Movie').isRejected, isTrue);
      expect(check('Episode 01', 'Episode 010').isRejected, isTrue);
    });

    test('副本/重复/下载标记只允许手动', () {
      expect(check('Movie', 'Movie (1)').isManual, isTrue);
      expect(check('Movie', 'Movie - 副本').isManual, isTrue);
      expect(check('Movie', 'Movie copy').isManual, isTrue);
    });

    test('高度相似但缺少可靠身份证据的只允许手动', () {
      expect(check('Episode 02', 'Episode 02 (2)').isManual, isTrue);
      // 明显不同的电影仍应被拒绝（不因共享一个词而升级为"相似"）。
      expect(check('Movie', 'Other Movie').isRejected, isTrue);
      expect(check('Movie', 'Movie Prequel Story').isRejected, isTrue);
    });
  });

  group('结构化曲目号自动匹配（音乐专辑命名污染）', () {
    test('媒体带 [L] 标签、歌词带源容器+重复曲目号 → 自动匹配', () {
      expect(
        check('01. Good Morning [L]', '01. 01. Good Morning.m4a').isAuto,
        isTrue,
      );
      expect(
        check('02. Champion [L]', '02. 02. Champion.m4a').isAuto,
        isTrue,
      );
      expect(
        check('13. Big Brother [L]', '13. 13. Big Brother.m4a').isAuto,
        isTrue,
      );
      expect(check('Song [L]', 'Song.flac').isAuto, isTrue);
    });

    test('不同曲目号/不同标题绝不自动配对（防错配）', () {
      expect(
        check('01. Good Morning [L]', '02. 02. Champion.m4a').isAuto,
        isFalse,
      );
      expect(
        check('01. Good Morning [L]', '02. 02. Champion.m4a').isRejected,
        isTrue,
      );
      expect(
        check('01. Good Morning [L]', '01. 01. Champion.m4a').isAuto,
        isFalse,
      );
      expect(
        check('02. Champion [L]', '12. Homecoming (feat. Chris Martin).m4a')
            .isRejected,
        isTrue,
      );
    });

    test('多字符罗马数字/续集编号不会被当标签剥离而错配', () {
      expect(check('Star Wars [II]', 'Star Wars').isAuto, isFalse);
      expect(check('Star Wars [IV]', 'Star Wars').isAuto, isFalse);
      expect(check('Star Wars [II]', 'Star Wars').isManual, isTrue);
    });

    test('语言短标签如 [CHS] 仍被保留用于语言排序', () {
      final zh = check('Movie', 'Movie [CHS]');
      expect(zh.isAuto, isTrue);
      expect(zh.languageCode, 'zh-Hans');
      final en = check('Movie', 'Movie [EN]');
      expect(en.isAuto, isTrue);
      expect(en.languageCode, 'en');
    });
  });

  group('分 P 轨道与剧集', () {
    test('视频普通文件时 stream_N 轨道字幕被排除', () {
      expect(check('Movie', 'Movie.stream_0').isRejected, isTrue);
      expect(check('Movie', 'Movie.stream_1.chs').isRejected, isTrue);
    });

    test('视频本身是 stream 文件时按正常规则匹配', () {
      expect(check('Movie.stream_0', 'Movie.stream_0').isAuto, isTrue);
      expect(
        check('Movie.stream_0', 'Movie.stream_0.chs').isAuto,
        isTrue,
      );
    });

    test('剧集 S/E 编号逐字一致匹配', () {
      expect(check('Show.S01E01', 'Show.S01E01.chs').isAuto, isTrue);
      expect(check('Show - 04', 'Show - 04.zh-Hans').isAuto, isTrue);
    });
  });

  group('中文标题', () {
    test('中文主名与中文装饰前缀', () {
      expect(check('流浪地球', '流浪地球').isAuto, isTrue);
      expect(check('流浪地球', '【精校】流浪地球.chs').isAuto, isTrue);
      expect(check('流浪地球', '流浪地球2').isRejected, isTrue);
    });
  });

  group('边缘空主干', () {
    test('空串输入按拒绝处理且不抛异常', () {
      expect(check('', '').isRejected, isTrue);
      expect(check('Movie', '').isRejected, isTrue);
    });
  });
}
