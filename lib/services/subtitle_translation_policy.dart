import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'subtitle_translation_languages.dart';

enum SubtitleTranslationMode { smart, fixed }

const keepOriginal = 'original';

String subtitleLanguageFamily(String code) {
  final normalized = normalizeSubtitleLanguage(code);
  if (normalized == 'zh-CN' || normalized == 'zh-TW') return 'zh';
  if (normalized == 'pt-PT') return 'pt';
  if (normalized == 'en-GB') return 'en';
  return normalized;
}

class SmartTranslationRule {
  const SmartTranslationRule({required this.source, required this.target});
  final String source, target;
  Map<String, String> toJson() => {'source': source, 'target': target};
  factory SmartTranslationRule.fromJson(Map value) => SmartTranslationRule(
    source: normalizeSubtitleLanguage(
      value['source'] is String ? value['source'] as String : 'zh-CN',
    ),
    target: value['target'] == keepOriginal
        ? keepOriginal
        : normalizeSubtitleLanguage(
            value['target'] is String ? value['target'] as String : 'en',
          ),
  );
}

/// Immutable, serializable rules shared by file and streaming translation.
class SmartTranslationPolicy {
  const SmartTranslationPolicy({
    this.rules = const [SmartTranslationRule(source: 'zh-CN', target: 'en')],
    this.otherTarget = 'zh-CN',
    this.keepUncertain = true,
  });
  final List<SmartTranslationRule> rules;
  final String otherTarget;
  final bool keepUncertain;

  String get fingerprint => sha256
      .convert(utf8.encode(jsonEncode(toJson())))
      .toString()
      .substring(0, 16);
  String get summary {
    final parts = rules.map((rule) {
      final source = subtitleLanguageFamily(rule.source) == 'zh'
          ? '中文（简/繁）'
          : subtitleLanguageLabel(rule.source);
      final target = targetLabel(rule.target);
      return '$source→$target';
    }).toList();
    final other = targetLabel(otherTarget);
    parts.add('其他→$other');
    final directions = parts.join(' / ');
    return '智能互译 · $directions';
  }

  String get compactSummary {
    String short(String code) =>
        const {
          'zh-CN': '中',
          'zh-TW': '繁中',
          'en': '英',
          'ja': '日',
          'ko': '韩',
          'fr': '法',
          'de': '德',
          'es': '西',
          keepOriginal: '原文',
        }[code] ??
        subtitleLanguageLabel(code);
    final first = rules.isEmpty
        ? ''
        : '${short(rules.first.source)}→${short(rules.first.target)} / ';
    final extra = rules.length > 1 ? ' +${rules.length - 1}' : '';
    return '智能互译：$first其他→${short(otherTarget)}$extra';
  }

  static String targetLabel(String code) =>
      code == keepOriginal ? '保留原文' : subtitleLanguageLabel(code);
  String targetFor(String language) {
    final family = subtitleLanguageFamily(language);
    for (final rule in rules) {
      if (subtitleLanguageFamily(rule.source) == family) return rule.target;
    }
    return otherTarget;
  }

  SmartTranslationPolicy copyWith({
    List<SmartTranslationRule>? rules,
    String? otherTarget,
    bool? keepUncertain,
  }) => SmartTranslationPolicy(
    rules: List.unmodifiable(rules ?? this.rules),
    otherTarget: otherTarget ?? this.otherTarget,
    keepUncertain: keepUncertain ?? this.keepUncertain,
  );
  Map<String, dynamic> toJson() => {
    'version': 1,
    'rules': rules.map((rule) => rule.toJson()).toList(),
    'otherTarget': otherTarget,
    'keepUncertain': keepUncertain,
  };
  factory SmartTranslationPolicy.fromJson(Map value) => SmartTranslationPolicy(
    rules: value['rules'] is List
        ? List.unmodifiable(
            (value['rules'] as List).whereType<Map>().map(
              SmartTranslationRule.fromJson,
            ),
          )
        : const [SmartTranslationRule(source: 'zh-CN', target: 'en')],
    otherTarget: value['otherTarget'] == keepOriginal
        ? keepOriginal
        : normalizeSubtitleLanguage(
            value['otherTarget'] is String
                ? value['otherTarget'] as String
                : 'zh-CN',
          ),
    keepUncertain: value['keepUncertain'] != false,
  );

  void validate(List<SubtitleTranslationLanguage> languages) {
    final allowed = languages.map((language) => language.code).toSet();
    final seen = <String>{};
    for (final rule in rules) {
      if (!allowed.contains(rule.source)) {
        throw ArgumentError('当前服务或模型不支持规则中的源语言');
      }
      if (!seen.add(subtitleLanguageFamily(rule.source))) {
        throw ArgumentError('同一种语言只能设置一条规则（简繁中文共用规则）');
      }
      if (rule.target != keepOriginal && !allowed.contains(rule.target)) {
        throw ArgumentError('当前服务或模型不支持规则中的目标语言');
      }
    }
    if (otherTarget != keepOriginal && !allowed.contains(otherTarget)) {
      throw ArgumentError('当前服务或模型不支持其他语言的目标语言');
    }
  }

  SmartTranslationPolicy forLanguages(
    List<SubtitleTranslationLanguage> languages,
  ) {
    final allowed = languages.map((language) => language.code).toSet();
    final fallback = allowed.contains('zh-CN') ? 'zh-CN' : languages.first.code;
    final seen = <String>{};
    return copyWith(
      rules: [
        for (final rule in rules)
          if (allowed.contains(rule.source) &&
              seen.add(subtitleLanguageFamily(rule.source)))
            SmartTranslationRule(
              source: rule.source,
              target:
                  rule.target == keepOriginal || allowed.contains(rule.target)
                  ? rule.target
                  : fallback,
            ),
      ],
      otherTarget: otherTarget == keepOriginal || allowed.contains(otherTarget)
          ? otherTarget
          : fallback,
    );
  }
}
