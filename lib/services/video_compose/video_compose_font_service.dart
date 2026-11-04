import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:flutter/services.dart' show ByteData, rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/subtitle_style.dart';
import '../../models/subtitle_font.dart' show normalizeBundledFontFamily;
import '../subtitle_font_service.dart';

class VideoComposeFontService {
  static const Set<String> bundledFontFamilies = <String>{
    'Noto Sans SC',
    'MiSans',
    'Noto Serif CJK SC',
    'Swei Gothic CJK SC',
    'Comic Relief',
    'Roboto',
  };

  static const List<String> _bundledFontAssetPaths = <String>[
    'assets/fonts/Brawler-Bold.otf',
    'assets/fonts/Brawler-Medium.otf',
    'assets/fonts/Brawler-Regular.otf',
    'assets/fonts/Brawler-SemiBold.otf',
    'assets/fonts/ComicRelief-Bold.ttf',
    'assets/fonts/ComicRelief-Regular.ttf',
    'assets/fonts/Inter-Black.otf',
    'assets/fonts/Inter-Bold.otf',
    'assets/fonts/Inter-ExtraBold.otf',
    'assets/fonts/Inter-ExtraLight.otf',
    'assets/fonts/Inter-Light.otf',
    'assets/fonts/Inter-Medium.otf',
    'assets/fonts/Inter-Regular.otf',
    'assets/fonts/Inter-SemiBold.otf',
    'assets/fonts/Inter-Thin.otf',
    'assets/fonts/NotoSansCJKsc-Regular.otf',
    'assets/fonts/Roboto_Condensed-Black.ttf',
    'assets/fonts/Roboto_Condensed-Bold.ttf',
    'assets/fonts/Roboto_Condensed-ExtraBold.ttf',
    'assets/fonts/Roboto_Condensed-ExtraLight.ttf',
    'assets/fonts/Roboto_Condensed-Light.ttf',
    'assets/fonts/Roboto_Condensed-Medium.ttf',
    'assets/fonts/Roboto_Condensed-Regular.ttf',
    'assets/fonts/Roboto_Condensed-SemiBold.ttf',
    'assets/fonts/Roboto_Condensed-Thin.ttf',
  ];

  String? _mobileFontsDirCache;

  bool requiresBundledFonts(SubtitleStyle style) {
    return bundledFontFamilies.contains(
          normalizeBundledFontFamily(style.fontFamilyChinese),
        ) ||
        bundledFontFamilies.contains(
          normalizeBundledFontFamily(style.fontFamilyEnglish),
        );
  }

  Future<String?> resolveAssFontsDir() async {
    if (Platform.isWindows || Platform.isMacOS) {
      return _resolveBundledFontsDir();
    }
    if (Platform.isAndroid || Platform.isIOS) {
      return _prepareMobileFontsDir();
    }
    return null;
  }

  Future<void> configureForRender({String? fontsDir}) async {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    final List<String> fontDirs = <String>[];
    if (fontsDir != null) {
      fontDirs.add(fontsDir);
    }
    if (Platform.isAndroid) {
      fontDirs.add('/system/fonts');
    }
    if (Platform.isIOS) {
      fontDirs.add('/System/Library/Fonts');
    }
    if (fontDirs.isEmpty) return;
    final Map<String, String> fontNameMap = mobileFontNameMap();
    await FFmpegKitConfig.setFontDirectoryList(
      fontDirs,
      fontNameMap.isEmpty ? null : fontNameMap,
    );
    if (fontsDir != null) {
      await FFmpegKitConfig.setFontDirectory(
        fontsDir,
        fontNameMap.isEmpty ? null : fontNameMap,
      );
    }
  }

  String resolveSystemFont(String familyName) {
    familyName = normalizeBundledFontFamily(familyName);
    if (familyName.startsWith('subtitle_font_')) {
      final font = SubtitleFontService.instance.find(familyName);
      if (font == null) throw StateError('字幕字体未安装：$familyName');
      return font.internalFamily;
    }
    switch (familyName) {
      case 'Swei Gothic CJK SC':
        return '獅尾圓體SC-Bold';
      case 'Noto Sans SC':
        return 'Noto Sans CJK SC';
      case 'Noto Serif CJK SC':
        return 'Noto Serif CJK SC';
      case 'Comic Relief':
        return 'Comic Relief';
      case 'MiSans':
        return 'MiSans';
      case 'Roboto':
        return 'Roboto Condensed Condensed';
    }

    if (Platform.isAndroid || Platform.isIOS) {
      switch (familyName) {
        case 'Sans Serif':
        case 'System':
          return 'sans-serif';
        case 'Serif':
          return 'serif';
        case 'Monospace':
          return 'monospace';
        case 'Cursive':
          return 'cursive';
        default:
          return familyName;
      }
    }

    switch (familyName) {
      case 'Sans Serif':
      case 'System':
        return 'Arial';
      case 'Serif':
        return 'Times New Roman';
      case 'Monospace':
        return 'Courier New';
      case 'Cursive':
        return 'Comic Sans MS';
      default:
        return familyName;
    }
  }

  Map<String, String> mobileFontNameMap() {
    return <String, String>{
      'NotoSansCJKsc-Regular.otf': 'Noto Sans CJK SC',
      'NotoSerifCJKsc-Bold.otf': 'Noto Serif CJK SC',
      'SweiGothicCJKsc-Bold.ttf': '獅尾圓體SC-Bold',
      'ComicRelief-Regular.ttf': 'Comic Relief',
      'ComicRelief-Bold.ttf': 'Comic Relief',
      'MiSans-Thin.otf': 'MiSans',
      'MiSans-ExtraLight.otf': 'MiSans',
      'MiSans-Light.otf': 'MiSans',
      'MiSans-Regular.otf': 'MiSans',
      'MiSans-Normal.otf': 'MiSans',
      'MiSans-Medium.otf': 'MiSans',
      'MiSans-Semibold.otf': 'MiSans',
      'MiSans-Demibold.otf': 'MiSans',
      'MiSans-Bold.otf': 'MiSans',
      'MiSans-Heavy.otf': 'MiSans',
      'Roboto_Condensed-Thin.ttf': 'Roboto Condensed Condensed',
      'Roboto_Condensed-ExtraLight.ttf': 'Roboto Condensed Condensed',
      'Roboto_Condensed-Light.ttf': 'Roboto Condensed Condensed',
      'Roboto_Condensed-Regular.ttf': 'Roboto Condensed Condensed',
      'Roboto_Condensed-Medium.ttf': 'Roboto Condensed Condensed',
      'Roboto_Condensed-SemiBold.ttf': 'Roboto Condensed Condensed',
      'Roboto_Condensed-Bold.ttf': 'Roboto Condensed Condensed',
      'Roboto_Condensed-ExtraBold.ttf': 'Roboto Condensed Condensed',
      'Roboto_Condensed-Black.ttf': 'Roboto Condensed Condensed',
    };
  }

  /// Isolates each job's font versions from every other installed font file.
  Future<String> prepareAssFonts(
    SubtitleStyle style, {
    Set<String>? usedFamilies,
  }) async {
    final library = SubtitleFontService.instance;
    await library.ready;
    final families =
        usedFamilies ??
        {
          style.textStyle.defaultFont.family,
          ...style.textStyle.resolvedLanguageFonts.values.map((f) => f.family),
        };
    await library.verifyFiles(families);
    final directory = await (await getTemporaryDirectory()).createTemp(
      'compose_font_snapshot_',
    );
    try {
      final names = <String, String>{};
      for (final family in families) {
        if (!family.startsWith('subtitle_font_')) continue;
        final font = library.find(family)!;
        final existing = names[font.internalFamily];
        if (existing != null && existing != family) {
          throw StateError('同名字体的不同版本不能用于近似渲染，请选择精确渲染');
        }
        names[font.internalFamily] = family;
        for (final path in font.facePaths) {
          await File(path).copy(p.join(directory.path, p.basename(path)));
        }
      }
      // Copy selected weights only. A CJK family can contain hundreds of MB
      // of unused weights; one regular face is enough for the fallback.
      final choices = [
        style.textStyle.defaultFont,
        ...style.textStyle.resolvedLanguageFonts.values,
      ];
      final manifest =
          jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
      for (final node in manifest) {
        final family = node['family'];
        if (!families.contains(family) && family != 'Noto Sans SC') continue;
        final faces = node['fonts'] as List;
        if (faces.isEmpty) continue;
        final wanted = choices
            .where((f) => f.family == family)
            .map((f) => f.weight)
            .toSet();
        if (wanted.isEmpty) wanted.add(400);
        final selected = <String>{};
        for (final weight in wanted) {
          final closest = faces.reduce(
            (a, b) =>
                ((a['weight'] as int? ?? 400) - weight).abs() <=
                    ((b['weight'] as int? ?? 400) - weight).abs()
                ? a
                : b,
          );
          selected.add(closest['asset'] as String);
        }
        for (final asset in selected) {
          final bytes = await rootBundle.load(asset);
          await File(p.join(directory.path, p.basename(asset))).writeAsBytes(
            bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
            flush: true,
          );
        }
      }
      return directory.path;
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<String?> _prepareMobileFontsDir() async {
    if (_mobileFontsDirCache != null &&
        Directory(_mobileFontsDirCache!).existsSync()) {
      return _mobileFontsDirCache;
    }
    try {
      final List<String> discoveredAssets = await _collectBundledFontAssets();
      final Set<String> fontAssets = <String>{
        ..._bundledFontAssetPaths,
        ...discoveredAssets,
      };
      if (fontAssets.isEmpty) return null;
      final Directory tempDir = await getTemporaryDirectory();
      final Directory fontsDir = Directory(
        p.join(tempDir.path, 'compose_fonts'),
      );
      if (!await fontsDir.exists()) {
        await fontsDir.create(recursive: true);
      }
      // Remove only font files previously copied into this app-owned cache.
      for (final name in const [
        '方正黑体 简体中文.TTF',
        '方正楷体 简体中文.ttf',
        'OPPO Sans 4.0.ttf',
      ]) {
        final retiredFont = File(p.join(fontsDir.path, name));
        if (await retiredFont.exists()) await retiredFont.delete();
      }
      int copiedCount = 0;
      for (final String assetPath in fontAssets) {
        try {
          final ByteData data = await rootBundle.load(assetPath);
          final String fileName = p.basename(assetPath);
          final File file = File(p.join(fontsDir.path, fileName));
          await file.writeAsBytes(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
            flush: true,
          );
          copiedCount++;
        } catch (_) {}
      }
      if (copiedCount == 0) {
        return null;
      }
      _mobileFontsDirCache = fontsDir.path;
      return _mobileFontsDirCache;
    } catch (_) {
      return null;
    }
  }

  Future<List<String>> _collectBundledFontAssets() async {
    final Set<String> assets = <String>{};
    try {
      final String fontManifestContent = await rootBundle.loadString(
        'FontManifest.json',
      );
      final dynamic decoded = jsonDecode(fontManifestContent);
      if (decoded is List) {
        for (final dynamic familyNode in decoded) {
          if (familyNode is! Map) continue;
          final dynamic fonts = familyNode['fonts'];
          if (fonts is! List) continue;
          for (final dynamic fontNode in fonts) {
            if (fontNode is! Map) continue;
            final String? asset = fontNode['asset']?.toString();
            if (asset != null && _isFontAssetPath(asset)) {
              assets.add(asset);
            }
          }
        }
      }
    } catch (_) {}
    if (assets.isNotEmpty) {
      final List<String> list = assets.toList()..sort();
      return list;
    }
    try {
      final String assetManifestContent = await rootBundle.loadString(
        'AssetManifest.json',
      );
      final dynamic decoded = jsonDecode(assetManifestContent);
      if (decoded is Map) {
        for (final dynamic key in decoded.keys) {
          final String path = key.toString();
          if (_isFontAssetPath(path)) {
            assets.add(path);
          }
        }
      } else if (decoded is List) {
        for (final dynamic node in decoded) {
          if (node is Map && node['asset'] != null) {
            final String path = node['asset'].toString();
            if (_isFontAssetPath(path)) {
              assets.add(path);
            }
          } else if (node is String && _isFontAssetPath(node)) {
            assets.add(node);
          }
        }
      }
    } catch (_) {}
    final List<String> list = assets.toList()..sort();
    return list;
  }

  bool _isFontAssetPath(String path) {
    final String lower = path.toLowerCase();
    return lower.startsWith('assets/fonts/') &&
        (lower.endsWith('.ttf') ||
            lower.endsWith('.otf') ||
            lower.endsWith('.ttc'));
  }

  String? _resolveBundledFontsDir() {
    if (!(Platform.isWindows || Platform.isMacOS)) return null;
    final Directory exeDir = File(Platform.resolvedExecutable).parent;
    final String candidate = p.join(
      exeDir.path,
      'data',
      'flutter_assets',
      'assets',
      'fonts',
    );
    final Directory packagedDir = Directory(candidate);
    if (packagedDir.existsSync()) {
      return packagedDir.path;
    }
    final Directory devDir = Directory(
      p.join(Directory.current.path, 'assets', 'fonts'),
    );
    if (devDir.existsSync()) {
      return devDir.path;
    }
    return null;
  }
}
