import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/subtitle_font.dart';
import '../models/subtitle_style.dart';
import '../utils/subtitle_font_parser.dart';
import '../utils/subtitle_font_resolver.dart';
import 'network/network_http.dart';

class SubtitleFontService extends ChangeNotifier {
  static final instance = SubtitleFontService();
  final Directory? storageDirectory;
  final Future<void> Function(String, List<Uint8List>)? fontLoader;
  final Future<Uint8List> Function(
    String,
    CancelToken,
    void Function(int, int)?,
  )?
  fetchBytes;
  SubtitleFontService({
    this.storageDirectory,
    this.fontLoader,
    this.fetchBytes,
  });
  Future<void>? _initialization;
  Directory? _directory;
  SharedPreferences? _prefs;
  final Map<String, SubtitleFontAsset> _imported = {};
  final Set<String> _loaded = {};
  final Map<String, Future<void>> _loading = {};
  Future<void> _writes = Future.value();
  String? loadError;
  final Map<String, String> _languages = {};
  Future<void> get ready => _initialization ??= _initialize();

  static const bundled = <SubtitleFontAsset>[
    SubtitleFontAsset(id: 'System', name: '系统字体'),
    SubtitleFontAsset(
      id: 'Noto Sans SC',
      name: '思源黑体',
      weights: [100, 200, 300, 400, 500, 700, 900],
      license: SubtitleFontLicense.commercial,
      assetPath: 'assets/fonts/licenses/NotoSans-OFL.txt',
      sourceUrl: 'https://github.com/notofonts/noto-cjk',
      licenseUrl: 'https://openfontlicense.org/',
      verifiedOn: '2026-09-09',
    ),
    SubtitleFontAsset(
      id: 'Inter',
      name: 'Inter',
      weights: [100, 200, 300, 400, 500, 600, 700, 800, 900],
      license: SubtitleFontLicense.commercial,
      assetPath: 'assets/fonts/licenses/Inter-OFL.txt',
      sourceUrl: 'https://github.com/rsms/inter',
      licenseUrl: 'https://openfontlicense.org/',
      verifiedOn: '2026-09-09',
    ),
    SubtitleFontAsset(
      id: 'Comic Relief',
      name: 'Comic Relief',
      weights: [400, 700],
      license: SubtitleFontLicense.commercial,
      assetPath: 'assets/fonts/licenses/ComicRelief-OFL.txt',
      sourceUrl: 'https://github.com/loudifier/Comic-Relief',
      licenseUrl: 'https://openfontlicense.org/',
      verifiedOn: '2026-09-09',
    ),
    SubtitleFontAsset(
      id: 'Roboto',
      name: 'Roboto Condensed',
      weights: [100, 200, 300, 400, 500, 600, 700, 800, 900],
      license: SubtitleFontLicense.commercial,
      assetPath: 'assets/fonts/licenses/RobotoCondensed-OFL.txt',
      sourceUrl: 'https://github.com/googlefonts/RobotoCondensed',
      licenseUrl: 'https://openfontlicense.org/',
      verifiedOn: '2026-09-09',
    ),
    SubtitleFontAsset(
      id: 'Brawler',
      name: 'Brawler',
      weights: [400, 700],
      license: SubtitleFontLicense.commercial,
      assetPath: 'assets/fonts/licenses/Brawler-OFL.txt',
      sourceUrl: 'https://github.com/google/fonts/tree/main/ofl/brawler',
      licenseUrl: 'https://openfontlicense.org/',
      verifiedOn: '2026-09-09',
    ),
  ];
  List<SubtitleFontAsset> get fonts => [...bundled, ..._imported.values];
  SubtitleFontAsset? find(String id) =>
      _imported[id] ?? bundled.where((f) => f.id == id).firstOrNull;
  String nameOf(String id) => find(id)?.name ?? id;
  bool get initialized => _directory != null;
  bool isLoaded(String id) =>
      !id.startsWith('subtitle_font_') || _loaded.contains(id);

  Future<void> _initialize() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      final savedLanguages = _prefs!.getString('subtitleFontLanguages');
      if (savedLanguages != null) {
        _languages.addAll(
          (jsonDecode(savedLanguages) as Map).cast<String, String>(),
        );
      }
      _directory =
          storageDirectory ??
          Directory(
            p.join(
              (await getApplicationSupportDirectory()).path,
              'subtitle_fonts',
            ),
          );
      await _directory!.create(recursive: true);
      final registry = File(p.join(_directory!.path, 'library.json'));
      if (await registry.exists()) {
        for (final entry in jsonDecode(await registry.readAsString()) as List) {
          final font = SubtitleFontAsset.fromJson(
            (entry as Map).cast<String, dynamic>(),
          );
          _imported[font.id] = font;
        }
      }
    } catch (e) {
      loadError = '字体库读取失败：$e';
    }
    notifyListeners();
  }

  Future<void> _save() {
    final snapshot = jsonEncode(
      _imported.values.map((f) => f.toJson()).toList(),
    );
    final write = _writes.then((_) async {
      final file = File(p.join(_directory!.path, 'library.json'));
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(snapshot, flush: true);
      await temporary.rename(file.path);
    });
    _writes = write.catchError((Object _) {});
    return write;
  }

  Future<SubtitleFontAsset> importFile(String path) async {
    await ready;
    final extension = p.extension(path).toLowerCase();
    if (!['.ttf', '.otf'].contains(extension)) {
      throw const FormatException('请选择 TTF 或 OTF 字体');
    }
    final file = File(path);
    if (await file.length() > 64 * 1024 * 1024) {
      throw const FormatException('字体文件不能超过 64 MB');
    }
    return _install([await file.readAsBytes()], [extension]);
  }

  Future<SubtitleFontAsset> _install(
    List<Uint8List> faces,
    List<String> extensions, {
    SubtitleOnlineFont? online,
    String licenseText = '',
  }) async {
    if (_directory == null || loadError != null) {
      throw StateError(loadError ?? '字体目录不可用');
    }
    final parsed = await Future.wait(
      faces.map((face) => compute(parseSubtitleFont, face)),
    );
    final hashes = faces.map((b) => sha256.convert(b).toString()).toList();
    final existing = _imported.values
        .where(
          (f) => online == null
              ? f.faceHashes.contains(hashes.first)
              : listEquals(f.faceHashes, hashes),
        )
        .firstOrNull;
    if (existing != null) {
      var repaired = false;
      for (var i = 0; i < hashes.length; i++) {
        final index = existing.faceHashes.indexOf(hashes[i]);
        if (index < 0) continue;
        final file = File(existing.facePaths[index]);
        if (!await file.exists() ||
            sha256.convert(await file.readAsBytes()).toString() != hashes[i]) {
          await file.writeAsBytes(faces[i], flush: true);
          repaired = true;
        }
      }
      if (repaired) {
        _loaded.remove(existing.id);
        _prepared.removeWhere(
          (key, value) => key.split('|').contains(existing.id),
        );
      }
      await ensureLoaded(existing.id);
      return existing;
    }
    final digest = sha256.convert(utf8.encode(hashes.join(':'))).toString();
    final id = 'subtitle_font_$digest';
    final paths = <String>[];
    for (var i = 0; i < faces.length; i++) {
      final path = p.join(_directory!.path, '${hashes[i]}${extensions[i]}');
      await File(path).writeAsBytes(faces[i], flush: true);
      paths.add(path);
    }
    final weights = parsed.expand((f) => f.weights).toSet().toList()..sort();
    final font = SubtitleFontAsset(
      id: id,
      name: online?.name ?? parsed.first.family,
      internalFamily: parsed.first.family,
      path: paths.first,
      facePaths: paths,
      faceHashes: hashes,
      sha256: digest,
      weights: weights,
      coverage: parsed.expand((f) => f.coverage).toList(),
      license: online?.license ?? SubtitleFontLicense.unknown,
      licenseText: licenseText,
      sourceUrl: online?.sourceUrl ?? '',
      licenseUrl: online?.licenseFile ?? '',
      verifiedOn: online?.verifiedOn ?? '',
    );
    await _load(id, faces);
    if (licenseText.isNotEmpty) {
      await File(
        p.join(_directory!.path, '$id-LICENSE.txt'),
      ).writeAsString(licenseText, flush: true);
    }
    _imported[id] = font;
    try {
      await _save();
    } catch (_) {
      _imported.remove(id);
      rethrow;
    }
    notifyListeners();
    return font;
  }

  Future<void> _load(String id, List<Uint8List> bytes) async {
    if (_loaded.contains(id)) return;
    if (fontLoader != null) {
      await fontLoader!(id, bytes);
    } else {
      final loader = FontLoader(id);
      for (final face in bytes) {
        loader.addFont(Future.value(ByteData.sublistView(face)));
      }
      await loader.load();
    }
    _loaded.add(id);
  }

  Future<void> ensureLoaded(String id) async {
    if (!id.startsWith('subtitle_font_') || _loaded.contains(id)) return;
    return _loading.putIfAbsent(id, () async {
      try {
        await ready;
        final font = _imported[id];
        if (font == null) throw StateError('找不到字幕字体，请重新导入：$id');
        final paths = font.facePaths.isNotEmpty ? font.facePaths : [font.path!];
        final faces = <Uint8List>[];
        for (var i = 0; i < paths.length; i++) {
          final file = File(paths[i]);
          if (!await file.exists()) throw StateError('字幕字体文件缺失：${font.name}');
          final bytes = await file.readAsBytes();
          if (i < font.faceHashes.length &&
              sha256.convert(bytes).toString() != font.faceHashes[i]) {
            throw StateError('字幕字体文件已改变：${font.name}');
          }
          faces.add(bytes);
        }
        await _load(id, faces);
      } finally {
        _loading.remove(id);
      }
    });
  }

  final Map<String, Future<void>> _prepared = {};
  Future<void> prepareFamilies(Iterable<String> values) {
    final families =
        values.where((f) => f.startsWith('subtitle_font_')).toSet().toList()
          ..sort();
    return _prepared.putIfAbsent(
      families.join('|'),
      () => Future.wait(families.map(ensureLoaded)),
    );
  }

  Future<void> prepareStyle(SubtitleStyle style) => prepareFamilies([
    style.textStyle.defaultFont.family,
    ...style.textStyle.resolvedLanguageFonts.values.map((f) => f.family),
  ]);

  Set<String> familiesForTracks(
    SubtitleTextStyle style, {
    required Iterable<String> primary,
    required Iterable<String> secondary,
    String? primaryLanguage,
    String? secondaryLanguage,
    bool splitByLine = false,
  }) {
    final families = <String>{};
    final separate = secondary.toList();
    for (final text in primary) {
      final lines = text.split('\n');
      if (splitByLine && separate.isEmpty && lines.length > 1) {
        families.addAll(
          familiesForText(lines.first, style, language: primaryLanguage),
        );
        families.addAll(
          familiesForText(
            lines.skip(1).join('\n'),
            style,
            language: secondaryLanguage,
          ),
        );
      } else {
        families.addAll(
          familiesForText(text, style, language: primaryLanguage),
        );
      }
    }
    for (final text in separate) {
      families.addAll(
        familiesForText(text, style, language: secondaryLanguage),
      );
    }
    return families;
  }

  Future<void> verifyFiles(Iterable<String> families) async {
    await ready;
    for (final id in families.toSet()) {
      if (!id.startsWith('subtitle_font_')) continue;
      final font = find(id);
      if (font == null) throw StateError('字幕字体未安装：$id');
      for (var i = 0; i < font.facePaths.length; i++) {
        final file = File(font.facePaths[i]);
        if (!await file.exists() ||
            sha256.convert(await file.readAsBytes()).toString() !=
                font.faceHashes[i]) {
          throw StateError('字幕字体缺失或已改变：${font.name}');
        }
      }
      await ensureLoaded(id);
    }
  }

  Future<List<SubtitleOnlineFont>>? _catalog;
  Future<List<SubtitleOnlineFont>> catalog() => _catalog ??= _loadCatalog();
  Future<List<SubtitleOnlineFont>> _loadCatalog() async {
    final raw =
        jsonDecode(
              await rootBundle.loadString(
                'assets/fonts/licenses/subtitle-font-catalog.json',
              ),
            )
            as Map;
    return (raw['fonts'] as List)
        .map(
          (f) =>
              SubtitleOnlineFont.fromJson((f as Map).cast<String, dynamic>()),
        )
        .toList();
  }

  Future<Uint8List> _fetch(
    String url,
    CancelToken cancel,
    void Function(int, int)? progress,
  ) async {
    if (cancel.isCancelled) throw cancel.cancelError!;
    if (fetchBytes != null) return fetchBytes!(url, cancel, progress);
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 25),
        receiveTimeout: const Duration(seconds: 60),
      ),
    );
    NetworkHttp.instance.configureDio(dio);
    try {
      final response = await openCancellableDioStream(
        (child) => dio.get<ResponseBody>(
          url,
          cancelToken: child,
          options: Options(responseType: ResponseType.stream),
        ),
        cancelToken: cancel,
      );
      final body = response.data!;
      final total =
          int.tryParse(
            body.headers[Headers.contentLengthHeader]?.firstOrNull ?? '',
          ) ??
          -1;
      if (total > 64 * 1024 * 1024) throw const FormatException('字体文件过大');
      final builder = BytesBuilder(copy: false);
      await for (final chunk in body.stream) {
        builder.add(chunk);
        if (builder.length > 64 * 1024 * 1024) {
          throw const FormatException('字体文件过大');
        }
        progress?.call(builder.length, total);
      }
      return builder.takeBytes();
    } finally {
      dio.close(force: true);
    }
  }

  Future<SubtitleFontAsset> download(
    SubtitleOnlineFont font, {
    required CancelToken cancel,
    void Function(double?)? onProgress,
  }) async {
    await ready;
    if (!font.directDownload) throw StateError('请到字体官网获取');
    final license = utf8.decode(await _fetch(font.licenseFile, cancel, null));
    if (license.trim().isEmpty) throw const FormatException('无法读取字体许可证');
    final faces = <Uint8List>[];
    for (var i = 0; i < font.files.length; i++) {
      final face = await _fetch(
        font.files[i],
        cancel,
        (received, total) => onProgress?.call(
          total > 0 ? (i + received / total) / font.files.length : null,
        ),
      );
      final actualHash = i < font.hashes.length && font.hashes[i].length == 40
          ? sha1.convert([
              ...utf8.encode('blob ${face.length}\u0000'),
              ...face,
            ]).toString()
          : sha256.convert(face).toString();
      if (i >= font.hashes.length || actualHash != font.hashes[i]) {
        throw const FormatException('字体校验失败，请重试');
      }
      faces.add(face);
    }
    if (cancel.isCancelled) throw cancel.cancelError!;
    return _install(
      faces,
      font.files.map((u) => p.extension(Uri.parse(u).path)).toList(),
      online: font,
      licenseText: license,
    );
  }

  final Map<String, String?> _inferredLanguages = {};
  bool hasLanguageForSource(String path) =>
      _inferredLanguages.containsKey(_sourceKey(path)) ||
      _languages.containsKey(_sourceKey(path));
  String? secondarySource(String? primary, String? secondary) =>
      secondary ?? (primary == null ? null : '$primary#subtitle-secondary');
  String? manualLanguageForSource(String? path) =>
      path == null ? null : _languages[_sourceKey(path)];
  String? languageForSource(
    String? path, {
    String? label,
    Iterable<String> texts = const [],
  }) {
    if (path == null) return null;
    final key = _sourceKey(path);
    if (_languages.containsKey(key)) return _languages[key];
    if (_inferredLanguages.containsKey(key)) return _inferredLanguages[key];
    final name = '${label ?? ''} ${p.basename(path)}'.toLowerCase();
    String? language;
    for (final entry in {
      'ja': ['日文', '日语', '日本語', 'japanese'],
      'ko': ['韩文', '韩语', '한국', 'korean'],
      'zh': ['中文', '汉语', 'chinese'],
      'en': ['英文', '英语', 'english'],
    }.entries) {
      if (entry.value.any(name.contains)) {
        language = entry.key;
        break;
      }
    }
    final match = RegExp(
      r'(?:^|[. _\-\[\(])(zh(?:-hans|-hant|-cn|-tw)?|en|ja|jpn|ko|kor|fr|de|es|ru|ar|th|hi|vi)(?:$|[. _\-\]\)])',
    ).firstMatch(name);
    language ??= match == null
        ? null
        : normalizeSubtitleLanguage(match.group(1));
    if (language == null && texts.isNotEmpty) {
      final sample = texts.take(100).join('\n');
      if (RegExp(r'[\u3040-\u30ff]').hasMatch(sample)) {
        language = 'ja';
      } else if (RegExp(r'[\uac00-\ud7af]').hasMatch(sample)) {
        language = 'ko';
      } else if (RegExp(r'[\u0600-\u06ff]').hasMatch(sample)) {
        language = 'ar';
      } else if (RegExp(r'[\u0400-\u052f]').hasMatch(sample)) {
        language = 'ru';
      } else if (RegExp(r'[\u4e00-\u9fff]').hasMatch(sample)) {
        language = 'zh';
      } else if (RegExp(r'[a-zA-Z]').hasMatch(sample)) {
        language = 'en';
      }
    }
    if (language != null || texts.isNotEmpty) {
      _inferredLanguages[key] = language;
    }
    return language;
  }

  String _sourceKey(String path) =>
      p.normalize(Platform.isWindows ? path.toLowerCase() : path);
  Future<void> setSourceLanguage(String path, String language) async {
    await ready;
    final key = _sourceKey(path), tag = normalizeSubtitleLanguage(language);
    if (tag.isEmpty) {
      _languages.remove(key);
    } else {
      _languages[key] = tag;
    }
    await _prefs!.setString('subtitleFontLanguages', jsonEncode(_languages));
    notifyListeners();
  }

  Set<String> familiesForText(
    String text,
    SubtitleTextStyle style, {
    String? language,
  }) => resolveSubtitleFontRuns(
    text,
    style,
    language: language,
  ).map((r) => r.font.family).toSet();
}
