import 'dart:io';

import 'package:path/path.dart' as p;

import 'ai_chat_settings.dart';
import 'ai_agent_catalog.dart';

class AiCliPathException implements Exception {
  const AiCliPathException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Resolves files, install directories and commands without evaluating a shell.
/// GUI applications often start with an older PATH than the user's terminal.
class AiCliLocator {
  AiCliLocator({Map<String, String>? environment, bool? windows})
    : environment = environment ?? Platform.environment,
      windows = windows ?? Platform.isWindows;

  final Map<String, String> environment;
  final bool windows;
  p.Context get _paths =>
      p.Context(style: windows ? p.Style.windows : p.Style.posix);

  String _env(String name) {
    for (final entry in environment.entries) {
      if (entry.key.toLowerCase() == name.toLowerCase()) return entry.value;
    }
    return '';
  }

  List<String> get searchDirectories {
    final paths = _paths;
    final home = windows ? _env('USERPROFILE') : _env('HOME');
    final local = _env('LOCALAPPDATA');
    final roaming = _env('APPDATA');
    return <String>{
      ..._env('PATH')
          .split(windows ? ';' : ':')
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty),
      if (windows && local.isNotEmpty) ...[
        paths.join(local, 'Programs', 'OpenAI', 'Codex', 'bin'),
        paths.join(local, 'Programs', 'opencode'),
        paths.join(local, 'Programs', 'nodejs'),
        paths.join(local, 'Microsoft', 'WinGet', 'Links'),
      ],
      if (windows && roaming.isNotEmpty) paths.join(roaming, 'npm'),
      if (windows && _env('ProgramFiles').isNotEmpty)
        paths.join(_env('ProgramFiles'), 'nodejs'),
      if (home.isNotEmpty) ...[
        paths.join(home, '.codex', 'bin'),
        paths.join(home, '.opencode', 'bin'),
        paths.join(home, '.local', 'bin'),
        paths.join(home, '.bun', 'bin'),
      ],
      if (!windows) ...[
        '/opt/homebrew/bin',
        '/usr/local/bin',
        '/usr/bin',
        '/bin',
      ],
    }.toList();
  }

  Map<String, String> childEnvironment(String executable) => {
    ...environment,
    'PATH': <String>{
      _paths.dirname(executable),
      ...searchDirectories,
    }.join(windows ? ';' : ':'),
  };

  Future<String> resolve(AiBackend backend, [String suppliedPath = '']) async {
    if (backend == AiBackend.api) {
      throw const AiCliPathException('API 服务不需要命令行工具。');
    }
    final preset = backend.agentPreset;
    if (preset != null &&
        !preset.supportsPlatform(
          aiAgentHostPlatform,
          architecture: aiAgentHostArchitecture,
        )) {
      throw AiCliPathException('${preset.label} 暂不支持当前系统或 CPU 架构。');
    }
    final name =
        backend.agentPreset?.executable ??
        (backend == AiBackend.codex
            ? 'codex'
            : backend == AiBackend.opencode
            ? 'opencode'
            : '');
    final label = backend.label;
    var input = suppliedPath.trim();
    if (name.isEmpty && input.isEmpty) {
      throw const AiCliPathException('请为自定义 ACP Agent 填写可执行文件或命令名。');
    }
    if (input.length > 1 &&
        ((input.startsWith('"') && input.endsWith('"')) ||
            (input.startsWith("'") && input.endsWith("'")))) {
      input = input.substring(1, input.length - 1).trim();
    }
    input = input.replaceAllMapped(RegExp(r'%([a-zA-Z_][a-zA-Z0-9_]*)%'), (
      match,
    ) {
      final value = _env(match[1]!);
      return value.isEmpty ? match[0]! : value;
    });
    if (input == '~' || input.startsWith('~/') || input.startsWith('~\\')) {
      final home = windows ? _env('USERPROFILE') : _env('HOME');
      if (home.isNotEmpty) {
        input = _paths.join(home, input.length == 1 ? '' : input.substring(2));
      }
    }
    if (RegExp('["\r\n\x00]').hasMatch(input)) {
      throw const AiCliPathException('请填写工具文件或安装文件夹，不要填写整条命令。');
    }
    if (input.isNotEmpty) {
      final type = await FileSystemEntity.type(input);
      if (type == FileSystemEntityType.directory) {
        if (name.isEmpty) {
          throw const AiCliPathException('自定义 ACP Agent 请选择可执行文件，不要只选择文件夹。');
        }
        for (final directory in [input, _paths.join(input, 'bin')]) {
          final found = await _inDirectory(directory, name);
          if (found != null) return found;
        }
        throw AiCliPathException(
          '该文件夹中没有 $name${windows ? '.exe / .cmd' : ''}，请选择 $label 的安装目录或可执行文件。',
        );
      }
      if (type == FileSystemEntityType.file) {
        return _normalizeShim(File(input).absolute.path);
      }
      if (input.contains('/') ||
          input.contains('\\') ||
          _paths.isAbsolute(input)) {
        throw AiCliPathException('$label 路径不存在，请检查填写的文件或文件夹。');
      }
    }
    final command = input.isEmpty ? name : input;
    for (final directory in searchDirectories) {
      final found = await _inDirectory(directory, command);
      if (found != null) return found;
    }
    throw AiCliPathException('未找到 $label。请选择已安装的工具文件或安装文件夹，或将它加入 PATH 后重试。');
  }

  Future<String?> _inDirectory(String directory, String name) async {
    final extensions = windows && _paths.extension(name).isEmpty
        ? ['.exe', '.cmd', '.bat', '']
        : [''];
    for (final extension in extensions) {
      final file = File(_paths.join(directory, '$name$extension'));
      if (await file.exists()) return _normalizeShim(file.absolute.path);
    }
    return null;
  }

  Future<String> _normalizeShim(String path) async {
    if (!windows || !path.toLowerCase().endsWith('.ps1')) return path;
    final stem = path.substring(0, path.length - 4);
    for (final extension in ['.exe', '.cmd', '.bat']) {
      if (await File('$stem$extension').exists()) return '$stem$extension';
    }
    throw const AiCliPathException(
      '请选择同目录的 .exe 或 .cmd 文件，PowerShell .ps1 不是可直接启动的 CLI 文件。',
    );
  }

  /// Prompts always travel on stdin; only fixed options and validated IDs may
  /// enter a Windows npm shim's command line.
  ({String executable, List<String> arguments}) command(
    String executable,
    List<String> arguments,
  ) {
    if (!windows ||
        !RegExp(r'\.(cmd|bat)$', caseSensitive: false).hasMatch(executable)) {
      return (executable: executable, arguments: arguments);
    }
    if (RegExp(r'["%!^\r\n]').hasMatch(executable) ||
        arguments.any(
          (argument) => RegExp(r'["&|<>^%!\r\n]').hasMatch(argument),
        )) {
      throw const AiCliPathException(
        '该 Windows 启动脚本路径或参数含不支持的特殊字符，请选择原生 .exe 文件。',
      );
    }
    return (
      executable: _env('ComSpec').isEmpty ? 'cmd.exe' : _env('ComSpec'),
      arguments: ['/d', '/s', '/c', 'call', executable, ...arguments],
    );
  }
}
