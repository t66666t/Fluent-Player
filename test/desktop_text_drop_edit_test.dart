import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/desktop_text_drop_edit.dart';

void main() {
  TextEditingValue append(String original, int caret, String dropped) =>
      insertDesktopDroppedText(
        TextEditingValue(
          text: original,
          selection: TextSelection.collapsed(offset: caret),
        ),
        dropped,
        insertion: DesktopTextDropInsertion.appendLine,
      );

  test('empty and whitespace-only logical lines are filled directly', () {
    expect(append('', 0, '链接一').text, '链接一');
    expect(append(' \t ', 1, '链接一').text, '链接一');
    expect(append('前\n \t \n后', 4, '链接一').text, '前\n链接一\n后');
    expect(append('\n后', 0, '链接一').text, '链接一\n后');
  });

  test(
    'drops follow a complete line, preserving links and subsequent content',
    () {
      expect(
        append('https://example.com/first', 8, '第二条').text,
        'https://example.com/first\n第二条',
      );
      expect(append('前\n后', 1, '中').text, '前\n中\n后');
      expect(append('前\n \t \n后', 1, '中').text, '前\n中\n后');
      expect(append('前\n', 1, '中').text, '前\n中');
    },
  );

  test(
    'repeated drops advance the caret without blank lines or lost content',
    () {
      var value = const TextEditingValue(
        text: '原链接\n后面的链接',
        selection: TextSelection.collapsed(offset: 1),
      );
      for (final text in ['第一个', '第二个', '第三个']) {
        value = insertDesktopDroppedText(
          value,
          text,
          insertion: DesktopTextDropInsertion.appendLine,
        );
        expect(
          value.text[value.selection.extentOffset - 1],
          text[text.length - 1],
        );
      }
      expect(value.text, '原链接\n第一个\n第二个\n第三个\n后面的链接');
    },
  );

  test('reversed selections replace exactly the selected text', () {
    const value = TextEditingValue(
      text: '原来的名字',
      selection: TextSelection(baseOffset: 5, extentOffset: 0),
    );
    final result = insertDesktopDroppedText(
      value,
      '新名字😀',
      insertion: DesktopTextDropInsertion.appendLine,
    );
    expect(result.text, '新名字😀');
    expect(result.selection.extentOffset, result.text.length);
    expect(result.composing, TextRange.empty);
  });

  test('invalid ranges fall back to the end and Unicode is preserved', () {
    const value = TextEditingValue(text: '中文😀');
    final result = insertDesktopDroppedText(
      value,
      '繁體e\u0301',
      insertion: DesktopTextDropInsertion.appendLine,
    );
    expect(result.text, '中文😀\n繁體e\u0301');
    expect(result.selection.extentOffset, result.text.length);
  });

  test('line endings normalize; boundary blanks do not multiply', () {
    expect(append('原链接', 3, '\r\n第一\r\n第二\r第三\n').text, '原链接\n第一\n第二\n第三');
    expect(append('原链接', 3, ' \r\n ').text, '原链接');
  });

  test('normal editors insert at the caret without adding a newline', () {
    const value = TextEditingValue(
      text: '左右',
      selection: TextSelection.collapsed(offset: 1),
    );
    expect(insertDesktopDroppedText(value, '中\n间').text, '左中\n间右');
    expect(
      insertDesktopDroppedText(value, '中\r\n间', singleLine: true).text,
      '左中 间右',
    );
    expect(
      insertDesktopDroppedText(
        value,
        '新地址',
        insertion: DesktopTextDropInsertion.replaceAll,
      ).text,
      '新地址',
    );
  });
}
