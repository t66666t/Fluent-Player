# 外部 Agent 连接步骤

调研日期：2026-11-03。本文区分官方文档已确认的操作、本机观察和真实调用验证；列出某个客户端不表示已在该客户端实机通过全部流程。菜单名称会随版本、语言和账号设置变化。

## 先在播放器准备

1. 打开“媒体库设置 → 连接外部 AI”，开启资料读取，选择允许访问的目录，并保持播放器运行。
2. 选择实际使用的客户端。WorkBuddy、WorkBuddy AI、千问办公和普通千问是不同产品，不能互相套用配置。
3. 可以把“复制连接提示词”的内容发给有本机文件操作权限的 Agent，让它备份并合并配置；也可以在“其他连接方式”中添加连接或复制配置。
4. 配置写入后，继续完成下文对应客户端的加载、信任和启用。**提示词可以协助配置，不能代替客户端要求的用户确认，也不能保证运行中的会话自动出现新工具。**

完整版连接名是 `fluent_player`；社区版是 `fluent_player_community`。下文以完整版为例。两版应分别从各自播放器复制配置，勿交叉使用令牌和地址。

## 如何才算连接完成

在目标 Agent 的原生工具列表中找到播放器工具，并让它真实调用：

> 请使用 Fluent Player 的 MCP 工具，先调用 player_overview，再调用 library_browse，列出我授权的媒体库目录。请说明实际调用结果；如果工具未加载，请告诉我需要在客户端完成的具体步骤，不要使用模拟数据或把写入配置当成连接成功。

这两次调用都成功返回，才表示这个 Agent 当前能够使用播放器。播放器“检测连接”只检查播放器自身服务；工具缓存、配置文件和本机 HTTP 检测也不能证明目标 Agent 的当前任务已加载工具。工具列表应包含 `player_overview` 和 `library_browse`；单独开放历史对话后才会出现 `conversations_read`。

批量查哪些媒体有文稿用 `library_documents`，跨视频搜原文关键词用 `library_document_search`；这两个工具沿 `nextOffset` 翻页。总结多个视频直接将 `mediaIds` 传给 `documents_read_batch`，无需逐个查询清单；将返回的 `nextRequests` 整体传入下次 `requests`，直到为空，并说明所有页 `errors` 中未覆盖的资料。单文稿细查仍可用 `documents_list` 和 `document_read`，保持同一个 `revision`，直到 `nextOffset` 为 `null`。连接功能不会自动转录或下载资料。当前默认 10 项工具；升级后仍只看到 7 项时，按客户端要求刷新 MCP 工具或重新加载连接。

## Codex

1. 在播放器选择 **Codex**，添加连接或让 Agent 将生成的 TOML 合并到当前 `CODEX_HOME/config.toml`；未设置 `CODEX_HOME` 时是用户目录的 `.codex/config.toml`。保留原有连接、账号和模型设置。
2. 打开 Codex 的 **Settings → MCP servers**，确认存在 `fluent_player`。也可按官方界面流程使用 **Add server → Streamable HTTP** 添加；认证请求头使用播放器生成的配置，不只填写服务地址。
3. 官方桌面流程保存后有 **Restart** 步骤。当前有任务运行时，先保留“已配置，等待加载”，等方便时再处理该步骤；不要为连接播放器强制终止现有任务。新建对话本身不保证运行中的后端重新读取配置。
4. 加载后用 `/mcp` 查看状态，再发送上面的验证请求。若当前会话没有原生工具，不报告调用验证通过。

官方 app-server 有 `config/mcpServer/reload` 接口，但这是宿主接口，不等于每个对话 Agent 都有刷新工具。本机没有验证出可供当前 Agent 使用、且不重启现有后端的原生加载路径。不要通过启动另一个独立测试进程，声称已经刷新当前会话。

来源：[Codex MCP](https://learn.chatgpt.com/docs/extend/mcp)、[app-server](https://learn.chatgpt.com/docs/app-server)。

## WorkBuddy

1. 在播放器选择 **WorkBuddy**，添加连接或让 Agent 合并当前实例的 `mcp.json`。默认是用户目录 `.workbuddy/mcp.json`；实例指定了配置目录时使用该目录。
2. 在 WorkBuddy 左侧进入 **专家·技能·连接器 → 连接器 → 自定义连接器 → 配置 MCP**。确认有 `fluent_player` 并保存。已有其他连接时，只合并播放器条目。
3. 返回 MCP 列表。若出现“首次连接此 MCP 服务器需要您的信任确认”，阅读后由用户点击 **信任**。只写入文件不会替用户完成此步骤。
4. 开启播放器右侧开关，展开条目，确认工具列表已加载。灰色圆点、关闭的开关或等待信任，都表示尚未准备好。
5. 回到任务，在输入框左下角 **+ → 连接器** 中启用播放器；界面提供 **去对话** 时也可从连接器发起。再发送验证请求。

外部程序改写配置文件，不保证 WorkBuddy 当前运行时立即读取。找不到新增条目时，先进入客户端配置页检查并保存；不要反复让 Agent 写同一文件。若版本仍要求重新加载或重启，明确提示用户稍后处理，不中断其他任务。

本机 5.9.3 的截图确认存在独立的首次“信任”步骤。工具缓存只能证明曾发现工具；是否当前可用仍以该任务的真实调用为准。

来源：[WorkBuddy 用户连接器指南](https://www.workbuddy.cn/docs/workbuddy/From-Beginner-to-Expert-Guide/Function-Description/Connector)、[WorkBuddy MCP 配置规范](https://open.workbuddy.cn/docs/connector)。

## WorkBuddy AI

1. 在播放器选择 **WorkBuddy AI**，使用它自己的配置，勿写到国内 WorkBuddy 的目录。本机这一版本的自定义配置位于 `.workbuddy-ai/connectors/default/mcp.json`；其他版本先核对客户端实际入口，不猜测路径。
2. 官方海外界面入口是左栏 **Connectors → Custom Connector**；按页面添加或保存播放器配置。
3. 完成该版本显示的信任/权限确认，开启连接开关，检查工具列表；再通过消息输入框的连接器管理，将播放器用于当前任务。
4. 发送验证请求。遇到当前任务未载入工具，按客户端显示的重新加载步骤处理；不能因为国内 WorkBuddy 验证成功，就报告 WorkBuddy AI 已通过。

本机安装版本为 5.5.2，尚未完成这一客户端的完整界面与调用验证。海外官方文档确认自定义连接器入口、输入框快速管理和启用开关，没有据此承诺所有版本菜单完全一致。

来源：[WorkBuddy AI 官方连接器指南](https://www.workbuddy.ai/docs/workbuddy/From-Beginner-to-Expert-Guide/Function-Description/Connector)。

## 千问办公 / QwenWork

1. 在播放器选择 **千问办公**，复制该客户端的 JSON 配置。
2. 在千问办公进入 **扩展 → 连接器 → + 添加 → 粘贴 JSON 配置**，粘贴后点击 **导入**。
3. 在 **已安装 → 自定义** 中找到播放器，完成界面显示的授权并开启开关；展开确认工具列表。
4. **新建一个对话任务**，然后发送验证请求。阿里官方明确：刚开启或关闭连接器后，原有对话不会更新工具，应新建任务；这一步不是重启整个应用。

千问办公使用 `type: "streamable-http"`。不要套用 WorkBuddy 的 `streamableHttp` 或将普通千问当作千问办公。本机安装的普通千问尚未确认提供这种自定义 MCP 接口，因此不能报告其已支持。

来源：[千问办公官方连接器文档](https://help.aliyun.com/zh/qwenwork/qw-connectors)。

## Cursor

1. 在播放器选择 **Cursor**。让 Agent 合并用户 `.cursor/mcp.json`，或使用 Cursor 的 MCP 配置入口添加。配置是 `mcpServers`，包含地址和认证头。
2. 在 **Customize → MCPs**（部分版本为 Settings → MCP）确认并启用播放器。
3. 官方手动配置流程包含保存后重启 Cursor。当前有任务时先保存配置，待方便时加载；不要保证当前会话即时可用。
4. 在聊天的 **Available Tools** 中检查播放器工具已启用，首次调用按提示确认，再发送验证请求。故障可查看 **MCP Logs**，勿公开其中的凭据。

Cursor 有配置导入链接，但本功能不把含认证令牌的配置放入 URL。本文未完成 Cursor 实机验证。

来源：[Cursor MCP 帮助](https://cursor.com/help/customization/mcp)、[配置导入链接](https://cursor.com/docs/mcp/install-links)。

## VS Code / Copilot

1. 在播放器选择 **VS Code / Copilot** 并复制配置。
2. 按 **Ctrl+Shift+P → MCP: Open User Configuration**，将播放器合并到该用户 MCP 文件的 `servers` 中并保存。不要将这份 `servers` 格式直接替换为其他客户端的 `mcpServers` 文件。
3. 运行 **MCP: List Servers → fluent_player → Start Server**；已有连接可使用 **Restart Server**。这针对服务器，不要求重启整套 VS Code。
4. 首次出现服务器信任或工具调用权限提示时，由用户审核确认。
5. 在聊天的工具配置中启用播放器，发送验证请求。

VS Code 当前也有面向 Copilot 的其他全局/可移植配置入口；本功能生成的 `servers` 对应用户 MCP 配置文件，应使用匹配的入口。本文未完成 VS Code 实机验证。

来源：[VS Code MCP 服务器指南](https://code.visualstudio.com/docs/agent-customization/mcp-servers)、[MCP 配置参考](https://code.visualstudio.com/docs/agents/reference/mcp-configuration)。

## TRAE

1. 在播放器选择 **TRAE**，复制配置。
2. 进入 TRAE 的 **设置 → MCP → 添加 → 手动添加**，按客户端要求合并服务器配置并保存。Agent 窗口显示运行环境时选择 **本地**；云端任务不能访问本机播放器的 loopback 地址。
3. 确认连接启动成功，并为实际使用的智能体启用播放器；完成首次工具调用确认。
4. 若现有对话未出现新工具，检查该智能体的工具选择，再按客户端提示重新加载或新建对话，最后发送验证请求。

菜单和可用传输随产品版本、地区不同；没有原生本机 HTTP MCP 入口的版本不能据此声称支持。本文未完成 TRAE 实机验证。

来源：[TRAE 官方添加 MCP Server](https://docs.trae.cn/ide_add-mcp-servers)、[在智能体中使用 MCP](https://docs.trae.cn/ide_use-mcp-servers-in-agents)。

## Qoder

1. 在播放器选择 **Qoder**，复制配置。
2. 进入 **Qoder IDE Settings → MCP → My Servers → + Add**，在打开的 JSON 中合并配置，关闭文件时按提示保存。官方说明 HTTP 端点按远程服务器配置，Qoder 会自动识别 Streamable HTTP。
3. 确认服务器显示连接图标，展开查看工具；在聊天中切到 **Agent 模式**，完成工具调用确认（Windows 为 **Ctrl+Enter**，macOS 为 **⌘+Enter**）。
4. 发送验证请求。工具未出现时，按客户端的连接状态与重新加载提示处理，不仅根据配置文件判断成功。

本文未完成 Qoder 实机验证。

来源：[Qoder MCP 官方指南](https://docs.qoder.com/user-guide/chat/model-context-protocol)。

## Claude Code

1. 在播放器选择 **Claude Code**，让有文件权限的 Agent 将 JSON 合并到当前工作区 `.mcp.json`，保留其他服务器。不要将认证令牌作为命令参数或发到聊天正文。
2. 在 Claude Code 使用 `/mcp` 检查连接；按显示的工作区信任、项目 MCP 服务器和调用权限提示确认。服务器已经列出但连接失败时，可在该服务器菜单中选择 **Reconnect**。
3. 若当前会话未加载刚添加的服务器，按客户端要求重新进入该工作区会话；保留其他正在运行的任务。
4. 确认播放器工具可见后，发送验证请求并审核首次调用提示。

Claude Code 与 Claude Desktop 是不同客户端。本文未完成 Claude Code 实机验证。

来源：[Claude Code MCP 官方指南](https://code.claude.com/docs/en/mcp)。

## Gemini CLI

1. 在播放器选择 **Gemini CLI**，将生成的 `mcpServers` 合并到用户 `.gemini/settings.json`。HTTP MCP 地址使用 `httpUrl`，不要当成本地程序启动命令。
2. 在 Gemini CLI 的交互会话执行 `/mcp reload` 重新加载服务器，再用 `/mcp list` 检查工具。若播放器显示 Disabled，使用 `/mcp enable fluent_player`。
3. 审核首次调用授权；无需将服务器设置成永久信任或跳过客户端原有的确认。
4. 工具可见后发送验证请求。当前版本没有重新加载能力时，稍后重新进入会话，不终止其他任务。

本文未完成 Gemini CLI 实机验证。

来源：[Gemini CLI MCP 官方指南](https://geminicli.com/docs/tools/mcp-server/)、[交互命令参考](https://geminicli.com/docs/reference/commands/)。

## 其他 Agent 与暂未支持的情况

- 其他 Agent 需要支持在本机访问 **Streamable HTTP MCP**、配置认证请求头，以及让当前任务使用自定义服务器。使用它自己的 MCP 设置入口，不猜测配置文件位置。
- 只有云端远程连接器的产品无法通过 `127.0.0.1` 访问用户电脑上的播放器。本功能不提供公网地址或跨设备连接。
- Claude Desktop 当前没有随播放器提供 `.mcpb` 桌面扩展或 stdio 桥，因此暂不作为已支持客户端；不要把本机地址填到由云端发起连接的入口。
- 普通千问尚未确认自定义 MCP 能力，不能使用千问办公的说明充当支持依据。
- 播放器服务面向 Windows、macOS、Linux 桌面，文件路径按当前系统生成；本次实机验证限于 Windows。某个 Agent 是否支持某个操作系统，还需看该 Agent 的发行版。

## 排查顺序

1. 播放器是否正在运行、资料读取开关是否开启？改了端口或撤销过令牌后，重新复制配置并更新客户端。
2. 客户端是否选对？标题、说明文件里的 `client`、实际客户端与服务器名称应匹配。
3. 配置是否保存在该实例实际使用的位置？已写文件但列表没有条目时，进入客户端的 MCP 配置页检查并保存或按其提示加载。
4. 是否仍在等待用户信任、开关是否关闭、工具是否被禁用、当前任务是否选择了连接器？
5. 是否需要新建任务或稍后重新加载？按客户端要求操作，不一律要求重启整套应用。
6. 两个原生 MCP 工具是否真实返回？把“已配置”“等待确认/加载”“工具可见”“调用验证通过”分开报告。

不要为排查安装模型或桥接运行时，不要关闭系统代理或安全防护，不要覆盖整份配置，也不要自动修改客户端的信任记录。若客户端或网络限制无法解决，保留现有任务，说明卡住的具体阶段。
