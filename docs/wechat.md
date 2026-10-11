# 微信聊天通知使用教程（PushPlus ClawBot）

推荐使用[图形配置软件](desktop.md)完成电脑端安装、开关和保存设置。本页继续介绍手机端准备、渠道限制，以及可选的命令行操作。

[返回项目首页](../README.md) · [想用 ntfy？看 ntfy 教程](ntfy.md)

**这份教程只讲微信聊天通知。** 本项目通过 PushPlus 的 ClawBot，把提醒发到你自己的微信机器人聊天里。只用微信时，不需要安装 ntfy App，也不用订阅 ntfy 主题。

~~~text
Codex → 电脑上的通知脚本 → PushPlus → 微信 ClawBot 聊天 → 小米手环
~~~

## 先完成电脑基础安装

按[首页的电脑基础安装](../README.md#电脑基础安装两种方式都先做这一步)下载项目并运行 `install.ps1`。它安装两种方式共用的脚本和 Codex 钩子。

安装器显示的“服务器”和“订阅主题”用于 ntfy。只用微信时，可以略过手机 ntfy 订阅，继续下面的连接。

## 1. 登录 PushPlus，绑定微信机器人

1. 打开 [PushPlus 官网](https://www.pushplus.plus/)，用微信登录并完成实名认证。
2. 在[个人中心](https://www.pushplus.plus/uc.html)进入 **渠道配置 → 微信 ClawBot → 立即绑定**，用手机微信扫码确认。
3. 在微信里主动给机器人发一句话，再在网站点击 **我已发送**，确认状态显示 **已激活**。

不需要安装 OpenClaw，也不用给 Codex 增加机器人聊天程序；PushPlus 负责转发提醒。

**每收到十条推送，要主动给机器人发一句话；至少每二十四小时也要主动对话一次。一个微信号只能绑定一个 ClawBot。** 不保持互动时，后续提醒可能无法送达。[PushPlus ClawBot 官方说明](https://www.pushplus.plus/doc/channel/clawbot.html)

## 2. 复制 Token，在电脑窗口保存

在 PushPlus 的“发送消息”页面找到上方 **用户 Token**，点击“一键复制”。

- 已经有用户 Token，就不用再新增“消息 Token”。消息 Token 也可使用。
- 填的是用户 Token 或消息 Token，**不是开放接口 AccessKey，也不是 ntfy 的主题**。
- 网页下方的“试一试”只用于网站手动发消息，不会替电脑保存密钥。网页发送渠道的选择也不会改变本工具的设置。
- 不要把 Token 发到聊天、Issue 或 GitHub，也不要写进命令参数。

按你希望接收的方式，选择下面一个操作，不必连续运行两次。

### 只用微信，不用 ntfy 接收

在项目目录打开 PowerShell，运行：

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\enable-wechat.ps1 -Gui -OnlyWechat
~~~

把 Token 粘贴到“连接 Codex 微信提醒”密码框，点击 **保存并测试**。这会把自动提醒设为 `["wechat"]`，之后只走微信。

### 微信和 ntfy 都保留

在项目目录双击 **connect-wechat.cmd**，或者运行：

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\enable-wechat.ps1 -Gui
~~~

在同一个密码框填写 Token，点击 **保存并测试**。默认启用 `["ntfy", "wechat"]`，原来的 ntfy 主题和标题会保留。想在手机收到 ntfy，还需按[ntfy 教程](ntfy.md)订阅它。

### 密钥保存到哪里？

Token 通过 Windows DPAPI 加密，保存到 Codex 目录的 `pushplus-token.dpapi`。默认位置是 `%USERPROFILE%\.codex\pushplus-token.dpapi`；设置过 `CODEX_HOME` 时使用那个目录。

加密文件只适用于这台电脑的当前 Windows 用户，换电脑或用户要重新填写。JSON、控制台、日志不输出明文密钥。不要把密钥文件和本机配置上传到仓库。

连接微信不改变已经信任的钩子命令，下次事件即可读取设置。首次安装仍需回到首页完成钩子审查和完整重启。

## 3. 分别确认手机和手环收到

点击“保存并测试”前，退出机器人聊天页面，把微信放到后台并锁屏。手机和手环保持蓝牙连接。

电脑显示“微信 ClawBot 聊天推送请求已提交”，只表示 PushPlus 接受请求，**不代表手机或手环已经收到**。先检查机器人聊天里的 **Codex 通知测试**，再检查手环是否振动或显示消息。

需要再发一条，只测微信：

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\send-test.ps1 -Channel wechat
~~~

这次测试不发送 ntfy，也不改变自动提醒通道。

### iPhone + 小米手环 9

1. 在 iPhone 允许微信显示锁屏通知，检查专注模式是否拦截消息。
2. 在微信里检查机器人聊天的消息通知设置，确保没有关闭提醒。
3. 在小米运动健康的应用通知设置中开启 **微信**，检查手环勿扰模式。
4. 退出聊天页面，把手机锁屏，发送上面的微信测试。
5. **手机和手环都实际收到以后**，再关闭小米运动健康里的 **其他**。需要的电话、信息等提醒可照常保留。

这样可以用手环的“微信”开关接收 Codex 提醒。微信里的其他聊天通知仍可能转发到手环，不能只挑 Codex 的消息。

2026-10-11 已实际验证：iPhone 和小米手环 9 都收到 ClawBot 聊天消息。其他手机和手环组合请按同样步骤自行确认。

然后回到[首页的钩子审查与重启步骤](../README.md#3-审查并信任-codex-钩子)，验证 Codex 完成和弹出问题时的自动提醒。

## 4. 暂停 ntfy，只保留微信

打开共用配置 `ntfy-codex.json`，只把现有 `channels` 字段改为：

~~~json
"channels": ["wechat"]
~~~

保留文件里的其他内容和逗号。这个片段不是完整配置文件。更改后下次自动提醒即生效；原来的 ntfy 主题仍保留，想恢复时可改为 `["ntfy", "wechat"]`。

这里的 `wechat` 表示本工具的微信通道，发送时自动使用 ClawBot，不需要填写额外的微信渠道字段。

`server`、`topic`、`priority`、`tags`、`click`、`authorization` 都属于 ntfy，不用于微信。微信消息显示和点击行为由微信处理。`title`、`inputTitle`、`testTitle` 是两种方式共用的标题。

## 关闭微信，回到 ntfy

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\enable-wechat.ps1 -Disable
~~~

自动提醒回到 ntfy，本机加密密钥保留。手机需已经订阅正确 ntfy 主题；如果想手环继续接收 ntfy，还需恢复小米运动健康中的“其他”。

这只关闭微信，不卸载整个工具。完整卸载及删除密钥的方法见[首页](../README.md#设置更新和卸载)。

## 微信或手环收不到时检查什么？

### 微信本身没收到

- 电脑是否报错，是否已经生成加密密钥文件并启用 `wechat`。
- PushPlus 是否完成实名，Token 是否有效，ClawBot 是否已经扫码绑定并显示“已激活”。
- 是否在十条推送后、二十四小时内主动给机器人发过消息。
- 微信能看到新消息、锁屏却没有提醒时，检查 iPhone 通知权限、专注模式和聊天通知设置。
- 可以在 PushPlus 网站查看投递状态。用网页“试一试”排查时，选择 **微信 ClawBot**，它只决定那次网页测试。

### 微信收到，手环没有

- 先确认手机锁屏时有通知弹出，而不只是打开微信后看到聊天消息。
- 检查蓝牙连接、小米运动健康中的“微信”开关，以及手环勿扰模式。
- 测试时退出聊天界面并锁屏，再发送一次微信测试。

### 日志报错或被跳过

PushPlus 的实名要求和额度以[官方说明](https://www.pushplus.plus/doc/guide/use.html)为准。本工具保守限制为每分钟最多五次微信请求；达到限制时跳过微信，不自动补发。已启用的 ntfy 仍会继续尝试。

| 记录或返回码 | 意思 | 怎么处理 |
| --- | --- | --- |
| queued/事件/wechat，channel=clawbot | 请求被接受 | 检查手机和手环，不能仅凭它断定送达 |
| 905 | 未实名认证 | 在 PushPlus 完成实名后再测试 |
| 903 | Token 无效 | 复制正确 Token，重新运行连接窗口 |
| 900 | 账号受限 | 当天暂停微信请求，次日再尝试；查看官方账号限制说明 |
| rate-limit | 本机一分钟内尝试次数过多 | 等下一分钟再手动测试，不会自动补发 |

修复账号或密钥问题后，可重新运行连接脚本更新密钥与本机发送状态。只用微信的用户记得保留 `-OnlyWechat`；普通连接默认重新启用双通道。

每条消息只发送给密钥所属用户，不填写好友或群组参数。[PushPlus 消息接口说明](https://www.pushplus.plus/doc/guide/api.html)
