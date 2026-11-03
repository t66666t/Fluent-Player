# 桌面 AI Agent 对话

AI 对话可以连接本机已经安装的 Agent，使用其登录状态和模型服务。入口沿用「AI 设置 → 连接方式」，回答、思考内容、停止生成、字幕上下文和聊天记录使用现有对话界面。

本功能仅面向 Windows、macOS 和 Linux。Android、iOS 不提供这些桌面 Agent 选项。连接方式列表直接隐藏当前平台或处理器架构不支持的选项，不显示灰色禁用项。如果已有配置选中了不支持的 Agent，设置页恢复已保存的 API 配置，同时保留桌面 Agent 的路径、参数、模型和思考等级。本次不增加远程连接、WSL 管理、工具安装或自动升级。

## 使用方式

1. 按 Agent 的官方说明安装工具，并先在终端完成登录或模型服务配置。
2. 在 AI 设置中选择对应 Agent。应用会从 PATH 和常见安装目录查找；也可以填写可执行文件或安装文件夹。
3. 点击「自动检测安装与登录」确认连接，再刷新模型目录。模型和思考选项以工具实际提供的内容为准。
4. 测试连接成功后，在原有 AI 对话中提问。切换工具时分别保存路径、模型和思考等级。

应用不读取 Agent 的凭据文件，也不把登录密钥复制进聊天设置。工具检查使用协议握手与会话创建；它与真实模型请求不同，账号是否能调用指定模型仍由连接测试确认。Agent 自身没有提供模型目录时，不编造可选模型或上下文规格。

## 接入清单

现有 Codex CLI 和 OpenCode CLI 保留原有接入方式。新增 Agent 使用 ACP v1 的 JSON-RPC 标准输入输出接口。

| 选项 | 运行的程序 | 固定参数 | 首次准备 |
| --- | --- | --- | --- |
| Claude Agent | `claude-agent-acp` | 无 | 安装 ACP 适配器，完成 Claude 登录或服务配置；不要选择普通 `claude` 命令代替适配器 |
| Gemini CLI | `gemini` | `--acp` | 安装支持此参数的版本，在终端完成 Gemini 登录 |
| Qwen Code | `qwen` | `--acp` | 在工具中通过 `/auth` 配置服务 |
| Kimi Code CLI | `kimi` | `acp` | 使用新的 Kimi Code CLI，通过 `/login` 登录 |
| GitHub Copilot CLI | `copilot` | `--acp` | 安装支持 ACP 的版本，通过 `/login` 登录 |
| Qoder CLI | `qoder` | `--acp` | 先运行 `qoder login` |
| Cursor CLI | `cursor-agent` | `acp` | 先安装并登录；安装中只有 `agent` 命令时，可手动指定该文件 |
| Mistral Vibe | `vibe-acp` | 无 | 安装 ACP 可执行文件并配置模型服务 |
| Goose | `goose` | `acp` | 安装 CLI，通过 `goose configure` 配置服务 |
| 自定义 ACP Agent | 用户指定 | 用户填写 | 工具须支持 ACP v1 标准输入输出协议并已完成登录 |

自定义参数填写为 JSON 字符串数组，例如 `["--acp"]` 或 `["acp"]`。路径与参数独立保存，不能在路径栏填写整条命令。提示词通过进程标准输入发送，不拼入 shell 命令行。

上述工具通常提供 Windows、macOS、Linux 版本，但具体 CPU 架构和运行依赖由上游决定：

- Kimi Code CLI 在 Windows 上需要 Git for Windows 提供的 Git Bash。
- Qoder 暂不提供 Windows ARM64 版本；Goose、Vibe 的预设平台匹配也不承诺 Windows ARM64。
- Mistral Vibe 的官方主要支持环境是 UNIX；Windows 需要单独验证。
- Gemini、Qwen、Copilot、Claude 适配器的 npm 安装方式需要相应版本的 Node.js。应用不会自动安装运行时。
- Kiro 暂未加入预设：其 ACP v2/v3 引擎存在协议差异。需要时可通过自定义 ACP 指定经验证的标准协议版本。

## 对话行为与边界

外部 Agent 的文本和思考流映射到现有回答区域。模型目录优先使用 Agent 的 `configOptions`，兼容旧版 `models.availableModels`；选择模型与思考等级只发送该工具已公布的选项。

每次请求使用完整的应用内对话上下文、独立 ACP 会话和独立临时会话目录，避免叠加 Agent 的隐藏历史。进程工作目录仍为应用创建的私有临时目录。停止生成会取消当前请求并清理所属进程；一个请求的退出不会停止另一个对话。

### ACP 连接复用

Claude、Gemini CLI、Qwen Code、Kimi Code、GitHub Copilot CLI、Qoder、Cursor、Mistral Vibe、Goose 和自定义 ACP Agent 共用以下生命周期：

- 正常完成的连接保留 15 分钟，下一次检查、读取模型目录或聊天可以复用进程和 initialize 握手。最多保留两个空闲进程，每个进程累计创建 32 个会话后回收；不发送保活提示词或后台推理。
- 每个进程同一时间只服务一个请求。并发请求使用其他进程，取消或失败只回收所属进程。完成后移除该请求的取消监听；关闭设置页不会通过已经完成的检查取消下一轮聊天。
- 可执行文件先解析为实际路径，再根据 Agent、路径、启动参数和应用网络配置匹配连接。模型与思考等级在每个新会话中重新按原设置选择，不降低思考等级。
- 每次仍调用 session/new，校验会话 ID，隔离配置、输出和当前请求的上下文；完成后清理临时会话目录。程序关闭和请求结束共用同一次清理，等待尚未完成的会话目录创建。
- 如果复用连接在提交提示词之前断开，允许重建一次。若 Agent 无法创建第二个独立会话或返回重复会话 ID，先重建进程再准备会话，并在当前客户端生命周期内对这个启动配置使用一次性进程。不会因此重发已经提交的提示词。

这只省去本地进程冷启动和 ACP 初始化，模型服务自身的等待、每个新会话的初始化及网络延迟仍会存在。协议允许一个 Agent 进程承载多个独立会话，不代表每家 Agent 都能复用其内部的模型 HTTP 连接。

### OpenCode 的判断

现有 OpenCode 后端使用一次性的 run --format json，不能通过保留 stdin 直接变为常驻协议。其官方提供 [serve 与 run --attach](https://opencode.ai/docs/cli/#run)，也提供 [ACP 接口](https://opencode.ai/docs/acp/)。这些接口可以另外实现连接复用，但切换需要处理本地服务认证、生成任务取消、video-chat 专用 Agent 权限和模型 variant 的等价行为。

本轮保留 OpenCode 现有传输。当前机器未安装 OpenCode，未将缺少原生验证的传输切换混入 ACP 生命周期修复。其余 ACP 后端在协议兼容时已经自动使用上述复用，无需新增开关。

本入口用于字幕与媒体问答。客户端不提供文件或终端能力，并拒绝工具权限请求。它不是通用代码工作区；Agent 自身配置、插件或运行时行为仍由该工具管理，客户端能力声明不等于操作系统沙箱。

## 验证与发布记录

协议测试使用受控的模拟进程覆盖握手、模型发现、流式回答、思考、取消和失败清理。`test/ai_agent_native_test.dart` 还提供真实子进程测试：通过 `AI_ACP_NATIVE_DART` 指定独立 Dart 可执行文件，运行 `test/fixtures/ai_acp_stdio_agent.dart`，覆盖 JSONL 字节分片、中文流式内容、模型/思考等级设置、跨检查/目录/聊天复用同一进程、独立会话和进程/临时目录回收。普通测试默认跳过此项。

另可通过 `AI_ACP_QWEN=true` 检查本机已安装的 Qwen Code 握手和模型发现，`AI_ACP_QWEN_PATH` 可指定路径。仅开启此项不发送推理请求；额外设置 `AI_ACP_QWEN_INFERENCE=true` 才发送一次最小连接问答。上述测试证明客户端协议处理与界面行为，不代表各厂商账号已经完成真实模型推理。

发布时应分别记录实际验证的平台、CPU 架构、Agent 版本和账号状态。仅编译通过、检查到工具或读取到模型目录，不能记为真实对话验证。没有对应工具或登录凭据的平台应明确列为未实测。

### 本次验证（2026-11-02）

- Windows x64：真实 Dart 子进程的一次初始化、四个新会话（检查、模型目录和两轮聊天）复用同一进程，中文分片流式、模型/思考等级、取消及进程和临时目录清理通过。
- 本机 Qwen Code 0.24.0：本轮 ACP 握手及模型发现通过，没有发送推理请求。此前最小问答及独立 Qwen CLI 均返回默认模型 `404 Model not exist`；未更改工具的全局模型或凭据配置。
- 本轮 164 项定向回归通过（包含 32 项 ACP 协议用例、真实 Dart 子进程和 Qwen 握手/模型发现），静态分析通过。协议用例覆盖冷/热启动、新会话、并发隔离、旧取消令牌、路径/参数/网络配置变化、空闲回收、会话上限、不兼容会话回退、启动与关闭竞态。此前完整 AI 和音乐对话回归 830 项通过、6 项跳过、1 项失败；已有 Markdown 标题链接字重断言（预期 w700、工作区已有样式 w600）未改动。
- Windows 调试构建与本次涉及代码的静态分析通过。macOS、Linux 和其余新增 Agent 的真实账号推理尚未实测。

## 参考

- [ACP 官方注册表](https://github.com/agentclientprotocol/registry)：预设启动参数和分发平台参考，应用不会在启动时下载注册表或安装包。
- [ACP v1 协议](https://agentclientprotocol.com/protocol/overview)：握手、会话、模型配置、流式输出及取消。
- [DeepChat 进程管理](https://github.com/ThinkInAIXYZ/deepchat/blob/48b83df5e0fedd70e5c3d9974a8a5e6e52d2ea85/src/main/agent/acp/runtime/acpProcessManager.ts#L475-L530)：参考启动签名匹配、健康进程复用和独占生命周期；没有照搬其按对话保留完整会话历史的方式。
- [ACP v1 会话规范](https://agentclientprotocol.com/protocol/v1/session-setup)：独立上下文和唯一会话 ID。
- [Claude Agent ACP](https://github.com/agentclientprotocol/claude-agent-acp)、[Qwen Code](https://github.com/QwenLM/qwen-code)、[Kimi Code CLI](https://github.com/MoonshotAI/kimi-code)。
- [Qoder ACP](https://docs.qoder.com/cli/acp)、[Cursor ACP](https://cursor.com/docs/cli/acp)、[Kiro ACP v3 迁移说明](https://kiro.dev/docs/cli/v3/acp-migration/)。
