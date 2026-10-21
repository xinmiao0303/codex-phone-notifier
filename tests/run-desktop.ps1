#requires -Version 5.1
[CmdletBinding()]
param([switch]$SkipExecutable)
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
. (Join-Path $repository 'scripts\common.ps1')
. (Join-Path $repository 'scripts\claude-common.ps1')
$backend = Join-Path $repository 'desktop\desktop-backend.ps1'
$workspace = Join-Path ([IO.Path]::GetTempPath()) ('codex-desktop-test-' + [guid]::NewGuid().ToString('N'))
$directory = Join-Path $workspace '中文 用户目录'
$claudeDirectory = Join-Path $workspace '中文 用户目录\.claude'
$configPath = Join-Path $directory 'ntfy-codex.json'
$hooksPath = Join-Path $directory 'hooks.json'
$tokenPath = Join-Path $directory 'pushplus-token.dpapi'
$senderPath = Join-Path $directory 'scripts\codex-ntfy-notify.ps1'
$claude = Get-ClaudeNotifierPaths $claudeDirectory
$script:checks = 0
function Assert-DesktopCheck([bool]$Condition, [string]$Message) { if (-not $Condition) { throw ('图形功能验证失败：' + $Message) }; $script:checks++ }
function Invoke-DesktopRequest([string]$Action, [object]$Settings = $null, [string]$Channel = '', [bool]$KeepConfig = $false, [string]$CodexDirectory = $directory, [string]$ClaudeHome = $claudeDirectory) {
    # 测试必须同时指定两个目录，绝不读取或修改真实的 .codex 与 .claude。
    $request = [pscustomobject]@{ action=$Action; directory=$CodexDirectory; claudeDirectory=$ClaudeHome; settings=$Settings; channel=$Channel; keepConfig=$KeepConfig }
    # 模拟匿名标准输入中的 JSON，避免被后端清空的密钥影响测试的原始对象。
    $copy = $request | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $output = & $backend -RequestObject $copy
    return ($output | ConvertFrom-Json)
}
function Get-ClaudeOwnedStops { $document = Read-NotifierJson $claude.settings; if ($null -eq $document.PSObject.Properties['hooks']) { return 0 }; return @(@($document.hooks.Stop) | ForEach-Object { @($_.hooks) } | Where-Object { Test-ClaudeNotifierHandler $_ $claude.script }).Count }
try {
    $status = Invoke-DesktopRequest 'status'
    Assert-DesktopCheck ($status.ok -and -not $status.data.installed -and -not [IO.Directory]::Exists($directory)) '打开界面读取状态，不自动安装或生成真实配置'
    Assert-DesktopCheck (-not $status.data.codexEnabled -and -not $status.data.claudeEnabled) '没有检测到工具时两个开关默认关闭'
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $foreign = [pscustomobject]@{ command='powershell.exe -Command "Write-Output other"'; type='command' }
    Write-NotifierJson $hooksPath ([pscustomobject]@{ hooks=[pscustomobject]@{ Stop=@([pscustomobject]@{ hooks=@($foreign) }) } })
    [IO.File]::WriteAllText((Join-Path $directory 'config.toml'), 'keep = true')
    $status = Invoke-DesktopRequest 'status'
    Assert-DesktopCheck ($status.data.codexEnabled -and -not $status.data.claudeEnabled) '检测到 Codex 目录时默认开启 Codex 提醒'
    $desired = [pscustomobject]@{ codexEnabled=$true; claudeEnabled=$false; ntfyEnabled=$false; wechatEnabled=$true; server='https://ntfy.sh'; topic='desktop-test-topic'; token='fake-desktop-secret-not-an-account' }
    $installed = Invoke-DesktopRequest 'install' $desired
    Assert-DesktopCheck ($installed.ok -and $installed.data.installed -and $installed.data.wechatEnabled -and -not $installed.data.ntfyEnabled) '界面安装只启用用户选择的微信'
    Assert-DesktopCheck ($installed.data.codexInstalled -and -not $installed.data.claudeInstalled -and -not [IO.Directory]::Exists($claude.root)) '关闭的 Claude Code 不会被部署'
    Assert-DesktopCheck ($installed.data.hasToken -and -not ($installed | ConvertTo-Json -Depth 12).Contains($desired.token)) '界面状态只返回已保存标记，不返回 Token'
    $secure = [IO.File]::ReadAllText($tokenPath) | ConvertTo-SecureString
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { Assert-DesktopCheck ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) -eq $desired.token) '图形后端保存的密钥与原发送脚本加密格式兼容' }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer); $secure.Dispose() }
    $settings = Read-NotifierJson $configPath
    Set-NotifierProperty $settings 'customField' ([pscustomobject]@{ keep='existing value' })
    Set-NotifierProperty $settings 'authorization' 'fake-private-authorization'
    Write-NotifierJson $configPath $settings
    $hooksHash = (Get-FileHash -LiteralPath $hooksPath).Hash
    $keyHash = (Get-FileHash -LiteralPath $tokenPath).Hash
    $desired.token = ''; $desired.ntfyEnabled = $true; $desired.wechatEnabled = $false
    $saved = Invoke-DesktopRequest 'save' $desired
    $settings = Read-NotifierJson $configPath
    Assert-DesktopCheck ($saved.ok -and $saved.data.ntfyEnabled -and -not $saved.data.wechatEnabled -and $settings.customField.keep -eq 'existing value') '界面开关单独控制渠道，保留额外配置'
    Assert-DesktopCheck ((Get-FileHash -LiteralPath $hooksPath).Hash -eq $hooksHash -and (Get-FileHash -LiteralPath $tokenPath).Hash -eq $keyHash) '留空密钥不会覆盖原 Token，保存不更改钩子'
    Assert-DesktopCheck (-not ($saved | ConvertTo-Json -Depth 12).Contains('fake-private-authorization')) '界面不返回 ntfy 认证凭据'

    # 打开 Claude Code 开关：自动部署，沿用同一套渠道、主题和加密 Token，不改动 Codex 钩子。
    $desired.claudeEnabled = $true
    $withClaude = Invoke-DesktopRequest 'save' $desired
    $claudeSettings = Read-NotifierJson $claude.config
    Assert-DesktopCheck ($withClaude.ok -and $withClaude.data.claudeInstalled -and $withClaude.data.claudeEnabled -and (Get-ClaudeOwnedStops) -eq 1) '打开开关即部署 Claude Code 提醒'
    Assert-DesktopCheck ((@($claudeSettings.channels) -join ',') -eq 'ntfy' -and $claudeSettings.topic -eq 'desktop-test-topic' -and $claudeSettings.title -eq 'Claude Code 任务已完成') 'Claude Code 使用同一套渠道和主题，标题保持自己的'
    Assert-DesktopCheck ([IO.File]::ReadAllText($claude.token) -eq [IO.File]::ReadAllText($tokenPath)) '已有的加密 Token 同步给 Claude Code'
    Assert-DesktopCheck ((Get-FileHash -LiteralPath $hooksPath).Hash -eq $hooksHash) '部署 Claude Code 不改动 Codex 钩子'
    $claudeHooksHash = (Get-FileHash -LiteralPath $claude.settings).Hash
    $desired.codexEnabled = $false
    $codexOff = Invoke-DesktopRequest 'save' $desired
    Assert-DesktopCheck ($codexOff.ok -and $codexOff.data.codexInstalled -and -not $codexOff.data.codexEnabled -and $codexOff.data.claudeEnabled) '可以单独关闭 Codex 提醒'
    Assert-DesktopCheck ((Get-FileHash -LiteralPath $hooksPath).Hash -eq $hooksHash -and (Get-FileHash -LiteralPath $claude.settings).Hash -eq $claudeHooksHash) '开关只改配置，不改任何钩子'
    $global:DesktopTestRequests = @()
    function Invoke-RestMethod { param($Method,$Uri,$Headers,$Body,$ContentType,$TimeoutSec); $global:DesktopTestRequests += $Uri; return [pscustomobject]@{ id='desktop-test'; event='message'; code=200; data='test-receipt' } }
    & $senderPath -Event input -ConfigPath $configPath *> $null
    Assert-DesktopCheck ($global:DesktopTestRequests.Count -eq 0 -and [IO.File]::ReadAllText((Join-Path $directory 'ntfy-codex.log')) -match 'skip/input: reminders-off') '关闭 Codex 提醒后，Codex 钩子静默跳过'
    $tested = Invoke-DesktopRequest 'test' $desired 'ntfy'
    Assert-DesktopCheck ($tested.ok -and $global:DesktopTestRequests.Count -eq 1 -and [IO.File]::ReadAllText($claude.log) -match 'sent/test') 'Codex 关闭时，测试改由 Claude Code 发送一条'
    $desired.claudeEnabled = $false
    $claudeOff = Invoke-DesktopRequest 'save' $desired
    & $claude.script -ConfigPath $claude.config -HookInput ([pscustomobject]@{ hook_event_name='Stop'; session_id='desktop'; prompt_id='p1' }) *> $null
    Assert-DesktopCheck ($claudeOff.ok -and -not $claudeOff.data.claudeEnabled -and $claudeOff.data.claudeInstalled -and $global:DesktopTestRequests.Count -eq 1) '可以单独关闭 Claude Code 提醒'
    $desired.codexEnabled = $true; $desired.claudeEnabled = $true
    $bothOn = Invoke-DesktopRequest 'save' $desired
    Assert-DesktopCheck ($bothOn.ok -and $bothOn.data.codexEnabled -and $bothOn.data.claudeEnabled) '两个提醒可以同时开启'

    # 提醒内容：界面读取默认值、保存自定义内容（测试内容两边共用）、拒绝无效内容、发送预览。
    $content = $bothOn.data.content
    Assert-DesktopCheck (@($content.shared).Count -eq 1 -and @($content.shared)[0].defaultTitle -eq '手机提醒测试' -and @($content.codex).Count -eq 3 -and @($content.claude).Count -eq 6) '界面拿到通用测试、Codex 三类和 Claude Code 六类提醒'
    Assert-DesktopCheck (@($content.codex)[0].defaultBody -match '\{电脑\}' -and @(@($content.claude) | Where-Object { $_.event -eq 'error' })[0].placeholders -contains '原因') '默认正文和占位符来自发送脚本'
    $desired | Add-Member -NotePropertyName content -NotePropertyValue ([pscustomobject]@{ shared=[pscustomobject]@{ testTitle='界面测试标题'; testBody='' }; codex=[pscustomobject]@{ inputBody="自定义输入`r`n在 {电脑}" }; claude=[pscustomobject]@{ title=''; planTitle='计划好了 · {项目}' } })
    $edited = Invoke-DesktopRequest 'save' $desired
    $codexSettings = Read-NotifierJson $configPath; $claudeSettings = Read-NotifierJson $claude.config
    Assert-DesktopCheck ($edited.ok -and $codexSettings.testTitle -eq '界面测试标题' -and $claudeSettings.testTitle -eq '界面测试标题') '通用测试内容同时写入两边'
    Assert-DesktopCheck ($codexSettings.inputBody -eq "自定义输入`n在 {电脑}" -and $null -eq $claudeSettings.PSObject.Properties['inputBody'] -and $claudeSettings.planTitle -eq '计划好了 · {项目}') '各自的内容只写入对应工具'
    Assert-DesktopCheck ($null -eq $claudeSettings.PSObject.Properties['title'] -and @(@($edited.data.content.claude) | Where-Object { $_.event -eq 'done' })[0].title -eq '') '留空表示恢复默认，删除该键'
    $hash = (Get-FileHash -LiteralPath $configPath).Hash
    $desired.content.claude.planTitle = "两行`n标题"
    $badTitle = Invoke-DesktopRequest 'save' $desired
    $desired.content.claude.planTitle = '计划好了 · {项目}'
    $desired.content.codex.inputBody = 'x' * 1001
    $badBody = Invoke-DesktopRequest 'save' $desired
    $desired.content.codex.inputBody = "自定义输入`r`n在 {电脑}"
    Assert-DesktopCheck (-not $badTitle.ok -and -not $badBody.ok -and (Get-FileHash -LiteralPath $configPath).Hash -eq $hash) '多行标题和过长正文在写文件前被拒绝'
    $global:DesktopTestRequests = @()
    function Invoke-RestMethod { param($Method,$Uri,$Headers,$Body,$ContentType,$TimeoutSec); $global:DesktopTestRequests += ([Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json); return [pscustomobject]@{ id='desktop-preview'; event='message' } }
    $request = [pscustomobject]@{ action='preview'; tool='shared'; event='test'; directory=$directory; claudeDirectory=$claudeDirectory; settings=$desired } | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $sharedPreview = (& $backend -RequestObject $request) | ConvertFrom-Json
    $request.tool = 'claude'; $request.event = 'plan'
    $claudePreview = (& $backend -RequestObject $request) | ConvertFrom-Json
    $request.tool = 'codex'; $request.event = 'consent'
    $codexPreview = (& $backend -RequestObject $request) | ConvertFrom-Json
    $titles = @($global:DesktopTestRequests | ForEach-Object { $_.title })
    Assert-DesktopCheck ($sharedPreview.ok -and $claudePreview.ok -and $codexPreview.ok -and $titles.Count -eq 3) '三种预览各发一条'
    Assert-DesktopCheck ($titles[0] -eq '预览 · 界面测试标题' -and $titles[1] -eq '预览 · 计划好了 · 示例项目' -and $titles[2] -eq '预览 · Codex 等待你授权') '预览使用刚保存的内容和示例值'
    $request.tool = 'shared'; $request.event = 'done'
    $mismatch = (& $backend -RequestObject $request) | ConvertFrom-Json
    Assert-DesktopCheck (-not $mismatch.ok -and $global:DesktopTestRequests.Count -eq 3) '不认识的预览请求被拒绝，不发送'
    $desired.content = [pscustomobject]@{ shared=[pscustomobject]@{ testTitle='' }; codex=[pscustomobject]@{ inputBody='' }; claude=[pscustomobject]@{ planTitle='' } }
    $restored = Invoke-DesktopRequest 'save' $desired
    $codexSettings = Read-NotifierJson $configPath; $claudeSettings = Read-NotifierJson $claude.config
    Assert-DesktopCheck ($restored.ok -and $null -eq $codexSettings.PSObject.Properties['testTitle'] -and $null -eq $codexSettings.PSObject.Properties['inputBody'] -and $null -eq $claudeSettings.PSObject.Properties['planTitle']) '全部恢复默认后配置里不留自定义键'
    $desired.PSObject.Properties.Remove('content')
    Remove-Item Function:\Invoke-RestMethod

    $desired.ntfyEnabled = $false
    $paused = Invoke-DesktopRequest 'save' $desired
    $global:DesktopTestRequests = @()
    function Invoke-RestMethod { param($Method,$Uri,$Headers,$Body,$ContentType,$TimeoutSec); $global:DesktopTestRequests += $Uri; return [pscustomobject]@{ code=200; data='test-receipt' } }
    & $senderPath -Event input -ConfigPath $configPath *> $null
    & $claude.script -ConfigPath $claude.config -HookInput ([pscustomobject]@{ hook_event_name='Stop'; session_id='paused'; prompt_id='p1' }) *> $null
    Assert-DesktopCheck ($paused.ok -and $global:DesktopTestRequests.Count -eq 0 -and [IO.File]::Exists($tokenPath) -and [IO.File]::Exists($claude.token)) '两个渠道都关闭时两边都不发送，配置与 Token 保留'
    $strictPaused = $false
    try { & $senderPath -Event test -ConfigPath $configPath -Strict *> $null } catch { $strictPaused = $_.Exception.Message -match '所有通知渠道已关闭' }
    Assert-DesktopCheck $strictPaused '全部暂停时手动测试明确提示渠道已关闭'
    $hash = (Get-FileHash -LiteralPath $configPath).Hash
    $claudeHash = (Get-FileHash -LiteralPath $claude.config).Hash
    $desired.server = 'https://user:password@example.com'
    $invalid = Invoke-DesktopRequest 'save' $desired
    Assert-DesktopCheck (-not $invalid.ok -and (Get-FileHash -LiteralPath $configPath).Hash -eq $hash -and (Get-FileHash -LiteralPath $claude.config).Hash -eq $claudeHash) '无效服务器在写文件前被拒绝'
    $desired.server = 'https://ntfy.sh'; $desired.wechatEnabled = $true
    $disabledTest = Invoke-DesktopRequest 'test' $desired 'ntfy'
    Assert-DesktopCheck (-not $disabledTest.ok -and $global:DesktopTestRequests.Count -eq 0) '关闭的渠道不能被界面测试意外发送'
    function Invoke-RestMethod { throw 'fake transport error' }
    $failedTest = Invoke-DesktopRequest 'test' $desired 'wechat'
    Assert-DesktopCheck (-not $failedTest.ok -and $failedTest.data.wechatEnabled -and $failedTest.data.hasToken) '测试发送失败后，界面仍能拿到已经保存的状态'
    Remove-Item Function:\Invoke-RestMethod
    $removedNtfy = Invoke-DesktopRequest 'remove-ntfy'
    $settings = Read-NotifierJson $configPath
    $claudeSettings = Read-NotifierJson $claude.config
    Assert-DesktopCheck ($removedNtfy.ok -and $removedNtfy.data.wechatEnabled -and $null -eq $settings.PSObject.Properties['topic'] -and $null -eq $claudeSettings.PSObject.Properties['topic'] -and [IO.File]::Exists($tokenPath)) '独立移除 ntfy 同时作用于两边，不影响微信密钥'
    $removedWechat = Invoke-DesktopRequest 'remove-wechat'
    Assert-DesktopCheck ($removedWechat.ok -and -not $removedWechat.data.wechatEnabled -and -not [IO.File]::Exists($tokenPath) -and -not [IO.File]::Exists($claude.token) -and (Get-FileHash -LiteralPath $hooksPath).Hash -eq $hooksHash) '独立移除微信删除两边 Token，不删除共用钩子'
    $missingToken = Invoke-DesktopRequest 'save' $desired
    Assert-DesktopCheck (-not $missingToken.ok) '没有密钥时不能开启微信'
    $uninstalled = Invoke-DesktopRequest 'uninstall' $null '' $true
    $hooks = Read-NotifierJson $hooksPath
    Assert-DesktopCheck ($uninstalled.ok -and -not $uninstalled.data.installed -and [IO.File]::Exists($configPath) -and @($hooks.hooks.Stop.hooks | Where-Object { $_.command -eq $foreign.command }).Count -eq 1) '卸载可保留配置，不删除其他工具的钩子'
    Assert-DesktopCheck (-not $uninstalled.data.claudeInstalled -and (Get-ClaudeOwnedStops) -eq 0 -and [IO.File]::Exists($claude.config) -and -not [IO.File]::Exists($claude.script)) '一键卸载同时移除 Claude Code 钩子，可保留配置'
    Assert-DesktopCheck ([IO.File]::ReadAllText((Join-Path $directory 'config.toml')) -eq 'keep = true') '所有图形操作保留 config.toml'
    $uninstalled = Invoke-DesktopRequest 'uninstall'
    Assert-DesktopCheck ($uninstalled.ok -and -not [IO.File]::Exists($configPath) -and -not [IO.File]::Exists($claude.config)) '卸载支持同时移除两边的配置'
    [IO.File]::WriteAllText($hooksPath, '{ invalid')
    $desired.wechatEnabled = $false
    $broken = Invoke-DesktopRequest 'install' $desired
    Assert-DesktopCheck (-not $broken.ok -and [IO.File]::ReadAllText($hooksPath) -eq '{ invalid' -and -not [IO.File]::Exists($senderPath) -and -not [IO.File]::Exists($claude.script)) '坏 JSON 阻止安装，不覆盖用户原文件'

    # 只用 Claude Code 的电脑：一键部署不创建 .codex，测试由 Claude Code 发送。
    $onlyCodex = Join-Path $workspace '没有 Codex'
    $onlyClaude = Join-Path $workspace '只有 Claude\.claude'
    [IO.Directory]::CreateDirectory($onlyClaude) | Out-Null
    $fresh = Invoke-DesktopRequest 'status' $null '' $false $onlyCodex $onlyClaude
    Assert-DesktopCheck ($fresh.ok -and -not $fresh.data.codexEnabled -and $fresh.data.claudeEnabled) '只检测到 Claude Code 时只默认开启它'
    $none = [pscustomobject]@{ codexEnabled=$false; claudeEnabled=$false; ntfyEnabled=$true; wechatEnabled=$false; server='https://ntfy.sh'; topic='claude-only-topic'; token='' }
    $refused = Invoke-DesktopRequest 'install' $none '' $false $onlyCodex $onlyClaude
    Assert-DesktopCheck (-not $refused.ok -and -not [IO.Directory]::Exists($onlyCodex)) '两个提醒都关闭时拒绝部署'
    $none.claudeEnabled = $true
    $claudeOnly = Invoke-DesktopRequest 'install' $none '' $false $onlyCodex $onlyClaude
    Assert-DesktopCheck ($claudeOnly.ok -and $claudeOnly.data.claudeInstalled -and -not $claudeOnly.data.codexInstalled -and -not [IO.Directory]::Exists($onlyCodex)) '只部署 Claude Code，不创建 Codex 目录'
    Assert-DesktopCheck (-not $claudeOnly.restartRequired -and $claudeOnly.message -match 'Claude Code') '只部署 Claude Code 时不要求重启 Codex'
    $global:DesktopTestRequests = @()
    function Invoke-RestMethod { param($Method,$Uri,$Headers,$Body,$ContentType,$TimeoutSec); $global:DesktopTestRequests += [Text.Encoding]::UTF8.GetString($Body); return [pscustomobject]@{ id='desktop-test'; event='message' } }
    $claudeTest = Invoke-DesktopRequest 'test' $none 'ntfy' $false $onlyCodex $onlyClaude
    Assert-DesktopCheck ($claudeTest.ok -and $global:DesktopTestRequests.Count -eq 1 -and $global:DesktopTestRequests[0] -match '手机提醒测试' -and [IO.File]::ReadAllText((Get-ClaudeNotifierPaths $onlyClaude).log) -match 'sent/test') '只装 Claude Code 时测试由它发送，使用通用测试标题'
    Remove-Item Function:\Invoke-RestMethod
    $gone = Invoke-DesktopRequest 'uninstall' $null '' $false $onlyCodex $onlyClaude
    Assert-DesktopCheck ($gone.ok -and -not $gone.data.installed -and -not [IO.Directory]::Exists($onlyCodex)) '一键卸载不会创建没用过的 Codex 目录'

    if (-not $SkipExecutable) {
        $executable = Join-Path $repository 'dist\CodexPhoneNotifier.exe'
        if (-not [IO.File]::Exists($executable)) { throw '请先运行 build-desktop.ps1，再测试真实 EXE。' }
        $resultFile = Join-Path $workspace 'exe-result.json'
        $process = Start-Process -FilePath $executable -ArgumentList @('--self-check', ('"' + $resultFile + '"')) -WindowStyle Hidden -PassThru -Wait
        $verified = Read-NotifierJson $resultFile
        Assert-DesktopCheck ($process.ExitCode -eq 0 -and $verified.ok -and $verified.checks -eq 10) '真实 EXE 通过匿名标准输入完成十项集成检查'
    }
    Write-Host ('PASS: desktop {0} checks; PowerShell {1}' -f $script:checks,$PSVersionTable.PSVersion)
} finally {
    $target = [IO.Path]::GetFullPath($workspace)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($target.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($target).StartsWith('codex-desktop-test-')) {
        if ([IO.Directory]::Exists($target)) { Remove-Item -LiteralPath $target -Recurse -Force }
    } else { throw '拒绝清理不属于本测试的目录。' }
}
