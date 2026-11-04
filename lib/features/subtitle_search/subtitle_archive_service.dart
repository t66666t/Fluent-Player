import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../utils/subtitle_parser.dart';
import 'subtitle_entry_metadata.dart';
import 'subtitle_release_info.dart';
import 'subtitle_search_failures.dart';
import 'subtitle_search_models.dart';
import 'subtitle_text_codec.dart';
import 'subtitle_unrar.dart';

/// Budgets shared by download, listing, inflation and nested archives.
class ArchivePolicy {
  const ArchivePolicy({
    this.downloadBytes = 64 * 1024 * 1024,
    this.entryBytes = 8 * 1024 * 1024,
    this.expandedBytes = 64 * 1024 * 1024,
    this.maxEntries = 2000,
    this.maxDepth = 2,
    this.dictBytes = 64 * 1024 * 1024,
  });

  final int downloadBytes;
  final int entryBytes;
  final int expandedBytes;
  final int maxEntries;
  final int maxDepth;
  final int dictBytes;
}

enum ArchiveContainerKind {
  zip,
  rar4,
  rar5,
  sevenZip,
  text,
  html,
  json,
  empty,
  unknown,
}

class ArchiveEntryInfo {
  const ArchiveEntryInfo({
    required this.id,
    required this.path,
    required this.size,
    required this.method,
    required this.kind,
    this.encrypted = false,
    this.warning = '',
  });

  final String id;
  final String path;
  final int size;
  final String method;
  final String kind;
  final bool encrypted;
  final String warning;
}

class ArchiveManifest {
  const ArchiveManifest({
    required this.container,
    required this.backend,
    required this.entries,
    required this.complete,
    this.warnings = const [],
    this.capability = '',
  });

  final ArchiveContainerKind container;
  final String backend;
  final List<ArchiveEntryInfo> entries;
  final bool complete;
  final List<String> warnings;
  final String capability;

  int get textCandidates => entries.where((e) => e.kind == 'text').length;
}

class PackageDecodeResult {
  const PackageDecodeResult({
    required this.documents,
    required this.manifest,
    this.failure,
  });

  final List<SubtitleSearchDocument> documents;
  final ArchiveManifest manifest;
  final SubtitleFailure? failure;
}

class SubtitlePackageDecoder {
  const SubtitlePackageDecoder({this.policy = const ArchivePolicy()});
  final ArchivePolicy policy;

  PackageDecodeResult decode(
    Uint8List bytes, {
    required String name,
    String? password,
    String? encoding,
    bool Function()? cancelled,
  }) {
    final kind = identifyContainer(bytes, name: name);
    if (cancelled?.call() == true) {
      return _failed(kind, _cancelled());
    }
    try {
      return switch (kind) {
        ArchiveContainerKind.empty => _failed(kind, _empty()),
        ArchiveContainerKind.html => _failed(kind, _html()),
        ArchiveContainerKind.json => _failed(
          kind,
          const SubtitleFailure(
            stage: SubtitleFailureStage.inspect,
            kind: SubtitleFailureKind.htmlOrJson,
            message: '下载到的是错误信息，不是字幕文件',
            recovery: SubtitleRecovery.openDetail,
          ),
        ),
        ArchiveContainerKind.sevenZip => _failed(
          kind,
          const SubtitleFailure(
            stage: SubtitleFailureStage.extract,
            kind: SubtitleFailureKind.unsupported,
            message: '这是 7z 压缩包。当前构建没有链接 7z 解码器，不能把它当成解压失败或没有字幕',
            recovery: SubtitleRecovery.openDetail,
            detail: '7z',
          ),
        ),
        ArchiveContainerKind.rar4 || ArchiveContainerKind.rar5 => _rar(
          bytes,
          kind: kind,
          password: password ?? '',
          encoding: encoding,
          cancelled: cancelled,
        ),
        ArchiveContainerKind.zip => _zip(
          bytes,
          password: password,
          encoding: encoding,
          cancelled: cancelled,
          depth: 0,
          expanded: _Budget(policy),
        ),
        ArchiveContainerKind.text || ArchiveContainerKind.unknown => _loose(
          bytes,
          name: name,
          encoding: encoding,
        ),
      };
    } on SubtitleFailure catch (error) {
      return _failed(kind, error);
    }
  }

  PackageDecodeResult _loose(
    Uint8List bytes, {
    required String name,
    String? encoding,
  }) {
    if (bytes.length > policy.entryBytes) {
      throw _limit('单个字幕超过 ${policy.entryBytes ~/ (1024 * 1024)} MiB');
    }
    final document = _document(
      name: p.basename(name).isEmpty ? 'subtitle.srt' : p.basename(name),
      bytes: bytes,
      entryId: 'loose:${sha256.convert(bytes)}',
      encoding: encoding,
    );
    if (document == null) {
      throw const SubtitleFailure(
        stage: SubtitleFailureStage.parse,
        kind: SubtitleFailureKind.noSubtitle,
        message: '没有找到可读取的 SRT、VTT、ASS 或 SSA 字幕',
      );
    }
    return PackageDecodeResult(
      documents: [document],
      manifest: ArchiveManifest(
        container: ArchiveContainerKind.text,
        backend: 'text',
        entries: [
          ArchiveEntryInfo(
            id: document.entryId,
            path: document.name,
            size: bytes.length,
            method: 'store',
            kind: 'text',
          ),
        ],
        complete: true,
      ),
    );
  }

  PackageDecodeResult _zip(
    Uint8List bytes, {
    required String? password,
    required String? encoding,
    required bool Function()? cancelled,
    required int depth,
    required _Budget expanded,
  }) {
    if (bytes.length > policy.downloadBytes) throw _limit('压缩包超过下载上限');
    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(
        bytes,
        verify: true,
        password: password,
      );
    } on FormatException catch (error) {
      throw SubtitleFailure(
        stage: SubtitleFailureStage.extract,
        kind: error.message.toLowerCase().contains('password')
            ? SubtitleFailureKind.badPassword
            : SubtitleFailureKind.damaged,
        message: error.message.toLowerCase().contains('password')
            ? '压缩包密码不正确'
            : 'ZIP 校验未通过或文件已损坏',
        retryable: false,
        recovery: error.message.toLowerCase().contains('password')
            ? SubtitleRecovery.enterPassword
            : SubtitleRecovery.none,
      );
    }
    final packageHash = sha256.convert(bytes).toString();
    final entries = <ArchiveEntryInfo>[];
    final documents = <SubtitleSearchDocument>[];
    final warnings = <String>[];
    if (archive.length > policy.maxEntries) {
      throw _limit('压缩包超过 ${policy.maxEntries} 个条目');
    }
    var index = 0;
    for (final file in archive) {
      if (cancelled?.call() == true) throw _cancelled();
      final rawName = file.name.replaceAll('\\', '/');
      if (file.isSymbolicLink || _unsafePath(rawName)) {
        warnings.add('已跳过不安全路径：$rawName');
        continue;
      }
      if (!file.isFile) continue;
      final id = '$packageHash:$index:$rawName';
      index++;
      final extension = p.extension(rawName).toLowerCase();
      if (file.size > policy.entryBytes || !expanded.take(file.size)) {
        warnings.add('超过大小限制，停止继续展开：$rawName');
        entries.add(
          ArchiveEntryInfo(
            id: id,
            path: rawName,
            size: file.size,
            method: 'zip',
            kind: 'limit',
            warning: '超过大小限制',
          ),
        );
        break;
      }
      final payload = Uint8List.fromList(file.content);
      if (depth + 1 < policy.maxDepth &&
          (extension == '.zip' || extension == '.rar')) {
        final nested = extension == '.zip'
            ? _zip(
                payload,
                password: password,
                encoding: encoding,
                cancelled: cancelled,
                depth: depth + 1,
                expanded: expanded,
              )
            : _rar(
                payload,
                kind: identifyContainer(payload, name: rawName),
                password: password ?? '',
                encoding: encoding,
                cancelled: cancelled,
              );
        documents.addAll(nested.documents);
        entries.addAll(nested.manifest.entries);
        warnings.addAll(nested.manifest.warnings);
        continue;
      }
      final kind = _entryKind(extension);
      entries.add(
        ArchiveEntryInfo(
          id: id,
          path: rawName,
          size: payload.length,
          method: 'zip',
          kind: kind,
        ),
      );
      if (kind != 'text') continue;
      final document = _document(
        name: rawName,
        bytes: payload,
        entryId: id,
        encoding: encoding,
      );
      if (document != null) documents.add(document);
    }
    documents.sort(_byEpisode);
    return PackageDecodeResult(
      documents: documents,
      manifest: ArchiveManifest(
        container: ArchiveContainerKind.zip,
        backend: 'package:archive ZipDecoder verify=true',
        entries: entries,
        complete: true,
        warnings: warnings,
        capability: 'ZIP store/deflate，CRC 已校验',
      ),
      failure: documents.isEmpty ? _noText(entries, warnings) : null,
    );
  }

  PackageDecodeResult _rar(
    Uint8List bytes, {
    required ArchiveContainerKind kind,
    required String password,
    required String? encoding,
    required bool Function()? cancelled,
  }) {
    // The separately licensed helper also keeps native extraction failures
    // outside the player process. Prefer it to optional user-installed FFI.
    if (SubtitleUnrar.locateTool() != null) {
      return _rarTool(
        bytes,
        kind: kind,
        password: password,
        encoding: encoding,
        cancelled: cancelled,
      );
    }
    final native = SubtitleUnrar.tryLoad();
    if (native != null) {
      return _rarNative(
        native,
        bytes,
        kind: kind,
        password: password,
        encoding: encoding,
        cancelled: cancelled,
      );
    }
    if (kind == ArchiveContainerKind.rar5) {
      return _rar5StoreFallback(
        bytes,
        encoding: encoding,
        cancelled: cancelled,
      );
    }
    throw const SubtitleFailure(
      stage: SubtitleFailureStage.extract,
      kind: SubtitleFailureKind.unsupported,
      message: '这是 RAR 压缩包。此平台还没有可用的 UnRAR 解码库',
      recovery: SubtitleRecovery.openDetail,
      detail: 'rar4',
    );
  }

  PackageDecodeResult _rarNative(
    SubtitleUnrar native,
    Uint8List bytes, {
    required ArchiveContainerKind kind,
    required String password,
    required String? encoding,
    required bool Function()? cancelled,
  }) {
    final directory = Directory.systemTemp.createTempSync('subtitle-unrar-');
    final archivePath = p.join(directory.path, 'package.rar');
    File(archivePath).writeAsBytesSync(bytes, flush: true);
    final session = native.open(
      archivePath,
      password: password,
      dictLimitBytes: policy.dictBytes,
    );
    final entries = <ArchiveEntryInfo>[];
    final documents = <SubtitleSearchDocument>[];
    final warnings = <String>[];
    final packageHash = sha256.convert(bytes).toString();
    var expanded = 0;
    var index = 0;
    try {
      while (true) {
        if (cancelled?.call() == true) {
          session.cancel();
          throw _cancelled();
        }
        final UnrarEntry? entry;
        try {
          entry = session.next();
        } on UnrarException catch (error) {
          throw _fromUnrar(error);
        }
        if (entry == null) break;
        if (index >= policy.maxEntries) {
          session.skip();
          warnings.add('已达到 ${policy.maxEntries} 个条目上限');
          break;
        }
        final current = index++;
        final rawName = entry.name.replaceAll('\\', '/');
        if (entry.link || entry.isDirectory || _unsafePath(rawName)) {
          warnings.add(entry.link ? '已跳过链接：$rawName' : '已跳过目录或部分路径：$rawName');
          session.skip();
          continue;
        }
        final extension = p.extension(rawName).toLowerCase();
        final itemKind = _entryKind(extension);
        final id = '$packageHash:$current:$rawName';
        entries.add(
          ArchiveEntryInfo(
            id: id,
            path: rawName,
            size: entry.unpacked,
            method: 'rar m${entry.method} dict=${entry.dictKib}KiB',
            kind: itemKind,
            encrypted: entry.encrypted,
          ),
        );
        if (itemKind != 'text') {
          session.skip();
          continue;
        }
        if (entry.unpacked > policy.entryBytes ||
            expanded + entry.unpacked > policy.expandedBytes) {
          warnings.add('超过大小限制，停止继续展开：$rawName');
          session.skip();
          break;
        }
        final outputName = 'entry-$current.bin';
        try {
          session.extract(directory.path, outputName);
        } on UnrarException catch (error) {
          final failure = _fromUnrar(error);
          if (failure.kind == SubtitleFailureKind.entryParse) {
            warnings.add('${failure.message}：$rawName');
            continue;
          }
          throw failure;
        }
        final file = File(p.join(directory.path, outputName));
        final payload = file.existsSync()
            ? file.readAsBytesSync()
            : Uint8List(0);
        if (file.existsSync()) file.deleteSync();
        expanded += payload.length;
        final document = _document(
          name: rawName,
          bytes: payload,
          entryId: id,
          encoding: encoding,
        );
        if (document != null) documents.add(document);
      }
    } finally {
      session.close();
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    }
    documents.sort(_byEpisode);
    return PackageDecodeResult(
      documents: documents,
      manifest: ArchiveManifest(
        container: kind,
        backend: native.version,
        entries: entries,
        complete: warnings.every(
          (w) => !w.contains('上限') && !w.contains('大小限制'),
        ),
        warnings: warnings,
        capability: 'RAR4/RAR5 via ${native.version}; CRC checked by UnRAR',
      ),
      failure: documents.isEmpty ? _noText(entries, warnings) : null,
    );
  }

  PackageDecodeResult _rarTool(
    Uint8List bytes, {
    required ArchiveContainerKind kind,
    required String password,
    required String? encoding,
    required bool Function()? cancelled,
  }) {
    final tool = SubtitleUnrar.locateTool();
    if (tool == null) {
      throw const SubtitleFailure(
        stage: SubtitleFailureStage.extract,
        kind: SubtitleFailureKind.unsupported,
        message: '没有找到随应用提供的 RAR 解压组件',
      );
    }
    if (cancelled?.call() == true) throw _cancelled();
    final directory = Directory.systemTemp.createTempSync('subtitle-unrar-');
    final archivePath = p.join(directory.path, 'package.rar');
    final outdir = p.join(directory.path, 'out');
    Directory(outdir).createSync();
    File(archivePath).writeAsBytesSync(bytes, flush: true);
    try {
      final env = Map<String, String>.from(Platform.environment);
      if (password.isEmpty) {
        env.remove('SUBTITLE_UNRAR_PASSWORD');
      } else {
        env['SUBTITLE_UNRAR_PASSWORD'] = password;
      }
      final result = Process.runSync(
        tool,
        [archivePath, outdir],
        environment: env,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      final raw = '${result.stdout}'.trim();
      if (raw.isEmpty) {
        throw SubtitleFailure(
          stage: SubtitleFailureStage.extract,
          kind: SubtitleFailureKind.damaged,
          message: '解压组件没有返回结果（${result.exitCode}）',
          detail: '${result.stderr}',
        );
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const SubtitleFailure(
          stage: SubtitleFailureStage.extract,
          kind: SubtitleFailureKind.damaged,
          message: '解压组件返回了无法识别的结果',
        );
      }
      final code = decoded['code'] as int? ?? 0;
      final rows = decoded['entries'];
      final entries = <ArchiveEntryInfo>[];
      final documents = <SubtitleSearchDocument>[];
      final packageHash = sha256.convert(bytes).toString();
      if (rows is List) {
        for (final row in rows.whereType<Map>()) {
          final name = '${row['name'] ?? ''}'.replaceAll('\\', '/');
          final index = row['index'] as int? ?? entries.length;
          final unpacked = row['unpacked'] as int? ?? 0;
          final flags = row['flags'] as int? ?? 0;
          final id = '$packageHash:$index:$name';
          final extension = p.extension(name).toLowerCase();
          entries.add(
            ArchiveEntryInfo(
              id: id,
              path: name,
              size: unpacked,
              method: 'rar m${row['method']} dict=${row['dict']}KiB',
              kind: _entryKind(extension),
              encrypted: flags & 2 != 0,
            ),
          );
          final fileName = '${row['file'] ?? ''}';
          if (fileName.isEmpty || _unsafePath(fileName)) continue;
          final payloadFile = File(p.join(outdir, fileName));
          if (!payloadFile.existsSync()) continue;
          final payload = payloadFile.readAsBytesSync();
          final document = _document(
            name: name,
            bytes: Uint8List.fromList(payload),
            entryId: id,
            encoding: encoding,
          );
          if (document != null) documents.add(document);
        }
      }
      if (documents.isEmpty && code != 0) {
        throw _fromUnrar(UnrarException(code, '${decoded['error'] ?? ''}'));
      }
      documents.sort(_byEpisode);
      return PackageDecodeResult(
        documents: documents,
        manifest: ArchiveManifest(
          container: kind,
          backend: 'UnRAR 7.13 bundled tool',
          entries: entries,
          complete: code == 0,
          capability: 'RAR4/RAR5；Windows 上以随包进程运行，因为 dart.exe 无法完成该 DLL 的初始化',
        ),
        failure: documents.isEmpty ? _noText(entries, const []) : null,
      );
    } finally {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    }
  }

  PackageDecodeResult _rar5StoreFallback(
    Uint8List bytes, {
    required String? encoding,
    required bool Function()? cancelled,
  }) {
    final reader = _Rar5Reader(bytes);
    final listed = reader.list();
    final documents = <SubtitleSearchDocument>[];
    final entries = <ArchiveEntryInfo>[];
    final packageHash = sha256.convert(bytes).toString();
    var index = 0;
    for (final item in listed) {
      if (cancelled?.call() == true) throw _cancelled();
      final id = '$packageHash:$index:${item.path}';
      index++;
      final extension = p.extension(item.path).toLowerCase();
      entries.add(
        ArchiveEntryInfo(
          id: id,
          path: item.path,
          size: item.unpacked,
          method: item.methodLabel,
          kind: _entryKind(extension),
          encrypted: item.encrypted,
        ),
      );
      if (item.stored == null || _entryKind(extension) != 'text') continue;
      final document = _document(
        name: item.path,
        bytes: item.stored!,
        entryId: id,
        encoding: encoding,
      );
      if (document != null) documents.add(document);
    }
    final compressed = listed
        .where((e) => e.stored == null && !e.encrypted)
        .length;
    final failure = documents.isEmpty
        ? SubtitleFailure(
            stage: SubtitleFailureStage.extract,
            kind: listed.any((e) => e.encrypted)
                ? SubtitleFailureKind.encrypted
                : SubtitleFailureKind.unsupported,
            message: compressed > 0
                ? '识别为 RAR5，但此平台没有 UnRAR，不能解压方法 ${listed.first.methodLabel}'
                : 'RAR5 里没有可直接读取的未压缩文本字幕',
            recovery: SubtitleRecovery.openDetail,
            detail: 'rar5-store-only',
          )
        : null;
    return PackageDecodeResult(
      documents: documents..sort(_byEpisode),
      manifest: ArchiveManifest(
        container: ArchiveContainerKind.rar5,
        backend: 'dart-rar5-store',
        entries: entries,
        complete: reader.complete,
        warnings: reader.warnings,
        capability: '仅 RAR5 存储法；压缩条目需要 UnRAR',
      ),
      failure: failure,
    );
  }

  SubtitleSearchDocument? _document({
    required String name,
    required Uint8List bytes,
    required String entryId,
    required String? encoding,
  }) {
    final decoded = const SubtitleTextCodec().decode(
      bytes,
      encoding: encoding,
      fileName: name,
    );
    final cues = SubtitleParser.parse(decoded.text, sourcePath: name);
    if (cues.isEmpty) return null;
    if (cues.length > 50000) throw _limit('字幕条目过多');
    final metadata = SubtitleEntryMetadata.infer(name, decoded.text);
    final warnings = [
      if (decoded.uncertain)
        '编码不确定，当前按 ${decoded.encoding} 显示。可切换 ${decoded.candidates.join('、')}，不会重新下载',
      if (decoded.replacements > 0) '解码替换了 ${decoded.replacements} 个无法识别的字符',
    ];
    return SubtitleSearchDocument(
      name: name,
      content: decoded.text,
      cues: cues,
      entryId: entryId,
      encoding: decoded.encoding,
      format: _format(name, decoded.text),
      languages: metadata.languages,
      languageEvidence: '${metadata.evidence}:${metadata.label}',
      contentHash: sha256.convert(bytes).toString(),
      warnings: warnings,
    );
  }
}

class _Budget {
  _Budget(this.policy);
  final ArchivePolicy policy;
  var used = 0;
  bool take(int size) {
    if (size < 0 || used + size > policy.expandedBytes) return false;
    used += size;
    return true;
  }
}

ArchiveContainerKind identifyContainer(Uint8List bytes, {String name = ''}) {
  if (bytes.isEmpty) return ArchiveContainerKind.empty;
  if (bytes.length >= 8 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x61 &&
      bytes[2] == 0x72 &&
      bytes[3] == 0x21 &&
      bytes[4] == 0x1a &&
      bytes[5] == 0x07 &&
      bytes[6] == 0x01 &&
      bytes[7] == 0x00) {
    return ArchiveContainerKind.rar5;
  }
  if (bytes.length >= 7 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x61 &&
      bytes[2] == 0x72 &&
      bytes[3] == 0x21 &&
      bytes[4] == 0x1a &&
      bytes[5] == 0x07 &&
      bytes[6] == 0x00) {
    return ArchiveContainerKind.rar4;
  }
  if (bytes.length >= 6 &&
      bytes[0] == 0x37 &&
      bytes[1] == 0x7a &&
      bytes[2] == 0xbc &&
      bytes[3] == 0xaf &&
      bytes[4] == 0x27 &&
      bytes[5] == 0x1c) {
    return ArchiveContainerKind.sevenZip;
  }
  if (bytes.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4b) {
    return ArchiveContainerKind.zip;
  }
  final head = utf8
      .decode(bytes.take(256).toList(), allowMalformed: true)
      .trimLeft();
  final lower = head.toLowerCase();
  if (lower.startsWith('<!doctype html') ||
      lower.startsWith('<html') ||
      lower.startsWith('<head') ||
      lower.startsWith('<body')) {
    return ArchiveContainerKind.html;
  }
  if (lower.startsWith('{') || lower.startsWith('[')) {
    return ArchiveContainerKind.json;
  }
  return ArchiveContainerKind.text;
}

String _format(String name, String text) {
  final body = text.trimLeft().toLowerCase();
  if (body.startsWith('webvtt')) return 'vtt';
  if (body.contains('[script info]') || body.contains('dialogue:')) {
    return p.extension(name).toLowerCase() == '.ssa' ? 'ssa' : 'ass';
  }
  if (body.contains('-->')) return 'srt';
  final extension = p.extension(name).toLowerCase();
  return extension.isEmpty ? 'txt' : extension.substring(1);
}

String _entryKind(String extension) => switch (extension) {
  '.srt' || '.vtt' || '.ass' || '.ssa' => 'text',
  '.sup' ||
  '.idx' ||
  '.sub' ||
  '.png' ||
  '.jpg' ||
  '.jpeg' ||
  '.bmp' => 'image',
  '.ttf' || '.otf' || '.ttc' => 'font',
  _ => 'other',
};

bool _unsafePath(String name) {
  final parts = name.replaceAll('\\', '/').split('/');
  const reserved = {
    'con',
    'prn',
    'aux',
    'nul',
    'com1',
    'com2',
    'com3',
    'com4',
    'lpt1',
    'lpt2',
    'lpt3',
  };
  if (name.startsWith('/') || name.contains(':')) return true;
  for (final part in parts) {
    if (part.isEmpty || part == '.' || part == '..') return true;
    final stem = part.split('.').first.toLowerCase();
    if (reserved.contains(stem)) return true;
  }
  return false;
}

int _byEpisode(SubtitleSearchDocument a, SubtitleSearchDocument b) {
  final left = SubtitleReleaseInfo.parse(a.name);
  final right = SubtitleReleaseInfo.parse(b.name);
  final special = (left.special ? 1 : 0).compareTo(right.special ? 1 : 0);
  if (special != 0) return special;
  final episode = (left.episode ?? 1 << 20).compareTo(right.episode ?? 1 << 20);
  if (episode != 0) return episode;
  return a.name.compareTo(b.name);
}

SubtitleFailure _cancelled() => const SubtitleFailure(
  stage: SubtitleFailureStage.extract,
  kind: SubtitleFailureKind.cancelled,
  message: '已取消',
  retryable: true,
  recovery: SubtitleRecovery.retryDownload,
);

SubtitleFailure _empty() => const SubtitleFailure(
  stage: SubtitleFailureStage.inspect,
  kind: SubtitleFailureKind.empty,
  message: '下载内容是空的',
  retryable: true,
  recovery: SubtitleRecovery.retryDownload,
);

SubtitleFailure _html() => const SubtitleFailure(
  stage: SubtitleFailureStage.inspect,
  kind: SubtitleFailureKind.htmlOrJson,
  message: '下载到的是网页而不是字幕，需要打开这条字幕的详情页',
  recovery: SubtitleRecovery.openDetail,
);

SubtitleFailure _limit(String message) => SubtitleFailure(
  stage: SubtitleFailureStage.extract,
  kind: SubtitleFailureKind.limit,
  message: message,
  recovery: SubtitleRecovery.none,
);

SubtitleFailure? _noText(
  List<ArchiveEntryInfo> entries,
  List<String> warnings,
) {
  if (entries.any((e) => e.kind == 'image')) {
    return const SubtitleFailure(
      stage: SubtitleFailureStage.parse,
      kind: SubtitleFailureKind.imageSubtitle,
      message: '包里是图片字幕，不能当作文本导入',
      detail: '需要 OCR',
    );
  }
  if (entries.isEmpty) {
    return SubtitleFailure(
      stage: SubtitleFailureStage.parse,
      kind: SubtitleFailureKind.noSubtitle,
      message: warnings.isEmpty ? '压缩包里没有可读取的文本字幕' : warnings.join('\n'),
    );
  }
  final kinds = entries.map((e) => e.kind).toSet().join('、');
  return SubtitleFailure(
    stage: SubtitleFailureStage.parse,
    kind: SubtitleFailureKind.noSubtitle,
    message: '没有可读取的文本字幕。实际看到的文件类别：$kinds',
  );
}

SubtitleFailure _fromUnrar(UnrarException error) => switch (error.code) {
  SubtitleUnrar.missingPassword => const SubtitleFailure(
    stage: SubtitleFailureStage.extract,
    kind: SubtitleFailureKind.encrypted,
    message: '这个压缩包需要密码',
    recovery: SubtitleRecovery.enterPassword,
  ),
  SubtitleUnrar.badPassword => const SubtitleFailure(
    stage: SubtitleFailureStage.extract,
    kind: SubtitleFailureKind.badPassword,
    message: '密码不正确，原压缩包仍可继续使用',
    recovery: SubtitleRecovery.enterPassword,
  ),
  SubtitleUnrar.missingVolume => SubtitleFailure(
    stage: SubtitleFailureStage.extract,
    kind: SubtitleFailureKind.missingVolume,
    message: error.detail.isEmpty ? '缺少分卷，请选择其余分卷' : '缺少分卷：${error.detail}',
    recovery: SubtitleRecovery.chooseVolume,
    detail: error.detail,
  ),
  SubtitleUnrar.largeDict || SubtitleUnrar.limit => const SubtitleFailure(
    stage: SubtitleFailureStage.extract,
    kind: SubtitleFailureKind.limit,
    message: '压缩字典或输出路径超出限制',
  ),
  SubtitleUnrar.cancelled => _cancelled(),
  SubtitleUnrar.badData => const SubtitleFailure(
    stage: SubtitleFailureStage.extract,
    kind: SubtitleFailureKind.damaged,
    message: 'UnRAR 完整性校验没有通过',
  ),
  _ => SubtitleFailure(
    stage: SubtitleFailureStage.extract,
    kind: SubtitleFailureKind.damaged,
    message: '解压失败（${error.code}）',
    detail: error.detail,
  ),
};

PackageDecodeResult _failed(
  ArchiveContainerKind kind,
  SubtitleFailure failure,
) {
  return PackageDecodeResult(
    documents: const [],
    manifest: ArchiveManifest(
      container: kind,
      backend: 'identify',
      entries: const [],
      complete: false,
      warnings: [failure.message],
    ),
    failure: failure,
  );
}

class _StoredRarEntry {
  const _StoredRarEntry({
    required this.path,
    required this.unpacked,
    required this.methodLabel,
    required this.encrypted,
    this.stored,
  });
  final String path;
  final int unpacked;
  final String methodLabel;
  final bool encrypted;
  final Uint8List? stored;
}

class _Rar5Reader {
  _Rar5Reader(this.bytes);
  final Uint8List bytes;
  final warnings = <String>[];
  var complete = false;

  List<_StoredRarEntry> list() {
    final signature = _findSignature();
    if (signature < 0) {
      throw const SubtitleFailure(
        stage: SubtitleFailureStage.inspect,
        kind: SubtitleFailureKind.damaged,
        message: '没有找到 RAR5 签名',
      );
    }
    var offset = signature + 8;
    final entries = <_StoredRarEntry>[];
    while (offset + 8 < bytes.length && entries.length < 2000) {
      final header = _readHeader(offset);
      if (header == null) {
        warnings.add('从第 ${entries.length} 个条目之后无法继续读取容器');
        break;
      }
      offset = header.next;
      if (header.type == 5) {
        complete = true;
        break;
      }
      if (header.type == 4) {
        throw const SubtitleFailure(
          stage: SubtitleFailureStage.extract,
          kind: SubtitleFailureKind.encrypted,
          message: 'RAR 头部已加密，需要密码',
          recovery: SubtitleRecovery.enterPassword,
        );
      }
      if (header.entry != null) entries.add(header.entry!);
    }
    return entries;
  }

  int _findSignature() {
    final limit = bytes.length < 1024 * 1024 ? bytes.length - 8 : 1024 * 1024;
    for (var i = 0; i <= limit; i++) {
      if (bytes[i] == 0x52 &&
          bytes[i + 1] == 0x61 &&
          bytes[i + 2] == 0x72 &&
          bytes[i + 3] == 0x21 &&
          bytes[i + 4] == 0x1a &&
          bytes[i + 5] == 0x07 &&
          bytes[i + 6] == 0x01 &&
          bytes[i + 7] == 0x00) {
        return i;
      }
    }
    return -1;
  }

  _RarHeader? _readHeader(int offset) {
    if (offset + 6 > bytes.length) return null;
    final expected = _u32(offset);
    final coveredStart = offset + 4;
    var cursor = coveredStart;
    final size = _vint(cursor);
    cursor = size.next;
    final end = cursor + size.value;
    if (end > bytes.length || size.value > 2 * 1024 * 1024) return null;
    if (_crc(bytes.sublist(coveredStart, end)) != expected) {
      warnings.add('RAR5 头校验失败，已停止枚举');
      return null;
    }
    final type = _vint(cursor);
    cursor = type.next;
    final flags = _vint(cursor);
    cursor = flags.next;
    var extra = 0;
    var data = 0;
    if ((flags.value & 0x0001) != 0) {
      final read = _vint(cursor);
      extra = read.value;
      cursor = read.next;
      if (extra > size.value) return null;
    }
    if ((flags.value & 0x0002) != 0) {
      final read = _vint(cursor);
      data = read.value;
      cursor = read.next;
    }
    _StoredRarEntry? entry;
    if (type.value == 2 || type.value == 3) {
      final fileFlags = _vint(cursor);
      cursor = fileFlags.next;
      final unpacked = _vint(cursor);
      cursor = unpacked.next;
      final attributes = _vint(cursor);
      cursor = attributes.next;
      if ((fileFlags.value & 0x0002) != 0) cursor += 4;
      var crc = 0;
      final hasCrc = (fileFlags.value & 0x0004) != 0;
      if (hasCrc) {
        crc = _u32(cursor);
        cursor += 4;
      }
      final comp = _vint(cursor);
      cursor = comp.next;
      final host = _vint(cursor);
      cursor = host.next;
      final nameLen = _vint(cursor);
      cursor = nameLen.next;
      if (cursor + nameLen.value > end) return null;
      final path = utf8.decode(
        bytes.sublist(cursor, cursor + nameLen.value),
        allowMalformed: true,
      );
      cursor += nameLen.value;
      var encrypted = false;
      while (cursor < end) {
        final recordSize = _vint(cursor);
        cursor = recordSize.next;
        if (cursor + recordSize.value > end) break;
        final recordType = _vint(cursor);
        if (recordType.value == 1) encrypted = true;
        cursor += recordSize.value;
      }
      final method = (comp.value >> 7) & 7;
      final algo = comp.value & 0x3f;
      final dictBits = (comp.value >> 10) & 0x1f;
      final dict = dictBits >= 31 ? 0 : 128 * 1024 * (1 << dictBits);
      final label = 'v${algo + 6}:m$method:${_dictLabel(dict)}';
      Uint8List? stored;
      if (type.value == 2 &&
          method == 0 &&
          !encrypted &&
          data >= 0 &&
          end + data <= bytes.length) {
        stored = Uint8List.sublistView(bytes, end, end + data);
        if (hasCrc && _crc(stored) != crc) {
          warnings.add('$path 的数据 CRC 不匹配');
          stored = null;
        }
      }
      if (type.value == 2 && (fileFlags.value & 0x0001) == 0) {
        entry = _StoredRarEntry(
          path: path,
          unpacked: unpacked.value,
          methodLabel: label,
          encrypted: encrypted,
          stored: stored,
        );
      }
    }
    final next = end + data;
    if (next < offset) return null;
    return _RarHeader(type.value, next, entry);
  }
}

class _RarHeader {
  const _RarHeader(this.type, this.next, this.entry);
  final int type;
  final int next;
  final _StoredRarEntry? entry;
}

class _Vint {
  const _Vint(this.value, this.next);
  final int value;
  final int next;
}

extension on _Rar5Reader {
  _Vint _vint(int offset) {
    var value = 0;
    var shift = 0;
    var cursor = offset;
    for (var i = 0; i < 10; i++) {
      if (cursor >= bytes.length) {
        return _Vint(0, bytes.length);
      }
      final bite = bytes[cursor++];
      value |= (bite & 0x7f) << shift;
      if ((bite & 0x80) == 0) return _Vint(value, cursor);
      shift += 7;
    }
    return _Vint(0, cursor);
  }

  int _u32(int offset) =>
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);

  int _crc(List<int> data) {
    var crc = 0xffffffff;
    for (final bite in data) {
      crc ^= bite;
      for (var i = 0; i < 8; i++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
      }
    }
    return (crc ^ 0xffffffff) & 0xffffffff;
  }
}

String _dictLabel(int bytes) {
  if (bytes <= 0) return '0';
  if (bytes % (1024 * 1024) == 0) return '${bytes ~/ (1024 * 1024)}M';
  if (bytes % 1024 == 0) return '${bytes ~/ 1024}K';
  return '$bytes';
}
