# Codex 首字等待与连接复用

本次仅调整连接生命周期和状态提示，不改模型、思考等级、思考展示偏好或本机 Codex 配置。

## 已调整的行为

- 空闲聊天的设置页借用聊天控制器拥有的连接。设置页完成连接测试后关闭，不再销毁该连接；下一条聊天请求可继续复用它。后台仍有对话或标题请求时，设置页使用独立连接，避免干扰正在生成的回答。
- Codex 初始化进程的空闲保活从两分钟延长到十五分钟，不发送模型请求维持保活。聊天控制器释放时立即清理；进程断开或更换工具路径时重新连接。
- 状态区分别显示启动、复用连接、准备本轮会话，以及请求已发送后等待响应。准备独立会话不再统一标成“正在连接所选模型”。
- 每轮仍使用独立 ephemeral 线程。应用已经发送经过预算处理的完整上下文，复用带有旧输入的线程会叠加历史，因此此处保留上下文隔离。

复用本机 App Server 进程及标准输入输出连接，不等于保证 Codex 到模型服务的每一条底层网络连接都不重建。上游请求的排队、处理和首字等待需要分别判断。

## 源码参考与取舍

- [DeepChat 的进程管理](https://github.com/ThinkInAIXYZ/deepchat/blob/48b83df5e0fedd70e5c3d9974a8a5e6e52d2ea85/src/main/agent/acp/runtime/acpProcessManager.ts#L475-L530) 校验启动配置和进程存活状态，复用健康连接；[会话管理](https://github.com/ThinkInAIXYZ/deepchat/blob/48b83df5e0fedd70e5c3d9974a8a5e6e52d2ea85/src/main/agent/acp/runtime/acpSessionManager.ts#L144-L164) 按对话管理归属。本项目借鉴连接由对话生命周期持有的方式，保留自己的上下文隔离策略。
- [AionUi 的启动诊断](https://github.com/iOfficeAI/AionUi/blob/11cd2a9a20d1e033157636efc570b41384c66d85/scripts/benchmark-acp-startup.ts#L118-L185) 区分进程启动、协议初始化、会话创建和首字时间。本项目采用分阶段测量与提示；未运行其客户端作跨软件速度排名。
- [OpenAI App Server 官方文档](https://learn.chatgpt.com/docs/app-server) 区分连接初始化、线程和生成轮次，连接上的 initialize 只执行一次。

## 本机验证（2026-11-02）

Windows x64，Codex CLI 0.162.1，沿用应用当前选择的 `gpt-6.1-terra` 和 `high`。同一进程连续发送两条相同的最小提示 `Reply with OK. Do not use tools.`，不包含视频字幕：

| 阶段 | 第一条 | 第二条 |
| --- | ---: | ---: |
| 启动与初始化完成 | 622ms | 复用已有连接 |
| 准备会话到本地接受确认 | 414ms | 158ms |
| 接受确认后到正文首字 | 5834ms | 5862ms |
| 从发送到正文首字 | 6870ms | 6020ms |

第二条没有再次初始化进程。此样本的主要等待发生在本地接受确认之后；两条短消息不能代表长字幕或所有时段的延迟，也不能据此将全部等待归因于某一种上游因素。

124 项定向回归与静态分析通过，覆盖进程复用、设置页借用后关闭、思考参数保留、空闲到期回收、释放控制器、取消和失败恢复。上表的真实 CLI 双轮验证也通过。原生探针在 `test/ai_codex_live_stream_test.dart`，仅设置 `RUN_AI_CODEX_APP_SERVER_LIVE=1` 时运行；可用 `AI_CODEX_MODEL`、`AI_CODEX_EFFORT`、`AI_CODEX_LATENCY_PROMPT` 指定诊断参数。这些参数只影响探针，不写回应用或 Codex 设置。
