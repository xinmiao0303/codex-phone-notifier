#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
. (Join-Path $repository 'scripts\common.ps1')
$script:checks = 0
function Assert-Check {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('验证失败：' + $Message) }
    $script:checks++
}
# 所有安装都使用独立临时目录，绝不操作测试者真正的 .codex。
$workspace = Join-Path ([IO.Path]::GetTempPath()) ('codex phone 测试-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($workspace) | Out-Null
$homeUnderTest = Join-Path $workspace '用户 设置'
$installer = Join-Path $repository 'install.ps1'
$uninstaller = Join-Path $repository 'uninstall.ps1'
$notifySource = Join-Path $repository 'scripts\notify.ps1'
$config = Join-Path $homeUnderTest 'ntfy-codex.json'
$hookFile = Join-Path $homeUnderTest 'hooks.json'
$installedScript = Join-Path $homeUnderTest 'scripts\codex-ntfy-notify.ps1'
try {
    & $installer -CodexHome $homeUnderTest *> $null
    $settings = Read-NotifierJson $config
    Assert-Check ($settings.topic -match '^codex-[a-f0-9]{24}$') '首次安装生成随机主题'
    Assert-Check ($settings.title -eq 'Codex 任务已完成' -and $settings.inputTitle -eq 'Codex 等待你回答') '默认中文标题'
    Assert-Check ($settings.click -eq '') '默认没有网页跳转'
    $bytes = [IO.File]::ReadAllBytes($hookFile)
    Assert-Check (-not ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'hooks.json 不能带 BOM'
    $bytes = [IO.File]::ReadAllBytes($installedScript)
    Assert-Check ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) '中文 ps1 兼容 PowerShell 5'

    # 让本工具和其他工具共享同一组，验证更新不能误删邻居。
    $seed = Read-NotifierJson $hookFile
    $owned = @($seed.hooks.Stop)[0].hooks[0]
    $foreign = [pscustomobject]@{ type='command'; command='powershell.exe -Command "Write-Output other-hook"' }
    $seed.hooks.Stop = @([pscustomobject]@{ hooks=@($owned, $foreign); marker='keep-me' })
    $seed.hooks.PreToolUse = @([pscustomobject]@{ matcher='^Bash$'; hooks=@($foreign) })
    Write-NotifierJson $hookFile $seed
    $settings.title = '自定义中文标题'
    $settings.priority = 'high'
    Write-NotifierJson $config $settings
    $configHash = (Get-FileHash -LiteralPath $config).Hash
    $toml = Join-Path $homeUnderTest 'config.toml'
    [IO.File]::WriteAllText($toml, 'untouched = true')
    & $installer -CodexHome $homeUnderTest *> $null
    & $installer -CodexHome $homeUnderTest *> $null
    $after = Read-NotifierJson $hookFile
    $ownedStops = @($after.hooks.Stop.hooks | Where-Object { $_.command -like '*-Event done' })
    Assert-Check ($ownedStops.Count -eq 1) '重复安装不重复添加完成钩子'
    $ownedInputs = @($after.hooks.PreToolUse.hooks | Where-Object { $_.command -like '*-Event input' })
    Assert-Check ($ownedInputs.Count -eq 1) '重复安装不重复添加输入钩子'
    Assert-Check (@($after.hooks.Stop.hooks | Where-Object { $_.command -eq $foreign.command }).Count -eq 1) '共享分组中的其他工具被保留'
    Assert-Check ((Get-FileHash -LiteralPath $config).Hash -eq $configHash) '重复安装逐字保留现有配置'
    Assert-Check ([IO.File]::ReadAllText($toml) -eq 'untouched = true') '不修改 config.toml'
    Assert-Check (@(Get-ChildItem -LiteralPath (Join-Path $homeUnderTest 'backups') -Filter hooks.json -File -Recurse).Count -gt 0) '已有配置有备份'
    $pattern = $ownedInputs[0].command
    $matcher = @($after.hooks.PreToolUse | Where-Object { $_.hooks.command -contains $pattern })[0].matcher
    Assert-Check ('request_user_input_async' -match $matcher -and 'functions.request_user_input' -match $matcher) '两种提问工具都匹配'
    Assert-Check ('request_permissions' -notmatch $matcher -and 'exec_command' -notmatch $matcher) '不把审批和普通工具当成问题'

    # 替换 HTTP 命令来检查真实脚本发出的字节，不向公共 ntfy 发测试消息。
    $global:NotifierTestRequests = @()
    function Invoke-RestMethod {
        param($Method, $Uri, $Headers, $Body, $ContentType, $TimeoutSec)
        $decoded = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
        $global:NotifierTestRequests += [pscustomobject]@{ payload=$decoded; uri=$Uri; headers=$Headers; contentType=$ContentType; bytes=$Body }
        return [pscustomobject]@{ id='local-test-id'; event='message' }
    }
    foreach ($event in @('done', 'input', 'test')) { & $notifySource -Event $event -ConfigPath $config -Strict *> $null }
    Assert-Check ($global:NotifierTestRequests.Count -eq 3) '三个通知事件各发送一次'
    Assert-Check ($global:NotifierTestRequests[0].payload.title -eq '自定义中文标题') '支持自定义完成标题'
    Assert-Check ($global:NotifierTestRequests[1].payload.title -eq 'Codex 等待你回答') '输入标题为中文'
    Assert-Check ($global:NotifierTestRequests[2].payload.title -eq 'Codex 通知测试') '测试标题为中文'
    Assert-Check ($global:NotifierTestRequests[1].payload.message -match '等待你选择或回答') 'UTF-8 正文没有乱码'
    Assert-Check ($global:NotifierTestRequests[1].payload.message -match '时间：\d{4}-\d{2}-\d{2} {4}\d{2}:\d{2}:\d{2}$') '通知时间没有时区，日期与时间之间为四个空格'
    Assert-Check ($global:NotifierTestRequests[0].payload.priority -eq 4) '文字优先级映射为 JSON 数字'
    Assert-Check ($null -eq $global:NotifierTestRequests[1].payload.PSObject.Properties['click']) '空 click 不会写进通知'
    Assert-Check ($global:NotifierTestRequests[0].contentType -eq 'application/json; charset=utf-8') '明确使用 UTF-8 JSON'
    & $notifySource -Event startup -ConfigPath $config *> $null
    Assert-Check ($global:NotifierTestRequests.Count -eq 3) '启动事件不发送通知'

    # 发送失败默认不阻塞 hook；手动严格测试必须向调用者报告失败。
    function Invoke-RestMethod { throw [InvalidOperationException]::new('fake transport failure') }
    $quietFailed = $false
    try { & $notifySource -Event input -ConfigPath $config *> $null } catch { $quietFailed = $true }
    Assert-Check (-not $quietFailed) '发送失败不阻塞正常 hook'
    $strictFailed = $false
    try { & $notifySource -Event test -ConfigPath $config -Strict *> $null } catch { $strictFailed = $true }
    Assert-Check $strictFailed '严格测试不能把发送失败当成功'
    Remove-Item Function:\Invoke-RestMethod

    # 微信只用模拟密钥和模拟 HTTP；本机加密存储也必须能正常解密。
    $setupWechat = Join-Path $repository 'enable-wechat.ps1'
    $fakeToken = 'test-token-never-a-real-account'
    $secureToken = ConvertTo-SecureString $fakeToken -AsPlainText -Force
    $hooksHash = (Get-FileHash -LiteralPath $hookFile).Hash
    & $setupWechat -CodexHome $homeUnderTest -Token $secureToken -NoTest *> $null
    $settings = Read-NotifierJson $config
    $tokenFile = Join-Path $homeUnderTest 'pushplus-token.dpapi'
    $stateFile = Join-Path $homeUnderTest 'wechat-send-state.json'
    Assert-Check (@($settings.channels).Count -eq 2 -and $settings.channels -contains 'wechat') '连接微信默认保留 ntfy'
    Assert-Check ((Get-FileHash -LiteralPath $hookFile).Hash -eq $hooksHash) '连接微信不改已信任的钩子命令'
    Assert-Check (-not [IO.File]::ReadAllText($config).Contains($fakeToken) -and -not [IO.File]::ReadAllText($tokenFile).Contains($fakeToken)) '真实配置与密钥文件不保存明文 token'
    Assert-Check ($settings.title -eq '自定义中文标题' -and $settings.priority -eq 'high') '连接微信保留已有标题和设置'
    $wechatConfigHash = (Get-FileHash -LiteralPath $config).Hash
    & $installer -CodexHome $homeUnderTest *> $null
    Assert-Check ((Get-FileHash -LiteralPath $config).Hash -eq $wechatConfigHash -and [IO.File]::Exists($tokenFile)) '安装更新保留微信配置及加密密钥'

    $global:NotifierTestRequests = @()
    $global:NotifierTestFailure = ''
    function Invoke-RestMethod {
        param($Method, $Uri, $Headers, $Body, $ContentType, $TimeoutSec)
        $decoded = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
        $global:NotifierTestRequests += [pscustomobject]@{ payload=$decoded; uri=$Uri; timeout=$TimeoutSec }
        if ($Uri -eq 'https://www.pushplus.plus/send') {
            if ($global:NotifierTestFailure -eq 'wechat') { return [pscustomobject]@{ code=905; msg='not verified'; data=$null } }
            if ($global:NotifierTestFailure -eq 'blocked') { return [pscustomobject]@{ code=900; msg='limited'; data=$null } }
            return [pscustomobject]@{ code=200; data='local-wechat-id' }
        }
        if ($global:NotifierTestFailure -eq 'ntfy') { throw 'fake ntfy failure' }
        return [pscustomobject]@{ id='local-ntfy-id'; event='message' }
    }
    & $notifySource -Event input -ConfigPath $config -Channel wechat -Strict *> $null
    Assert-Check ($global:NotifierTestRequests.Count -eq 1 -and $global:NotifierTestRequests[0].uri -eq 'https://www.pushplus.plus/send') '微信测试仅请求 HTTPS 微信接口'
    $wechatPayload = $global:NotifierTestRequests[0].payload
    Assert-Check ($wechatPayload.token -eq $fakeToken -and $wechatPayload.channel -eq 'wechat' -and $wechatPayload.template -eq 'txt') '本机解密并选择微信纯文本渠道'
    Assert-Check ($wechatPayload.title -eq 'Codex 等待你回答' -and $wechatPayload.content -match '时间：\d{4}-\d{2}-\d{2} {4}\d{2}:\d{2}:\d{2}$') '微信保留中文及时间格式'
    Assert-Check ($null -eq $wechatPayload.PSObject.Properties['topic'] -and $null -eq $wechatPayload.PSObject.Properties['to']) '只发送给自己，不发送群组或好友'
    $log = [IO.File]::ReadAllText((Join-Path $homeUnderTest 'ntfy-codex.log'))
    Assert-Check ($log.Contains('queued/input/wechat') -and -not $log.Contains($fakeToken) -and -not $log.Contains('sent/input/wechat')) '只记请求排队，不把接口接受当成手机送达'

    $global:NotifierTestRequests = @()
    & $notifySource -Event done -ConfigPath $config -Strict *> $null
    Assert-Check ($global:NotifierTestRequests.Count -eq 2 -and $global:NotifierTestRequests[0].timeout -eq 4 -and $global:NotifierTestRequests[1].timeout -eq 4) '双通道分别发送并限制总等待时间'
    $global:NotifierTestFailure = 'ntfy'
    $global:NotifierTestRequests = @()
    $someFailed = $false
    try { & $notifySource -Event test -ConfigPath $config -Strict *> $null } catch { $someFailed = $true }
    Assert-Check ($someFailed -and $global:NotifierTestRequests.Count -eq 2) 'ntfy 失败仍尝试微信，严格测试报告部分失败'
    $global:NotifierTestFailure = 'wechat'
    $global:NotifierTestRequests = @()
    $someFailed = $false
    try { & $notifySource -Event test -ConfigPath $config -Strict *> $null } catch { $someFailed = $true }
    Assert-Check ($someFailed -and $global:NotifierTestRequests.Count -eq 2) '微信实名错误不影响 ntfy，并报告失败'
    $log = [IO.File]::ReadAllText((Join-Path $homeUnderTest 'ntfy-codex.log'))
    Assert-Check ($log.Contains('api_code=905') -and -not $log.Contains($fakeToken)) '日志保留返回码但不包含 token'

    $global:NotifierTestFailure = ''
    $global:NotifierTestRequests = @()
    & $notifySource -Event done -ConfigPath $config -Channel wechat *> $null
    $global:NotifierTestRequests = @()
    & $notifySource -Event done -ConfigPath $config -Channel wechat *> $null
    Assert-Check ($global:NotifierTestRequests.Count -eq 0) '一分钟内达到五次后不再请求微信'
    Remove-Item -LiteralPath $stateFile -Force
    $global:NotifierTestFailure = 'blocked'
    & $notifySource -Event done -ConfigPath $config -Channel wechat *> $null
    $global:NotifierTestRequests = @()
    $global:NotifierTestFailure = ''
    & $notifySource -Event done -ConfigPath $config *> $null
    Assert-Check ($global:NotifierTestRequests.Count -eq 1 -and $global:NotifierTestRequests[0].uri -ne 'https://www.pushplus.plus/send') '900 后暂停当日微信请求，ntfy 继续发送'
    & $setupWechat -CodexHome $homeUnderTest -Token $secureToken -OnlyWechat -NoTest *> $null
    $settings = Read-NotifierJson $config
    Assert-Check (@($settings.channels).Count -eq 1 -and $settings.channels[0] -eq 'wechat' -and -not [IO.File]::Exists($stateFile)) '可切换仅微信并重置发送状态'
    & $setupWechat -CodexHome $homeUnderTest -Disable *> $null
    $settings = Read-NotifierJson $config
    Assert-Check (@($settings.channels).Count -eq 1 -and $settings.channels[0] -eq 'ntfy' -and [IO.File]::Exists($tokenFile)) '关闭微信保留 ntfy 和加密密钥'
    Remove-Item Function:\Invoke-RestMethod

    & $installer -CodexHome $homeUnderTest -NoInputReminder -NoStartupHook *> $null
    $after = Read-NotifierJson $hookFile
    Assert-Check (@($after.hooks.PreToolUse.hooks | Where-Object { $_.command -like '*-Event input' }).Count -eq 0) '可关闭输入提醒'
    Assert-Check (@($after.hooks.PreToolUse.hooks | Where-Object { $_.command -eq $foreign.command }).Count -eq 1) '关闭输入提醒不移除其他 PreToolUse'
    & $uninstaller -CodexHome $homeUnderTest -KeepConfig *> $null
    $after = Read-NotifierJson $hookFile
    Assert-Check ([IO.File]::Exists($config) -and [IO.File]::Exists($tokenFile) -and -not [IO.File]::Exists($installedScript)) '卸载可保留主题配置和加密微信密钥'
    Assert-Check (@($after.hooks.Stop.hooks | Where-Object { $_.command -eq $foreign.command }).Count -eq 1) '卸载保留其他 Stop'
    Assert-Check ([IO.File]::ReadAllText($toml) -eq 'untouched = true') '卸载仍保留 config.toml'
    & $uninstaller -CodexHome $homeUnderTest *> $null
    Assert-Check (-not [IO.File]::Exists($config) -and -not [IO.File]::Exists($tokenFile)) '可再次卸载并移除配置及微信密钥'

    $invalidHome = Join-Path $workspace 'invalid'
    [IO.Directory]::CreateDirectory($invalidHome) | Out-Null
    $invalidHooks = Join-Path $invalidHome 'hooks.json'
    [IO.File]::WriteAllText($invalidHooks, '{ invalid json')
    $badJsonFailed = $false
    try { & $installer -CodexHome $invalidHome *> $null } catch { $badJsonFailed = $true }
    Assert-Check $badJsonFailed '错误 JSON 会阻止安装'
    Assert-Check ([IO.File]::ReadAllText($invalidHooks) -eq '{ invalid json') '错误 JSON 不被覆盖'
    Assert-Check (-not [IO.File]::Exists((Join-Path $invalidHome 'scripts\codex-ntfy-notify.ps1'))) '失败安装不先覆盖脚本'
    Write-Host ('PASS: {0} checks; PowerShell {1}' -f $script:checks, $PSVersionTable.PSVersion)
} finally {
    # 删除前确认目标在系统临时目录里，且确实是本测试创建的目录。
    $resolved = [IO.Path]::GetFullPath($workspace)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved).StartsWith('codex phone 测试-')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    } else { throw '拒绝清理不属于本测试的目录。' }
}
