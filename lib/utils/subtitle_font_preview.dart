import 'dart:ui' show TextDirection;

/// Small, language-specific specimens for the online font list.
/// The full font is installed only when the user chooses to download it.
class SubtitleFontPreviewSample {
  final String language;
  final String languageLabel;
  final String primary;
  final String? secondary;
  final TextDirection direction;

  const SubtitleFontPreviewSample({
    required this.language,
    required this.languageLabel,
    required this.primary,
    this.secondary,
    this.direction = TextDirection.ltr,
  });

  String get text => secondary == null ? primary : '$primary\n$secondary';
}

String _normalizePreviewLanguage(String language) {
  final value = language.toLowerCase().replaceAll('_', '-');
  return switch (value) {
    'zh-cn' || 'zh-sg' || 'zh-hans' => 'zh-Hans',
    'zh-tw' || 'zh-hk' || 'zh-mo' || 'zh-hant' => 'zh-Hant',
    'jpn' => 'ja',
    'kor' => 'ko',
    'eng' => 'en',
    _ => value,
  };
}

SubtitleFontPreviewSample subtitleFontPreviewSample(
  Iterable<String> languages, {
  String preferredLanguage = '',
  String fontName = '',
}) {
  final family = fontName.trim().toLowerCase();
  if (family == 'allkin') {
    return const SubtitleFontPreviewSample(
      language: 'zxx',
      languageLabel: '图形符号',
      primary: '\uE000 \uE001 \uE002 \uE003 \uE004 \uE005',
    );
  }
  if (family.startsWith('libre barcode ')) {
    return const SubtitleFontPreviewSample(
      language: 'zxx',
      languageLabel: '条形码',
      primary: '0123456789',
    );
  }
  if (family == 'noto sans symbols') {
    return const SubtitleFontPreviewSample(
      language: 'zxx',
      languageLabel: '符号',
      primary: '← ↑ → ↓ ↔',
    );
  }
  if (family == 'noto sans symbols 2') {
    return const SubtitleFontPreviewSample(
      language: 'zxx',
      languageLabel: '符号',
      primary: '♠ ♣ ♥ ♦ ☀ ★ ✓ ✗',
    );
  }
  if (family == 'noto music') {
    return const SubtitleFontPreviewSample(
      language: 'zxx',
      languageLabel: '音乐符号',
      primary: '\u{1D11E} \u{1D122} \u{1D15F}',
    );
  }
  if (family == 'noto znamenny musical notation') {
    return const SubtitleFontPreviewSample(
      language: 'zxx',
      languageLabel: '音乐符号',
      primary: '\u{1CF00} \u{1CF01} \u{1CF02} \u{1CF03} \u{1CF04} \u{1CF05}',
    );
  }
  if (family == 'noto color emoji' || family == 'noto emoji') {
    return const SubtitleFontPreviewSample(
      language: 'zxx',
      languageLabel: '表情符号',
      primary: '😀 😃 😄',
    );
  }
  if (family.endsWith(' math')) {
    return const SubtitleFontPreviewSample(
      language: 'zxx',
      languageLabel: '数学符号',
      primary: '∑ ∫ √ π ∞',
    );
  }
  if (family == 'linefont' || family == 'wavefont') {
    return const SubtitleFontPreviewSample(
      language: 'zxx',
      languageLabel: '图形符号',
      primary: 'abcdefghijklm',
    );
  }
  final available = languages.map(_normalizePreviewLanguage).toSet();
  final preferred = _normalizePreviewLanguage(preferredLanguage);
  String? chosen;
  if (available.contains(preferred)) {
    chosen = preferred;
  } else if (preferred == 'zh') {
    chosen = available.contains('zh-Hans')
        ? 'zh-Hans'
        : available.contains('zh-Hant')
        ? 'zh-Hant'
        : available.contains('zh')
        ? 'zh'
        : null;
  } else if (['fr', 'de', 'es'].contains(preferred) &&
      available.contains('en')) {
    // These filters already include the catalog's Latin/English families.
    chosen = preferred;
  }
  chosen ??= const [
    'zh-Hans',
    'zh-Hant',
    'zh',
    'ja',
    'ko',
    'ar',
    'he',
    'hi',
    'km',
    'lo',
    'my',
    'ta',
    'th',
    'ru',
    'el',
    'vi',
    'xlc',
    'en',
  ].where(available.contains).firstOrNull;
  chosen ??= 'en';

  final (label, text, direction) = switch (chosen) {
    'zh-Hant' => ('繁體中文', '字幕預覽', TextDirection.ltr),
    'zh' || 'zh-Hans' => ('简体中文', '字幕预览', TextDirection.ltr),
    'ja' => ('日语', '字幕プレビュー', TextDirection.ltr),
    'ko' => ('韩语', '자막 미리보기', TextDirection.ltr),
    'ar' => ('阿拉伯语', 'معاينة الترجمة', TextDirection.rtl),
    'he' => ('希伯来语', 'תצוגת כתוביות', TextDirection.rtl),
    'hi' => ('印地语', 'उपशीर्षक पूर्वावलोकन', TextDirection.ltr),
    'km' => ('高棉语', 'ចំណងជើងរង', TextDirection.ltr),
    'lo' => ('老挝语', 'ຄຳບັນຍາຍ', TextDirection.ltr),
    'my' => ('缅甸语', 'စာတန်းထိုး', TextDirection.ltr),
    'ta' => ('泰米尔语', 'வசன முன்னோட்டம்', TextDirection.ltr),
    'th' => ('泰语', 'ตัวอย่างคำบรรยาย', TextDirection.ltr),
    'ru' => ('俄语', 'Предпросмотр субтитров', TextDirection.ltr),
    'el' => ('希腊语', 'Προεπισκόπηση υποτίτλων', TextDirection.ltr),
    'vi' => ('越南语', 'Xem trước phụ đề', TextDirection.ltr),
    'fr' => ('法语', 'Aperçu des sous-titres', TextDirection.ltr),
    'de' => ('德语', 'Untertitelvorschau', TextDirection.ltr),
    'es' => ('西班牙语', 'Vista previa de subtítulos', TextDirection.ltr),
    'xlc' => (
      '吕基亚文',
      '\u{10280}\u{10281}\u{10282}\u{10283}\u{10284}\u{10285}',
      TextDirection.ltr,
    ),
    _ => ('英语', 'Subtitle preview Aa', TextDirection.ltr),
  };
  final bilingual = chosen != 'en' && available.contains('en');
  return SubtitleFontPreviewSample(
    language: chosen,
    languageLabel: bilingual ? '$label · 英语' : label,
    primary: bilingual ? '$text Aa' : text,
    direction: direction,
  );
}
