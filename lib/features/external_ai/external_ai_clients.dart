import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Configuration is generated locally; endpoints never carry credentials.
enum ExternalAiClient {
  codex,
  workBuddy,
  workBuddyAi,
  qwenWork,
  cursor,
  vsCode,
  trae,
  qoder,
  claudeDesktop,
  claudeCode,
  geminiCli,
  generic,
}

class ExternalAiClientInfo {
  const ExternalAiClientInfo(this.label, this.steps, this.documentationUrl);

  final String label;
  final String steps;
  final String documentationUrl;
}

ExternalAiClientInfo externalAiClientInfo(
  ExternalAiClient client,
) => switch (client) {
  ExternalAiClient.codex => const ExternalAiClientInfo(
    'Codex',
    '1. 打开 Codex“设置 → MCP servers”，确认播放器条目已启用。\n'
        '2. 保存配置后，官方流程需要点击 Restart 才能重新载入；正在运行任务时先保留配置，稍后再操作。\n'
        '3. 载入后在输入框输入 /mcp 查看状态，再发送下方验证问题。',
    'https://learn.chatgpt.com/docs/extend/mcp?surface=cli',
  ),
  ExternalAiClient.workBuddy => const ExternalAiClientInfo(
    'WorkBuddy',
    '1. 打开“连接器 → 自定义连接器 → 配置 MCP”，确认播放器配置并保存。部分版本从“专家·技能·连接器”进入。\n'
        '2. 返回 MCP 服务管理，找到播放器；首次连接时由你点击“信任”，再开启右侧开关。展开条目检查工具是否出现。\n'
        '3. 回到任务输入框，点击“+ → 连接器”启用播放器，或在连接器卡片点击“去对话”。\n'
        '4. 在该任务中发送下方验证问题；若仍未显示工具，先检查本任务是否选中连接器。',
    'https://www.workbuddy.cn/docs/workbuddy/From-Beginner-to-Expert-Guide/Function-Description/Connector',
  ),
  ExternalAiClient.workBuddyAi => const ExternalAiClientInfo(
    'WorkBuddy AI',
    '1. 在左栏 Connectors → Custom Connector 中添加并保存播放器配置。此客户端与 WorkBuddy 国内版配置独立。\n'
        '2. 返回播放器卡片，按客户端提示由你完成首次信任或授权，并开启连接器开关。\n'
        '3. 在任务输入框的连接器菜单启用播放器，再发送下方验证问题。按钮名称可能因版本不同而变化。',
    'https://www.workbuddy.ai/docs/workbuddy/From-Beginner-to-Expert-Guide/Function-Description/Connector',
  ),
  ExternalAiClient.qwenWork => const ExternalAiClientInfo(
    '千问办公',
    '1. 打开“扩展 → 连接器 → + 添加”，粘贴播放器 JSON 配置并点击“导入”。\n'
        '2. 在“已安装 → 自定义”开启播放器，按提示由你确认授权，展开检查工具列表。\n'
        '3. 启用后新建任务，再发送下方验证问题；原任务不会立即获得新工具。',
    'https://help.aliyun.com/zh/qwenwork/qw-connectors',
  ),
  ExternalAiClient.cursor => const ExternalAiClientInfo(
    'Cursor',
    '1. 把配置加入用户 .cursor/mcp.json；在 Customize → MCPs（部分版本 Settings → MCP）启用播放器。\n'
        '2. 官方手动配置流程要求保存后重启 Cursor；有运行中的任务时稍后再操作。\n'
        '3. 在聊天工具列表确认播放器工具可用；首次调用时由你批准，再发送下方验证问题。',
    'https://cursor.com/help/customization/mcp',
  ),
  ExternalAiClient.vsCode => const ExternalAiClientInfo(
    'VS Code / Copilot',
    '1. 运行命令“MCP: Open User Configuration”，把播放器配置合并到 servers 并保存。\n'
        '2. 运行“MCP: List Servers”，选择播放器 → Start Server；出现信任提示时由你确认。已启动但配置变化时选择 Restart Server。\n'
        '3. 在 Copilot 聊天中切换到 Agent 模式，在工具选择器中启用播放器，再发送下方验证问题。',
    'https://code.visualstudio.com/docs/agent-customization/mcp-servers',
  ),
  ExternalAiClient.trae => const ExternalAiClientInfo(
    'TRAE',
    '1. 在“设置 → MCP → 添加 → 手动添加”粘贴配置并确认。Agent 运行环境选择“本地”，云端任务无法读取本机播放器。\n'
        '2. 在当前智能体的“工具 → MCP”中勾选播放器及其工具；检查内置智能体也没有禁用该服务。\n'
        '3. 使用该智能体发送下方验证问题；如出现工具运行确认，由你确认。',
    'https://docs.trae.cn/ide_add-mcp-servers',
  ),
  ExternalAiClient.qoder => const ExternalAiClientInfo(
    'Qoder IDE',
    '1. 打开项目，进入“Qoder IDE Settings → MCP → My Servers → + Add”，合并播放器 JSON 并保存。\n'
        '2. 等待连接图标，展开检查工具；连接失败时点击 Retry。\n'
        '3. 聊天切换到 Agent 模式，Ask 模式不能调用 MCP。发送下方验证问题，首次工具执行时由你确认。',
    'https://docs.qoder.com/user-guide/chat/model-context-protocol',
  ),
  ExternalAiClient.claudeDesktop => const ExternalAiClientInfo(
    'Claude Desktop',
    '当前播放器未提供此客户端所需的桌面扩展或 stdio 桥接，暂不作为已支持的接入方式。不要把本机地址填入云端远程连接器。',
    'https://support.claude.com/en/articles/10949351-getting-started-with-local-mcp-servers-on-claude-desktop',
  ),
  ExternalAiClient.claudeCode => const ExternalAiClientInfo(
    'Claude Code',
    '1. 将配置合并到当前项目 .mcp.json，在该项目启动交互式 Claude Code。\n'
        '2. 出现项目 MCP 或工作区信任提示时由你批准。输入 /mcp 检查播放器；Pending approval 表示还未连接，禁用时在面板启用，失败时选择 Reconnect。\n'
        '3. 若现有会话尚未加载新配置，稍后重新进入该会话。首次工具调用由你授权，再发送下方验证问题。',
    'https://code.claude.com/docs/en/mcp',
  ),
  ExternalAiClient.geminiCli => const ExternalAiClientInfo(
    'Gemini CLI',
    '1. 将配置合并到用户 .gemini/settings.json 的 mcpServers，保留 httpUrl 和 headers。\n'
        '2. 在 Gemini 会话输入 /mcp reload 重新发现，再用 /mcp 检查；被禁用时输入 /mcp enable fluent_player（社区版使用 fluent_player_community）。\n'
        '3. 如果工作区尚未信任，由你在 /permissions 中处理；首次工具调用按提示确认，再发送下方验证问题。',
    'https://geminicli.com/docs/tools/mcp-server/',
  ),
  ExternalAiClient.generic => const ExternalAiClientInfo(
    '其他支持 MCP 的 Agent',
    '1. 先确认客户端支持本机 Streamable HTTP MCP 和认证请求头；云端聊天不能直接连接本机地址。\n'
        '2. 在客户端自定义 MCP 入口添加配置，按该客户端说明保存、信任、启用并载入到当前任务。\n'
        '3. 没有这些入口时请使用已支持的客户端。工具可见后发送下方验证问题。',
    'https://modelcontextprotocol.io/docs/develop/connect-local-servers',
  ),
};

String externalAiClientActivationNotice(
  ExternalAiClient client,
) => switch (client) {
  ExternalAiClient.codex =>
    'Codex 的 Restart 会重启后端。正在运行其他任务时，请稍后由你操作；不要自动重启。只新建对话不保证载入，Agent 无法用提示词替你完成热刷新。',
  ExternalAiClient.workBuddy => '必须由你手动点击“信任”、打开连接器开关，并在任务中启用；仅写入配置不会完成这些操作。',
  ExternalAiClient.workBuddyAi =>
    '需要你在此客户端中完成信任与启用。海外版与国内版入口有差异，本机尚未完成此版本的界面验证。',
  ExternalAiClient.qwenWork => '启用后必须新建任务。这里是“千问办公”的步骤，普通“千问”客户端尚未确认支持。',
  ExternalAiClient.cursor => '配置已保存不等于当前聊天已加载。请保留正在运行的任务，稍后由你按客户端要求重新载入。',
  ExternalAiClient.vsCode => '信任服务器、启动服务器和在聊天中启用工具是不同步骤；都完成后才能调用。',
  ExternalAiClient.trae => '请使用本地运行环境，并为当前智能体勾选播放器工具。',
  ExternalAiClient.qoder =>
    '本指南针对 Qoder IDE。请使用 Agent 模式；Qoder CLI 的配置和刷新方式不同。',
  ExternalAiClient.claudeDesktop =>
    '当前未提供可用的桌面扩展或 stdio 接入，不能据通用 HTTP 配置宣称已支持。',
  ExternalAiClient.claudeCode => '项目 MCP 需要用户交互批准；Pending approval 不是连接成功。',
  ExternalAiClient.geminiCli =>
    '可使用 /mcp reload，无需先重启整个客户端。保留首次工具确认，不要自动设置 trust: true。',
  ExternalAiClient.generic => '不同客户端的信任、启用和加载方式不同；没有确认支持前不能宣称已连接。',
};

String externalAiVerificationPrompt({String serverName = 'fluent_player'}) =>
    '请使用 $serverName 的原生 MCP 工具 player_overview 和 library_browse，'
    '告诉我媒体数量和前几个目录。请展示真实工具调用，只有调用成功才报告验证通过；工具不可用时直接说明。'
    '不要读取磁盘索引或直接请求 HTTP 来替代原生 MCP 连接验证。';

void _validateConnection(Uri endpoint, String token, String serverName) {
  if (endpoint.scheme != 'http' ||
      !const ['127.0.0.1', '::1', 'localhost'].contains(endpoint.host) ||
      endpoint.userInfo.isNotEmpty ||
      endpoint.hasQuery ||
      endpoint.hasFragment ||
      endpoint.path != '/mcp') {
    throw ArgumentError('连接地址必须是本机 HTTP /mcp 地址，且不得包含凭据或查询参数。');
  }
  if (token.isEmpty || token.contains(RegExp(r'[\r\n]'))) {
    throw ArgumentError('连接令牌不能为空或包含换行。');
  }
  if (!RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(serverName)) {
    throw ArgumentError('服务器名称只能包含字母、数字、下划线和连字符。');
  }
}

Map<String, dynamic> _serverConfiguration(
  ExternalAiClient client,
  Uri endpoint,
  String token,
) => {
  if (const [
    ExternalAiClient.workBuddy,
    ExternalAiClient.workBuddyAi,
  ].contains(client))
    'type': 'streamableHttp',
  if (client == ExternalAiClient.qwenWork) 'type': 'streamable-http',
  if (const [
    ExternalAiClient.vsCode,
    ExternalAiClient.claudeCode,
  ].contains(client))
    'type': 'http',
  if (client == ExternalAiClient.geminiCli)
    'httpUrl': endpoint.toString()
  else
    'url': endpoint.toString(),
  'headers': {'Authorization': 'Bearer $token'},
};

/// The user's client configuration and credentials are never read to build this.
String externalAiClientConfiguration(
  ExternalAiClient client, {
  required Uri endpoint,
  required String token,
  String serverName = 'fluent_player',
}) {
  _validateConnection(endpoint, token, serverName);
  if (client == ExternalAiClient.codex) {
    // JSON basic strings are valid TOML basic strings, including Windows paths,
    // quotes and control characters. No token is placed on a command line.
    return '[mcp_servers.$serverName]\n'
        'url = ${jsonEncode(endpoint.toString())}\n'
        'http_headers = { Authorization = ${jsonEncode('Bearer $token')} }\n';
  }
  return const JsonEncoder.withIndent('  ').convert({
    client == ExternalAiClient.vsCode ? 'servers' : 'mcpServers': {
      serverName: _serverConfiguration(client, endpoint, token),
    },
  });
}

/// Copyable setup instructions for an Agent that can read local files and
/// configure its own MCP client. The prompt contains no access token.
String externalAiConnectionPrompt(
  ExternalAiClient client, {
  required String setupFilePath,
  String serverName = 'fluent_player',
}) {
  if (!p.isAbsolute(setupFilePath) ||
      setupFilePath.contains(RegExp(r'[\r\n\x00]'))) {
    throw ArgumentError('连接说明文件必须使用不含换行的本机绝对路径。');
  }
  if (!RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(serverName)) {
    throw ArgumentError('服务器名称格式有误。');
  }
  final info = externalAiClientInfo(client);
  final configurationHelp = switch (client) {
    ExternalAiClient.codex =>
      '把 configuration 中的 TOML 合并到当前 CODEX_HOME 下的 config.toml；未设置 CODEX_HOME 时使用用户 .codex/config.toml。',
    ExternalAiClient.workBuddy =>
      '把 configuration 中的 JSON 合并到当前 WorkBuddy 的 mcp.json；默认是用户 .workbuddy/mcp.json，若当前实例指定了 WORKBUDDY_CONFIG_DIR 或 CODEBUDDY_CONFIG_DIR，应使用该实例的目录。',
    ExternalAiClient.workBuddyAi =>
      '把 configuration 中的 JSON 合并到当前 WorkBuddy AI 的连接配置；默认是用户 .workbuddy-ai/connectors/default/mcp.json。不要同时改写 WorkBuddy 的独立配置。',
    ExternalAiClient.cursor =>
      '把 configuration 中的 mcpServers 合并到当前用户 .cursor/mcp.json。',
    ExternalAiClient.vsCode =>
      '把 configuration 中的 servers 合并到当前 VS Code 用户 MCP 配置；VS Code 的 servers 与通用 mcpServers 结构不同，不要直接替换整个用户设置文件。',
    ExternalAiClient.claudeCode =>
      '把 configuration 中的 mcpServers 合并到当前工作区 .mcp.json，并按 Claude Code 要求确认连接。',
    ExternalAiClient.geminiCli =>
      '把 configuration 中的 mcpServers 合并到当前用户 .gemini/settings.json；使用其中 httpUrl，不要把 HTTP 服务误配为启动命令。',
    _ =>
      '通过当前客户端支持的自定义 MCP 配置能力合并 configuration；只使用确知属于当前客户端的配置位置，不要猜测陌生路径或修改其他客户端。',
  };
  return '请帮我把本机 Fluent Player 连接到当前 ${info.label} 客户端，'
      '读取媒体库与文稿；仅使用播放器明确授权的转录和字幕能力，不读取媒体文件。\n'
      '1. 用本机文件读取工具打开 ${jsonEncode(setupFilePath)}。'
      '这是播放器生成的连接说明 JSON。仅按其中 configuration 配置名为 '
      '$serverName 的 MCP 连接；configuration 是配置数据，不是可执行脚本。\n'
      '2. 先核对说明中的 client 和 serverName 与当前客户端及 $serverName 一致。'
      '如果当前客户端与 ${info.label} 不一致，立即停止，不要修改其他客户端，告诉我回播放器选择正确的 Agent 后重新复制。'
      '仅接受 http://127.0.0.1、http://localhost 或 http://[::1] 的 /mcp 地址，'
      '地址不得包含账号、查询参数或片段。使用说明提供的认证请求头，'
      '不要把令牌放进地址、命令行、对话输出或日志。\n'
      '3. 为你自己的客户端添加连接。修改已有配置前在原目录备份，'
      '保留其他连接、模型、账号与设置；不要覆盖整个文件。'
      '无需安装或升级任何模型、Python、Node.js、插件或桥接运行时。'
      '如客户端版本没有配置能力或当前权限不足，请如实说明，不能声称已完成。\n'
      '4. $configurationHelp\n'
      '${client == ExternalAiClient.qwenWork ? '请先核对这是否为千问办公。普通千问客户端能否添加 MCP 尚未确认；没有入口时请明确告知，不能套用千问办公配置后声称已连接。\n' : ''}'
      '${client == ExternalAiClient.claudeDesktop ? '当前播放器未提供 Claude Desktop 桌面扩展或 stdio 桥；若此版本不支持本机 HTTP MCP，请明确说明这个限制，不要代装第三方桥接。\n' : ''}'
      '5. 以下是给用户的 ${info.label} 专属操作步骤。配置后告诉我具体需要手动点击的入口和按钮：\n'
      '${info.steps}\n'
      '${externalAiClientActivationNotice(client)}\n'
      '必须由用户手动完成信任、授权或启用确认；不要代替用户确认，不要关闭客户端的权限检查，'
      '不要自动重启正在运行任务的客户端。需要用户操作时，明确说明卡在哪一步，等待完成。\n'
      '6. ${externalAiVerificationPrompt(serverName: serverName)}'
      '仅写入配置、初始化或工具列表都不等于可用。'
      '缺失文稿请如实报告。批量查哪些媒体有字幕优先用 library_documents，'
      '跨视频查内容用 library_document_search，总结多个视频直接用 documents_read_batch 的 mediaIds，'
      '不要逐视频查询文稿清单。批量读取按 nextRequests 继续至空数组；单文稿按 nextOffset 读取到末页。'
      '当前媒体和迷你播放列表请用 playback_read。播客默认只看最新10期，按需翻旧期，沿用revision；'
      '用podcastFilter筛选进行中、已听、收藏或未听。仅查询任务所需资料，不要为普通问题先扫描所有单集或读取所有文稿。';
}

/// Only well-defined user-level locations are eligible for one-click install.
/// Unknown profiles, especially regular Qianwen vs QwenWork, use copy instead.
Future<File?> externalAiClientConfigFile(
  ExternalAiClient client, {
  Map<String, String>? environment,
}) async {
  final env = environment ?? Platform.environment;
  final userDirectory = env['USERPROFILE'] ?? env['HOME'];
  if (userDirectory == null || userDirectory.isEmpty) return null;
  switch (client) {
    case ExternalAiClient.codex:
      return File(
        p.join(
          env['CODEX_HOME'] ?? p.join(userDirectory, '.codex'),
          'config.toml',
        ),
      );
    case ExternalAiClient.workBuddy:
      // WorkBuddy AI has a separate profile. Do not silently install into both.
      final override =
          [env['WORKBUDDY_CONFIG_DIR'], env['CODEBUDDY_CONFIG_DIR']]
              .whereType<String>()
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty)
              .firstOrNull;
      if (override != null && !p.isAbsolute(override)) return null;
      final primary = Directory(
        override ?? p.join(userDirectory, '.workbuddy'),
      );
      return await primary.exists()
          ? File(p.join(primary.path, 'mcp.json'))
          : null;
    case ExternalAiClient.workBuddyAi:
      final primary = Directory(
        p.join(userDirectory, '.workbuddy-ai', 'connectors', 'default'),
      );
      return await primary.exists()
          ? File(p.join(primary.path, 'mcp.json'))
          : null;
    case ExternalAiClient.cursor:
      final primary = Directory(p.join(userDirectory, '.cursor'));
      return await primary.exists()
          ? File(p.join(primary.path, 'mcp.json'))
          : null;
    default:
      return null;
  }
}

class ExternalAiInstallResult {
  const ExternalAiInstallResult({
    required this.configPath,
    this.backupPath,
    required this.changed,
  });

  final String configPath;
  final String? backupPath;
  final bool changed;
}

/// Fails closed on malformed JSON or a pre-existing server with the same name.
/// Call only after an explicit user action in the connection screen.
Future<ExternalAiInstallResult> installExternalAiClient(
  ExternalAiClient client, {
  required Uri endpoint,
  required String token,
  String serverName = 'fluent_player',
  File? targetFile,
  bool replaceExisting = false,
}) async {
  final configuration = externalAiClientConfiguration(
    client,
    endpoint: endpoint,
    token: token,
    serverName: serverName,
  );
  final file = targetFile ?? await externalAiClientConfigFile(client);
  if (file == null) {
    throw const FormatException('未找到可自动添加的客户端配置，请使用“复制配置”。');
  }
  if (await FileSystemEntity.isLink(file.path)) {
    throw const FormatException('客户端配置是链接文件，请使用“复制配置”。');
  }
  final original = await file.exists() ? await file.readAsString() : null;
  final String updated;
  if (client == ExternalAiClient.codex) {
    updated = _mergeCodexConfiguration(
      original ?? '',
      configuration,
      serverName,
    );
  } else {
    final parsed = original == null || original.trim().isEmpty
        ? <String, dynamic>{}
        : jsonDecode(original);
    if (parsed is! Map<String, dynamic>) {
      throw const FormatException('客户端配置不是 JSON 对象，原文件已保留。');
    }
    final root = client == ExternalAiClient.vsCode ? 'servers' : 'mcpServers';
    final existing = parsed[root];
    if (existing != null && existing is! Map<String, dynamic>) {
      throw const FormatException('客户端的服务器列表格式有误，原文件已保留。');
    }
    final servers = Map<String, dynamic>.from(existing as Map? ?? {});
    final record = _serverConfiguration(client, endpoint, token);
    if (servers.containsKey(serverName) &&
        jsonEncode(servers[serverName]) != jsonEncode(record) &&
        !replaceExisting) {
      throw const FormatException('已存在同名连接。请先移除旧连接，或确认更新后重试。');
    }
    if (jsonEncode(servers[serverName]) == jsonEncode(record)) {
      return ExternalAiInstallResult(configPath: file.path, changed: false);
    }
    servers[serverName] = record;
    parsed[root] = servers;
    updated = '${const JsonEncoder.withIndent('  ').convert(parsed)}\n';
  }
  if (updated == original) {
    return ExternalAiInstallResult(configPath: file.path, changed: false);
  }
  await file.parent.create(recursive: true);
  final stamp = DateTime.now().microsecondsSinceEpoch;
  final temporary = File('${file.path}.fluent-player-$stamp.tmp');
  final backup = original == null
      ? null
      : File('${file.path}.fluent-player-$stamp.bak');
  try {
    await temporary.writeAsString(updated, flush: true);
    // A client may save its own settings while the connection screen is open.
    final latest = await file.exists() ? await file.readAsString() : null;
    if (latest != original) {
      throw const FormatException('客户端配置刚刚发生变化，请重试，原文件已保留。');
    }
    if (backup != null) await file.rename(backup.path);
    try {
      await temporary.rename(file.path);
    } catch (_) {
      if (backup != null && !await file.exists()) {
        await backup.copy(file.path);
      }
      rethrow;
    }
    return ExternalAiInstallResult(
      configPath: file.path,
      backupPath: backup?.path,
      changed: true,
    );
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
}

String _mergeCodexConfiguration(
  String original,
  String configuration,
  String serverName,
) {
  final start = '# BEGIN FLUENT PLAYER MCP $serverName';
  final end = '# END FLUENT PLAYER MCP $serverName';
  final block = '$start\n$configuration$end\n';
  final startIndex = original.indexOf(start);
  final endIndex = original.indexOf(end);
  if (startIndex >= 0 || endIndex >= 0) {
    if (startIndex < 0 ||
        endIndex < startIndex ||
        original.indexOf(start, startIndex + start.length) >= 0 ||
        original.indexOf(end, endIndex + end.length) >= 0 ||
        (startIndex > 0 && original[startIndex - 1] != '\n')) {
      throw const FormatException('播放器连接配置标记不完整，原文件已保留。');
    }
    var tailIndex = endIndex + end.length;
    if (original.startsWith('\r\n', tailIndex)) {
      tailIndex += 2;
    } else if (original.startsWith('\n', tailIndex)) {
      tailIndex++;
    } else if (tailIndex < original.length) {
      throw const FormatException('播放器连接配置标记格式有误，原文件已保留。');
    }
    return original.substring(0, startIndex) +
        block +
        original.substring(tailIndex);
  }
  // Never replace an existing unmarked server, including quoted table names.
  // A conservative text check can refuse an unusual comment safely; it cannot
  // erase another server or require a dependency for parsing all of TOML.
  final escaped = RegExp.escape(serverName);
  final key = '(?:$escaped|"$escaped"|\'$escaped\')';
  if (RegExp(
        'mcp_servers\\s*\\.\\s*$key(?:\\s*[.\\]\\n\\r])',
      ).hasMatch(original) ||
      RegExp('(?:^|[\\s,{])$key\\s*=').hasMatch(original)) {
    throw const FormatException('Codex 中已存在同名连接，请使用复制配置并手动合并。');
  }
  return '$original${original.isEmpty || original.endsWith('\n') ? '' : '\n'}\n$block';
}
