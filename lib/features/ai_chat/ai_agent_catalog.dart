import 'dart:convert';

import 'ai_chat_settings.dart';
import 'ai_agent_platform_stub.dart'
    if (dart.library.io) 'ai_agent_platform_native.dart'
    as host;

String get aiAgentHostPlatform => host.aiAgentHostPlatform;
String get aiAgentHostArchitecture => host.aiAgentHostArchitecture;

/// Launch installed tools only. No package runners or automatic downloads.
/// Commands follow the ACP registry and each agent's official documentation.
class AiAgentPreset {
  const AiAgentPreset({
    required this.backend,
    required this.label,
    required this.executable,
    required this.arguments,
    required this.instructions,
    required this.documentationUrl,
    this.platforms = const ['windows', 'macos', 'linux'],
    this.windowsArm64 = true,
  });

  final AiBackend backend;
  final String label, executable, instructions, documentationUrl;
  final List<String> arguments, platforms;
  final bool windowsArm64;
  bool supportsPlatform(String platform, {String? architecture}) =>
      platforms.contains(platform) &&
      !(platform == 'windows' && architecture == 'arm64' && !windowsArm64);
}

const aiAgentPresets = <AiAgentPreset>[
  AiAgentPreset(
    backend: AiBackend.claude,
    label: 'Claude Agent',
    executable: 'claude-agent-acp',
    arguments: [],
    instructions:
        '请先安装 Claude Agent ACP 适配器（claude-agent-acp），并完成 Claude 登录或配置。此处选择适配器，不是 claude 命令。',
    documentationUrl: 'https://github.com/agentclientprotocol/claude-agent-acp',
  ),
  AiAgentPreset(
    backend: AiBackend.geminiCli,
    label: 'Gemini CLI',
    executable: 'gemini',
    arguments: ['--acp'],
    instructions: '请先安装支持 --acp 的 Gemini CLI，并在终端运行 gemini 完成登录。',
    documentationUrl: 'https://geminicli.com/docs/get-started/installation/',
  ),
  AiAgentPreset(
    backend: AiBackend.qwenCode,
    label: 'Qwen Code',
    executable: 'qwen',
    arguments: ['--acp'],
    instructions: '请先安装 Qwen Code，并在终端运行 qwen，通过 /auth 完成登录或配置服务。',
    documentationUrl: 'https://github.com/QwenLM/qwen-code',
  ),
  AiAgentPreset(
    backend: AiBackend.kimiCode,
    label: 'Kimi Code CLI',
    executable: 'kimi',
    arguments: ['acp'],
    instructions:
        '请先安装 Kimi Code CLI，并运行 kimi 的 /login 完成登录。Windows 还需要 Git for Windows 提供的 Git Bash。',
    documentationUrl: 'https://github.com/MoonshotAI/kimi-code',
  ),
  AiAgentPreset(
    backend: AiBackend.copilot,
    label: 'GitHub Copilot CLI',
    executable: 'copilot',
    arguments: ['--acp'],
    instructions:
        '请先安装支持 --acp 的 GitHub Copilot CLI，在终端运行 copilot，通过 /login 登录。',
    documentationUrl:
        'https://docs.github.com/en/copilot/get-started/cli-quickstart',
  ),
  AiAgentPreset(
    backend: AiBackend.qoder,
    windowsArm64: false,
    label: 'Qoder CLI',
    executable: 'qoder',
    arguments: ['--acp'],
    instructions:
        '请先安装 Qoder CLI，并运行 qoder login 完成登录。官方暂未提供 Windows ARM64 支持。',
    documentationUrl: 'https://docs.qoder.com/cli/acp',
  ),
  AiAgentPreset(
    backend: AiBackend.cursor,
    label: 'Cursor CLI',
    executable: 'cursor-agent',
    arguments: ['acp'],
    instructions:
        '请先安装并登录 Cursor CLI。自动查找 cursor-agent；如安装使用 agent 命令，可直接选择它的可执行文件。',
    documentationUrl: 'https://cursor.com/docs/cli/acp',
  ),
  AiAgentPreset(
    backend: AiBackend.vibe,
    windowsArm64: false,
    label: 'Mistral Vibe',
    executable: 'vibe-acp',
    arguments: [],
    instructions:
        '请先安装并配置 Mistral Vibe，选择 vibe-acp 可执行文件。Windows 版本需要单独验证；官方主要支持 UNIX 环境。',
    documentationUrl: 'https://github.com/mistralai/mistral-vibe',
  ),
  AiAgentPreset(
    backend: AiBackend.goose,
    windowsArm64: false,
    label: 'Goose',
    executable: 'goose',
    arguments: ['acp'],
    instructions: '请先安装 Goose CLI，并运行 goose configure 配置模型服务。',
    documentationUrl: 'https://goose-docs.ai/docs/getting-started/installation',
  ),
  AiAgentPreset(
    backend: AiBackend.acp,
    label: '自定义 ACP Agent',
    executable: '',
    arguments: [],
    instructions:
        '选择已安装、支持 ACP v1 标准输入输出协议的 Agent 文件，并填写参数。先在工具自身完成登录；应用不会安装或升级工具。',
    documentationUrl: 'https://agentclientprotocol.com/get-started/agents',
  ),
];

extension AiBackendAgent on AiBackend {
  AiAgentPreset? get agentPreset {
    for (final preset in aiAgentPresets) {
      if (preset.backend == this) return preset;
    }
    return null;
  }

  bool get usesAcp => agentPreset != null;
  String get label => switch (this) {
    AiBackend.api => 'API 服务',
    AiBackend.codex => 'Codex CLI',
    AiBackend.opencode => 'OpenCode CLI',
    _ => agentPreset!.label,
  };
}

/// JSON keeps spaces and quoting unambiguous; arguments never form a shell line.
List<String> aiParseAgentArguments(String input) {
  final dynamic value;
  try {
    value = jsonDecode(input.trim().isEmpty ? '[]' : input);
  } on FormatException {
    throw const FormatException('请填写 JSON 字符串数组，例如 ["--acp"]。');
  }
  if (value is! List ||
      value.length > 64 ||
      value.any((item) => item is! String || item.contains('\u0000')) ||
      value.whereType<String>().fold<int>(0, (n, item) => n + item.length) >
          16384) {
    throw const FormatException('参数必须是最多 64 项的 JSON 字符串数组，且不能包含空字符。');
  }
  return List<String>.unmodifiable(value.cast<String>());
}
