# Codex 与 Claude Code 手机提醒

**Codex 或 Claude Code 做完这一轮任务，或者正在等你选择、回答、确认计划或允许操作时，让手机提醒你。**

适合在 Windows 电脑上使用 Codex、Claude Code 的人。你可以离开电脑去做其他事情，收到提醒后再回来继续。这个工具负责通知，不会替你回答问题或批准操作。

两个工具共用同一套通知渠道（ntfy、微信），在图形界面里可以**分别开启或关闭 Codex 提醒和 Claude Code 提醒**，一键部署、一键卸载。只用其中一个工具也可以。Claude Code 的详细说明见 [Claude Code 提醒教程](docs/claude-code.md)。

## 先选一种通知方式

本项目支持 **ntfy 通知**和**微信通知**，两种方式分别设置，也可以同时使用。

| | ntfy 通知 | 微信通知（PushPlus） |
| --- | --- | --- |
| 消息发到哪里 | 手机的 ntfy App | 手机微信里的 ClawBot 机器人聊天 |
| 手机需要准备什么 | 安装 ntfy，订阅主题 | 用微信登录 PushPlus、实名认证、绑定并激活 ClawBot；不用安装 ntfy |
| 电脑需要填写什么 | ntfy 服务器和订阅主题；安装器会生成随机主题 | PushPlus 的用户 Token 或消息 Token，在本机密码框填写 |
| iPhone 配小米手环 9 | 本次设备需要开启“其他”才能转发 ntfy | 可以通过“微信”开关转发，已实际收到聊天消息 |
| 详细教程 | [ntfy 通知：订阅、测试和设置](docs/ntfy.md) | [微信通知：连接、测试和手环设置](docs/wechat.md) |

**ntfy 的“订阅主题”和 PushPlus 的“Token”是两回事，不能互相填写。** 小米手环上只想关闭“其他”、保留“微信”的用户，请看微信教程。

安装器第一次安装时默认只启用 ntfy。连接微信时默认保留 ntfy；也可以选择只用微信。具体选择方法见下方“自动提醒走哪条通道”。

## 推荐使用图形界面

[下载 Windows 软件 CodexPhoneNotifier.exe](https://github.com/xinmiao0303/codex-phone-notifier/releases/latest/download/CodexPhoneNotifier.exe) → 双击打开 → 打开需要的 **Codex 提醒** / **Claude Code 提醒** → 选择渠道 → 点击 **一键部署 / 更新**。

窗口里可以分别开关 Codex 与 Claude Code 提醒，在 **提醒内容** 页自己编辑每一类提醒的标题和正文（支持 `{电脑}`、`{时间}`、`{项目}` 等占位符，并可发送预览），开启或关闭 ntfy 和微信、复制订阅主题、保存加密 Token、分别测试、移除一个渠道，或一键卸载两边的通知工具。关闭某个工具的提醒只暂停它，钩子保留，不用重新信任或重启；两个渠道都关闭时暂停全部提醒，配置保留。保存后可以关闭窗口，不用一直开着。

手机订阅、微信扫码实名和 Codex 钩子信任仍需自己完成，界面会提供指引；Claude Code 不需要审查钩子，新开会话即生效。[图形界面完整教程与截图](docs/desktop.md)

## 会收到什么？

下面的标题和内容，两种通知方式都适用。

| 什么时候 | 默认通知标题 | 你可以做什么 |
| --- | --- | --- |
| Codex 完成这一轮回复 | Codex 任务已完成 | 回来查看结果 |
| Codex 弹出选择题或纯文字输入框 | Codex 等待你回答 | 回来选择或输入答案 |
| 插件弹出原生应用访问确认框，仍在等待答复 | Codex 等待你授权 | 回来检查并选择是否允许 |
| 你主动发送测试 | 手机提醒测试（与 Claude Code 共用） | 检查接收是否正常 |

标题和正文默认使用中文。正文只有提醒、电脑名称和时间，不包含聊天内容、代码或问题正文。时间示例：`2026-10-11    08:30:00`，日期和时刻之间四个空格，不显示 `+08:00`。

完成提醒只面向交互式主聊天：脚本读取本机会话记录，确认这一轮真正结束后才发送。同一轮、同一通道只提醒一次；后台内部任务、子任务、思考过程及被中断的轮次不会单独报完成。完成一轮回复不等于整个项目做完。启动 Codex 不发手机提醒。

选择题和纯文字输入框都能提醒；如果只是回复正文里写了一句问话、没有调用提问工具，则不会产生独立的等待输入事件。

**0.6.0 使用独立的原生授权连接。** 安装时为已配置的 Computer Use / `node_repl` 加入一个本机 MCP 转发程序。插件发出原生交互请求后，等待一秒仍未答复才发提醒；快速自动答复、已经选择、取消调用或退出时会停止尚未发出的提醒。同一请求只发一次。它原样传递插件请求和用户答复，不代替你允许或拒绝，也不记录弹窗正文。

普通 `PermissionRequest`、命令提权及网络自动审批继续不提醒。当前只接入本地 `node_repl` 的 MCP 原生交互，不覆盖 Windows UAC、系统权限窗口或其他无关软件的弹窗。原生连接需要完整退出所有 Codex 窗口后重新打开；实际手机送达还需按下文测试。安装器通过 Codex 现有的 `CODEX_NODE_REPL_PATH` 用户环境设置登记转发程序，避免启动时配置被重新生成而失效；卸载时会恢复这个设置。其他自定义运行程序不会被覆盖。

会话记录格式属于 Codex 内部实现，可能随版本变化；遇到无法识别或不能确认结束的记录时，脚本会跳过完成提醒并记录原因，不会猜测任务已经完成。

### Claude Code 会收到什么？

| 什么时候 | 默认通知标题 |
| --- | --- |
| Claude Code 完成这一轮回复 | Claude Code 任务已完成 |
| 弹出选择题，或 MCP 服务弹出输入表单 | Claude Code 等待你回答 |
| 计划模式写好计划，等你批准 | Claude Code 等待你确认计划 |
| 请求使用工具的权限，约 6 秒仍未答复 | Claude Code 等待你授权 |
| 因限流、登录失效、服务繁忙等 API 错误中断 | Claude Code 出错停止 |

桌面版 Code 标签、终端里的 `claude`、VS Code 插件都读取同一份 `~/.claude/settings.json`，部署一次全部生效。后台子代理或定时唤醒还会让 Claude 自动继续时不报完成；你按 Esc 中断、`claude -p` 脚本和被自动批准的操作不提醒；桌面版里选择题同时触发授权通知时只提醒一次。正文同样只有提醒、电脑名称和时间。详见 [Claude Code 提醒教程](docs/claude-code.md)。

## 两种方式分别怎么工作？

~~~text
ntfy 通知：Codex → 本机脚本 → ntfy 服务 → 订阅对应主题的 ntfy App
微信通知：Codex → 本机脚本 → PushPlus → 微信 ClawBot 聊天 → 手环
~~~

微信方式通过 PushPlus 的 ClawBot 发到机器人聊天，不使用 ntfy 的订阅主题。需要先扫码绑定并激活；每收到十条推送，以及至少每二十四小时，要主动给机器人发一句话，详见[微信教程](docs/wechat.md)。两条通道使用同一套 Codex 钩子，不需要装两套钩子。钩子（hook）就是 Codex 在任务结束或弹出问题时，自动运行电脑上的通知脚本。

## 电脑基础安装：两种方式都先做这一步

需要 Windows、支持 hooks 的 Codex，以及 Windows 自带的 PowerShell 5.1 或 PowerShell 7。不需要 Python、Node.js 或管理员权限。电脑和手机需要能够访问所选通知服务。

### 1. 下载并安装电脑端

推荐按[图形界面教程](docs/desktop.md)下载软件，在窗口里完成安装和渠道配置。下面的命令行方式仍可使用。

打开 [本仓库](https://github.com/xinmiao0303/codex-phone-notifier)，点击绿色 **Code → Download ZIP**，解压。

打开 PowerShell，进入项目目录。下面的路径只是例子，请换成你的解压位置：

~~~powershell
cd 'C:\Tools\codex-phone-notifier-main'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
~~~

也可以用 Git 下载，再运行同一条安装命令：

~~~powershell
git clone https://github.com/xinmiao0303/codex-phone-notifier.git
cd .\codex-phone-notifier
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
~~~

安装器显示的“服务器”和“订阅主题”用于 **ntfy**。如果只用微信，不用在手机上订阅这个主题，下一步直接连接微信即可。

`-ExecutionPolicy Bypass` 只作用于这一次启动的 PowerShell 进程，不会永久更改系统执行策略。

### 2. 完成你选的通知方式

- **用 ntfy**：按 [ntfy 教程](docs/ntfy.md)安装手机 App、订阅主题，并单独测试 ntfy。
- **用微信**：按 [微信教程](docs/wechat.md)连接 PushPlus、填写本机密钥，并单独测试微信。教程包含“只用微信”的命令，不要求安装 ntfy App。
- **两种都用**：先订阅 ntfy，再连接微信；分别测试两条通道。

### 3. 审查并信任 Codex 钩子

在项目目录运行：

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\review-hooks.ps1
~~~

这会打开 Codex 的终端界面，不会主动发送模型任务。启动时若提示审查钩子，进入审查界面；也可以输入 **/hooks**。

找到命令指向 **codex-ntfy-notify.ps1** 的本工具钩子，检查后信任：

- **Stop**：在后台确认主轮次真正结束，去重后发送完成提醒。
- **PreToolUse**：仅在弹出选择题或纯文字输入框时提醒。
- **SessionStart**：只登记本地日志。

不要信任不认识的其他工具的钩子。完成后用 Ctrl+C 退出终端里的 Codex，必要时再按一次。

### 4. 完整重启，再测试自动提醒

**关闭所有 Codex 桌面窗口，再重新打开。** 首次安装或修改钩子后，不要跳过这一步。

1. 让 Codex 完成一个简短任务，回复结束后检查 **Codex 任务已完成**。
2. 让 Codex **弹出一道选择题，并先停留在提问阶段**，问题出现时检查 **Codex 等待你回答**。

3. 让 Computer Use 请求访问一个尚未允许的应用。原生“允许 ChatGPT 使用某应用？”弹窗停留超过一秒时，检查手机是否收到一条 **Codex 等待你授权**。普通自动审批不应触发这条通知。

手动发送测试成功，只说明通知通道可用；还需要用真实任务和问题框验证自动触发。已经审查过并重启的用户，仅切换通知通道或修改标题时，无需重新装钩子或重启。

## 自动提醒走哪条通道？

配置默认在 `%USERPROFILE%\.codex\ntfy-codex.json`；设置过 `CODEX_HOME` 时使用对应目录。打开默认配置：

~~~powershell
notepad "$HOME\.codex\ntfy-codex.json"
~~~

这个文件供两种通道共用，文件名沿用 ntfy；**只用微信时也会使用它**。不要因为文件名里有 ntfy，就把它删掉。

只修改现有 JSON 中的 `channels` 字段，保留其他内容和逗号：

| 你想怎么接收 | channels 的值 | 前提 |
| --- | --- | --- |
| 只用 ntfy | `["ntfy"]` | 手机已经订阅对应主题 |
| 只用微信 | `["wechat"]` | 已完成 PushPlus 连接并保存本机密钥 |
| ntfy 和微信都用 | `["ntfy", "wechat"]` | 两种方式都设置完成 |
| 暂停全部 | `[]` | 主题和加密密钥保留 |

旧配置没有 `channels` 时默认 ntfy。双通道会分别尝试发送；一条失败仍会尝试另一条。

### 单独测试，不要混淆结果

~~~powershell
# 只测 ntfy：去手机 ntfy App 检查
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\send-test.ps1 -Channel ntfy

# 只测微信：去手机微信和手环检查
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\send-test.ps1 -Channel wechat
~~~

`-Channel` 只决定这一次测试发到哪里，不改变自动提醒的通道。省略它时，按配置中启用的通道发送测试。

## 设置、更新和卸载

| 设置 | 适用范围 |
| --- | --- |
| title / inputTitle / consentTitle / testTitle | 两种通道的标题，可用占位符 |
| body / inputBody / consentBody / testBody | 两种通道的正文，可用占位符；留空用默认 |
| server / topic / authorization | 仅 ntfy：服务器、主题和服务器认证 |
| priority / tags / inputTags / click | 仅 ntfy：优先级、图标和点击链接 |
| pushplus-token.dpapi | 仅微信：在本机加密的 PushPlus 密钥，不写进 JSON |

[config.example.json](config.example.json) 只是可公开的示例，不是任何人的真实配置。具体设置与限制分别见 [ntfy 教程](docs/ntfy.md)和[微信教程](docs/wechat.md)。

只要完成提醒、不需要等待回答和应用授权提醒：

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -NoInputReminder -NoApprovalReminder
~~~

修改钩子后完整重启 Codex。它不会移除其他工具的提问前钩子。

更新时下载新版本，在新目录再次运行 `install.ps1`。默认保留已有主题、标题、通道和加密微信密钥。已经连接过微信的用户，更新前也要先按微信教程完成 ClawBot 绑定和激活；原密钥可以继续使用。若新增或改变了钩子，审查后完整重启。

完整卸载两种通道：

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
~~~

卸载会备份并移除本工具钩子、脚本、配置、加密微信密钥与微信发送状态，保留其他工具的钩子、config.toml、聊天记录和备份。卸载后完整重启 Codex。

想保留配置和加密密钥，方便以后重装，在命令末尾加 `-KeepConfig`。原文件备份位于 Codex 目录的 **backups/codex-phone-notifier/**。

**只想关闭微信、保留 ntfy**，不要卸载整个工具；按[微信教程的关闭步骤](docs/wechat.md#关闭微信回到-ntfy)操作。

## 收不到提醒时先看哪一部分？

- ntfy App 收不到：看 [ntfy 排查](docs/ntfy.md#ntfy-收不到时检查什么)。
- 微信或手环收不到：看 [微信与手环排查](docs/wechat.md#微信或手环收不到时检查什么)。
- 手动测试能收到、自动提醒收不到：检查钩子是否已信任、是否完整重启、是否真的弹出了问题框。正文里的普通问句不等于提问工具。
- 检查当前工作模式是否支持本地命令钩子；部分云端编排场景不支持，即使工具在本机执行。参考 [Codex hooks 文档](https://learn.chatgpt.com/docs/hooks)。

查看日志：

~~~powershell
Get-Content "$HOME\.codex\ntfy-codex.log" -Tail 20
~~~

| 日志 | 属于哪种通知 | 表示什么 |
| --- | --- | --- |
| sent/test、sent/done、sent/input | ntfy | 消息已发布到 ntfy 服务，仍要检查手机是否收到 |
| queued/事件/wechat | 微信 | PushPlus 接受了请求，还不代表手机或手环收到 |
| input-hook-start | 共用钩子 | 问题框触发了输入提醒 |
| skip/done | 共用钩子 | 后台会话、尚未结束或无法确认，不发送完成提醒 |
| skip/approval: disabled | 共用钩子 | 旧普通审批钩子已静默跳过 |
| queued/consent/wechat、sent/consent | 原生应用授权 | 等待答复的 MCP 交互已提交到对应通知服务 |
| skip/事件/通道: duplicate-or-busy | 对应通道 | 同一事件已发送或正在发送，跳过重复 |
| error/事件/通道 | 对应通道 | 发送失败、限速或暂停 |

日志不记录令牌、主题和聊天正文。提交 Issue 时请说明是 **ntfy 收不到**、**微信收不到**还是**手环收不到**，不要粘贴真实配置或密钥。

## 项目文件和验证

| 文件 | 用途 |
| --- | --- |
| docs/desktop.md | 软件窗口的安装、开关、配置、测试和卸载 |
| desktop/Program.cs / desktop/desktop-backend.ps1 | Windows 图形界面及配置后端 |
| build-desktop.ps1 | 编译便携版 Windows 软件 |
| docs/ntfy.md | ntfy 的手机订阅、测试、设置和排查 |
| docs/wechat.md | 微信的密钥连接、手环设置、限制和排查 |
| install.ps1 / review-hooks.ps1 | 共用的电脑安装和钩子审查 |
| send-test.ps1 | 用 -Channel 单独测试 ntfy 或微信 |
| connect-wechat.cmd / enable-wechat.ps1 | 仅微信：本机密钥填写、连接或关闭微信 |
| uninstall.ps1 | 共用卸载，保留其他工具的配置 |
| scripts/notify.ps1 | 根据 channels 发送对应通知 |
| scripts/common.ps1 | 安装、配置和卸载的共用文件处理 |
| config.example.json | 可公开的配置示例 |
| tests/run.ps1 | 隔离检查，不向真实手机发消息 |
| tests/run-hook-events.ps1 | 主会话结束、后台误报、并发去重及移除授权提醒的回归检查 |
| tests/run-hook-stdin.ps1 | Windows PowerShell 真实标准输入、中文、表情及 BOM 检查 |
| desktop/McpConsentProxy.cs / scripts/mcp-consent.ps1 | 原生授权的 MCP 转发、自动安装和恢复原启动器 |
| tests/run-consent.ps1 | MCP 消息保真、答复取消、重复事件、安装升级和卸载恢复检查 |
| docs/claude-code.md | Claude Code 提醒的触发场景、安装、设置和排查 |
| claude-code/ | Claude Code 的命令行安装、卸载、测试和微信连接脚本 |
| scripts/claude-notify.ps1 / scripts/claude-common.ps1 | 解析 Claude Code 钩子事件并发送；登记和移除 settings.json 中的钩子 |
| tests/run-claude.ps1 | Claude Code 事件归类、去重、暂停、导入 Codex 设置、真实子进程和卸载检查 |

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run.ps1
pwsh.exe -NoProfile -File .\tests\run.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-hook-events.ps1
pwsh.exe -NoProfile -File .\tests\run-hook-events.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-hook-stdin.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-consent.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-claude.ps1
pwsh.exe -NoProfile -File .\tests\run-claude.ps1
~~~

测试无需第三方框架，使用临时目录、测试密钥和模拟 HTTP，不读取真实订阅、不修改真正的 .codex 或 .claude。Windows PowerShell 5.1 与 PowerShell 7.6 均通过基础配置 58 项、事件回归 50 项、真实标准输入 10 项和 Claude Code 101 项检查；GitHub Actions 执行同一套检查。

图形界面后端另通过 49 项隔离检查，真实 EXE 通过 10 项集成检查，覆盖两个工具的部署、分别开关、共用渠道与加密 Token、提醒内容的编辑与预览、全部暂停和一键卸载。图形界面已渲染检查。

2026-10-11 实机验证：ntfy 在 iPhone 上收到完成与输入提醒；微信通过 PushPlus ClawBot 发到机器人聊天，iPhone 和小米手环 9 都实际收到聊天消息。Codex 测试版本为 0.162.0-alpha.17.2。Android 和 Apple Watch 未做本项目的实机验证。

## 许可证与致谢

本项目使用 [MIT 许可证](LICENSE)，可以使用、修改和分享。

使用场景受到 [isclin123/codex-watch-notifier](https://github.com/isclin123/codex-watch-notifier) 启发。本仓库是重新编写的 Windows 中文通知实现，未复制原仓库脚本；见 [NOTICE.md](NOTICE.md)。

两种服务的官方资料：[ntfy 发布说明](https://docs.ntfy.sh/publish/)、[PushPlus 消息接口](https://www.pushplus.plus/doc/guide/api.html)。
