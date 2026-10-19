#requires -Version 5.1
[CmdletBinding()]
param([object]$RequestObject = $null)
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot '..\scripts\common.ps1')
. (Join-Path $PSScriptRoot '..\scripts\mcp-consent.ps1')
function Get-DesktopStatus {
    $settings = Read-NotifierJson $configPath
    $document = Read-NotifierJson $hooksPath
    $ownedStop = $false
    if ($null -ne $document.PSObject.Properties['hooks']) {
        foreach ($handler in @($document.hooks.Stop.hooks)) {
            if ($null -ne $handler -and ([string]$handler.command).IndexOf($senderPath, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $ownedStop = $true }
        }
    }
    $channels = @()
    if ([IO.File]::Exists($configPath)) {
        if ($null -eq $settings.PSObject.Properties['channels']) { $channels = @('ntfy') }
        else { $channels = @($settings.channels) }
    }
    $server = 'https://ntfy.sh'
    if ($settings.server) { $server = [string]$settings.server }
    return [ordered]@{
        directory=$directory; installed=([IO.File]::Exists($senderPath) -and [IO.File]::Exists($configPath) -and $ownedStop)
        hasConfig=[IO.File]::Exists($configPath); hasToken=[IO.File]::Exists($tokenPath)
        ntfyEnabled=($channels -contains 'ntfy'); wechatEnabled=($channels -contains 'wechat')
        server=$server; topic=[string]$settings.topic
    }
}
function Assert-DesktopInput {
    if ($null -eq $request.settings) { throw '[用户提示]缺少通知设置，请重新打开窗口。' }
    $script:desired = $request.settings
    $script:server = ([string]$desired.server).Trim().TrimEnd('/')
    $script:topic = ([string]$desired.topic).Trim()
    $uri = $null
    if (-not [Uri]::TryCreate($server, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http', 'https') -or $uri.UserInfo) { throw '[用户提示]ntfy 服务器必须是 http:// 或 https:// 地址，且不能包含用户名或密码。' }
    if ($topic -and $topic -notmatch '^[A-Za-z0-9_-]{1,64}$') { throw '[用户提示]ntfy 主题请使用 1 至 64 个英文字母、数字、短横线或下划线。' }
    if ([bool]$desired.ntfyEnabled -and -not $topic) { throw '[用户提示]请填写 ntfy 主题，或点击“生成新主题”。' }
    if ([bool]$desired.wechatEnabled -and -not [IO.File]::Exists($tokenPath) -and [string]::IsNullOrWhiteSpace([string]$desired.token)) { throw '[用户提示]开启微信前，请填写 PushPlus 用户 Token，并完成 ClawBot 绑定和激活。' }
}
function Save-DesktopSettings {
    param([switch]$Install)
    Assert-DesktopInput
    # 先读完并验证已有文件，再备份和修改。无法读取时绝不覆盖。
    $settings = Read-NotifierJson $configPath
    $hooks = Read-NotifierJson $hooksPath
    if (-not $Install -and -not (Get-DesktopStatus).installed) { throw '[用户提示]请先点击“安装 / 更新通知工具”。' }
    $encrypted = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$desired.token)) {
        Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1') -ErrorAction Stop
        $secure = ConvertTo-SecureString -String ([string]$desired.token).Trim() -AsPlainText -Force
        try { $encrypted = ConvertFrom-SecureString -SecureString $secure } finally { $secure.Dispose() }
    }
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $paths = @($configPath, $senderPath, $tokenPath, $statePath)
    if ($Install) { $paths += @($hooksPath,(Join-Path $directory 'config.toml'),(Join-Path $directory 'mcp-consent-proxy.json')) }
    $existing = @($paths | Where-Object { [IO.File]::Exists($_) })
    $backup = Backup-NotifierFiles $directory $paths
    $oldRuntimeOverride = Get-ConsentRuntimeOverride
    try {
        if ($Install) {
            & (Join-Path $PSScriptRoot '..\install.ps1') -CodexHome $directory *> $null
            $settings = Read-NotifierJson $configPath
        }
        $channels = @()
        if ([bool]$desired.ntfyEnabled) { $channels += 'ntfy' }
        if ([bool]$desired.wechatEnabled) { $channels += 'wechat' }
        Set-NotifierProperty $settings 'channels' $channels
        Set-NotifierProperty $settings 'server' $server
        if ($topic) { Set-NotifierProperty $settings 'topic' $topic }
        else { $settings.PSObject.Properties.Remove('topic') }
        # 保存设置时也更新发送脚本；通道开关不会改动已信任的钩子命令。
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\scripts\notify.ps1') -Destination $senderPath -Force
        if ($null -ne $encrypted) {
            [IO.File]::WriteAllText($tokenPath, $encrypted, [Text.UTF8Encoding]::new($false))
            if ([IO.File]::Exists($statePath)) { Remove-Item -LiteralPath $statePath -Force }
        }
        Write-NotifierJson $configPath $settings
        $script:settingsSaved = $true
    } catch {
        if($Install){
            $native = Read-NotifierJson (Join-Path $directory 'mcp-consent-proxy.json')
            if($native.runtimeOverride -and (Get-ConsentRuntimeOverride) -eq $native.proxyCommand){Set-ConsentRuntimeOverride $oldRuntimeOverride}
        }
        foreach ($path in $paths) {
            if ($existing -contains $path) { Copy-Item -LiteralPath (Join-Path $backup ([IO.Path]::GetFileName($path))) -Destination $path -Force }
            elseif ([IO.File]::Exists($path)) { Remove-Item -LiteralPath $path -Force }
        }
        throw
    } finally { $encrypted = $null; if ($null -ne $request.settings) { $request.settings.token = $null } }
}
try {
    $request = $RequestObject
    if ($null -eq $request) { $request = [Console]::In.ReadToEnd() | ConvertFrom-Json }
    $directory = Resolve-NotifierDirectory ([string]$request.directory)
    $configPath = Join-Path $directory 'ntfy-codex.json'
    $hooksPath = Join-Path $directory 'hooks.json'
    $senderPath = Join-Path $directory 'scripts\codex-ntfy-notify.ps1'
    $tokenPath = Join-Path $directory 'pushplus-token.dpapi'
    $statePath = Join-Path $directory 'wechat-send-state.json'
    $script:settingsSaved = $false
    $message = '已读取本机设置。'
    $restartRequired = $false
    switch ([string]$request.action) {
        'status' { }
        'save' { Save-DesktopSettings; $message = '设置已保存，下次自动提醒即生效。' }
        'install' { Save-DesktopSettings -Install; $message = '安装完成。请完整重启 Codex 以加载插件授权提醒连接；首次安装还需审查通知钩子。'; $restartRequired = $true }
        'test' {
            if ([string]$request.channel -notin @('ntfy','wechat')) { throw '[用户提示]请选择要测试的通知渠道。' }
            Assert-DesktopInput
            if (($request.channel -eq 'ntfy' -and -not [bool]$desired.ntfyEnabled) -or ($request.channel -eq 'wechat' -and -not [bool]$desired.wechatEnabled)) { throw '[用户提示]请先打开这个渠道的开关，再发送测试。' }
            Save-DesktopSettings
            & $senderPath -Event test -Channel ([string]$request.channel) -ConfigPath $configPath -Strict *> $null
            if ($request.channel -eq 'wechat') { $message = '微信聊天测试请求已提交。请锁屏后检查手机是否收到；接口接受请求不等于送达。' }
            else { $message = 'ntfy 测试已发布。请检查订阅该主题的 ntfy App。' }
        }
        { $_ -in @('remove-ntfy','remove-wechat') } {
            $settings = Read-NotifierJson $configPath
            if (-not [IO.File]::Exists($configPath)) { throw '[用户提示]尚未安装通知工具。' }
            $paths = @($configPath, $senderPath)
            $channel = 'ntfy'
            if ($request.action -eq 'remove-wechat') { $channel = 'wechat'; $paths += @($tokenPath, $statePath) }
            $existing = @($paths | Where-Object { [IO.File]::Exists($_) })
            $backup = Backup-NotifierFiles $directory $paths
            $channels = @('ntfy')
            if ($null -ne $settings.PSObject.Properties['channels']) { $channels = @($settings.channels) }
            Set-NotifierProperty $settings 'channels' @($channels | Where-Object { $_ -ne $channel })
            if ($channel -eq 'ntfy') {
                foreach ($name in @('server','topic','authorization','priority','tags','inputTags','click')) { $settings.PSObject.Properties.Remove($name) }
                $message = '已关闭 ntfy 并移除其本机配置，微信和 Codex 钩子保留。'
            } else { $message = '已关闭微信并移除本机加密 Token，ntfy 和 Codex 钩子保留。' }
            try {
                if ([IO.File]::Exists($senderPath)) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\scripts\notify.ps1') -Destination $senderPath -Force }
                Write-NotifierJson $configPath $settings
                if ($channel -eq 'wechat') {
                    foreach ($path in @($tokenPath,$statePath)) { if ([IO.File]::Exists($path)) { Remove-Item -LiteralPath $path -Force } }
                }
            } catch {
                foreach ($path in $paths) {
                    if ($existing -contains $path) { Copy-Item -LiteralPath (Join-Path $backup ([IO.Path]::GetFileName($path))) -Destination $path -Force }
                    elseif ([IO.File]::Exists($path)) { Remove-Item -LiteralPath $path -Force }
                }
                throw
            }
        }
        'uninstall' {
            & (Join-Path $PSScriptRoot '..\uninstall.ps1') -CodexHome $directory -KeepConfig:([bool]$request.keepConfig) *> $null
            $message = '通知工具已卸载，请完整退出并重新打开 Codex。'
            $restartRequired = $true
        }
        default { throw '[用户提示]不支持的操作，请重新打开软件。' }
    }
    [pscustomobject]@{ ok=$true; message=$message; data=(Get-DesktopStatus); restartRequired=$restartRequired } | ConvertTo-Json -Depth 12 -Compress
} catch {
    $message = '操作未完成（' + $_.Exception.GetType().Name + '）。请检查安装目录、配置文件和网络；发送失败时可以查看本地日志中的返回码。'
    if ($_.Exception.Message.StartsWith('[用户提示]')) { $message = $_.Exception.Message.Substring(6) }
    $data = $null
    if ($script:settingsSaved) { try { $data = Get-DesktopStatus } catch { } }
    [pscustomobject]@{ ok=$false; message=$message; data=$data; restartRequired=$false } | ConvertTo-Json -Depth 12 -Compress
} finally {
    if ($null -ne $request -and $null -ne $request.settings) { $request.settings.token = $null }
}
