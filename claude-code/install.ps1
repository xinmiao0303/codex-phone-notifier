#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Topic = '',
    [string]$Server = 'https://ntfy.sh',
    [string]$ClaudeHome = '',
    # 已经装过 Codex 手机提醒时，默认沿用它的通道、ntfy 主题和加密微信密钥。
    [string]$CodexHome = '',
    [switch]$NoImport,
    [switch]$NoInputReminder,
    [switch]$NoApprovalReminder,
    [switch]$NoErrorReminder,
    [switch]$IdleReminder,
    [switch]$ForceConfig,
    [switch]$SendTest
)
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
. (Join-Path $repository 'scripts\common.ps1')
. (Join-Path $repository 'scripts\claude-common.ps1')
$paths = Get-ClaudeNotifierPaths (Resolve-ClaudeDirectory $ClaudeHome)
$sourceScript = Join-Path $repository 'scripts\claude-notify.ps1'
# 先检查已有 JSON；有问题时停止，不覆盖 Claude Code 的其他设置。
$document = Read-NotifierJson $paths.settings
$settings = Read-NotifierJson $paths.config
$hookMember = $document.PSObject.Properties['hooks']
if ($null -eq $hookMember) {
    Set-NotifierProperty $document 'hooks' ([pscustomobject]@{})
} elseif ($null -eq $hookMember.Value -or $hookMember.Value -is [array] -or $hookMember.Value -is [string] -or $hookMember.Value -is [ValueType]) { throw 'settings.json 中的 hooks 必须是 JSON 对象，请先修复。' }
$hooks = $document.hooks
$writeConfig = -not [IO.File]::Exists($paths.config) -or $ForceConfig
$importedFrom = ''
$copyToken = ''
if ($writeConfig) {
    $settings = [pscustomobject][ordered]@{
        channels = @('ntfy')
        server = 'https://ntfy.sh'
        topic = 'claude-' + [guid]::NewGuid().ToString('N').Substring(0, 24)
        title = 'Claude Code 任务已完成'
        inputTitle = 'Claude Code 等待你回答'
        planTitle = 'Claude Code 等待你确认计划'
        approvalTitle = 'Claude Code 等待你授权'
        errorTitle = 'Claude Code 出错停止'
        idleTitle = 'Claude Code 仍在等你'
        testTitle = 'Claude Code 通知测试'
        priority = 'default'
        tags = 'computer,white_check_mark'
        inputTags = 'computer,question'
        click = ''
        showProject = $false
    }
    if (-not $NoImport) {
        $codexDirectory = Resolve-NotifierDirectory $CodexHome
        $codexConfig = Join-Path $codexDirectory 'ntfy-codex.json'
        if ([IO.File]::Exists($codexConfig)) {
            $codex = Read-NotifierJson $codexConfig
            # 只沿用通道与连接信息；标题保持 Claude Code 自己的中文标题。
            foreach ($name in @('channels', 'server', 'topic', 'authorization', 'priority', 'click')) {
                $member = $codex.PSObject.Properties[$name]
                if ($null -ne $member -and $null -ne $member.Value) { Set-NotifierProperty $settings $name $member.Value }
            }
            if ($null -eq $codex.PSObject.Properties['channels']) { $settings.channels = @('ntfy') }
            $settings.channels = @($settings.channels)
            $codexToken = Join-Path $codexDirectory 'pushplus-token.dpapi'
            if ([IO.File]::Exists($codexToken) -and -not [IO.File]::Exists($paths.token)) { $copyToken = $codexToken }
            $importedFrom = $codexConfig
        }
    }
    if ($PSBoundParameters.ContainsKey('Topic')) { $settings.topic = $Topic }
    if ($PSBoundParameters.ContainsKey('Server')) { $settings.server = $Server.TrimEnd('/') }
    if ([string]$settings.topic -notmatch '^[A-Za-z0-9_-]{1,64}$') { throw '主题请使用 1 至 64 个英文字母、数字、短横线或下划线。' }
    $serverUri = $null
    if (-not [Uri]::TryCreate([string]$settings.server, [UriKind]::Absolute, [ref]$serverUri) -or $serverUri.Scheme -notin @('http', 'https') -or $serverUri.UserInfo) { throw '服务器地址应以 http:// 或 https:// 开头，且不能包含用户名或密码。' }
    if (@($settings.channels) -contains 'wechat' -and -not $copyToken -and -not [IO.File]::Exists($paths.token)) {
        Write-Warning '沿用的设置启用了微信，但找不到加密密钥；请随后运行 connect-wechat.cmd 填写。'
    }
}
Remove-ClaudeNotifierHandlers $hooks $paths.script
Add-ClaudeNotifierHandler $hooks 'Stop' $paths.script ''
if (-not $NoErrorReminder) { Add-ClaudeNotifierHandler $hooks 'StopFailure' $paths.script '' }
if (-not $NoInputReminder) { Add-ClaudeNotifierHandler $hooks 'PreToolUse' $paths.script 'AskUserQuestion|ExitPlanMode' }
$notificationTypes = @()
if (-not $NoApprovalReminder) { $notificationTypes += 'permission_prompt' }
if (-not $NoInputReminder) { $notificationTypes += @('elicitation_dialog', 'elicitation_url_dialog') }
if ($IdleReminder) { $notificationTypes += 'idle_prompt' }
if ($notificationTypes.Count -gt 0) { Add-ClaudeNotifierHandler $hooks 'Notification' $paths.script ($notificationTypes -join '|') }
[IO.Directory]::CreateDirectory($paths.root) | Out-Null
$owned = @($paths.settings, $paths.config, $paths.script, $paths.token)
$originalFiles = @($owned | Where-Object { [IO.File]::Exists($_) })
$backup = Backup-ClaudeNotifierFiles $paths.root $owned
try {
    Copy-NotifierScript $sourceScript $paths.script
    if ($writeConfig) { Write-NotifierJson $paths.config $settings }
    if ($copyToken) { Copy-Item -LiteralPath $copyToken -Destination $paths.token }
    # 最后才登记钩子，避免指向尚未安装的脚本。
    Write-NotifierJson $paths.settings $document
} catch {
    Restore-NotifierFiles $backup $owned $originalFiles
    throw
}
$settings = Read-NotifierJson $paths.config
$channels = @('ntfy')
if ($null -ne $settings.PSObject.Properties['channels']) { $channels = @($settings.channels) }
Write-Host ''
Write-Host 'Claude Code 手机提醒安装完成。'
Write-Host ('已登记的钩子：' + ((Get-ClaudeNotifierHookSummary $document.hooks $paths.script) -join '、'))
if ($importedFrom) { Write-Host ('已沿用 Codex 手机提醒的通道设置：' + $importedFrom) }
if ($copyToken) { Write-Host '已复制本机加密的 PushPlus 密钥（仍只能在当前 Windows 用户下解密）。' }
if ($channels.Count -eq 0) { Write-Host '当前所有通道都已关闭，提醒处于暂停状态。' }
else { Write-Host ('自动提醒通道：' + ($channels -join ' + ')) }
if ($channels -contains 'ntfy') {
    Write-Host ('   ntfy 服务器：' + $settings.server)
    Write-Host ('   ntfy 订阅主题：' + $settings.topic)
}
if ($document.PSObject.Properties['disableAllHooks'] -and $document.disableAllHooks -eq $true) {
    Write-Warning 'settings.json 里设置了 disableAllHooks: true，所有钩子都不会运行，请先关闭它。'
}
Write-Host '下一步：'
Write-Host '1. 新开一个 Claude Code 会话（桌面版 Code 标签、终端 claude、VS Code 插件都读取同一份设置）。'
Write-Host '   终端里可以输入 /hooks 查看本工具登记的钩子。'
Write-Host '2. 运行 send-test.ps1 检查手机；再用真实任务、选择题和授权请求验证自动提醒。'
if (-not $writeConfig) { Write-Host '已保留原来的通知配置；需要重新生成时使用 -ForceConfig。' }
Write-Host ('配置文件：' + $paths.config)
Write-Host ('原文件备份：' + $backup)
if ($SendTest) { & $paths.script -Event test -ConfigPath $paths.config -Strict }
