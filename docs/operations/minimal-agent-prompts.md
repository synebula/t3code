# 最小化 agent 提示词与工具

这个分支默认关闭 T3 Code 向 coding agent 注入的全部自有提示词，并且不再向 agent 下发 `t3-code` MCP 工具。agent 只会收到用户消息、附件路径、provider 自身提供的系统提示，以及用户通过启动参数显式提供的提示。

## 开关

开关位于 [`packages/provider-core/src/server/extraIntegrations.ts`](../../packages/provider-core/src/server/extraIntegrations.ts)：

- 不设置 `T3_CODE_EXTRA_INTEGRATIONS`：关闭 T3 额外集成。这是默认行为。
- `T3_CODE_EXTRA_INTEGRATIONS=1`：恢复上游行为，注入提示词并下发 MCP 工具。
- 其他值（包括 `0`、`true`、空字符串）：保持关闭。

开关在进程启动时读取。修改后需要重启 server。测试运行时会由 [`packages/shared/src/testing/providerEnv.ts`](../../packages/shared/src/testing/providerEnv.ts) 自动设为 `1`，以保留上游提示词测试的覆盖；需要测试关闭路径时，单独把环境变量设为 `0`。

## 已关闭的注入

关闭路径尽量收在提示词来源处，适配器本体基本不动：

| 注入内容                                                                      | 关闭方式                                                                                        | 关闭后的行为                                       |
| ----------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| `<runtime_info>`、模型信息、PR 链接与 watch 指令                              | `buildRuntimeInstructions` 返回空串；`PULL_REQUEST_LINKING_INSTRUCTIONS` 为空串                 | 不再添加                                           |
| `T3_CODE_ORCHESTRATION_INSTRUCTIONS`、`<t3_code_orchestration_instructions>`  | 该常量在关闭时为空串；`t3OrchestrationPrompt` / `t3OrchestrationSystemPrompt` 直接返回原 prompt | 不再添加                                           |
| 浏览器 `preview_*`、设备 `device_*` 使用说明                                  | 仅通过编排函数与 MCP session 携带                                                               | 不再添加                                           |
| ACP 交互模式说明与 `<t3_code_instructions>` 包装                              | `t3AcpPromptWithInstructions` 直接返回原 prompt                                                 | 用户原始 prompt 原样发送                           |
| Claude `CLAUDE_BACKGROUND_WAIT_INSTRUCTIONS`、设备说明与 `SubagentStart` hook | 只在 `mcpServers` 存在时拼接；关闭后无 MCP server                                               | 不再添加，hook 不注册                              |
| Codex `additionalContext` 中的 `t3_code_*` 条目                               | 只在 `hasT3Mcp` 时构建；关闭后无 MCP session                                                    | 不发送 T3 context；用户自己的 app context 不受影响 |
| Cursor 的 prompt 前缀、OpenCode 的 system/instructions、Muse 的首个文本块     | 编排函数返回原 prompt、runtime 文案为空串                                                       | 不再添加；相应 provider 不发送空的 system/text 块  |
| Pi 扩展的 `before_agent_start` 补丁                                           | 常量在关闭时为空串                                                                              | 不再添加                                           |
| SnapShot 捕获窗口的 accessibility/accessibleText JSON                         | `providerMessageTextWithAttachmentPaths` 忽略 `source`                                          | 只保留附件路径与提取文本，不发送窗口内容           |
| `t3-code` MCP server 与工具                                                   | `configureMcp: false`                                                                           | 不签发凭据，不添加 MCP server                      |

被关闭的 `t3-code` 工具包括 `delegate_task`、`t3_thread_*`、`t3_environment_*`、`request_secret`、`schedule_task`、`preview_*`、`device_*`、PR link/watch、HTML preview 等。它们依赖 MCP session，session 不存在时各 provider 适配器会自然跳过。

## 保留的行为

- provider 自带的系统提示，例如 Claude Code 的 `claude_code` preset。
- 用户在 Claude 启动参数里提供的 `--append-system-prompt`、`--append-system-prompt-file`。
- 附件路径、已提取文本等发送消息所必需的内容。
- 上下文交接、fork 增量和 side chat 的框架说明。它们只在该功能触发时出现，用于把历史材料标记为历史，不参与每轮 system prompt。
- 标题、提交信息、PR 描述、review guide、分支名生成。这些是独立的一次性模型调用，不注入 coding agent 会话。
- Triage playbook。它用于独立的 triage 流程，同样不注入 coding agent 会话。
- 模型选择、权限模式、sandbox、provider 鉴权等非提示词行为。

## 功能影响

关闭 MCP 工具后，agent 无法再通过 T3 调用线程、环境、密钥、定时任务、浏览器、设备、PR 链接与 watch 等能力。相关 UI 仍可正常使用，但需要 agent 主动调用 T3 工具的流程会停止工作。需要这些能力时，用 `T3_CODE_EXTRA_INTEGRATIONS=1` 启动。

关闭 accessibility 注入后，SnapShot 附件仍会附带图片路径，但 agent 看不到窗口的控件树或可读文本。

## 构建与运行

先按仓库 [README](../../README.md) 安装 `vp`（Vite+），再执行：

```sh
vp i
vp run build
vp run start
```

开发模式：

```sh
vp run dev
```

临时恢复上游行为：

```sh
T3_CODE_EXTRA_INTEGRATIONS=1 vp run dev
```

桌面端会继承启动它的环境变量，因此也可以在启动桌面端前导出该变量。

## 验证

```sh
vp test run packages/provider-core/src/server/extraIntegrations.test.ts \
  packages/provider-core/src/server/runtimeInstructions.test.ts \
  packages/provider-core/src/server/orchestrationInstructions.test.ts
vp run typecheck
vp run build
```

`extraIntegrations.test.ts` 覆盖默认关闭、开关解析、关闭时的提示词输出和 SnapShot 内容过滤。其余上游提示词测试在 `T3_CODE_EXTRA_INTEGRATIONS=1` 下运行，继续校验原有文案。

## 代码位置

- 开关：[`packages/provider-core/src/server/extraIntegrations.ts`](../../packages/provider-core/src/server/extraIntegrations.ts)
- 运行时与编排提示词：[`runtimeInstructions.ts`](../../packages/provider-core/src/server/runtimeInstructions.ts)、[`orchestrationInstructions.ts`](../../packages/provider-core/src/server/orchestrationInstructions.ts)
- 附件上下文：[`attachmentPrompt.ts`](../../packages/provider-core/src/server/attachmentPrompt.ts)
- 空值防护：ACP、Muse、OpenCode、OpenCode v2、Pi 的 adapter，以及 [`AntigravityAcpSupport.ts`](../../apps/server/src/provider/acp/AntigravityAcpSupport.ts)（空 system prompt append 不下发）
- MCP 开关：[`runtimeLayer.ts`](../../apps/server/src/orchestration-v2/runtimeLayer.ts)
- 测试环境默认值：[`providerEnv.ts`](../../packages/shared/src/testing/providerEnv.ts)
