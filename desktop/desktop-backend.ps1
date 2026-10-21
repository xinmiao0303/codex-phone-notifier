#requires -Version 5.1
[CmdletBinding()]
param([object]$RequestObject = $null)
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot '..\scripts\common.ps1')
. (Join-Path $PSScriptRoot '..\scripts\mcp-consent.ps1')
. (Join-Path $PSScriptRoot '..\scripts\claude-common.ps1')
# Codex 与 Claude Code 各有一份配置，渠道设置（ntfy、微信）由界面同步写入两份；
# “开启/关闭”只改配置里的 enabled，不改动已信任的钩子，也不需要重启。
function Test-CodexInstalled {
    $document = Read-NotifierJson $hooksPath
    $ownedStop = $false
    if ($null -ne $document.PSObject.Properties['hooks']) {
        foreach ($handler in @($document.hooks.Stop.hooks)) {
            if ($null -ne $handler -and ([string]$handler.command).IndexOf($senderPath, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $ownedStop = $true }
        }
    }
    return ([IO.File]::Exists($senderPath) -and [IO.File]::Exists($configPath) -and $ownedStop)
}
function Test-ReminderSwitch {
    param([string]$Path)
    $settings = Read-NotifierJson $Path
    return -not ($null -ne $settings.PSObject.Properties['enabled'] -and $settings.enabled -eq $false)
}
function Get-DesktopStatus {
    $codexInstalled = Test-CodexInstalled
    $claudeInstalled = Test-ClaudeNotifierInstalled $claude
    # 渠道设置以 Codex 配置为准；只装了 Claude Code 时读取它的配置。
    $source = $configPath
    if (-not [IO.File]::Exists($configPath) -and [IO.File]::Exists($claude.config)) { $source = $claude.config }
    $settings = Read-NotifierJson $source
    $channels = @()
    if ([IO.File]::Exists($source)) {
        if ($null -eq $settings.PSObject.Properties['channels']) { $channels = @('ntfy') }
        else { $channels = @($settings.channels) }
    }
    $server = 'https://ntfy.sh'
    if ($settings.server) { $server = [string]$settings.server }
    $codexDetected = [IO.Directory]::Exists($directory)
    $claudeDetected = [IO.Directory]::Exists($claudeDirectory)
    $codexEnabled = $codexDetected
    if ($codexInstalled) { $codexEnabled = Test-ReminderSwitch $configPath }
    $claudeEnabled = $claudeDetected
    if ($claudeInstalled) { $claudeEnabled = Test-ReminderSwitch $claude.config }
    return [ordered]@{
        directory=$directory; claudeDirectory=$claudeDirectory
        installed=($codexInstalled -or $claudeInstalled)
        codexInstalled=$codexInstalled; claudeInstalled=$claudeInstalled
        codexDetected=$codexDetected; claudeDetected=$claudeDetected
        codexEnabled=$codexEnabled; claudeEnabled=$claudeEnabled
        hasConfig=([IO.File]::Exists($configPath) -or [IO.File]::Exists($claude.config))
        hasToken=([IO.File]::Exists($tokenPath) -or [IO.File]::Exists($claude.token))
        ntfyEnabled=($channels -contains 'ntfy'); wechatEnabled=($channels -contains 'wechat')
        server=$server; topic=[string]$settings.topic
    }
}
function Read-DesiredFlag {
    param([string]$Name, [bool]$Fallback)
    # 旧版界面只管理 Codex：没有这两个字段时，默认只开 Codex。
    $member = $desired.PSObject.Properties[$Name]
    if ($null -eq $member -or $null -eq $member.Value) { return $Fallback }
    return [bool]$member.Value
}
function Assert-DesktopInput {
    if ($null -eq $request.settings) { throw '[用户提示]缺少通知设置，请重新打开窗口。' }
    $script:desired = $request.settings
    $script:server = ([string]$desired.server).Trim().TrimEnd('/')
    $script:topic = ([string]$desired.topic).Trim()
    $script:wantCodex = Read-DesiredFlag 'codexEnabled' $true
    $script:wantClaude = Read-DesiredFlag 'claudeEnabled' $false
    $uri = $null
    if (-not [Uri]::TryCreate($server, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http', 'https') -or $uri.UserInfo) { throw '[用户提示]ntfy 服务器必须是 http:// 或 https:// 地址，且不能包含用户名或密码。' }
    if ($topic -and $topic -notmatch '^[A-Za-z0-9_-]{1,64}$') { throw '[用户提示]ntfy 主题请使用 1 至 64 个英文字母、数字、短横线或下划线。' }
    if ([bool]$desired.ntfyEnabled -and -not $topic) { throw '[用户提示]请填写 ntfy 主题，或点击“生成新主题”。' }
    if ([bool]$desired.wechatEnabled -and -not [IO.File]::Exists($tokenPath) -and -not [IO.File]::Exists($claude.token) -and [string]::IsNullOrWhiteSpace([string]$desired.token)) { throw '[用户提示]开启微信前，请填写 PushPlus 用户 Token，并完成 ClawBot 绑定和激活。' }
}
function Set-ChannelSettings {
    param([string]$Path, [bool]$Enabled)
    $settings = Read-NotifierJson $Path
    $channels = @()
    if ([bool]$desired.ntfyEnabled) { $channels += 'ntfy' }
    if ([bool]$desired.wechatEnabled) { $channels += 'wechat' }
    Set-NotifierProperty $settings 'channels' $channels
    Set-NotifierProperty $settings 'server' $server
    if ($topic) { Set-NotifierProperty $settings 'topic' $topic }
    else { $settings.PSObject.Properties.Remove('topic') }
    Set-NotifierProperty $settings 'enabled' $Enabled
    Write-NotifierJson $Path $settings
}
function Save-DesktopSettings {
    param([switch]$Install)
    Assert-DesktopInput
    # 先读完并验证已有文件，再备份和修改。无法读取时绝不覆盖。
    $null = Read-NotifierJson $configPath; $null = Read-NotifierJson $hooksPath
    $null = Read-NotifierJson $claude.config; $null = Read-NotifierJson $claude.settings
    $codexInstalled = Test-CodexInstalled
    $claudeInstalled = Test-ClaudeNotifierInstalled $claude
    if (-not $Install -and -not ($codexInstalled -or $claudeInstalled)) { throw '[用户提示]请先点击“一键部署”。' }
    # 打开开关但还没装的工具现在安装；“一键部署”同时更新已安装的工具，关闭的工具保持暂停。
    $deployCodex = ($wantCodex -and -not $codexInstalled) -or ($Install -and $codexInstalled)
    $deployClaude = ($wantClaude -and -not $claudeInstalled) -or ($Install -and $claudeInstalled)
    $useCodex = $codexInstalled -or $deployCodex
    $useClaude = $claudeInstalled -or $deployClaude
    if (-not $useCodex -and -not $useClaude) { throw '[用户提示]请至少开启 Codex 提醒或 Claude Code 提醒中的一个。' }
    $encrypted = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$desired.token)) {
        Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1') -ErrorAction Stop
        $secure = ConvertTo-SecureString -String ([string]$desired.token).Trim() -AsPlainText -Force
        try { $encrypted = ConvertFrom-SecureString -SecureString $secure } finally { $secure.Dispose() }
    }
    $codexPaths = @(); $claudePaths = @()
    if ($useCodex) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        $codexPaths = @($configPath, $senderPath, $tokenPath, $statePath)
        if ($deployCodex) { $codexPaths += @($hooksPath,(Join-Path $directory 'config.toml'),(Join-Path $directory 'mcp-consent-proxy.json')) }
    }
    if ($useClaude) {
        [IO.Directory]::CreateDirectory($claude.root) | Out-Null
        $claudePaths = @($claude.config, $claude.script, $claude.token, $claude.wechatState, $claude.settings)
    }
    $existing = @(@($codexPaths) + @($claudePaths) | Where-Object { [IO.File]::Exists($_) })
    $codexBackup = ''; $claudeBackup = ''
    if ($useCodex) { $codexBackup = Backup-NotifierFiles $directory $codexPaths }
    if ($useClaude) { $claudeBackup = Backup-ClaudeNotifierFiles $claude.root $claudePaths }
    $oldRuntimeOverride = Get-ConsentRuntimeOverride
    try {
        if ($deployCodex) { & (Join-Path $PSScriptRoot '..\install.ps1') -CodexHome $directory *> $null }
        if ($deployClaude) { & (Join-Path $PSScriptRoot '..\claude-code\install.ps1') -ClaudeHome $claudeDirectory -NoImport *> $null }
        # 保存设置时也更新发送脚本；开关和渠道不会改动已信任的钩子命令。
        if ($useCodex) {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\scripts\notify.ps1') -Destination $senderPath -Force
            Set-ChannelSettings $configPath $wantCodex
        }
        if ($useClaude) {
            Copy-NotifierScript (Join-Path $PSScriptRoot '..\scripts\claude-notify.ps1') $claude.script
            Set-ChannelSettings $claude.config $wantClaude
        }
        $targets = @()
        if ($useCodex) { $targets += [pscustomobject]@{ token=$tokenPath; state=$statePath } }
        if ($useClaude) { $targets += [pscustomobject]@{ token=$claude.token; state=$claude.wechatState } }
        foreach ($target in $targets) {
            if ($null -ne $encrypted) {
                [IO.File]::WriteAllText($target.token, $encrypted, [Text.UTF8Encoding]::new($false))
                if ([IO.File]::Exists($target.state)) { Remove-Item -LiteralPath $target.state -Force }
            } elseif (-not [IO.File]::Exists($target.token)) {
                # 另一个工具已经保存过加密 Token 时，复制一份；DPAPI 仍只能由当前 Windows 用户解密。
                $other = @(@($tokenPath, $claude.token) | Where-Object { $_ -ne $target.token -and [IO.File]::Exists($_) })
                if ($other.Count -gt 0) { Copy-Item -LiteralPath $other[0] -Destination $target.token }
            }
        }
        $script:settingsSaved = $true
        $script:deployed = [pscustomobject]@{ codex=$deployCodex; claude=$deployClaude; codexNew=($deployCodex -and -not $codexInstalled); claudeNew=($deployClaude -and -not $claudeInstalled) }
    } catch {
        if($deployCodex){
            $native = Read-NotifierJson (Join-Path $directory 'mcp-consent-proxy.json')
            if($native.runtimeOverride -and (Get-ConsentRuntimeOverride) -eq $native.proxyCommand){Set-ConsentRuntimeOverride $oldRuntimeOverride}
        }
        foreach ($path in @($codexPaths)) {
            if ($existing -contains $path) { Copy-Item -LiteralPath (Join-Path $codexBackup ([IO.Path]::GetFileName($path))) -Destination $path -Force }
            elseif ([IO.File]::Exists($path)) { Remove-Item -LiteralPath $path -Force }
        }
        foreach ($path in @($claudePaths)) {
            if ($existing -contains $path) { Copy-Item -LiteralPath (Join-Path $claudeBackup ([IO.Path]::GetFileName($path))) -Destination $path -Force }
            elseif ([IO.File]::Exists($path)) { Remove-Item -LiteralPath $path -Force }
        }
        throw
    } finally { $encrypted = $null; if ($null -ne $request.settings) { $request.settings.token = $null } }
}
function Get-DeployMessage {
    param([string]$Prefix)
    $parts = @($Prefix)
    if ($deployed.codex) {
        if ($deployed.codexNew) { $parts += 'Codex：请在“安装与帮助”中审查通知钩子，再完整退出并重新打开 Codex。' }
        else { $parts += 'Codex：已更新，请完整重启 Codex 以加载插件授权提醒连接。' }
    }
    if ($deployed.claude) { $parts += 'Claude Code：新开一个会话即生效，无需重启。' }
    return ($parts -join ' ')
}
function Remove-Channel {
    param([string]$Path, [string]$Channel, [string]$Token, [string]$State, [string]$Sender, [string]$SenderSource, [string]$BackupRoot, [switch]$Claude)
    $settings = Read-NotifierJson $Path
    $paths = @($Path, $Sender)
    if ($Channel -eq 'wechat') { $paths += @($Token, $State) }
    $existing = @($paths | Where-Object { [IO.File]::Exists($_) })
    if ($Claude) { $backup = Backup-ClaudeNotifierFiles $BackupRoot $paths } else { $backup = Backup-NotifierFiles $BackupRoot $paths }
    $channels = @('ntfy')
    if ($null -ne $settings.PSObject.Properties['channels']) { $channels = @($settings.channels) }
    Set-NotifierProperty $settings 'channels' @($channels | Where-Object { $_ -ne $Channel })
    if ($Channel -eq 'ntfy') {
        foreach ($name in @('server','topic','authorization','priority','tags','inputTags','click')) { $settings.PSObject.Properties.Remove($name) }
    }
    try {
        if ([IO.File]::Exists($Sender)) {
            if ($Claude) { Copy-NotifierScript $SenderSource $Sender } else { Copy-Item -LiteralPath $SenderSource -Destination $Sender -Force }
        }
        Write-NotifierJson $Path $settings
        if ($Channel -eq 'wechat') {
            foreach ($item in @($Token,$State)) { if ([IO.File]::Exists($item)) { Remove-Item -LiteralPath $item -Force } }
        }
    } catch {
        foreach ($item in $paths) {
            if ($existing -contains $item) { Copy-Item -LiteralPath (Join-Path $backup ([IO.Path]::GetFileName($item))) -Destination $item -Force }
            elseif ([IO.File]::Exists($item)) { Remove-Item -LiteralPath $item -Force }
        }
        throw
    }
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
    $claudeDirectory = Resolve-ClaudeDirectory ([string]$request.claudeDirectory)
    $claude = Get-ClaudeNotifierPaths $claudeDirectory
    $script:settingsSaved = $false
    $script:deployed = $null
    $message = '已读取本机设置。'
    $restartRequired = $false
    switch ([string]$request.action) {
        'status' { }
        'save' {
            Save-DesktopSettings
            $message = '设置已保存，下次自动提醒即生效。'
            if ($deployed.codexNew -or $deployed.claudeNew) { $message = Get-DeployMessage '设置已保存，并安装了新开启的提醒。'; $restartRequired = $deployed.codexNew }
        }
        'install' { Save-DesktopSettings -Install; $message = Get-DeployMessage '部署完成。'; $restartRequired = $deployed.codex }
        'test' {
            if ([string]$request.channel -notin @('ntfy','wechat')) { throw '[用户提示]请选择要测试的通知渠道。' }
            Assert-DesktopInput
            if (($request.channel -eq 'ntfy' -and -not [bool]$desired.ntfyEnabled) -or ($request.channel -eq 'wechat' -and -not [bool]$desired.wechatEnabled)) { throw '[用户提示]请先打开这个渠道的开关，再发送测试。' }
            Save-DesktopSettings
            # 只发一条测试：优先用开启中的 Codex 发送脚本，其次用 Claude Code 的。
            $sender = $senderPath; $senderConfig = $configPath
            if (-not (Test-CodexInstalled) -or (-not $wantCodex -and $wantClaude -and (Test-ClaudeNotifierInstalled $claude))) { $sender = $claude.script; $senderConfig = $claude.config }
            & $sender -Event test -Channel ([string]$request.channel) -ConfigPath $senderConfig -Strict *> $null
            if ($request.channel -eq 'wechat') { $message = '微信聊天测试请求已提交。请锁屏后检查手机是否收到；接口接受请求不等于送达。' }
            else { $message = 'ntfy 测试已发布。请检查订阅该主题的 ntfy App。' }
        }
        { $_ -in @('remove-ntfy','remove-wechat') } {
            $codexReady = [IO.File]::Exists($configPath); $claudeReady = [IO.File]::Exists($claude.config)
            if (-not $codexReady -and -not $claudeReady) { throw '[用户提示]尚未安装通知工具。' }
            $channel = 'ntfy'
            if ($request.action -eq 'remove-wechat') { $channel = 'wechat' }
            if ($codexReady) { Remove-Channel $configPath $channel $tokenPath $statePath $senderPath (Join-Path $PSScriptRoot '..\scripts\notify.ps1') $directory }
            if ($claudeReady) { Remove-Channel $claude.config $channel $claude.token $claude.wechatState $claude.script (Join-Path $PSScriptRoot '..\scripts\claude-notify.ps1') $claude.root -Claude }
            if ($channel -eq 'ntfy') { $message = '已关闭 ntfy 并移除其本机配置，微信和两边的钩子保留。' }
            else { $message = '已关闭微信并移除本机加密 Token，ntfy 和两边的钩子保留。' }
        }
        'uninstall' {
            $parts = @()
            # 只处理装过本工具的一边；从没用过的工具目录不会被创建或改动。
            if ([IO.File]::Exists($senderPath) -or [IO.File]::Exists($configPath) -or (Test-CodexInstalled)) {
                & (Join-Path $PSScriptRoot '..\uninstall.ps1') -CodexHome $directory -KeepConfig:([bool]$request.keepConfig) *> $null
                $parts += 'Codex：请完整退出并重新打开 Codex。'; $restartRequired = $true
            }
            if ([IO.File]::Exists($claude.script) -or [IO.File]::Exists($claude.config)) {
                & (Join-Path $PSScriptRoot '..\claude-code\uninstall.ps1') -ClaudeHome $claudeDirectory -KeepConfig:([bool]$request.keepConfig) *> $null
                $parts += 'Claude Code：新开的会话不再提醒。'
            }
            $message = (@('通知工具已卸载。') + $parts) -join ' '
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
