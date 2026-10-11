# ntfy 通知使用教程

[返回项目首页](../README.md) · [想用微信？看微信教程](wechat.md)

**这份教程只讲 ntfy 通知。** 消息会发到手机的 ntfy App；不需要 PushPlus 账号，不用填写微信 Token。

## 先完成电脑基础安装

按[首页的电脑基础安装](../README.md#电脑基础安装两种方式都先做这一步)下载项目并运行 `install.ps1`。安装器会显示 **服务器地址**和**订阅主题**，先保留窗口。

新安装默认使用 ntfy。如果你之前改成了只用微信，需要把共用配置中的 `channels` 改为 `["ntfy"]`；想两种都用则改为 `["ntfy", "wechat"]`，微信还需要按自己的教程连接。

## 1. 手机安装 ntfy，订阅对应主题

安装 [ntfy 手机 App](https://ntfy.sh/app)，允许它显示通知。添加订阅时填写：

- **服务器**：安装器显示的服务器，默认是 `https://ntfy.sh`。
- **主题**：安装器显示的主题，完整复制，手机与电脑必须一致。

主题可以理解成“消息收件箱的地址”。安装器会生成随机主题，不需要在网上找一个热门主题。别人知道主题后也可能订阅或发送消息；不要公开真实主题，也不要往公共主题里发送隐私内容。需要访问控制时使用支持认证的服务器，参考 [ntfy 官方说明](https://docs.ntfy.sh/publish/#authentication)。

## 2. 只测试 ntfy

在电脑的项目目录执行：

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\send-test.ps1 -Channel ntfy
~~~

去手机的 **ntfy App** 检查 **Codex 通知测试**。这条命令不会发到微信，也不会改变自动提醒通道。

然后回到[首页的钩子审查与重启步骤](../README.md#3-审查并信任-codex-钩子)，验证真正的完成提醒和等待回答提醒。只测发送成功，不能证明 Codex 已经自动触发。

## 3. 点击通知不想打开网页

共用配置 `ntfy-codex.json` 中，ntfy 的 `click` 默认是空字符串：

~~~json
"click": ""
~~~

空字符串表示本工具不为新消息设置网页跳转链接。点击消息时由 ntfy 手机 App 处理。修改只影响之后的新通知，之前的消息仍保留原有链接。

这个设置只影响 ntfy，不改变微信消息的点击行为。

## ntfy 的设置

默认配置在 `%USERPROFILE%\.codex\ntfy-codex.json`；如果设置了 `CODEX_HOME`，使用对应目录。

| 配置项 | 用途 |
| --- | --- |
| server | ntfy 服务器地址 |
| topic | 电脑发送、手机订阅共同使用的主题 |
| authorization | 服务器需要认证时填写，例如 Bearer 后接访问令牌 |
| priority | 通知优先级，默认 default |
| tags / inputTags | 完成与输入提醒的图标标签 |
| click | 新通知的点击链接；默认空字符串 |

`title`、`inputTitle`、`testTitle` 是共用标题，修改后也会影响已启用的微信通道。上表中的 ntfy 专用字段不控制微信。

### 使用自己的服务器或主题

第一次安装时可以指定：

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Server 'https://ntfy.example.com' -Topic 'my-random-topic'
~~~

已经安装时，重复运行会保留已有配置。也可以打开现有 JSON，只修改 `server` 或 `topic`。换主题后，手机也要订阅新主题，测试通过后再移除旧订阅。

主题支持 1 至 64 个英文字母、数字、短横线或下划线。

安装器的 `-ForceConfig` 会重新写入**所有默认通知设置，包括 channels**。只想改一个主题时不要用它，以免把微信或自定义标题也重置。

## ntfy 和小米手环

本次测试的 iPhone + 小米手环 9，在小米运动健康中需要打开“其他”才能转发 ntfy，其他未单列的 App 通知也可能一起出现。

如果你希望关闭“其他”、通过单独的“微信”开关接收 Codex 提醒，改用[微信教程](wechat.md)。两种通道可以同时启用，手机 ntfy 仍可正常使用。

## ntfy 收不到时检查什么？

1. 检查单独测试命令是否报错。
2. 手机与电脑的服务器、主题是否完全一致。
3. ntfy 是否被允许显示通知，iPhone 的专注模式是否屏蔽提醒。
4. 电脑和手机能否访问服务器；服务器要求认证时，认证是否正确。
5. 手动测试能收到、自动提醒收不到时，按[首页排查钩子](../README.md#收不到提醒时先看哪一部分)。

日志中的 `sent/test`、`sent/done`、`sent/input` 属于 ntfy，表示消息已发布到服务端。微信会使用 `queued/事件/wechat`，不要拿 ntfy 的发送记录判断微信是否成功。

Android 可用 ntfy 客户端订阅，但本项目尚未做 Android 实机验证。Apple Watch 取决于 iPhone 的通知镜像设置，也未单独验证。
