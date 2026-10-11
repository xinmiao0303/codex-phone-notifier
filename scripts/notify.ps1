#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('done', 'input', 'test', 'startup')]
    [string]$Event = 'done',
    [string]$ConfigPath = '',
    [switch]$Strict
)
$ErrorActionPreference = 'Stop'
# 安装后独立运行，不依赖 Python、Node.js 或仓库里的其他文件。
$notifierDirectory = $env:CODEX_HOME
if ([string]::IsNullOrWhiteSpace($notifierDirectory)) { $notifierDirectory = Join-Path $env:USERPROFILE '.codex' }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $notifierDirectory 'ntfy-codex.json' }
$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
$logFile = Join-Path ([IO.Path]::GetDirectoryName($ConfigPath)) 'ntfy-codex.log'
function Write-DeliveryLog {
    param([string]$Text)
    try {
        $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'), $Text
        Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    } catch { }
}
function Read-TextOption {
    param([object]$Settings, [string]$Key, [string]$Fallback)
    $entry = $Settings.PSObject.Properties[$Key]
    if ($null -ne $entry -and -not [string]::IsNullOrWhiteSpace([string]$entry.Value)) { return [string]$entry.Value }
    return $Fallback
}
if ($Event -eq 'startup') { Write-DeliveryLog 'startup-ready'; return }
if ($Event -eq 'input') { Write-DeliveryLog 'input-hook-start' }
try {
    $settings = [IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json
    $server = (Read-TextOption $settings 'server' 'https://ntfy.sh').TrimEnd('/')
    $topic = Read-TextOption $settings 'topic' ''
    $endpoint = $null
    if (-not [Uri]::TryCreate($server, [UriKind]::Absolute, [ref]$endpoint) -or $endpoint.Scheme -notin @('http', 'https') -or $endpoint.UserInfo) { throw 'Invalid server address' }
    if ($topic -notmatch '^[A-Za-z0-9_-]{1,64}$') { throw 'Invalid topic name' }
    switch ($Event) {
        'done' {
            $title = Read-TextOption $settings 'title' 'Codex 任务已完成'
            $summary = 'Codex 已完成这一轮任务，你可以回来查看结果。'
            $tags = Read-TextOption $settings 'tags' 'computer,white_check_mark'
        }
        'input' {
            $title = Read-TextOption $settings 'inputTitle' 'Codex 等待你回答'
            $summary = 'Codex 正在等待你选择或回答，请返回电脑处理。'
            $tags = Read-TextOption $settings 'inputTags' 'computer,question'
        }
        'test' {
            $title = Read-TextOption $settings 'testTitle' 'Codex 通知测试'
            $summary = '这是一条测试通知。收到它，说明电脑到手机的发送通道可用。'
            $tags = 'computer,test_tube'
        }
    }
    $priorityNames = @{ min = 1; low = 2; default = 3; high = 4; max = 5 }
    $priorityText = Read-TextOption $settings 'priority' 'default'
    $priority = 0
    if ($priorityNames.ContainsKey($priorityText)) {
        $priority = $priorityNames[$priorityText]
    } elseif (-not [int]::TryParse($priorityText, [ref]$priority) -or $priority -lt 1 -or $priority -gt 5) { throw 'Invalid priority' }
    $computer = $env:COMPUTERNAME
    if ([string]::IsNullOrWhiteSpace($computer)) { $computer = '这台电脑' }
    $message = @($summary, ('电脑：' + $computer), ('时间：' + (Get-Date -Format 'yyyy-MM-dd    HH:mm:ss'))) -join [Environment]::NewLine
    $payload = [ordered]@{
        topic = $topic
        title = $title
        message = $message
        priority = $priority
        tags = @($tags.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    # 默认不提供 click，点击推送时由 ntfy 自己处理。
    $click = Read-TextOption $settings 'click' ''
    if ($click) { $payload.click = $click }
    $headers = @{}
    $authorization = Read-TextOption $settings 'authorization' ''
    if ($authorization) { $headers.Authorization = $authorization }
    # 使用 JSON 和明确的 UTF-8 字节，避免 Windows PowerShell 5 的中文标题乱码。
    $json = ConvertTo-Json -InputObject $payload -Depth 8 -Compress
    $request = @{
        Method = 'Post'
        Uri = $server + '/'
        Headers = $headers
        Body = [Text.Encoding]::UTF8.GetBytes($json)
        ContentType = 'application/json; charset=utf-8'
        TimeoutSec = 8
    }
    $result = Invoke-RestMethod @request
    if ($null -eq $result.PSObject.Properties['id'] -or $result.event -ne 'message') { throw 'Unexpected ntfy response' }
    Write-DeliveryLog ('sent/{0}: id={1}' -f $Event, $result.id)
    if ($Strict) { Write-Host ('通知已发送：' + $title) }
} catch {
    # 不把 token、主题名或服务器错误正文写到日志里，默认不阻止 Codex。
    Write-DeliveryLog ('error/{0}: {1}' -f $Event, $_.Exception.GetType().Name)
    if ($Strict) { throw ('通知发送失败，请检查配置和网络。日志：' + $logFile) }
}
