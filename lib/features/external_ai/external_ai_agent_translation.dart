import '../../models/subtitle_model.dart';
import '../../services/smart_subtitle_translator.dart';
import '../../services/subtitle_translation_languages.dart';
import '../../services/subtitle_translation_policy.dart';

class ExternalAiAgentTranslationPart {
  const ExternalAiAgentTranslationPart({
    required this.partId,
    required this.cueId,
    required this.text,
    required this.sourceLanguage,
    required this.targetLanguage,
  });

  final String partId, cueId, text, sourceLanguage, targetLanguage;

  Map<String, dynamic> toJson() => {
    'partId': partId,
    'cueId': cueId,
    'text': text,
    'sourceLanguage': sourceLanguage,
    'targetLanguage': targetLanguage,
  };

  factory ExternalAiAgentTranslationPart.fromJson(Map value) =>
      ExternalAiAgentTranslationPart(
        partId: _requiredString(value, 'partId'),
        cueId: _requiredString(value, 'cueId'),
        text: _requiredString(value, 'text'),
        sourceLanguage: _requiredString(value, 'sourceLanguage'),
        targetLanguage: _requiredString(value, 'targetLanguage'),
      );
}

String _requiredString(Map value, String key) {
  final result = value[key];
  if (result is! String || result.trim().isEmpty) {
    throw FormatException('Invalid Agent translation $key');
  }
  return result;
}

class _Segment {
  const _Segment.literal(this.text) : partId = null;
  const _Segment.part(this.partId) : text = null;
  final String? text, partId;

  Map<String, dynamic> toJson() => {
    if (partId != null) 'partId': partId else 'text': text,
  };

  factory _Segment.fromJson(Map value) {
    if (value.length != 1) {
      throw const FormatException('Invalid Agent translation segment');
    }
    if (value['partId'] is String) {
      return _Segment.part(_requiredString(value, 'partId'));
    }
    if (value['text'] is String) {
      return _Segment.literal(value['text'] as String);
    }
    throw const FormatException('Invalid Agent translation segment');
  }
}

/// Durable reconstruction instructions. Literal/protected/uncertain fragments
/// stay in the app; Agent output only replaces explicitly routed part IDs.
class ExternalAiAgentTranslationPlan {
  ExternalAiAgentTranslationPlan._({
    required List<String> cueIds,
    required List<ExternalAiAgentTranslationPart> parts,
    required Map<String, List<_Segment>> templates,
  }) : cueIds = List.unmodifiable(cueIds),
       parts = List.unmodifiable(parts),
       _templates = Map.unmodifiable({
         for (final entry in templates.entries)
           entry.key: List<_Segment>.unmodifiable(entry.value),
       }) {
    _validate();
  }

  final List<String> cueIds;
  final List<ExternalAiAgentTranslationPart> parts;
  final Map<String, List<_Segment>> _templates;

  List<ExternalAiAgentTranslationPart> partsForCue(String cueId) =>
      parts.where((part) => part.cueId == cueId).toList(growable: false);

  void _validate() {
    if (cueIds.toSet().length != cueIds.length ||
        cueIds.any((id) => id.trim().isEmpty) ||
        _templates.length != cueIds.length ||
        cueIds.any((id) => !_templates.containsKey(id))) {
      throw const FormatException('Invalid Agent translation cue identities');
    }
    final byId = <String, ExternalAiAgentTranslationPart>{};
    for (final part in parts) {
      if (part.partId.trim().isEmpty ||
          part.text.trim().isEmpty ||
          part.sourceLanguage.trim().isEmpty ||
          part.targetLanguage.trim().isEmpty ||
          !cueIds.contains(part.cueId) ||
          byId.containsKey(part.partId)) {
        throw const FormatException('Invalid Agent translation part');
      }
      byId[part.partId] = part;
    }
    final seen = <String>{};
    for (final cueId in cueIds) {
      for (final segment in _templates[cueId]!) {
        final id = segment.partId;
        if (id == null) continue;
        if (byId[id]?.cueId != cueId || !seen.add(id)) {
          throw const FormatException('Invalid Agent translation template');
        }
      }
    }
    if (seen.length != parts.length) {
      throw const FormatException('Unreferenced Agent translation parts');
    }
  }

  void _validateOutputIds(Map<String, String> translatedParts) {
    final known = parts.map((part) => part.partId).toSet();
    if (translatedParts.keys.any((id) => !known.contains(id))) {
      throw ArgumentError('Unknown Agent translation part');
    }
  }

  String _assemble(String cueId, Map<String, String> translatedParts) {
    final template = _templates[cueId];
    if (template == null) throw ArgumentError('Unknown Agent translation cue');
    return template.map((segment) {
      final id = segment.partId;
      if (id == null) return segment.text!;
      final output = translatedParts[id];
      if (output == null || output.trim().isEmpty) {
        throw ArgumentError('Missing Agent translation part $id');
      }
      return output;
    }).join();
  }

  /// Allows progressive per-cue writes; other known part IDs may be present.
  String reassembleForCue(String cueId, Map<String, String> translatedParts) {
    _validateOutputIds(translatedParts);
    return _assemble(cueId, translatedParts);
  }

  List<String> reassemble(Map<String, String> translatedParts) {
    _validateOutputIds(translatedParts);
    return [for (final cueId in cueIds) _assemble(cueId, translatedParts)];
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'parts': parts.map((part) => part.toJson()).toList(),
    'cues': [
      for (final cueId in cueIds)
        {
          'cueId': cueId,
          'segments': _templates[cueId]!.map((part) => part.toJson()).toList(),
        },
    ],
  };

  factory ExternalAiAgentTranslationPlan.fromJson(Map value) {
    if (value['version'] != 1 ||
        value['parts'] is! List ||
        value['cues'] is! List) {
      throw const FormatException('Invalid Agent translation plan');
    }
    final parts = <ExternalAiAgentTranslationPart>[];
    for (final raw in value['parts'] as List) {
      if (raw is! Map) throw const FormatException('Invalid translation part');
      parts.add(ExternalAiAgentTranslationPart.fromJson(raw));
    }
    final cueIds = <String>[];
    final templates = <String, List<_Segment>>{};
    for (final raw in value['cues'] as List) {
      if (raw is! Map || raw['segments'] is! List) {
        throw const FormatException('Invalid Agent translation cue template');
      }
      final cueId = _requiredString(raw, 'cueId');
      cueIds.add(cueId);
      templates[cueId] = [
        for (final segment in raw['segments'] as List)
          if (segment is Map)
            _Segment.fromJson(segment)
          else
            throw const FormatException('Invalid Agent translation segment'),
      ];
    }
    return ExternalAiAgentTranslationPlan._(
      cueIds: cueIds,
      parts: parts,
      templates: templates,
    );
  }
}

/// Captures the real smart router's provider callback without making requests.
/// Placeholders are replaced by the app after Agent returns the routed parts.
class ExternalAiAgentTranslationPlanner {
  ExternalAiAgentTranslationPlanner({SmartSubtitleTranslator? translator})
    : _translator = translator ?? SmartSubtitleTranslator();

  final SmartSubtitleTranslator _translator;

  Future<ExternalAiAgentTranslationPlan> plan({
    required List<SubtitleItem> items,
    List<String>? cueIds,
    SmartTranslationPolicy? policy,
    String? fixedTargetLanguage,
    String sourceLanguage = 'auto',
    String partIdPrefix = '',
    String precedingContext = '',
    List<SubtitleTranslationLanguage>? supportedSourceLanguages,
  }) async {
    final ids =
        cueIds ?? [for (var i = 0; i < items.length; i++) 'cue-${i + 1}'];
    if (ids.length != items.length ||
        ids.toSet().length != ids.length ||
        ids.any((id) => id.trim().isEmpty)) {
      throw ArgumentError(
        'Agent translation cue IDs must be unique and complete',
      );
    }
    if (sourceLanguage.trim().isEmpty) {
      throw ArgumentError('Agent translation source language is required');
    }
    if (fixedTargetLanguage != null) {
      if (fixedTargetLanguage.trim().isEmpty ||
          fixedTargetLanguage == keepOriginal) {
        throw ArgumentError('A fixed translation target language is required');
      }
      final parts = <ExternalAiAgentTranslationPart>[];
      final templates = <String, List<_Segment>>{};
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        if (item.text.trim().isEmpty) {
          templates[ids[i]] = [_Segment.literal(item.text)];
          continue;
        }
        final partId = '${partIdPrefix}part-${parts.length + 1}';
        parts.add(
          ExternalAiAgentTranslationPart(
            partId: partId,
            cueId: ids[i],
            text: item.text,
            sourceLanguage: sourceLanguage,
            targetLanguage: fixedTargetLanguage,
          ),
        );
        templates[ids[i]] = [_Segment.part(partId)];
      }
      return ExternalAiAgentTranslationPlan._(
        cueIds: ids,
        parts: parts,
        templates: templates,
      );
    }
    if (policy == null) {
      throw ArgumentError('Smart translation policy is required');
    }

    // Pick a marker absent from source text, including adversarial subtitles.
    var salt = 0;
    String prefix;
    do {
      prefix = '\uE000fluent-player-agent-translation:${salt++}:';
    } while (items.any((item) => item.text.contains(prefix)));
    const suffix = '\uE001';
    final routed = <({String text, String source, String target})>[];
    final output = await _translator.translate(
      items: items,
      policy: policy,
      precedingContext: precedingContext,
      supportedSourceLanguages: supportedSourceLanguages,
      onProgress: (_) {},
      translateBatch:
          (group, source, target, scope, progress, translated) async {
            final markers = <String>[];
            for (final item in group) {
              final index = routed.length;
              routed.add((text: item.text, source: source, target: target));
              markers.add('$prefix$index$suffix');
            }
            return markers;
          },
    );
    final marker = RegExp('${RegExp.escape(prefix)}(\\d+)$suffix');
    final partsByIndex = <int, ExternalAiAgentTranslationPart>{};
    final templates = <String, List<_Segment>>{};
    for (var i = 0; i < output.length; i++) {
      final text = output[i];
      final segments = <_Segment>[];
      var at = 0;
      for (final match in marker.allMatches(text)) {
        if (match.start > at) {
          segments.add(_Segment.literal(text.substring(at, match.start)));
        }
        final index = int.parse(match[1]!);
        if (index >= routed.length || partsByIndex.containsKey(index)) {
          throw StateError('Invalid smart translation reconstruction marker');
        }
        final part = routed[index];
        final partId = '${partIdPrefix}part-${index + 1}';
        partsByIndex[index] = ExternalAiAgentTranslationPart(
          partId: partId,
          cueId: ids[i],
          text: part.text,
          sourceLanguage: part.source,
          targetLanguage: part.target,
        );
        segments.add(_Segment.part(partId));
        at = match.end;
      }
      if (at < text.length) segments.add(_Segment.literal(text.substring(at)));
      templates[ids[i]] = segments;
    }
    if (partsByIndex.length != routed.length || output.length != ids.length) {
      throw StateError('Incomplete smart translation reconstruction plan');
    }
    return ExternalAiAgentTranslationPlan._(
      cueIds: ids,
      parts: [for (var i = 0; i < routed.length; i++) partsByIndex[i]!],
      templates: templates,
    );
  }
}
