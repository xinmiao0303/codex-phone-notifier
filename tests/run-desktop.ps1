#requires -Version 5.1
[CmdletBinding()]
param([switch]$SkipExecutable)
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
. (Join-Path $repository 'scripts\common.ps1')
$backend = Join-Path $repository 'desktop\desktop-backend.ps1'
$workspace = Join-Path ([IO.Path]::GetTempPath()) ('codex-desktop-test-' + [guid]::NewGuid().ToString('N'))
$directory = Join-Path $workspace '中文 用户目录'
$configPath = Join-Path $directory 'ntfy-codex.json'
$hooksPath = Join-Path $directory 'hooks.json'
$tokenPath = Join-Path $directory 'pushplus-token.dpapi'
$senderPath = Join-Path $directory 'scripts\codex-ntfy-notify.ps1'
$script:checks = 0
function Assert-DesktopCheck([bool]$Condition, [string]$Message) { if (-not $Condition) { throw ('图形功能验证失败：' + $Message) }; $script:checks++ }
function Invoke-DesktopRequest([string]$Action, [object]$Settings = $null, [string]$Channel = '', [bool]$KeepConfig = $false) {
    $request = [pscustomobject]@{ action=$Action; directory=$directory; settings=$Settings; channel=$Channel; keepConfig=$KeepConfig }
    # 模拟匿名标准输入中的 JSON，避免被后端清空的密钥影响测试的原始对象。
    $copy = $request | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $output = & $backend -RequestObject $copy
    return ($output | ConvertFrom-Json)
}
try {
    $status = Invoke-DesktopRequest 'status'
    Assert-DesktopCheck ($status.ok -and -not $status.data.installed -and -not [IO.Directory]::Exists($directory)) '打开界面读取状态，不自动安装或生成真实配置'
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $foreign = [pscustomobject]@{ command='powershell.exe -Command "Write-Output other"'; type='command' }
    Write-NotifierJson $hooksPath ([pscustomobject]@{ hooks=[pscustomobject]@{ Stop=@([pscustomobject]@{ hooks=@($foreign) }) } })
    [IO.File]::WriteAllText((Join-Path $directory 'config.toml'), 'keep = true')
    $desired = [pscustomobject]@{ ntfyEnabled=$false; wechatEnabled=$true; server='https://ntfy.sh'; topic='desktop-test-topic'; token='fake-desktop-secret-not-an-account' }
    $installed = Invoke-DesktopRequest 'install' $desired
    Assert-DesktopCheck ($installed.ok -and $installed.data.installed -and $installed.data.wechatEnabled -and -not $installed.data.ntfyEnabled) '界面安装只启用用户选择的微信'
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
    $desired.ntfyEnabled = $false
    $paused = Invoke-DesktopRequest 'save' $desired
    $global:DesktopTestRequests = @()
    function Invoke-RestMethod { param($Method,$Uri,$Headers,$Body,$ContentType,$TimeoutSec); $global:DesktopTestRequests += $Uri; return [pscustomobject]@{ code=200; data='test-receipt' } }
    & $senderPath -Event input -ConfigPath $configPath *> $null
    Assert-DesktopCheck ($paused.ok -and $global:DesktopTestRequests.Count -eq 0 -and [IO.File]::Exists($tokenPath)) '两个渠道都关闭时不发送，配置与 Token 保留'
    $strictPaused = $false
    try { & $senderPath -Event test -ConfigPath $configPath -Strict *> $null } catch { $strictPaused = $_.Exception.Message -match '所有通知渠道已关闭' }
    Assert-DesktopCheck $strictPaused '全部暂停时手动测试明确提示渠道已关闭'
    $hash = (Get-FileHash -LiteralPath $configPath).Hash
    $desired.server = 'https://user:password@example.com'
    $invalid = Invoke-DesktopRequest 'save' $desired
    Assert-DesktopCheck (-not $invalid.ok -and (Get-FileHash -LiteralPath $configPath).Hash -eq $hash) '无效服务器在写文件前被拒绝'
    $desired.server = 'https://ntfy.sh'; $desired.wechatEnabled = $true
    $disabledTest = Invoke-DesktopRequest 'test' $desired 'ntfy'
    Assert-DesktopCheck (-not $disabledTest.ok -and $global:DesktopTestRequests.Count -eq 0) '关闭的渠道不能被界面测试意外发送'
    function Invoke-RestMethod { throw 'fake transport error' }
    $failedTest = Invoke-DesktopRequest 'test' $desired 'wechat'
    Assert-DesktopCheck (-not $failedTest.ok -and $failedTest.data.wechatEnabled -and $failedTest.data.hasToken) '测试发送失败后，界面仍能拿到已经保存的状态'
    Remove-Item Function:\Invoke-RestMethod
    $removedNtfy = Invoke-DesktopRequest 'remove-ntfy'
    $settings = Read-NotifierJson $configPath
    Assert-DesktopCheck ($removedNtfy.ok -and $removedNtfy.data.wechatEnabled -and $null -eq $settings.PSObject.Properties['topic'] -and [IO.File]::Exists($tokenPath)) '独立移除 ntfy 不影响微信密钥'
    $removedWechat = Invoke-DesktopRequest 'remove-wechat'
    Assert-DesktopCheck ($removedWechat.ok -and -not $removedWechat.data.wechatEnabled -and -not [IO.File]::Exists($tokenPath) -and (Get-FileHash -LiteralPath $hooksPath).Hash -eq $hooksHash) '独立移除微信不删除共用钩子'
    $missingToken = Invoke-DesktopRequest 'save' $desired
    Assert-DesktopCheck (-not $missingToken.ok) '没有密钥时不能开启微信'
    $uninstalled = Invoke-DesktopRequest 'uninstall' $null '' $true
    $hooks = Read-NotifierJson $hooksPath
    Assert-DesktopCheck ($uninstalled.ok -and -not $uninstalled.data.installed -and [IO.File]::Exists($configPath) -and @($hooks.hooks.Stop.hooks | Where-Object { $_.command -eq $foreign.command }).Count -eq 1) '卸载可保留配置，不删除其他工具的钩子'
    Assert-DesktopCheck ([IO.File]::ReadAllText((Join-Path $directory 'config.toml')) -eq 'keep = true') '所有图形操作保留 config.toml'
    $uninstalled = Invoke-DesktopRequest 'uninstall'
    Assert-DesktopCheck ($uninstalled.ok -and -not [IO.File]::Exists($configPath)) '卸载支持同时移除配置'
    [IO.File]::WriteAllText($hooksPath, '{ invalid')
    $desired.wechatEnabled = $false
    $broken = Invoke-DesktopRequest 'install' $desired
    Assert-DesktopCheck (-not $broken.ok -and [IO.File]::ReadAllText($hooksPath) -eq '{ invalid' -and -not [IO.File]::Exists($senderPath)) '坏 JSON 阻止安装，不覆盖用户原文件'
    if (-not $SkipExecutable) {
        $executable = Join-Path $repository 'dist\CodexPhoneNotifier.exe'
        if (-not [IO.File]::Exists($executable)) { throw '请先运行 build-desktop.ps1，再测试真实 EXE。' }
        $resultFile = Join-Path $workspace 'exe-result.json'
        $process = Start-Process -FilePath $executable -ArgumentList @('--self-check', ('"' + $resultFile + '"')) -WindowStyle Hidden -PassThru -Wait
        $verified = Read-NotifierJson $resultFile
        Assert-DesktopCheck ($process.ExitCode -eq 0 -and $verified.ok -and $verified.checks -eq 7) '真实 EXE 通过匿名标准输入完成七项集成检查'
    }
    Write-Host ('PASS: desktop {0} checks; PowerShell {1}' -f $script:checks,$PSVersionTable.PSVersion)
} finally {
    $target = [IO.Path]::GetFullPath($workspace)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($target.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($target).StartsWith('codex-desktop-test-')) {
        if ([IO.Directory]::Exists($target)) { Remove-Item -LiteralPath $target -Recurse -Force }
    } else { throw '拒绝清理不属于本测试的目录。' }
}
