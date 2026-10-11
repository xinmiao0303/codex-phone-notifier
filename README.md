# Codex 手机提醒

**Codex 做完任务，或者正在等你选择、回答时，让手机提醒你。**

这个小工具适合在 Windows 电脑上使用 Codex 的人。你可以离开电脑去做其他事情，不必一直盯着聊天窗口。

收到提醒后，回到电脑继续使用 Codex。这个工具负责通知，不会替你回答问题或批准操作。

## 会收到什么？

| 什么时候 | 手机通知标题 | 你可以做什么 |
| --- | --- | --- |
| Codex 完成这一轮任务 | Codex 任务已完成 | 回来查看结果 |
| Codex 弹出选择题或问题框 | Codex 等待你回答 | 回来选择或输入答案 |
| 你主动发送测试 | Codex 通知测试 | 检查手机订阅是否正确 |

标题和正文默认使用中文。正文只包含提醒、电脑名称和时间，不包含聊天内容、代码或问题正文。通知时间不显示时区偏移，日期和时刻之间用四个空格，例如：`2026-10-11    08:30:00`。

默认不附带网页跳转链接；点击通知时由 ntfy 手机应用处理。启动 Codex 不会发送手机提醒。

**普通文字提问、权限审批、后台命令单独完成，不属于这个版本的输入提醒范围。** “任务完成”指一轮 Codex 回复结束，不是保证整个项目已经做完。

## 它是怎么工作的？

~~~text
Codex 发生事件 → 电脑上的通知脚本 → ntfy 服务 → 你订阅这个主题的手机
~~~

- **Codex 钩子（hook）**：Codex 在特定时刻自动运行一条命令。本工具用它识别任务结束和弹出问题。
- **ntfy**：把电脑发送的消息推送给手机的服务。
- **订阅主题（topic）**：可以理解成你的消息收件箱。电脑发送和手机订阅必须使用同一个名字。

安装时会自动生成随机主题，不需要自己想名字。公共 ntfy 服务上的随机主题不是带密码的私人频道，请不要把真实主题、访问令牌或本地配置上传到仓库。

## 使用前需要什么？

- Windows，以及支持 hooks 的 Codex。
- Windows 自带的 PowerShell 5.1；也支持 PowerShell 7。不需要 Python、Node.js 或管理员权限。
- 手机安装 [ntfy](https://ntfy.sh/app)，允许它显示通知。
- 电脑和手机能够访问你选择的 ntfy 服务器。默认使用 https://ntfy.sh 。

这里的安装脚本面向 Windows。iPhone 已实际验证；Android 可以使用 ntfy 客户端订阅，但本项目没有做 Android 实机验证。Apple Watch 的显示和震动取决于 iPhone 的通知镜像设置，项目没有单独验证手表。

## 从零开始安装

### 1. 下载并解压

打开 [本仓库](https://github.com/xinmiao0303/codex-phone-notifier)，点击绿色 **Code → Download ZIP**，解压。

如果已经安装 Git，也可以运行：

~~~powershell
git clone https://github.com/xinmiao0303/codex-phone-notifier.git
cd .\codex-phone-notifier
~~~

### 2. 在电脑上安装

打开 PowerShell，进入刚才解压的项目目录。例如：

~~~powershell
cd 'C:\Tools\codex-phone-notifier-main'
~~~

这个路径只是例子，请换成你自己的解压位置。然后执行：

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
~~~

安装器会输出 **服务器地址**和**订阅主题**。保留这个窗口，下一步需要照着填写。

这里的 Bypass 只作用于这一次启动的 PowerShell 进程，不会永久更改系统的执行策略。

### 3. 在手机上订阅

打开 ntfy，添加一个订阅：

- **服务器**：填写安装器显示的服务器，默认是 https://ntfy.sh 。
- **主题**：复制安装器显示的主题，必须完全一致。

允许 ntfy 发通知。先保持手机订阅不变；不要只在手机上改主题，否则电脑还会向旧主题发送。

### 4. 信任本工具的钩子

安装文件并不代表 Codex 会立即执行它。Codex 要求先审查并信任新钩子。

在项目目录运行：

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\review-hooks.ps1
~~~

这会打开 Codex 的终端界面，不会主动发送模型任务。

如果启动时显示钩子需要审查，进入审查界面；也可以输入 **/hooks**。找到命令指向 **codex-ntfy-notify.ps1** 的本工具钩子，检查后再信任：

- **Stop**：发送完成提醒。
- **PreToolUse**：仅在调用选择题/提问工具时发送输入提醒。
- **SessionStart**：启动登记，只写本地日志。

不要直接信任你不认识的其他工具的钩子。完成后退出终端里的 Codex，可以按 Ctrl+C；必要时再按一次。

### 5. 完整重启 Codex

**关闭所有 Codex 桌面窗口，再重新打开。**

这一步不要跳过。安装或改变钩子后，已经运行的会话可能仍使用旧配置。仅关闭审查终端不能代替重启桌面应用。

### 6. 测试

先测试手机发送通道：

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\send-test.ps1
~~~

手机应收到 **Codex 通知测试**。

再测试真正的自动提醒：

1. 让 Codex 完成一个简短任务，回复结束后应收到 **Codex 任务已完成**。
2. 让 Codex **弹出一道选择题，并先停留在提问阶段**。问题出现时应收到 **Codex 等待你回答**。
3. 区分这两个时间点：问题弹出时的提醒，和回答结束后的提醒。

手动测试成功只说明发送通道可用，不能代替对钩子自动触发的验证。

## 常用设置

配置默认在你的用户目录下：

~~~text
%USERPROFILE%\.codex\ntfy-codex.json
~~~

如果设置了 CODEX_HOME，则使用那个目录。可以在 PowerShell 中打开默认配置：

~~~powershell
notepad "$HOME\.codex\ntfy-codex.json"
~~~

[config.example.json](config.example.json) 只是示例，不是任何人的真实订阅。

| 配置项 | 用途 |
| --- | --- |
| server | ntfy 服务器 |
| topic | 手机与电脑共同使用的主题 |
| title | 完成提醒标题 |
| inputTitle | 等待回答提醒标题 |
| testTitle | 测试提醒标题 |
| priority | 提醒优先级，默认 default |
| tags / inputTags | ntfy 的图标标签 |
| click | 点击时打开的链接；留空则不设置网页链接 |
| authorization | 可选，用于需要认证的自建/受保护服务器，例如 Bearer 后接访问令牌 |

修改通知标题后，下次发送就会读取新配置，不需要重新信任钩子。把 click 设为空字符串，只影响之后的新通知；以前的通知仍保留原链接。

### 只要完成提醒

重新运行安装器，关闭输入提醒：

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -NoInputReminder
~~~

然后完整重启 Codex。其他工具的提问前钩子不会被移除。

### 使用自己的服务器或主题

第一次安装时可以指定：

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Server 'https://ntfy.example.com' -Topic 'my-random-topic'
~~~

如果已经有配置，重复安装会保留它。明确需要替换配置时才加 **-ForceConfig**；它会重新写入所有默认通知设置：

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Topic 'another-random-topic' -ForceConfig
~~~

换主题后，手机也要订阅新主题，测试通过后再移除旧订阅。本工具接受 1 至 64 个英文字母、数字、短横线或下划线作为主题名。

### 更新

下载新版本，在新版本目录中再次运行 install.ps1。默认保留已有主题、标题和其他通知设置，不会生成第二套重复钩子。

如果旧配置的标题仍是英文，直接在配置文件中改成中文即可。审查新增或改变的钩子后，完整重启 Codex。

## 没收到通知时怎么办？

### 测试通知都收不到

- 检查电脑是否提示发送失败。
- 手机与电脑的服务器、主题是否完全一致。
- ntfy 是否被允许显示通知；iPhone 的专注模式是否屏蔽了提醒。
- 电脑和手机是否都能访问服务器；自建服务器的认证是否正确。

### 测试能收到，自动提醒收不到

- 是否信任了钩子。
- 是否在安装之后完整退出并重开 Codex。
- Codex 的 hooks 功能是否被配置或管理策略关闭。
- 等待输入测试是否真的弹出了问题框，而不是一段普通文字。
- 当前工作模式是否支持本地命令钩子。官方文档说明部分云端编排场景不支持这类钩子，即使工具在本机执行。

可以查看本地日志：

~~~powershell
Get-Content "$HOME\.codex\ntfy-codex.log" -Tail 20
~~~

- **sent/test**：手动测试已发送。
- **sent/done**：完成提醒已发送。
- **input-hook-start**：输入提醒钩子已被调用。
- **sent/input**：输入提醒已发送。
- **error/事件**：发送失败。

本地日志仅记录事件、时间、错误类型或消息编号，不记录令牌、主题和聊天正文。提交 Issue 前，也请不要粘贴真实配置、主题或访问令牌。

## 如何卸载？

在项目目录执行：

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
~~~

它会移除本工具的三个钩子、通知脚本及订阅配置，保留其他工具的钩子、config.toml、聊天记录和备份。然后完整重启 Codex。

想保留主题配置，方便以后重装：

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -KeepConfig
~~~

安装、更新和卸载前的原文件备份保存在 Codex 目录的 **backups/codex-phone-notifier/** 中。

## 项目文件

| 文件 | 用途 |
| --- | --- |
| install.ps1 | 安装或更新，合并钩子并备份原文件 |
| review-hooks.ps1 | 打开 Codex 自带的钩子审查界面 |
| send-test.ps1 | 发送中文测试通知，失败会报错 |
| uninstall.ps1 | 卸载，保留其他配置 |
| scripts/notify.ps1 | 真正发送通知，安装后可以独立运行 |
| scripts/common.ps1 | 安装/卸载共用的文件处理 |
| config.example.json | 可公开的配置示例 |
| tests/run.ps1 | 在隔离目录中验证安装、更新、发送和卸载 |

中文 .ps1 文件使用 UTF-8 **带 BOM**，兼容 Windows PowerShell 5；写给 Codex 的 JSON 使用 UTF-8 **不带 BOM**，避免解析失败。

## 开发与验证

无需安装第三方测试框架：

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run.ps1
pwsh.exe -NoProfile -File .\tests\run.ps1
~~~

测试使用临时目录和模拟 HTTP，不会读取真实订阅、不向手机发消息，也不会修改真正的 .codex。

测试覆盖中文 UTF-8、重复安装、与其他钩子共存、已有配置保留、发送失败、禁用输入提醒、卸载及错误 JSON。GitHub Actions 同时在 Windows PowerShell 和 PowerShell 7 上执行。

发布前在 Windows PowerShell 5.1 与 PowerShell 7.6 下通过检查；Codex 0.162.0-alpha.17.2 上实际验证了任务完成与选择题提醒。Codex 后续版本的钩子行为可能变化，有问题欢迎提交 Issue。

## 许可证与致谢

本项目使用 [MIT 许可证](LICENSE)，可以使用、修改和分享。

使用场景受到 [isclin123/codex-watch-notifier](https://github.com/isclin123/codex-watch-notifier) 启发。本仓库是重新编写的 Windows 中文通知实现，未复制原仓库脚本；来源说明见 [NOTICE.md](NOTICE.md)。

参考：[Codex 官方 hooks 文档](https://learn.chatgpt.com/docs/hooks)、[ntfy 官方消息发布文档](https://docs.ntfy.sh/publish/)。
