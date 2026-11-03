import 'package:video_player_app/features/youtube_download/models/youtube_download_models.dart';
import 'yt_dlp_audio_format_order.dart';
import 'yt_dlp_video_format_selector.dart';

class YtDlpMetaParser {
  const YtDlpMetaParser();

  static String normalizeSubtitleLanguageCode(String languageCode) {
    return _normalizeSubtitleLanguageCodeImpl(languageCode);
  }

  static String preferenceLanguageKey(String languageCode) {
    final normalized = normalizeSubtitleLanguageCode(languageCode);
    if (normalized.isEmpty) {
      return '';
    }
    if (normalized == 'cmn' || normalized.startsWith('cmn-')) {
      return 'zh';
    }
    final primary = normalized.split('-').first;
    if (primary == 'zh') {
      return 'zh';
    }
    return primary;
  }

  static String resolveSubtitleLanguageLabel(String languageCode) {
    return _resolveSubtitleLanguageLabelImpl(languageCode);
  }

  static String resolvePreferenceLanguageLabel(String languageCode) {
    final preferenceKey = preferenceLanguageKey(languageCode);
    if (preferenceKey.isEmpty) {
      return languageCode;
    }
    if (preferenceKey == 'zh') {
      return '中文';
    }
    return _subtitleLanguageNames[preferenceKey] ??
        _resolveSubtitleLanguageLabelImpl(preferenceKey);
  }

  static bool matchesPreferenceLanguage(
    String preferenceKey,
    String languageCode,
  ) {
    final normalizedPreference = preferenceLanguageKey(preferenceKey);
    final normalizedLanguage = preferenceLanguageKey(languageCode);
    return normalizedPreference.isNotEmpty &&
        normalizedPreference == normalizedLanguage;
  }

  VideoMeta parse(Map<String, dynamic> rawInfo) {
    final source = _resolveSource(rawInfo);
    final thumbnails = _parseThumbnails(rawInfo);
    final formats = _extractFormats(rawInfo);
    final videoFormats = _parseVideoFormats(formats, source: source);
    final audioFormats = _parseAudioFormats(formats);
    final subtitles = _parseSubtitles(rawInfo);
    final chapters = _parseChapters(rawInfo);
    final videoFormatGroups = _groupVideoFormats(videoFormats);
    final audioFormatGroups = _groupAudioFormats(audioFormats);

    return VideoMeta(
      id: _stringValue(rawInfo['id']) ?? '',
      source: source,
      webpageUrl:
          _stringValue(rawInfo['webpage_url']) ??
          _stringValue(rawInfo['original_url']) ??
          _stringValue(rawInfo['url']) ??
          '',
      title: _stringValue(rawInfo['title']) ?? '未命名视频',
      uploader:
          _stringValue(rawInfo['uploader']) ??
          _stringValue(rawInfo['channel']) ??
          _stringValue(rawInfo['playlist_uploader']) ??
          '未知上传者',
      durationSeconds: _intValue(rawInfo['duration']),
      thumbnails: thumbnails,
      videoFormats: videoFormats,
      audioFormats: audioFormats,
      subtitles: subtitles,
      chapters: chapters,
      videoFormatGroups: videoFormatGroups,
      audioFormatGroups: audioFormatGroups,
      recommendedVideoFormatId: _pickRecommendedVideoFormatId(videoFormats),
      recommendedAudioFormatId: _pickRecommendedAudioFormatId(audioFormats),
      recommendedSubtitleLanguages: _pickRecommendedSubtitleLanguages(
        subtitles,
      ),
      rawInfo: rawInfo,
    );
  }

  List<Map<String, dynamic>> _extractFormats(Map<String, dynamic> rawInfo) {
    return (rawInfo['formats'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  List<ThumbnailInfo> _parseThumbnails(Map<String, dynamic> rawInfo) {
    final thumbnails = (rawInfo['thumbnails'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .map(
          (item) => ThumbnailInfo(
            url: _stringValue(item['url']) ?? '',
            width: _intValue(item['width']),
            height: _intValue(item['height']),
            id: _stringValue(item['id']),
          ),
        )
        .where((item) => item.url.isNotEmpty)
        .toList();

    final singleThumbnail = _stringValue(rawInfo['thumbnail']);
    if (singleThumbnail != null &&
        singleThumbnail.isNotEmpty &&
        thumbnails.every((item) => item.url != singleThumbnail)) {
      thumbnails.add(ThumbnailInfo(url: singleThumbnail));
    }

    thumbnails.sort((a, b) {
      final aScore = (a.width ?? 0) * (a.height ?? 0);
      final bScore = (b.width ?? 0) * (b.height ?? 0);
      return bScore.compareTo(aScore);
    });
    return thumbnails;
  }

  List<VideoFormat> _parseVideoFormats(
    List<Map<String, dynamic>> formats, {
    required String source,
  }) {
    final parsed = <VideoFormat>[];
    for (final format in formats) {
      if (!_isUsableVideoFormat(format)) {
        continue;
      }

      final ext =
          _stringValue(format['ext']) ??
          _stringValue(format['container']) ??
          'unknown';
      final videoCodec = _normalizeCodec(
        _stringValue(format['vcodec']),
        fallback: _inferVideoCodec(format),
      );
      final parsedFormat = VideoFormat(
        formatId: _stringValue(format['format_id']) ?? '',
        ext: ext,
        container: _stringValue(format['container']),
        videoCodec: videoCodec,
        audioCodec: _normalizeCodec(_stringValue(format['acodec'])),
        width: _intValue(format['width']),
        height: _intValue(format['height']),
        fps: _doubleValue(format['fps']),
        bitrate: _intValue(format['tbr']) ?? _intValue(format['vbr']),
        fileSize:
            _intValue(format['filesize']) ??
            _intValue(format['filesize_approx']),
        formatNote: _stringValue(format['format_note']),
        hasAudio: _hasUsableAudio(format),
        isHdr: _isHdr(format),
      );
      parsed.add(_markTwitterProgressiveAudio(parsedFormat, source));
    }

    return YtDlpVideoFormatSelector.sortForDisplay(_dedupeVideoFormats(parsed));
  }

  List<AudioFormat> _parseAudioFormats(List<Map<String, dynamic>> formats) {
    final parsed = <AudioFormat>[];
    for (final format in formats) {
      if (!_isUsableAudioFormat(format)) {
        continue;
      }

      final ext =
          _stringValue(format['ext']) ??
          _stringValue(format['container']) ??
          'unknown';
      parsed.add(
        AudioFormat(
          formatId: _stringValue(format['format_id']) ?? '',
          ext: ext,
          audioCodec: _normalizeCodec(
            _stringValue(format['acodec']),
            fallback: _inferAudioCodec(format),
          ),
          audioSampleRate: _intValue(format['asr']),
          bitrate: _bitrateKbps(format),
          fileSize:
              _intValue(format['filesize']) ??
              _intValue(format['filesize_approx']),
          // language_preference is a numeric rank, not a language code.
          language: _stringValue(format['language']),
          isDefaultTrack: _isOriginalAudioTrack(format),
          protocol: _stringValue(format['protocol']),
          qualityRank: _intValue(format['quality']),
        ),
      );
    }

    parsed.sort(YtDlpAudioFormatOrder.compare);
    return _dedupeAudioFormats(parsed);
  }

  /// Original speech, not "this format came from the preferred client".
  /// source_preference is set on every stream from that client, including dubs.
  bool _isOriginalAudioTrack(Map<String, dynamic> format) {
    final preference = _intValue(format['language_preference']);
    if (preference == 10) return true;
    final note = (_stringValue(format['format_note']) ?? '').toLowerCase();
    if (note.contains('original')) return true;
    // HLS "Default" describes AUTOSELECT/default rendition, not necessarily
    // original speech. Promoting it over HTTPS tracks can pick an unknown-
    // bitrate playlist even when the original full audio is available.
    return false;
  }

  List<SubtitleTrack> _parseSubtitles(Map<String, dynamic> rawInfo) {
    final tracks = <SubtitleTrack>[];
    tracks.addAll(_parseSubtitleMap(rawInfo['subtitles'], isAuto: false));
    tracks.addAll(
      _parseSubtitleMap(rawInfo['automatic_captions'], isAuto: true),
    );

    final deduped = <String, SubtitleTrack>{};
    for (final track in tracks) {
      final key = '${track.languageCode}|${track.isAutoGenerated}';
      deduped[key] = track;
    }
    return deduped.values.toList()..sort((a, b) {
      final aScore = _subtitlePriorityScore(a);
      final bScore = _subtitlePriorityScore(b);
      if (aScore != bScore) {
        return bScore.compareTo(aScore);
      }
      return a.displayName.compareTo(b.displayName);
    });
  }

  Map<String, List<String>> _groupVideoFormats(List<VideoFormat> formats) {
    final groups = <String, List<String>>{};
    for (final format in formats) {
      final resolutionGroup = _videoResolutionGroup(format.height);
      groups
          .putIfAbsent(resolutionGroup, () => <String>[])
          .add(format.formatId);
    }
    return groups;
  }

  Map<String, List<String>> _groupAudioFormats(List<AudioFormat> formats) {
    final groups = <String, List<String>>{};
    for (final format in formats) {
      final language = (format.language?.trim().isNotEmpty ?? false)
          ? format.language!
          : 'unknown';
      groups.putIfAbsent(language, () => <String>[]).add(format.formatId);
    }
    return groups;
  }

  String? _pickRecommendedVideoFormatId(List<VideoFormat> formats) {
    return YtDlpVideoFormatSelector.pickFormatId(formats);
  }

  String? _pickRecommendedAudioFormatId(List<AudioFormat> formats) {
    if (formats.isEmpty) {
      return null;
    }
    return formats.first.formatId;
  }

  List<String> _pickRecommendedSubtitleLanguages(List<SubtitleTrack> tracks) {
    if (tracks.isEmpty) {
      return const [];
    }
    final manualTrack = tracks.where((item) => !item.isAutoGenerated).toList();
    if (manualTrack.isNotEmpty) {
      return [manualTrack.first.languageCode];
    }
    return const [];
  }

  List<SubtitleTrack> _parseSubtitleMap(Object? value, {required bool isAuto}) {
    if (value is! Map) {
      return const [];
    }

    final entries = <SubtitleTrack>[];
    for (final mapEntry in value.entries) {
      final languageCode = mapEntry.key.toString();
      final candidates = (mapEntry.value as List? ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      if (!_shouldIncludeSubtitleTrack(
        languageCode,
        candidates,
        isAuto: isAuto,
      )) {
        continue;
      }
      final extCandidates = candidates
          .map((item) => _stringValue(item['ext']))
          .whereType<String>()
          .where((item) => item.isNotEmpty)
          .toSet()
          .toList();
      entries.add(
        SubtitleTrack(
          languageCode: languageCode,
          displayName: _subtitleDisplayName(languageCode, isAuto),
          isAutoGenerated: isAuto,
          extCandidates: extCandidates,
        ),
      );
    }
    return entries;
  }

  bool _shouldIncludeSubtitleTrack(
    String languageCode,
    List<Map<String, dynamic>> candidates, {
    required bool isAuto,
  }) {
    if (!isAuto) {
      return true;
    }
    if (languageCode.endsWith('-orig')) {
      return false;
    }
    return !_containsTranslatedSubtitleCandidate(candidates);
  }

  bool _containsTranslatedSubtitleCandidate(
    List<Map<String, dynamic>> candidates,
  ) {
    for (final candidate in candidates) {
      final url = _stringValue(candidate['url']) ?? '';
      if (url.isEmpty) {
        continue;
      }
      final parsed = Uri.tryParse(url);
      final tlang = parsed?.queryParameters['tlang']?.trim();
      if (tlang != null && tlang.isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  List<ChapterInfo> _parseChapters(Map<String, dynamic> rawInfo) {
    return (rawInfo['chapters'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .map(
          (item) => ChapterInfo(
            title: _stringValue(item['title']) ?? '章节',
            startTimeSeconds:
                _doubleValue(item['start_time']) ??
                _doubleValue(item['startTimeSeconds']),
            endTimeSeconds:
                _doubleValue(item['end_time']) ??
                _doubleValue(item['endTimeSeconds']),
          ),
        )
        .toList();
  }

  bool _isUsableVideoFormat(Map<String, dynamic> format) {
    final formatId = _stringValue(format['format_id']) ?? '';
    final note = (_stringValue(format['format_note']) ?? '').toLowerCase();
    final formatName = (_stringValue(format['format']) ?? '').toLowerCase();
    final ext = (_stringValue(format['ext']) ?? '').toLowerCase();
    final vcodec = (_stringValue(format['vcodec']) ?? '').toLowerCase();

    if (formatId.isEmpty) return false;
    if (note.contains('storyboard') || formatName.contains('storyboard')) {
      return false;
    }
    if (ext == 'mhtml') return false;
    if (_looksLikeSeparatedAudio(format)) return false;
    final hasPicture =
        (_intValue(format['width']) ?? 0) > 0 ||
        (_intValue(format['height']) ?? 0) > 0;
    if ((vcodec.isEmpty || vcodec == 'none') && !hasPicture) return false;
    if (vcodec.contains('images')) return false;
    return true;
  }

  bool _isUsableAudioFormat(Map<String, dynamic> format) {
    final formatId = _stringValue(format['format_id']) ?? '';
    final note = (_stringValue(format['format_note']) ?? '').toLowerCase();
    final ext = (_stringValue(format['ext']) ?? '').toLowerCase();
    final acodec = (_stringValue(format['acodec']) ?? '').toLowerCase();
    final vcodec = (_stringValue(format['vcodec']) ?? '').toLowerCase();

    if (formatId.isEmpty) return false;
    if (note.contains('storyboard')) return false;
    if (ext == 'mhtml') return false;
    if (vcodec.isNotEmpty && vcodec != 'none') return false;
    if (acodec.isNotEmpty && acodec != 'none') return true;
    return _looksLikeSeparatedAudio(format);
  }

  bool _looksLikeSeparatedAudio(Map<String, dynamic> format) {
    final vcodec = (_stringValue(format['vcodec']) ?? '').toLowerCase();
    if (vcodec.isNotEmpty && vcodec != 'none') {
      return false;
    }
    final formatId = (_stringValue(format['format_id']) ?? '').toLowerCase();
    final note = (_stringValue(format['format_note']) ?? '').toLowerCase();
    final formatName = (_stringValue(format['format']) ?? '').toLowerCase();
    return formatId.contains('audio') ||
        note.contains('audio only') ||
        formatName.contains('audio only');
  }

  bool _hasUsableAudio(Map<String, dynamic> format) {
    final acodec = (_stringValue(format['acodec']) ?? '').toLowerCase();
    return acodec.isNotEmpty && acodec != 'none';
  }

  /// Twitter's progressive MP4 already has AAC. The extractor omits acodec,
  /// which otherwise looks like a silent video and triggers a slow HLS audio
  /// download of the same sound.
  VideoFormat _markTwitterProgressiveAudio(VideoFormat format, String source) {
    if (!YtDlpVideoFormatSelector.isTwitterProgressiveVideo(
      format,
      source: source,
    )) {
      return format;
    }
    final codec = (format.audioCodec ?? '').trim().toLowerCase();
    if (format.hasAudio && codec.isNotEmpty && codec != 'none') {
      return format;
    }
    return VideoFormat(
      formatId: format.formatId,
      ext: format.ext,
      container: format.container,
      videoCodec: format.videoCodec,
      audioCodec: 'aac',
      width: format.width,
      height: format.height,
      fps: format.fps,
      bitrate: format.bitrate,
      fileSize: format.fileSize,
      formatNote: format.formatNote,
      hasAudio: true,
      isHdr: format.isHdr,
    );
  }

  bool _isHdr(Map<String, dynamic> format) {
    final note = (_stringValue(format['format_note']) ?? '').toLowerCase();
    final dynamicRange = (_stringValue(format['dynamic_range']) ?? '')
        .toLowerCase();
    return note.contains('hdr') || dynamicRange.contains('hdr');
  }

  String _resolveSource(Map<String, dynamic> rawInfo) {
    final extractor =
        _stringValue(rawInfo['extractor_key']) ??
        _stringValue(rawInfo['extractor']) ??
        '';
    final lower = extractor.toLowerCase();
    if (lower.contains('youtube')) {
      return 'youtube';
    }
    if (lower.isNotEmpty) {
      return lower;
    }
    return 'generic';
  }

  String? _inferVideoCodec(Map<String, dynamic> format) {
    final formatText =
        '${_stringValue(format['format']) ?? ''} ${_stringValue(format['format_note']) ?? ''}'
            .toLowerCase();
    if (formatText.contains('avc') || formatText.contains('h264')) {
      return 'h264';
    }
    if (formatText.contains('vp9')) {
      return 'vp9';
    }
    if (formatText.contains('av01') || formatText.contains('av1')) {
      return 'av1';
    }
    if (formatText.contains('hev1') || formatText.contains('h265')) {
      return 'h265';
    }
    final formatId = (_stringValue(format['format_id']) ?? '').toLowerCase();
    final ext = (_stringValue(format['ext']) ?? '').toLowerCase();
    final hasPicture =
        (_intValue(format['width']) ?? 0) > 0 ||
        (_intValue(format['height']) ?? 0) > 0;
    if (hasPicture && (formatId.startsWith('http') || ext == 'mp4')) {
      return 'h264';
    }
    return null;
  }

  String? _inferAudioCodec(Map<String, dynamic> format) {
    final formatText =
        '${_stringValue(format['format']) ?? ''} ${_stringValue(format['format_note']) ?? ''}'
            .toLowerCase();
    if (formatText.contains('aac')) {
      return 'aac';
    }
    if (formatText.contains('opus')) {
      return 'opus';
    }
    if (formatText.contains('mp3')) {
      return 'mp3';
    }
    final formatId = (_stringValue(format['format_id']) ?? '').toLowerCase();
    if (formatId.contains('audio') || formatId.contains('mp4a')) {
      return 'aac';
    }
    return null;
  }

  String? _normalizeCodec(String? codec, {String? fallback}) {
    final normalized = codec?.trim();
    if (normalized == null || normalized.isEmpty || normalized == 'none') {
      return fallback;
    }
    return normalized;
  }

  String _subtitleDisplayName(String languageCode, bool isAuto) {
    final label = resolveSubtitleLanguageLabel(languageCode);
    return isAuto ? '$label (自动)' : label;
  }

  int _subtitlePriorityScore(SubtitleTrack track) {
    final normalized = normalizeSubtitleLanguageCode(track.languageCode);
    var score = 0;
    if (_isSimplifiedChineseSubtitle(normalized)) {
      score += 5000;
    } else if (_isTraditionalChineseSubtitle(normalized)) {
      score += 4900;
    } else if (normalized == 'zh' || normalized.startsWith('zh-')) {
      score += 4800;
    } else if (normalized == 'en' || normalized.startsWith('en-')) {
      score += 4700;
    }
    if (!track.isAutoGenerated) {
      score += 200;
    }
    if (track.extCandidates.any((item) => item.toLowerCase() == 'srt')) {
      score += 30;
    }
    if (track.extCandidates.any((item) => item.toLowerCase() == 'vtt')) {
      score += 10;
    }
    return score;
  }

  static String _resolveSubtitleLanguageLabelImpl(String languageCode) {
    final normalized = normalizeSubtitleLanguageCode(languageCode);
    if (normalized.isEmpty) {
      return languageCode;
    }
    if (_isSimplifiedChineseSubtitle(normalized)) {
      return '中文(简体)';
    }
    if (_isTraditionalChineseSubtitle(normalized)) {
      return '中文(繁体)';
    }
    if (normalized == 'zh' || normalized.startsWith('zh-')) {
      return '中文';
    }
    final direct = _subtitleLanguageNames[normalized];
    if (direct != null) {
      return direct;
    }
    final parts = normalized.split('-');
    final primary = parts.first;
    final primaryLabel = _subtitleLanguageNames[primary];
    if (primaryLabel != null && parts.length > 1) {
      final suffix = parts[1].toUpperCase();
      return '$primaryLabel ($suffix)';
    }
    return primaryLabel ?? languageCode;
  }

  static String _normalizeSubtitleLanguageCodeImpl(String languageCode) {
    final normalized = languageCode.trim().replaceAll('_', '-').toLowerCase();
    if (normalized.isEmpty) {
      return '';
    }
    final parts = normalized
        .split('-')
        .where((item) => item.trim().isNotEmpty)
        .toList();
    if (parts.isEmpty) {
      return '';
    }
    final selected = <String>[parts.first];
    if (parts.length > 1) {
      final second = parts[1];
      if (second.length == 2 || second.length == 4) {
        selected.add(second);
      }
    }
    return selected.join('-');
  }

  static bool _isSimplifiedChineseSubtitle(String normalized) {
    return normalized == 'zh-cn' ||
        normalized == 'zh-hans' ||
        normalized == 'zh-sg';
  }

  static bool _isTraditionalChineseSubtitle(String normalized) {
    return normalized == 'zh-tw' ||
        normalized == 'zh-hant' ||
        normalized == 'zh-hk' ||
        normalized == 'zh-mo';
  }

  static const Map<String, String> _subtitleLanguageNames = {
    'aa': 'Afar',
    'ab': 'Abkhazian',
    'af': 'Afrikaans',
    'ak': 'Akan',
    'am': 'Amharic',
    'ar': 'العربية',
    'as': 'Assamese',
    'av': 'Avaric',
    'ay': 'Aymara',
    'az': 'Azərbaycan',
    'ba': 'Bashkir',
    'be': 'Беларуская',
    'bg': 'Български',
    'bh': 'Bihari',
    'bi': 'Bislama',
    'bm': 'Bambara',
    'bn': 'বাংলা',
    'bo': 'བོད་ཡིག',
    'br': 'Breton',
    'bs': 'Bosanski',
    'ca': 'Català',
    'ce': 'Chechen',
    'co': 'Corsu',
    'cs': 'Čeština',
    'cy': 'Cymraeg',
    'da': 'Dansk',
    'de': 'Deutsch',
    'el': 'Ελληνικά',
    'en': 'English',
    'eo': 'Esperanto',
    'es': 'Español',
    'et': 'Eesti',
    'eu': 'Euskara',
    'fa': 'فارسی',
    'fi': 'Suomi',
    'fo': 'Føroyskt',
    'fr': 'Français',
    'fy': 'Frysk',
    'ga': 'Gaeilge',
    'gd': 'Gàidhlig',
    'gl': 'Galego',
    'gn': 'Guaraní',
    'gu': 'ગુજરાતી',
    'ha': 'Hausa',
    'haw': 'ʻŌlelo Hawaiʻi',
    'he': 'עברית',
    'hi': 'हिन्दी',
    'hr': 'Hrvatski',
    'ht': 'Kreyòl',
    'hu': 'Magyar',
    'hy': 'Հայերեն',
    'id': 'Indonesia',
    'ig': 'Igbo',
    'is': 'Íslenska',
    'it': 'Italiano',
    'ja': '日本語',
    'jv': 'Jawa',
    'ka': 'ქართული',
    'kk': 'Қазақша',
    'km': 'ខ្មែរ',
    'kn': 'ಕನ್ನಡ',
    'ko': '한국어',
    'ku': 'Kurdî',
    'ky': 'Кыргызча',
    'la': 'Latina',
    'lb': 'Lëtzebuergesch',
    'lg': 'Luganda',
    'ln': 'Lingála',
    'lo': 'ລາວ',
    'lt': 'Lietuvių',
    'lv': 'Latviešu',
    'mg': 'Malagasy',
    'mi': 'Māori',
    'mk': 'Македонски',
    'ml': 'മലയാളം',
    'mn': 'Монгол',
    'mr': 'मराठी',
    'ms': 'Melayu',
    'mt': 'Malti',
    'my': 'မြန်မာ',
    'ne': 'नेपाली',
    'nl': 'Nederlands',
    'no': 'Norsk',
    'ny': 'Chichewa',
    'oc': 'Occitan',
    'or': 'ଓଡ଼ିଆ',
    'pa': 'ਪੰਜਾਬੀ',
    'pl': 'Polski',
    'ps': 'پښتو',
    'pt': 'Português',
    'qu': 'Quechua',
    'ro': 'Română',
    'ru': 'Русский',
    'rw': 'Kinyarwanda',
    'sd': 'سنڌي',
    'si': 'සිංහල',
    'sk': 'Slovenčina',
    'sl': 'Slovenščina',
    'sm': 'Samoan',
    'sn': 'Shona',
    'so': 'Soomaali',
    'sq': 'Shqip',
    'sr': 'Српски',
    'st': 'Sesotho',
    'su': 'Sunda',
    'sv': 'Svenska',
    'sw': 'Kiswahili',
    'ta': 'தமிழ்',
    'te': 'తెలుగు',
    'tg': 'Тоҷикӣ',
    'th': 'ไทย',
    'tk': 'Türkmen',
    'tl': 'Filipino',
    'tr': 'Türkçe',
    'tt': 'Tatar',
    'ug': 'ئۇيغۇرچە',
    'uk': 'Українська',
    'ur': 'اردو',
    'uz': 'Oʻzbek',
    'vi': 'Tiếng Việt',
    'wo': 'Wolof',
    'xh': 'isiXhosa',
    'yi': 'ייִדיש',
    'yo': 'Yorùbá',
    'zh': '中文',
    'zu': 'isiZulu',
  };

  String _videoResolutionGroup(int? height) {
    if (height == null || height <= 0) {
      return 'unknown';
    }
    if (height >= 2160) return '2160p+';
    if (height >= 1440) return '1440p';
    if (height >= 1080) return '1080p';
    if (height >= 720) return '720p';
    if (height >= 480) return '480p';
    if (height >= 360) return '360p';
    return 'other';
  }

  List<VideoFormat> _dedupeVideoFormats(List<VideoFormat> formats) {
    final seen = <String>{};
    final deduped = <VideoFormat>[];
    for (final format in formats) {
      final key =
          '${format.formatId}|${format.ext}|${format.height}|${format.videoCodec}|${format.hasAudio}';
      if (seen.add(key)) {
        deduped.add(format);
      }
    }
    return deduped;
  }

  List<AudioFormat> _dedupeAudioFormats(List<AudioFormat> formats) {
    final seen = <String>{};
    final deduped = <AudioFormat>[];
    for (final format in formats) {
      final key =
          '${format.formatId}|${format.ext}|${format.audioCodec}|${format.language}|${format.bitrate}';
      if (seen.add(key)) {
        deduped.add(format);
      }
    }
    return deduped;
  }

  String? _stringValue(Object? value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  /// Prefer abr, then tbr. Accept numeric strings like "128" / "128.4" / "128k".
  int? _bitrateKbps(Map<String, dynamic> format) {
    return _parseBitrateKbps(format['abr']) ??
        _parseBitrateKbps(format['tbr']) ??
        _parseBitrateKbps(format['audio_bitrate']);
  }

  int? _parseBitrateKbps(Object? value) {
    final direct = _intValue(value);
    if (direct != null && direct > 0) return direct;
    if (value == null) return null;
    final match = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(value.toString());
    if (match == null) return null;
    final parsed = double.tryParse(match.group(1)!);
    if (parsed == null || parsed <= 0) return null;
    return parsed.round();
  }

  int? _intValue(Object? value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is double) return value.round();
    return int.tryParse(value.toString());
  }

  double? _doubleValue(Object? value) {
    if (value == null) return null;
    if (value is double) return value;
    if (value is int) return value.toDouble();
    return double.tryParse(value.toString());
  }
}

/// Audio dropdown text. Language names reuse the subtitle catalog so the
/// list order (原声, 中文, English, …) is visible on each row.
extension YtDlpAudioFormatLabel on AudioFormat {
  String get displayLabel {
    final parts = <String>[];
    if (isDefaultTrack) {
      parts.add('原声');
    }
    final languageLabel = _audioLanguageLabel(language);
    if (languageLabel != null) {
      parts.add(languageLabel);
    } else if (!isDefaultTrack) {
      parts.add('未标注');
    }
    parts.add(_audioCodecShortLabel(audioCodec, ext));
    if (bitrate != null && bitrate! > 0) {
      parts.add('${bitrate}k');
    } else {
      parts.add('码率未提供');
    }
    if (isDynamicRangeCompressed) {
      parts.add('DRC');
    }
    if (protocol?.contains('m3u8') == true) parts.add('HLS');
    return parts.join(' · ');
  }
}

String? _audioLanguageLabel(String? language) {
  final normalized = language?.trim() ?? '';
  if (normalized.isEmpty || RegExp(r'^\d+$').hasMatch(normalized)) {
    return null;
  }
  return YtDlpMetaParser.resolveSubtitleLanguageLabel(normalized);
}

String _audioCodecShortLabel(String? audioCodec, String ext) {
  final codec = (audioCodec ?? '').trim().toLowerCase();
  final container = ext.trim().toLowerCase();
  if (codec.contains('aac') ||
      codec.contains('mp4a') ||
      container == 'm4a' ||
      container == 'aac') {
    return 'AAC';
  }
  if (codec.contains('opus') || container == 'opus') return 'Opus';
  if (codec.contains('mp3') || container == 'mp3') return 'MP3';
  if (codec.contains('vorbis')) return 'Vorbis';
  if (codec.contains('flac') || container == 'flac') return 'FLAC';
  if (codec.contains('eac3') || codec.contains('ec-3')) return 'EAC3';
  if (codec.contains('ac3') || codec.contains('ac-3')) return 'AC3';
  if (codec.isNotEmpty && codec != 'none') {
    return codec.split('.').first.toUpperCase();
  }
  if (container.isNotEmpty && container != 'unknown') {
    return container.toUpperCase();
  }
  return '音频';
}
