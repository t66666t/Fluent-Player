import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/folder_placeholder_style.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('封面文字会去掉书名号并取有意义的两字，而不是第一个符号', () {
    expect(FolderPlaceholderLook.autoLabelFor('日剧'), '日剧');
    expect(FolderPlaceholderLook.autoLabelFor('数学'), '数学');
    expect(FolderPlaceholderLook.autoLabelFor('《三国演义》'), '三国');
    expect(FolderPlaceholderLook.autoLabelFor('【课程】'), '课程');
    expect(FolderPlaceholderLook.autoLabelFor('Movies'), 'Mo');
    expect(FolderPlaceholderLook.autoLabelFor('music'), 'Mu');
    expect(FolderPlaceholderLook.autoLabelFor('NBA'), 'NB');
    expect(FolderPlaceholderLook.autoLabelFor('2024'), '20');
    expect(FolderPlaceholderLook.autoLabelFor('2024数学'), '数学');
    expect(FolderPlaceholderLook.autoLabelFor('Harry Potter'), 'HP');
    expect(FolderPlaceholderLook.autoLabelFor(''), '');
    expect(FolderPlaceholderLook.autoLabelFor('   '), '');
    expect(FolderPlaceholderLook.autoLabelFor('《》'), '');
    expect(
      FolderPlaceholderLook.autoLabelFor('《三国演义》', maxLength: 4),
      '三国演义',
    );
    expect(FolderPlaceholderLook.autoLabelFor('NBA', maxLength: 4), 'NBA');
    expect(FolderPlaceholderLook.autoLabelFor('2024', maxLength: 4), '2024');
    expect(FolderPlaceholderLook.autoLabelFor('数学', maxLength: 1), '数');
  });

  test('封面文字不论字数都用四字那一档的字号', () {
    double sizeOf(String glyph, [FolderPlaceholderPaintStyle style =
        FolderPlaceholderPaintStyle.letterBlock]) {
      return FolderPlaceholderLook.glyphSize(
        basis: 90,
        glyph: glyph,
        multiplier: 1,
        paintStyle: style,
      );
    }

    expect(sizeOf('数'), closeTo(sizeOf('数学'), 0.001));
    expect(sizeOf('周杰伦'), closeTo(sizeOf('数学'), 0.001));
    expect(sizeOf('数学大题'), closeTo(sizeOf('数学'), 0.001));
    expect(
      sizeOf('数', FolderPlaceholderPaintStyle.gradientGhost),
      closeTo(sizeOf('乔布斯传', FolderPlaceholderPaintStyle.gradientGhost), 0.001),
    );
    expect(sizeOf('K') / sizeOf('数'), closeTo(0.96, 0.001));
    expect(sizeOf('Em') / sizeOf('数学'), closeTo(0.96, 0.001));
  });

  test('封面文字可被文件夹覆盖，也可被全局开关关掉', () {
    expect(
      FolderPlaceholderLook.displayLabel(
        folderName: '《三国演义》',
        coverLabel: null,
        showCoverText: true,
      ),
      '三国',
    );
    expect(
      FolderPlaceholderLook.displayLabel(
        folderName: '《三国演义》',
        coverLabel: '演义',
        showCoverText: true,
      ),
      '演义',
    );
    expect(
      FolderPlaceholderLook.displayLabel(
        folderName: '数学',
        coverLabel: '',
        showCoverText: true,
      ),
      '',
    );
    expect(
      FolderPlaceholderLook.displayLabel(
        folderName: '数学',
        coverLabel: '数',
        showCoverText: false,
      ),
      '',
    );
    expect(FolderPlaceholderLook.clampLabel('三国演义全套'), '三国');
    expect(
      FolderPlaceholderLook.clampLabel('三国演义全套', maxLength: 4),
      '三国演义',
    );
  });

  test('同一 id 颜色稳定，切换风格只改饱和度与亮度，色相保持对齐', () {
    const id = 'collection-stable-id';
    final mutedA = FolderPlaceholderLook.swatchFor(
      folderId: id,
      colorStyle: FolderPlaceholderColorStyle.muted,
    );
    final mutedB = FolderPlaceholderLook.swatchFor(
      folderId: id,
      colorStyle: FolderPlaceholderColorStyle.muted,
    );
    expect(mutedA.accent, mutedB.accent);

    final mutedHsl = HSLColor.fromColor(mutedA.accent);
    final vividHsl = HSLColor.fromColor(
      FolderPlaceholderLook.swatchFor(
        folderId: id,
        colorStyle: FolderPlaceholderColorStyle.vivid,
      ).accent,
    );
    final pastelHsl = HSLColor.fromColor(
      FolderPlaceholderLook.swatchFor(
        folderId: id,
        colorStyle: FolderPlaceholderColorStyle.pastel,
      ).accent,
    );
    expect(vividHsl.hue, closeTo(mutedHsl.hue, 0.6));
    expect(pastelHsl.hue, closeTo(mutedHsl.hue, 0.6));
    expect(vividHsl.saturation, greaterThan(mutedHsl.saturation));
    expect(pastelHsl.lightness, greaterThan(mutedHsl.lightness));
  });

  test('一批不同 id 几乎不会撞成完全相同的强调色', () {
    final ids = <String>[
      for (var i = 0; i < 48; i++) 'collection-$i',
      'preview-riju',
      'preview-movies',
      'preview-music',
      'preview-math',
      'preview-sanguo',
      'preview-2024',
    ];
    final colors = ids
        .map(
          (id) => FolderPlaceholderLook.swatchFor(
            folderId: id,
            colorStyle: FolderPlaceholderColorStyle.muted,
          ).accent.toARGB32(),
        )
        .toSet();
    expect(colors.length, ids.length);
  });

  test('JSON 读写 round-trip 并容忍损坏数据', () {
    final original = FolderPlaceholderSettings.defaults.copyWith(
      paintStyle: FolderPlaceholderPaintStyle.letterBlock,
      colorStyle: FolderPlaceholderColorStyle.vivid,
      showCoverText: false,
      letterScale: 0.51,
      folderIconScale: 0.61,
      silhouetteOpacity: 0.18,
    );
    final restored = FolderPlaceholderSettings.fromJsonString(
      original.toJsonString(),
    );
    expect(restored, original);
    expect(
      FolderPlaceholderSettings.fromJsonString('not-json').paintStyle,
      FolderPlaceholderPaintStyle.gradientGhost,
    );
    expect(
      FolderPlaceholderSettings.fromJson(
        FolderPlaceholderSettings.legacyWidthBasedDefaults.toJson()
          ..remove('schemaVersion')
          ..remove('maxCoverTextLength'),
      ),
      FolderPlaceholderSettings.defaults,
    );

    final migrated = FolderPlaceholderSettings.fromJson({
      'paintStyle': 'gradientGhost',
      'colorStyle': 'muted',
      'letterScale': 0.50,
      'letterOpacity': 0.94,
      'cornerBadgeScale': 0.16,
      'folderIconScale': 0.64,
      'letterBadgeScale': 0.20,
      'iconOpacity': 0.92,
      'gradientLetterScale': 0.36,
      'silhouetteScale': 0.70,
      'silhouetteOpacity': 0.30,
    });
    expect(migrated.letterScale, closeTo(1.0, 0.001));
    expect(migrated.letterBadgeScale, closeTo(1.0, 0.001));
    expect(migrated.gradientLetterScale, closeTo(1.0, 0.001));
    expect(migrated.maxCoverTextLength, 2);
    expect(migrated.silhouetteScale, closeTo(0.70, 0.001));
    expect(migrated.showCoverText, isTrue);
  });

  test('默认是渐变剪影、柔和配色、不显示封面文字，剪影滑条为 58', () {
    const d = FolderPlaceholderSettings.defaults;
    expect(d.paintStyle, FolderPlaceholderPaintStyle.gradientGhost);
    expect(d.colorStyle, FolderPlaceholderColorStyle.muted);
    expect(d.showCoverText, isFalse);
    expect(
      FolderPlaceholderSettings.silhouetteScaleSpec.toSlider(d.silhouetteScale),
      closeTo(58, 0.2),
    );
  });

  test('滑条 0–100 在中间更精细、两端更粗略，并且能来回映射', () {
    const spec = FolderPlaceholderSliderSpec(
      min: 0.04,
      max: 2.8,
      comfort: 0.70,
    );
    expect(spec.fromSlider(0), closeTo(0.04, 0.001));
    expect(spec.fromSlider(50), closeTo(0.70, 0.001));
    expect(spec.fromSlider(100), closeTo(2.8, 0.001));
    expect(spec.toSlider(0.70), closeTo(50, 0.05));

    final nearComfort = (spec.fromSlider(55) - spec.fromSlider(50)).abs();
    final nearMax = (spec.fromSlider(100) - spec.fromSlider(95)).abs();
    expect(nearMax, greaterThan(nearComfort));
  });

  test('SettingsService 可持久化文件夹占位配置并写入导出快照', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();

    expect(
      settings.folderPlaceholderSettings.paintStyle,
      FolderPlaceholderPaintStyle.gradientGhost,
    );

    final updated = settings.folderPlaceholderSettings.copyWith(
      paintStyle: FolderPlaceholderPaintStyle.tintedIcon,
      folderIconScale: 0.66,
    );
    await settings.updateFolderPlaceholderSettings(updated);
    expect(settings.folderPlaceholderSettings, updated);

    final prefs = await SharedPreferences.getInstance();
    expect(
      FolderPlaceholderSettings.fromJsonString(
        prefs.getString('folderPlaceholderSettings')!,
      ),
      updated,
    );

    final home =
        settings.exportSettingsSnapshot()['home'] as Map<String, dynamic>;
    expect(home['folderPlaceholderSettings'], updated.toJson());
  });
}
