/// Filename and content evidence for one subtitle entry.
///
/// A package-level "双语" label is intentionally not an input. JPSC / JPTC
/// stay inferred until a person confirms them.
class SubtitleEntryMetadata {
  const SubtitleEntryMetadata({
    required this.languages,
    required this.label,
    required this.evidence,
    required this.inferred,
    this.group = '',
  });

  final List<String> languages;
  final String label;
  final String evidence;
  final bool inferred;
  final String group;

  static SubtitleEntryMetadata infer(String name, String text) {
    final source = name.toLowerCase().replaceAll('\\', '/');
    final fromName = _fromName(source);
    final kana = RegExp(r'[\u3040-\u30ff]').hasMatch(text);
    final han = RegExp(r'[\u4e00-\u9fff]').hasMatch(text);
    if (fromName.group.isNotEmpty) {
      return fromName;
    }
    if (kana && han) {
      return const SubtitleEntryMetadata(
        languages: ['ja', 'zh'],
        label: '中日双语（内容推断）',
        evidence: 'content',
        inferred: true,
        group: 'ja-zh',
      );
    }
    if (fromName.languages.isNotEmpty) return fromName;
    if (kana) {
      return const SubtitleEntryMetadata(
        languages: ['ja'],
        label: '日语（内容推断）',
        evidence: 'content',
        inferred: true,
        group: 'ja',
      );
    }
    return const SubtitleEntryMetadata(
      languages: [],
      label: '语言未知',
      evidence: 'unknown',
      inferred: true,
    );
  }

  static SubtitleEntryMetadata _fromName(String source) {
    SubtitleEntryMetadata named({
      required List<String> languages,
      required String label,
      required String group,
    }) => SubtitleEntryMetadata(
      languages: languages,
      label: '$label（文件名推断）',
      evidence: 'filename',
      inferred: true,
      group: group,
    );
    if (RegExp(r'jpsc|scjp|简日|簡日').hasMatch(source)) {
      return named(
        languages: const ['ja', 'zh-Hans'],
        label: '简日双语',
        group: 'ja-hans',
      );
    }
    if (RegExp(r'jptc|tcjp|繁日').hasMatch(source)) {
      return named(
        languages: const ['ja', 'zh-Hant'],
        label: '繁日双语',
        group: 'ja-hant',
      );
    }
    if (RegExp(r'(?:^|[._\[-])(?:chs|sc|zh-cn|zh-hans)(?:[._\]]|$)').hasMatch(source)) {
      return named(languages: const ['zh-Hans'], label: '简体中文', group: 'zh-hans');
    }
    if (RegExp(r'(?:^|[._\[-])(?:cht|tc|zh-tw|zh-hant|big5)(?:[._\]]|$)').hasMatch(source)) {
      return named(languages: const ['zh-Hant'], label: '繁体中文', group: 'zh-hant');
    }
    if (RegExp(r'(?:^|[._\[-])(?:ja|jp|jpn)(?:[._\]]|$)').hasMatch(source)) {
      return named(languages: const ['ja'], label: '日语', group: 'ja');
    }
    if (RegExp(r'(?:^|[._\[-])(?:en|eng)(?:[._\]]|$)').hasMatch(source)) {
      return named(languages: const ['en'], label: '英语', group: 'en');
    }
    return const SubtitleEntryMetadata(
      languages: [],
      label: '',
      evidence: 'unknown',
      inferred: true,
    );
  }
}

/// Stable key for a user-selected subtitle edition. Empty when the name
/// does not advertise one.
String subtitleEditionGroup(String name) =>
    SubtitleEntryMetadata.infer(name, '').group;
