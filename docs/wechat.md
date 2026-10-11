# 微信通知使用教程（PushPlus）

[返回项目首页](../README.md) · [想用 ntfy？看 ntfy 教程](ntfy.md)

**这份教程只讲微信通知。** 消息由 PushPlus 发到你自己的微信，不通过 ntfy。只用微信时，不需要安装 ntfy App，也不用在手机订阅 ntfy 主题。

~~~text
Codex → 电脑上的通知脚本 → PushPlus → 手机微信 → 小米手环
~~~

## 先完成电脑基础安装

按[首页的电脑基础安装](../README.md#电脑基础安装两种方式都先做这一步)下载项目并运行 `install.ps1`。它安装两种方式共用的脚本和 Codex 钩子。

安装器显示的“服务器”和“订阅主题”用于 ntfy。只用微信时，可以略过手机 ntfy 订阅，接着做下面的连接。

## 1. 准备 PushPlus

打开 [PushPlus 官网](https://www.pushplus.plus/)，用微信登录，按网站提示关注推送公众号并完成实名认证。

在“发送消息”页面找到上方的 **用户 Token**，点击“一键复制”。

- 已经有用户 Token，就不用再新增“消息 Token”。消息 Token 也可使用。
- 填的是用户 Token 或消息 Token，**不是开放接口 AccessKey，也不是 ntfy 的主题**。
- 网页下方的“试一试”只用于网站手动发消息，不会把密钥保存到你的电脑通知程序。
- 不要把 Token 发到聊天、Issue 或 GitHub，也不要写进命令参数。

## 2. 在电脑密钥窗口填写

按你希望接收的方式，选择一个操作。

### 微信和 ntfy 都保留

在项目目录双击 **connect-wechat.cmd**。把 Token 粘贴到“连接 Codex 微信提醒”密码框，点击“保存并测试”。

也可以在项目目录运行：

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\enable-wechat.ps1 -Gui
~~~

默认启用 `["ntfy", "wechat"]`。原来的 ntfy 主题和标题会保留；想在手机收到 ntfy，还需按[ntfy 教程](ntfy.md)订阅它。

### 只用微信，不用 ntfy 接收

在项目目录运行：

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\enable-wechat.ps1 -Gui -OnlyWechat
~~~

在同一个密码框粘贴 Token，点击“保存并测试”。这会把自动提醒设为 `["wechat"]`，之后自动通知只走微信，不要求你安装 ntfy App。

**两个操作选一个就可以，不必连续运行两次。**

### 密钥保存到哪里？

Token 通过 Windows DPAPI 加密，保存到 Codex 目录的 `pushplus-token.dpapi`。默认位置是 `%USERPROFILE%\.codex\pushplus-token.dpapi`；设置过 `CODEX_HOME` 时使用那个目录。

加密文件只适用于这台电脑的当前 Windows 用户，换电脑或用户要重新填写。JSON、控制台、日志不输出明文密钥。不要把密钥文件和本机配置上传到仓库。

连接微信不改变已经信任的钩子命令，下次事件即可读取设置。首次安装仍需回到首页完成钩子审查和完整重启。

## 3. 分别确认手机和手环收到

点击“保存并测试”前，把手机微信放到后台并锁屏，避免停留在公众号聊天界面。手机和手环保持蓝牙连接。

电脑显示“微信推送请求已提交”，只表示 PushPlus 接受请求，**不代表手机或手环已经收到**。先检查微信的 **Codex 通知测试**，再检查手环是否振动或显示消息。

需要再发一条，只测微信：

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\send-test.ps1 -Channel wechat
~~~

这条测试不发送 ntfy，也不改变自动提醒通道。

### iPhone + 小米手环 9

1. 在 iPhone 允许微信显示通知，检查专注模式是否拦截消息。
2. 在微信里检查 PushPlus 消息的通知设置。本次实机测试将其设为“重要通知”后，手环收到了消息，显示为“服务通知”。
3. 在小米运动健康的应用通知设置中开启 **微信**。
4. 手机微信放到后台并锁屏，重新发送上面的微信测试。
5. **手机和手环都实际收到以后**，再关闭小米运动健康里的 **其他**。需要的电话、信息等提醒可照常保留。

这解决了 ntfy 需要“其他”开关的问题。微信里的其他聊天通知仍可能转发到手环，不能只挑 Codex 的消息。

2026-10-11 已实际验证：iPhone、微信、PushPlus、小米运动健康、小米手环 9 收到测试通知。其他手机和手环组合请按同样步骤自行确认。

然后回到[首页的钩子审查与重启步骤](../README.md#3-审查并信任-codex-钩子)，验证 Codex 完成和弹出问题时的自动提醒。

## 4. 以后切换接收方式

打开共用配置 `ntfy-codex.json`，只修改 `channels` 字段，保留其他内容和逗号：

~~~json
"channels": ["wechat"]
~~~

上面是只用微信；想同时使用 ntfy 和微信，改为 `["ntfy", "wechat"]`。它只是现有配置中的一个字段，不是完整配置文件。

`server`、`topic`、`priority`、`tags`、`click`、`authorization` 都属于 ntfy，不用于微信。微信消息显示和点击行为由微信处理，不能用 ntfy 的 `click` 修改。

`title`、`inputTitle`、`testTitle` 则是共用标题，两种方式都会读取。

## 关闭微信，回到 ntfy

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\enable-wechat.ps1 -Disable
~~~

自动提醒回到 ntfy，本机加密密钥保留。手机需已经订阅正确 ntfy 主题；如果想手环继续接收 ntfy，还需恢复小米运动健康中的“其他”。

这只关闭微信，不卸载整个工具。完整卸载及删除密钥的方法见[首页](../README.md#设置更新和卸载)。

## 微信或手环收不到时检查什么？

### 微信本身没收到

- 电脑是否报错，是否已经生成加密密钥文件并启用 `wechat`。
- 是否关注了正确的 PushPlus 公众号、完成实名认证，Token 是否有效。
- 微信能看到新消息、锁屏却没有提醒时，检查 iPhone 通知权限、专注模式和微信里的消息通知设置。
- 可以在 PushPlus 网站查看该消息的投递状态；网站的“试一试”也能帮助判断是微信通道问题还是电脑配置问题。

### 微信收到，手环没有

- 先确认手机在锁屏时有通知弹出，而不只是打开微信后看到聊天消息。
- 检查手机与手环蓝牙连接、小米运动健康中的“微信”开关，以及手环勿扰模式。
- 检查微信内是否开启“重要通知”，测试时退出聊天界面并锁屏再试。
- 在确认手环收到以前，先保留“其他”，避免丢失现有 ntfy 手环提醒。

### 日志报错或被跳过

[PushPlus 官方额度说明](https://www.pushplus.plus/doc/guide/use.html)要求实名认证；普通实名账户的微信通道每天最多 200 次请求、每分钟最多 5 次，具体以官方当前规则为准。

本工具每分钟最多尝试 5 次。达到限制时跳过微信，不自动补发；已启用的 ntfy 仍继续尝试。

| 记录或返回码 | 意思 | 怎么处理 |
| --- | --- | --- |
| queued/事件/wechat | 请求被接受 | 检查手机和手环，不能仅凭它断定送达 |
| 905 | 未实名认证 | 在 PushPlus 完成实名后再测试 |
| 903 | Token 无效 | 复制正确 Token，重新运行连接窗口 |
| 900 | 账号受限 | 当天暂停微信请求，次日再尝试；查看官方账号限制说明 |
| rate-limit | 本机一分钟内尝试次数过多 | 等下一分钟再手动测试，不会自动补发 |

修复账号或密钥问题后，可重新运行连接脚本更新密钥与本机发送状态。只用微信的用户记得保留 `-OnlyWechat`；普通连接默认重新启用双通道。

每条消息只发送给密钥所属用户，不填写好友或群组参数。[PushPlus 消息接口说明](https://www.pushplus.plus/doc/guide/api.html)
