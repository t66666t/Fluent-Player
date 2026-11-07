import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/subtitle_debug_preset.dart';
import 'package:video_player_app/models/subtitle_font.dart';
import 'package:video_player_app/services/subtitle_debug_session.dart';
import 'package:video_player_app/services/subtitle_font_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'serif preset uses fallback until its optional font is installed',
    () async {
      SharedPreferences.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp(
        'optional_preset_font_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final fixture = await File(
        'test/fixtures/fonts/RobotoSlab-VariableFont_wght.ttf',
      ).readAsBytes();
      final library = SubtitleFontService(
        storageDirectory: directory,
        fontLoader: (_, _) async {},
        fetchBytes: (url, _, _) async => url.endsWith('/LICENSE')
            ? Uint8List.fromList(utf8.encode('Test license'))
            : fixture,
      );
      final session = SubtitleDebugSession(fontService: library);
      final original = subtitleDebugPresets.firstWhere(
        (preset) => preset.primaryFont == 'Noto Serif CJK SC',
      );
      expect(
        session.resolvedForDisplay(original.id).primaryFont,
        'Noto Sans SC',
      );

      final font = await library.download(
        SubtitleOnlineFont(
          name: 'Noto Serif SC',
          sourceUrl: 'https://example.test/serif',
          files: const ['https://example.test/font.ttf'],
          hashes: [sha256.convert(fixture).toString()],
          licenseFile: 'https://example.test/LICENSE',
        ),
        cancel: CancelToken(),
      );
      final resolved = session.resolvedForDisplay(original.id);
      expect(resolved.primaryFont, font.id);
      expect(resolved.styleFor().textStyle.fontFamilyChinese, font.id);
      final restored = SubtitleDebugPreset.restore(resolved.toJson());
      expect(restored?.primaryFont, font.id);
      expect(restored?.styleFor().textStyle.fontFamilyChinese, font.id);
    },
  );
}
