#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Topic = '',
    [string]$Server = 'https://ntfy.sh',
    [string]$CodexHome = '',
    [switch]$NoInputReminder,
    [switch]$NoStartupHook,
    [switch]$ForceConfig,
    [switch]$SendTest
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\common.ps1')
$directory = Resolve-NotifierDirectory $CodexHome
$configFile = Join-Path $directory 'ntfy-codex.json'
$hooksFile = Join-Path $directory 'hooks.json'
$targetScript = Join-Path $directory 'scripts\codex-ntfy-notify.ps1'
$sourceScript = Join-Path $PSScriptRoot 'scripts\notify.ps1'
# 先检查已有 JSON；有问题时停止，不覆盖其他配置。
$document = Read-NotifierJson $hooksFile
$settings = Read-NotifierJson $configFile
$hookMember = $document.PSObject.Properties['hooks']
if ($null -eq $hookMember) {
    Set-NotifierProperty $document 'hooks' ([pscustomobject]@{})
} elseif ($null -eq $hookMember.Value -or $hookMember.Value -is [array] -or $hookMember.Value -is [string] -or $hookMember.Value -is [ValueType]) { throw 'hooks 必须是 JSON 对象，请先修复 hooks.json。' }
$hooks = $document.hooks
$writeConfig = -not [IO.File]::Exists($configFile) -or $ForceConfig
if ($writeConfig) {
    if ([string]::IsNullOrWhiteSpace($Topic)) { $Topic = 'codex-' + [guid]::NewGuid().ToString('N').Substring(0, 24) }
    if ($Topic -notmatch '^[A-Za-z0-9_-]{1,64}$') { throw '主题请使用 1 至 64 个英文字母、数字、短横线或下划线。' }
    $serverUri = $null
    if (-not [Uri]::TryCreate($Server, [UriKind]::Absolute, [ref]$serverUri) -or $serverUri.Scheme -notin @('http', 'https') -or $serverUri.UserInfo) { throw '服务器地址应以 http:// 或 https:// 开头，且不能包含用户名或密码。' }
    $settings = [pscustomobject][ordered]@{
        channels = @('ntfy')
        server = $Server.TrimEnd('/')
        topic = $Topic
        title = 'Codex 任务已完成'
        inputTitle = 'Codex 等待你回答'
        testTitle = 'Codex 通知测试'
        priority = 'default'
        tags = 'computer,white_check_mark'
        inputTags = 'computer,question'
        click = ''
    }
}
Remove-NotifierHandlers $hooks $targetScript
# 引号支持包含空格和中文的安装路径。
$prefix = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $targetScript + '" -Event '
Add-NotifierHandler $hooks 'Stop' ($prefix + 'done') '' '发送 Codex 完成提醒'
if (-not $NoInputReminder) { Add-NotifierHandler $hooks 'PreToolUse' ($prefix + 'input') '(^|[._])request_user_input(_async)?$' '发送 Codex 等待输入提醒' }
if (-not $NoStartupHook) { Add-NotifierHandler $hooks 'SessionStart' ($prefix + 'startup') '^startup$' '准备 Codex 手机提醒' }
[IO.Directory]::CreateDirectory($directory) | Out-Null
$paths = @($hooksFile, $configFile, $targetScript)
$originalFiles = @($paths | Where-Object { [IO.File]::Exists($_) })
$backup = Backup-NotifierFiles $directory $paths
try {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($targetScript)) | Out-Null
    Copy-Item -LiteralPath $sourceScript -Destination $targetScript -Force
    if ($writeConfig) { Write-NotifierJson $configFile $settings }
    # 最后才登记钩子，避免指向尚未安装的脚本。
    Write-NotifierJson $hooksFile $document
} catch {
    foreach ($path in $paths) {
        if ($originalFiles -contains $path) {
            Copy-Item -LiteralPath (Join-Path $backup ([IO.Path]::GetFileName($path))) -Destination $path -Force
        } elseif ([IO.File]::Exists($path)) { Remove-Item -LiteralPath $path -Force }
    }
    throw
}
Write-Host ''
Write-Host '安装完成。请按下面的步骤让提醒真正生效：'
Write-Host ('1. 手机 ntfy 服务器：' + $settings.server)
Write-Host ('   手机 ntfy 订阅主题：' + $settings.topic)
Write-Host '2. 审查并信任本工具的钩子，可运行本目录的 review-hooks.ps1。'
Write-Host '3. 完整退出并重新打开 Codex。'
Write-Host '4. 运行 send-test.ps1 检查手机；再用真实任务和选择题验证自动提醒。'
if (-not $writeConfig) { Write-Host '已保留原来的通知配置；更换服务器或主题需要明确使用 -ForceConfig。' }
Write-Host ('配置文件：' + $configFile)
Write-Host ('原文件备份：' + $backup)
if ($SendTest) { & $targetScript -Event test -ConfigPath $configFile -Strict }
