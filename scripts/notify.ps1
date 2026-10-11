#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('done', 'input', 'test', 'startup')]
    [string]$Event = 'done',
    [string]$ConfigPath = '',
    [ValidateSet('all', 'ntfy', 'wechat')]
    [string]$Channel = 'all',
    [switch]$Strict
)
$ErrorActionPreference = 'Stop'
# 安装后独立运行；不依赖仓库中的其他文件。
$notifierDirectory = $env:CODEX_HOME
if ([string]::IsNullOrWhiteSpace($notifierDirectory)) { $notifierDirectory = Join-Path $env:USERPROFILE '.codex' }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $notifierDirectory 'ntfy-codex.json' }
$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
$configurationDirectory = [IO.Path]::GetDirectoryName($ConfigPath)
$logFile = Join-Path $configurationDirectory 'ntfy-codex.log'
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
function Read-WechatToken {
    # Windows DPAPI 只允许同一台电脑、同一 Windows 用户解密。
    $tokenFile = Join-Path $configurationDirectory 'pushplus-token.dpapi'
    if (-not [IO.File]::Exists($tokenFile)) { throw 'WechatTokenMissing' }
    $protectedToken = [IO.File]::ReadAllText($tokenFile).Trim() | ConvertTo-SecureString
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($protectedToken)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer).Trim() }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer); $protectedToken.Dispose() }
}
function Reserve-WechatRequest {
    param([switch]$Suspend)
    # 两个 Codex 会话也共享每分钟最多五次请求的限制；不睡眠、不重试。
    $stateFile = Join-Path $configurationDirectory 'wechat-send-state.json'
    $hashProvider = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($hashProvider.ComputeHash([Text.Encoding]::UTF8.GetBytes($ConfigPath.ToLowerInvariant()))).Replace('-', '') }
    finally { $hashProvider.Dispose() }
    $gate = [Threading.Mutex]::new($false, ('Local\CodexPhoneWechat-' + $hash))
    $held = $false
    try {
        try { $held = $gate.WaitOne(500) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { return 'busy' }
        $state = [pscustomobject]@{ attempts=@(); blockedUntil=0 }
        if ([IO.File]::Exists($stateFile)) { $state = [IO.File]::ReadAllText($stateFile) | ConvertFrom-Json }
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ($Suspend) {
            $state.blockedUntil = ([DateTimeOffset]((Get-Date).Date.AddDays(1))).ToUnixTimeSeconds()
            [IO.File]::WriteAllText($stateFile, ($state | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
            return ''
        }
        if ($state.blockedUntil -gt $now) { return 'blocked' }
        $recent = @($state.attempts | Where-Object { [long]$_ -gt ($now - 60) })
        if ($recent.Count -ge 5) { return 'rate-limit' }
        $state.attempts = @($recent) + @($now)
        [IO.File]::WriteAllText($stateFile, ($state | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        return ''
    } finally {
        if ($held) { $gate.ReleaseMutex() }
        $gate.Dispose()
    }
}
function Suspend-WechatRequests {
    # 与请求计数共用锁；收到 900 后，当天暂停微信，ntfy 照常。
    try { Reserve-WechatRequest -Suspend | Out-Null } catch { }
}
if ($Event -eq 'startup') { Write-DeliveryLog 'startup-ready'; return }
if ($Event -eq 'input') { Write-DeliveryLog 'input-hook-start' }
try {
    $settings = [IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json
    $channels = @('ntfy')
    if ($Channel -ne 'all') { $channels = @($Channel) }
    elseif ($null -ne $settings.PSObject.Properties['channels']) {
        $channels = @($settings.channels | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Select-Object -Unique)
    }
    if ($channels.Count -eq 0 -or @($channels | Where-Object { $_ -notin @('ntfy', 'wechat') }).Count -gt 0) { throw 'Invalid notification channels' }
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
    $computer = $env:COMPUTERNAME
    if ([string]::IsNullOrWhiteSpace($computer)) { $computer = '这台电脑' }
    $message = @($summary, ('电脑：' + $computer), ('时间：' + (Get-Date -Format 'yyyy-MM-dd    HH:mm:ss'))) -join [Environment]::NewLine
} catch {
    Write-DeliveryLog ('error/{0}: {1}' -f $Event, $_.Exception.GetType().Name)
    if ($Strict) { throw ('通知配置无法读取，请检查：' + $ConfigPath) }
    return
}
$failures = @()
# 双通道各最多四秒，避免超过现有钩子的十五秒上限。
$timeoutSeconds = 8
if ($channels.Count -gt 1) { $timeoutSeconds = 4 }
foreach ($deliveryChannel in $channels) {
    $hint = '请检查配置和网络。'
    $failureLabel = ''
    try {
        if ($deliveryChannel -eq 'ntfy') {
            $server = (Read-TextOption $settings 'server' 'https://ntfy.sh').TrimEnd('/')
            $topic = Read-TextOption $settings 'topic' ''
            $endpoint = $null
            if (-not [Uri]::TryCreate($server, [UriKind]::Absolute, [ref]$endpoint) -or $endpoint.Scheme -notin @('http', 'https') -or $endpoint.UserInfo) { throw 'Invalid server address' }
            if ($topic -notmatch '^[A-Za-z0-9_-]{1,64}$') { throw 'Invalid topic name' }
            $priorityNames = @{ min=1; low=2; default=3; high=4; max=5 }
            $priorityText = Read-TextOption $settings 'priority' 'default'
            $priority = 0
            if ($priorityNames.ContainsKey($priorityText)) { $priority = $priorityNames[$priorityText] }
            elseif (-not [int]::TryParse($priorityText, [ref]$priority) -or $priority -lt 1 -or $priority -gt 5) { throw 'Invalid priority' }
            $payload = [ordered]@{ topic=$topic; title=$title; message=$message; priority=$priority; tags=@($tags.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
            $click = Read-TextOption $settings 'click' ''
            if ($click) { $payload.click = $click }
            $headers = @{}
            $authorization = Read-TextOption $settings 'authorization' ''
            if ($authorization) { $headers.Authorization = $authorization }
            $request = @{ Method='Post'; Uri=$server+'/'; Headers=$headers; Body=[Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 8 -Compress)); ContentType='application/json; charset=utf-8'; TimeoutSec=$timeoutSeconds }
            $result = Invoke-RestMethod @request
            if ($null -eq $result.PSObject.Properties['id'] -or $result.event -ne 'message') { throw 'Unexpected ntfy response' }
            Write-DeliveryLog ('sent/{0}: id={1}' -f $Event, $result.id)
            if ($Strict) { Write-Host ('ntfy 通知已发送：' + $title) }
        } else {
            $hint = '请检查 PushPlus 登录、公众号关注、实名状态及密钥。'
            $token = Read-WechatToken
            if ([string]::IsNullOrWhiteSpace($token)) { throw 'Empty Wechat token' }
            $skipReason = Reserve-WechatRequest
            if ($skipReason) {
                $failureLabel = $skipReason
                $hint = '微信请求暂缓：每分钟最多五次；账号受限时暂停到次日。不要连续重试。'
                throw 'Wechat request paused'
            }
            # 不填写 topic 或 to；只发送给密钥所属的用户，不向群组或好友发消息。
            $payload = [ordered]@{ token=$token; title=$title; content=$message; template='txt'; channel='wechat' }
            $request = @{ Method='Post'; Uri='https://www.pushplus.plus/send'; Headers=@{}; Body=[Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress)); ContentType='application/json; charset=utf-8'; TimeoutSec=$timeoutSeconds }
            $result = Invoke-RestMethod @request
            $token = $null
            if ($null -eq $result -or $null -eq $result.PSObject.Properties['code']) { throw 'Unexpected PushPlus response' }
            if ([int]$result.code -ne 200) {
                $failureLabel = 'api_code=' + [int]$result.code
                switch ([int]$result.code) {
                    905 { $hint = 'PushPlus 尚未完成实名认证。' }
                    903 { $hint = 'PushPlus 密钥无效，请重新运行 enable-wechat.ps1 填写。' }
                    900 { Suspend-WechatRequests; $hint = 'PushPlus 账号受限，已暂停今天的微信请求。请在官网检查额度或账号状态。' }
                }
                throw 'PushPlus rejected request'
            }
            $receipt = [string]$result.data
            if ($receipt -notmatch '^[A-Za-z0-9_-]{1,128}$') { throw 'Missing PushPlus receipt' }
            # 200 只代表收到了请求；不能记作手机已收到。
            Write-DeliveryLog ('queued/{0}/wechat: id={1}' -f $Event, $receipt)
            if ($Strict) { Write-Host ('微信推送请求已提交：' + $title + '。请以手机和手环实际收到为准。') }
        }
    } catch {
        $token = $null
        if (-not $failureLabel) { $failureLabel = $_.Exception.GetType().Name }
        # 不记录密钥、主题、服务器返回正文或异常中的 URL。
        Write-DeliveryLog ('error/{0}/{1}: {2}' -f $Event, $deliveryChannel, $failureLabel)
        $failures += $deliveryChannel + '：' + $hint
    }
}
if ($Strict -and $failures.Count -gt 0) { throw ($failures -join [Environment]::NewLine) }
