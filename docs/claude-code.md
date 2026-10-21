# Claude Code 提醒

[返回首页](../README.md) · [图形界面](desktop.md) · [ntfy 手机设置](ntfy.md) · [微信机器人绑定](wechat.md)

Claude Code 做完这一轮任务，或者正在等你回答、确认计划、允许使用工具时，让手机提醒你。和 Codex 提醒共用同一套通知渠道（ntfy、微信 ClawBot），可以单独使用，也可以和 Codex 提醒一起用。

桌面版 Code 标签、终端里的 `claude`、VS Code 插件都读取同一份 `~/.claude/settings.json`，部署一次即可全部生效。

## 会收到什么？

| 什么时候 | 默认通知标题 | 触发来源 |
| --- | --- | --- |
| Claude Code 完成这一轮回复 | Claude Code 任务已完成 | `Stop` |
| 弹出选择题（AskUserQuestion），或 MCP 服务弹出输入表单 | Claude Code 等待你回答 | `PreToolUse`、`Notification` |
| 计划模式写好计划，等你批准 | Claude Code 等待你确认计划 | `PreToolUse`（ExitPlanMode） |
| 请求使用工具的权限，约 6 秒仍未答复 | Claude Code 等待你授权 | `Notification`（permission_prompt） |
| 因限流、登录失效、服务繁忙等 API 错误中断 | Claude Code 出错停止 | `StopFailure` |
| 回复完约 60 秒你还没动（默认关闭，`-IdleReminder` 开启） | Claude Code 仍在等你 | `Notification`（idle_prompt） |
| 你主动发送测试 | 手机提醒测试（与 Codex 共用） | 测试按钮或 `send-test.ps1` |

正文只有提醒、电脑名称和时间，不包含聊天内容、代码、问题正文、弹窗内容或命令。时间格式与 Codex 提醒一致：`2026-10-20    08:30:00`。

**不会提醒的情况：**

- 你自己按 Esc 中断的轮次（Claude Code 不会触发 `Stop`）。
- 后台子代理、工作流还在运行，或者设置了定时唤醒（`/loop`、定时任务）：Claude 之后会自动继续，这只是暂停，不是完成。只有后台命令（如开发服务器）时照常提醒，并注明“后台还有 N 个任务在运行”。
- 被自动批准、或你在 6 秒内就答复了的授权请求。
- `claude -p` 脚本、Agent SDK 程序等非交互调用。
- 同一轮、同一通道重复触发：只提醒一次。
- 图形界面里关闭了“Claude Code 提醒”：钩子保留，但静默跳过。

在桌面版和 VS Code 中，选择题和计划确认也会走授权通道。脚本会读取本机会话记录，把它们归到同一个问题上，不会先提醒“等待你回答”、6 秒后再提醒一次“等待你授权”。

## 用图形界面部署（推荐）

打开 [CodexPhoneNotifier.exe](https://github.com/xinmiao0303/codex-phone-notifier/releases/latest/download/CodexPhoneNotifier.exe)，勾选 **Claude Code 提醒**，选择渠道后点击 **一键部署 / 更新**。不需要审查钩子，**新开一个 Claude Code 会话即生效**。终端版第一次进入某个文件夹时，需要先接受“信任此文件夹”的提示，钩子才会运行。

之后取消勾选 **Claude Code 提醒** 并保存，就能暂停它；Codex 提醒和渠道设置不受影响。完整说明见 [图形界面教程](desktop.md)。

## 用命令行部署

在项目目录打开 PowerShell：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\claude-code\install.ps1
```

安装器会：

1. 把发送脚本和配置放到 `%USERPROFILE%\.claude\phone-notifier\`（设置过 `CLAUDE_CONFIG_DIR` 时使用对应目录）。
2. 在 `~/.claude/settings.json` 的 `hooks` 中登记本工具的钩子，保留其他所有设置和其他工具的钩子；修改前自动备份。
3. 如果本机已经装过 Codex 提醒，默认沿用它的通道、ntfy 主题和本机加密的微信 Token（复制一份，仍只能在当前 Windows 用户下解密），手机无需重新订阅。标题使用 Claude Code 自己的中文标题。

钩子以 exec 形式直接启动 `powershell.exe`，并设置 `async: true` 在后台运行，不会拖慢 Claude，也不会因为发送失败而阻止任何操作。终端里可以输入 `/hooks` 查看登记情况。

| 参数 | 作用 |
| --- | --- |
| `-NoImport` | 不沿用 Codex 提醒的设置，生成新的随机 ntfy 主题 |
| `-Topic` / `-Server` | 指定 ntfy 主题或服务器 |
| `-NoInputReminder` | 不提醒选择题、计划确认和 MCP 输入表单 |
| `-NoApprovalReminder` | 不提醒工具授权 |
| `-NoErrorReminder` | 不提醒 API 错误中断 |
| `-IdleReminder` | 增加“回复完约 60 秒仍在等你”的提醒 |
| `-ForceConfig` | 重新生成配置（默认保留已有配置） |
| `-SendTest` | 安装后立即发一条测试通知 |

### 连接微信

已经从 Codex 提醒沿用了 Token 的，不需要这一步。否则先按 [微信教程](wechat.md) 完成 PushPlus 实名认证和 ClawBot 绑定激活，再双击 `claude-code\connect-wechat.cmd`，在本机密码框里粘贴 Token。

```powershell
# 只用微信，不用 ntfy
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\claude-code\enable-wechat.ps1 -Gui -OnlyWechat

# 直接复制 Codex 提醒保存的加密 Token
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\claude-code\enable-wechat.ps1 -FromCodex

# 关闭微信，保留 ntfy 和加密 Token
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\claude-code\enable-wechat.ps1 -Disable
```

> 微信 ClawBot 每收到十条推送、以及至少每二十四小时，要主动给机器人发一句话。Codex 和 Claude Code 同时开微信时推送会更多，请留意。

### 单独测试

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\claude-code\send-test.ps1 -Channel ntfy
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\claude-code\send-test.ps1 -Channel wechat
```

测试成功只说明发送通道可用。还需要新开会话，用真实任务、一道选择题和一次授权请求验证自动提醒。

## 设置

配置文件：`%USERPROFILE%\.claude\phone-notifier\config.json`。用图形界面保存时，渠道、服务器和主题会和 Codex 提醒保持一致。

| 设置 | 作用 |
| --- | --- |
| `enabled` | `false` 时暂停 Claude Code 提醒（图形界面的开关），钩子保留 |
| `channels` | `["ntfy"]`、`["wechat"]`、`["ntfy", "wechat"]`，或 `[]` 暂停全部 |
| `title` / `inputTitle` / `planTitle` / `approvalTitle` / `errorTitle` / `idleTitle` / `testTitle` | 各类提醒的标题，可用占位符 |
| `body` / `inputBody` / `planBody` / `approvalBody` / `errorBody` / `idleBody` / `testBody` | 各类提醒的正文，可用占位符；留空用默认 |
| `server` / `topic` / `authorization` | 仅 ntfy：服务器、主题和服务器认证 |
| `priority` / `tags` / `inputTags` / `click` | 仅 ntfy：优先级、图标和点击链接 |
| `showProject` | `true` 时正文增加一行“项目：文件夹名”，同时开多个会话时便于区分；默认 `false` |
| `notifyWhilePaused` | `true` 时，后台子代理或定时唤醒还在等待时也报完成；默认 `false` |
| `includeHeadless` | `true` 时，`claude -p` 和 SDK 调用也提醒；默认 `false` |

标题和正文推荐在软件的 **提醒内容** 页修改，支持 `{电脑}`、`{时间}`、`{项目}`、`{原因}`、`{后台}` 占位符并能实时预览，规则见 [图形界面教程](desktop.md#修改提醒内容)。有自定义正文时 `showProject` 不再生效，需要项目名请在正文里写 `{项目}`。

修改配置后，下一次事件立即使用新设置，无需重启。[claude-code/config.example.json](../claude-code/config.example.json) 是可公开的示例。

## 卸载

图形界面的 **一键卸载** 会同时卸载 Codex 与 Claude Code 两边。只卸载 Claude Code：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\claude-code\uninstall.ps1
```

只移除本工具的钩子、脚本、配置和加密 Token，保留其他工具的钩子、Claude Code 设置、聊天记录和备份。加 `-KeepConfig` 保留配置和 Token。备份位于 `phone-notifier\backups\`。

## 收不到提醒时

```powershell
Get-Content "$HOME\.claude\phone-notifier\notifier.log" -Tail 20
```

| 日志 | 表示什么 |
| --- | --- |
| `sent/事件` | 已发布到 ntfy 服务，仍要检查手机是否收到 |
| `queued/事件/wechat` | PushPlus 接受了请求，还不代表手机收到 |
| `input-hook-start` / `plan-hook-start` / `approval-hook-start` | 提问、计划或授权钩子已触发 |
| `skip/事件: reminders-off` | 图形界面里关闭了 Claude Code 提醒 |
| `skip/done: background-agents=N` / `scheduled-wakeups=N` | Claude 之后会自动继续，暂不报完成 |
| `skip/approval: likely-same-question` | 这次授权就是刚提醒过的选择题，跳过 |
| `skip/事件: headless-session` / `unattended-session` | 脚本或无人值守会话，不提醒 |
| `skip/事件/通道: duplicate-or-busy` | 同一事件已发送或正在发送 |
| `error/事件/通道: …` | 发送失败、限速或暂停 |

日志不记录令牌、主题、会话内容。如果日志里完全没有新记录：确认是新开的会话、`settings.json` 里没有 `disableAllHooks: true`，终端版还要确认已信任当前文件夹。

基于 Claude Code 2.1.304 的 hooks 文档实现（`async`、exec 形式的 `args`、`StopFailure`、`Stop` 的 `background_tasks` / `session_crons` 字段、桌面版的 `permission_prompt` 通知都需要较新的版本）。
