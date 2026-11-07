import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/app_licenses.dart';
import 'package:video_player_app/services/subtitle_font_service.dart';
import 'package:video_player_app/utils/subtitle_font_parser.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'bundled fonts use one variable face and keep a full CJK fallback',
    () async {
      final manifest =
          jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
      List<Map<String, dynamic>> faces(String family) =>
          (manifest.singleWhere((node) => node['family'] == family)['fonts']
                  as List)
              .cast<Map<String, dynamic>>();

      for (final family in ['Noto Sans SC', 'App Reading']) {
        expect(
          faces(family).single['asset'],
          'assets/fonts/NotoSansSC-Variable.ttf',
        );
      }
      expect(
        faces('Noto Sans CJK Fallback').single['asset'],
        'assets/fonts/NotoSansCJKsc-Regular.otf',
      );
      expect(
        faces('Swei Gothic CJK SC').single['asset'],
        'assets/fonts/SweiGothicCJKsc-Bold.ttf',
      );
      expect(manifest.where((node) => node['family'] == 'MiSans'), isEmpty);
      expect(
        manifest.where((node) => node['family'] == 'Noto Serif CJK SC'),
        isEmpty,
      );
      final bundledAssets =
          (await AssetManifest.loadFromAssetBundle(rootBundle)).listAssets();
      expect(
        bundledAssets.where(
          (path) => RegExp(
            r'^assets/fonts/(MiSans-.*|NotoSerifCJKsc-.*)\.otf$',
          ).hasMatch(path),
        ),
        isEmpty,
      );

      final data = await rootBundle.load(
        'assets/fonts/NotoSansSC-Variable.ttf',
      );
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      expect(
        sha256.convert(bytes).toString(),
        'a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da',
      );
      final variable = parseSubtitleFont(bytes);
      expect(variable.variableWeightRange, (100, 900));
      final noto = SubtitleFontService.bundled.singleWhere(
        (font) => font.id == 'Noto Sans SC',
      );
      expect((noto.variableWeightMin, noto.variableWeightMax), (100, 900));
      expect(noto.hasVariableWeight, isTrue);

      final fallbackData = await rootBundle.load(
        'assets/fonts/NotoSansCJKsc-Regular.otf',
      );
      final fallback = parseSubtitleFont(
        fallbackData.buffer.asUint8List(
          fallbackData.offsetInBytes,
          fallbackData.lengthInBytes,
        ),
      );
      bool covers(List<List<int>> ranges, String value) => ranges.any(
        (range) =>
            value.runes.first >= range[0] && value.runes.first <= range[1],
      );
      expect(covers(variable.coverage, '字'), isTrue);
      expect(covers(variable.coverage, '한'), isFalse);
      expect(covers(fallback.coverage, '한'), isTrue);

      registerAppLicenses();
      final names = (await LicenseRegistry.licenses.toList())
          .expand((entry) => entry.packages)
          .toSet();
      expect(names, contains('Noto Sans SC variable'));
    },
  );
}
