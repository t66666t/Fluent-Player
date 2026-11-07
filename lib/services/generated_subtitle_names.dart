import 'subtitle_translation_languages.dart';
import 'package:path/path.dart' as p;
import '../models/managed_subtitle_asset.dart';
import '../models/video_item.dart';

/// Read old generated file labels in Chinese without moving the user's files.
String localizedSubtitleResultName(String name) => name
    .replaceAll(RegExp(r'\.optimized(?=\.|$)', caseSensitive: false), '.优化')
    .replaceAll(
      RegExp(r'\.(?:translated|translation)(?=\.|$)', caseSensitive: false),
      '.翻译',
    )
    .replaceAllMapped(
      RegExp(r'\.翻译\.([a-zA-Z][a-zA-Z-]*)(?=\.|$)'),
      (match) => '.翻译.${subtitleLanguageLabel(match[1]!)}',
    );

/// Human names are independent of task IDs, checkpoint files and providers.
/// Only new generated assets use this scheme; user names and stored paths stay.
String generatedSubtitleName({
  required String mediaTitle,
  required String version,
  Iterable<String> existingNames = const [],
}) {
  final topic = _generatedSubtitleTopic(mediaTitle);
  final label = switch (version) {
    '精校稿' => '优化',
    '互译稿' => '互译',
    '译稿' => '翻译',
    _ when version.endsWith('译稿') => version.substring(0, version.length - 2),
    _ => null,
  };
  final name = label == null ? '$topic · $version' : '［$label］$topic';
  return uniqueGeneratedSubtitleName(name, existingNames);
}

String _generatedSubtitleTopic(String mediaTitle) {
  var topic = mediaTitle
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceFirst(
        RegExp(
          r'\.(mp4|mkv|mov|avi|webm|m4v|mp3|m4a|wav|flac|aac|ogg|opus)$',
          caseSensitive: false,
        ),
        '',
      )
      .trim();
  if (topic.isEmpty) topic = '未命名媒体';
  if (topic.runes.length > 44) {
    topic = '${String.fromCharCodes(topic.runes.take(43))}…';
  }
  return topic;
}

/// Called again at the library's synchronous insertion boundary so concurrent
/// publications cannot both claim the same visible version.
String uniqueGeneratedSubtitleName(
  String requested,
  Iterable<String> existingNames,
) {
  final base = requested.replaceFirst(RegExp(r' v(?:[2-9]|[1-9]\d+)$'), '');
  final used = existingNames.map((name) => name.trim()).toSet();
  if (!used.contains(base)) return base;
  var number = 2;
  while (used.contains('$base v$number')) {
    number++;
  }
  return '$base v$number';
}

String subtitleTranslationManuscript(String? language) {
  if (language == 'mul') return '互译稿';
  final code = normalizeSubtitleLanguage(language ?? 'auto');
  if (code == 'auto') return '译稿';
  final label = switch (code) {
    'en' => '英文',
    'ja' => '日文',
    'ko' => '韩文',
    'fr' => '法文',
    'de' => '德文',
    'es' => '西班牙文',
    'ru' => '俄文',
    'it' => '意大利文',
    'pt' || 'pt-PT' => '葡萄牙文',
    _ => subtitleLanguageLabel(code),
  };
  return '$label译稿';
}

final _translationManuscriptVersions = {
  subtitleTranslationManuscript(null),
  subtitleTranslationManuscript('mul'),
  for (final language in subtitleTranslationLanguages)
    subtitleTranslationManuscript(language.code),
};

/// Render known old automatic labels without renaming files, rewriting a
/// library, or replacing a user's descriptive name. List order is durable and
/// makes equal legacy labels distinguishable across management and MCP views.
String subtitleManuscriptDisplayName(
  VideoItem media,
  ManagedSubtitleAsset asset,
) {
  String? version(ManagedSubtitleAsset candidate) {
    final name = candidate.displayName.trim();
    final fileLabel = name == p.basename(candidate.path);
    final legacy = RegExp(
      r'^(.+) · (.+?)(?: v(?:[2-9]|[1-9]\d+))?$',
    ).firstMatch(name);
    final legacyVersion =
        legacy?.group(1) == _generatedSubtitleTopic(media.title)
        ? legacy?.group(2)
        : null;
    final technical = RegExp(
      r'^(?:agent-|app-|subtitle-|mcp-|.*\d{12,}).*（(优化|翻译)）$',
    );
    if (candidate.kind == ManagedSubtitleAssetKind.ai) {
      // Undo the overbroad transcription prefix in display only. Match the
      // exact automatic name so descriptive user labels remain untouched.
      if (RegExp(
        '^(?:［听写］|\\[听写\\])${RegExp.escape(_generatedSubtitleTopic(media.title))}'
        r'(?: v(?:[2-9]|[1-9]\d+))?$',
      ).hasMatch(name)) {
        return '听写稿';
      }
      if (legacyVersion == '精校稿' || legacyVersion == '听写稿') {
        return legacyVersion;
      }
      if (['Agent 优化字幕', '软件 优化字幕', '优化字幕'].contains(name) ||
          fileLabel &&
              RegExp(
                r'\.(?:optimized|优化)\.',
                caseSensitive: false,
              ).hasMatch(name) ||
          technical.hasMatch(name) && name.endsWith('（优化）')) {
        return '精校稿';
      }
      if (name == 'AI 字幕') return '听写稿';
    }
    if (candidate.kind == ManagedSubtitleAssetKind.translated &&
        _translationManuscriptVersions.contains(legacyVersion)) {
      return legacyVersion;
    }
    if (candidate.kind == ManagedSubtitleAssetKind.translated &&
        (name == '翻译字幕' ||
            fileLabel &&
                RegExp(
                  r'\.(?:translated|translation|翻译)\.',
                  caseSensitive: false,
                ).hasMatch(name) ||
            RegExp(r'^(Agent|软件) 译文 · .+$').hasMatch(name) ||
            technical.hasMatch(name) && name.endsWith('（翻译）'))) {
      return subtitleTranslationManuscript(candidate.language);
    }
    return null;
  }

  if (version(asset) == null) return asset.displayName.trim();
  final used = media.managedSubtitleAssets
      .where((candidate) => version(candidate) == null)
      .map((candidate) => candidate.displayName.trim())
      .toSet();
  for (final candidate in media.managedSubtitleAssets) {
    final kind = version(candidate);
    if (kind == null) continue;
    final base = generatedSubtitleName(mediaTitle: media.title, version: kind);
    final revision =
        RegExp(
          r' v(?:[2-9]|[1-9]\d+)$',
        ).firstMatch(candidate.displayName.trim())?.group(0) ??
        '';
    final requested = '$base$revision';
    final name = used.contains(requested)
        ? uniqueGeneratedSubtitleName(base, used)
        : requested;
    if (candidate.assetId == asset.assetId) return name;
    used.add(name);
  }
  return asset.displayName.trim();
}
