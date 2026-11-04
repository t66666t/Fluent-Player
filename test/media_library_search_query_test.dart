import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/media_library_search_query.dart';

void main() {
  test('只匹配卡片自己的标题', () {
    final query = MediaLibrarySearchQuery('你');

    expect(query.matchesTitle('浙江大学翁恺教你C语言程序设计'), isTrue);
    expect(query.matchesTitle('6.1.5 编程练习解析 4-4：猜数游戏'), isFalse);
    expect(query.matchesTitle('4.1.1 循环：有些事情就得用循环才能解决'), isFalse);
  });

  test('多词查询采用规范化后的连续文字匹配而不是模糊匹配', () {
    final query = MediaLibrarySearchQuery('NBA   Finals');

    expect(query.matchesTitle('2026 NBA Finals 精彩集锦'), isTrue);
    expect(query.matchesTitle('Finals · NBA 精彩集锦'), isFalse);
  });

  test('英文匹配忽略大小写和首尾空白', () {
    final query = MediaLibrarySearchQuery('  nba  ');

    expect(query.matchesTitle('NBA Finals'), isTrue);
    expect(query.matchesTitle('WNBA Finals'), isTrue);
    expect(query.matchesTitle('篮球总决赛'), isFalse);
  });
}
