#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('done', 'input', 'approval', 'test', 'startup')]
    [string]$Event = 'done',
    [string]$ConfigPath = '',
    [ValidateSet('all', 'ntfy', 'wechat')]
    [string]$Channel = 'all',
    [switch]$Strict,
    [object]$HookInput = $null
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
function Get-NotifierDigest {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Read-TranscriptContext {
    param([object]$InputObject, [switch]$Completion)
    $answer = [pscustomobject]@{ main=$false; known=$false; final=$false; session=''; turn=''; reason='missing-transcript' }
    $path = [string]$InputObject.transcript_path
    if (-not $path -or -not [IO.File]::Exists($path)) { return $answer }
    try {
        # Codex 正在写入会话文件；共享读写，绝不锁住它。
        $stream = [IO.File]::Open($path, 'Open', 'Read', [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        $reader = [IO.StreamReader]::new($stream)
        try { $first = $reader.ReadLine() | ConvertFrom-Json } finally { $reader.Dispose() }
        if ($first.type -ne 'session_meta') { $answer.reason='unknown-transcript'; return $answer }
        $meta = $first.payload
        $answer.known=$true; $answer.session=[string]$meta.id
        if ($meta.parent_thread_id -or ($meta.thread_source -and [string]$meta.thread_source -ne 'user') -or ($meta.source -isnot [string]) -or [string]$meta.source -notin @('vscode','cli','desktop')) {
            $answer.reason='background-session'; return $answer
        }
        $answer.main=$true
        if (-not $Completion) { return $answer }
        if ($InputObject.session_id -and [string]$InputObject.session_id -ne $answer.session) { $answer.reason='session-mismatch'; return $answer }
        # 只读末尾 1 MiB；会话格式不认识时宁可不报完成，避免把思考过程当结果。
        $stream = [IO.File]::Open($path, 'Open', 'Read', [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        $offset = [Math]::Max(0, $stream.Length - 1048576)
        $null = $stream.Seek($offset, [IO.SeekOrigin]::Begin)
        $reader = [IO.StreamReader]::new($stream)
        $phase=''; $turn=''; $completed=$false; $aborted=$false
        try {
            if ($offset -gt 0) { $null = $reader.ReadLine() }
            while ($null -ne ($line=$reader.ReadLine())) {
                try { $record=$line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
                $p=$record.payload
                if ($record.type -eq 'turn_context' -and $p.turn_id) { $turn=[string]$p.turn_id }
                if ($record.type -eq 'event_msg') {
                    if ($p.type -eq 'task_started') { $turn=[string]$p.turn_id; $phase=''; $completed=$false; $aborted=$false }
                    elseif ($p.type -eq 'turn_aborted') { $aborted=$true }
                    elseif ($p.type -eq 'task_complete') { $turn=[string]$p.turn_id; $completed=$true }
                    elseif ($p.type -eq 'item_completed') {
                        if ($p.turn_id) { $turn=[string]$p.turn_id }
                        if ($p.item.type -eq 'AgentMessage') { $phase=[string]$p.item.phase }
                    }
                }
                if ($record.type -eq 'response_item') {
                    if ($p.type -eq 'message' -and $p.role -eq 'assistant') {
                        $phase=[string]$p.phase
                        if (-not $phase) { $phase=[string]$p.channel }
                    } elseif ($p.type -in @('function_call','custom_tool_call')) { $phase='tool'; $completed=$false }
                }
            }
        } finally { $reader.Dispose() }
        $answer.turn=$turn
        if (-not $turn -or ($InputObject.turn_id -and [string]$InputObject.turn_id -ne $turn)) { $answer.reason='turn-mismatch'; return $answer }
        if ($aborted) { $answer.reason='turn-interrupted'; return $answer }
        if ($phase -notin @('final','final_answer') -and -not $completed) { $answer.reason='not-final-answer'; return $answer }
        if (-not $completed) { $answer.reason='awaiting-completion'; return $answer }
        $answer.final=$true; $answer.reason='final-answer'; return $answer
    } catch { $answer.reason='transcript-unavailable'; return $answer }
}
function Set-EventReservation {
    param([string]$Key, [ValidateSet('reserve','sent','release')][string]$Action)
    if (-not $Key) { return $true }
    $stateFile=Join-Path $configurationDirectory 'notifier-event-state.json'
    $gate=[Threading.Mutex]::new($false, ('Local\CodexPhoneEvents-' + (Get-NotifierDigest $ConfigPath.ToLowerInvariant())))
    $held=$false
    try {
        try { $held=$gate.WaitOne(500) } catch [Threading.AbandonedMutexException] { $held=$true }
        if (-not $held) { return $false }
        $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $entries=@()
        if ([IO.File]::Exists($stateFile)) {
            $state=[IO.File]::ReadAllText($stateFile) | ConvertFrom-Json
            $entries=@($state.entries | Where-Object { ($_.status -eq 'sent' -and [long]$_.at -gt $now-86400) -or ($_.status -eq 'pending' -and [long]$_.at -gt $now-30) })
        }
        $existing=@($entries | Where-Object { $_.key -eq $Key })
        if ($Action -eq 'reserve') {
            if ($existing.Count -gt 0) { return $false }
            $entries+= [pscustomobject]@{key=$Key;at=$now;status='pending';owner=$eventOwner}
        } else {
            $owned=@($existing | Where-Object { $_.owner -eq $eventOwner })
            if ($owned.Count -eq 0) { return $false }
            $entries=@($entries | Where-Object { $_.key -ne $Key })
            if ($Action -eq 'sent') { $entries+=[pscustomobject]@{key=$Key;at=$now;status='sent';owner=''} }
        }
        $entries=@($entries | Sort-Object at -Descending | Select-Object -First 256)
        [IO.File]::WriteAllText($stateFile, ([pscustomobject]@{entries=$entries} | ConvertTo-Json -Depth 5 -Compress), [Text.UTF8Encoding]::new($false))
        return $true
    } catch { Write-DeliveryLog 'event-state-unavailable'; return $false }
    finally { if ($held) { $gate.ReleaseMutex() }; $gate.Dispose() }
}
# Hook stdin 只在本机解析，不写入日志或手机消息，尤其不泄漏 tool_input。
$eventKey=''; $eventOwner=[guid]::NewGuid().ToString('N')
if ($Event -notin @('startup','test')) {
    if ($null -eq $HookInput -and [Console]::IsInputRedirected) {
        $raw=[Console]::In.ReadToEnd()
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            try { $HookInput=$raw | ConvertFrom-Json -ErrorAction Stop }
            catch { Write-DeliveryLog ('skip/{0}: invalid-hook-input' -f $Event); return }
        }
    }
    if ($null -ne $HookInput) {
        if ($Event -eq 'input' -and [string]$HookInput.tool_name -match '(^|[._])request_permissions$') { $Event='approval' }
        $context=Read-TranscriptContext $HookInput -Completion:($Event -eq 'done')
        # Stop 在后台运行，等主轮次真正写入 task_complete；不会阻塞 Codex。
        for ($attempt=0; $Event -eq 'done' -and $context.reason -eq 'awaiting-completion' -and $attempt -lt 20; $attempt++) {
            Start-Sleep -Milliseconds 250
            $context=Read-TranscriptContext $HookInput -Completion
        }
        if ($Event -eq 'done' -and -not $context.final) { Write-DeliveryLog ('skip/done: ' + $context.reason); return }
        if ($Event -ne 'done' -and $context.known -and -not $context.main) { Write-DeliveryLog ('skip/{0}: background-session' -f $Event); return }
        $session=[string]$HookInput.session_id; $turn=[string]$HookInput.turn_id
        if ($Event -eq 'done') { $session=$context.session; $turn=$context.turn }
        if ($session -and $turn) {
            $identity=$Event+'|'+$session+'|'+$turn
            if ($Event -eq 'input') {
                if ($HookInput.tool_use_id) { $identity+='|'+[string]$HookInput.tool_use_id }
                else { $identity+='|'+($HookInput.tool_input | ConvertTo-Json -Depth 20 -Compress) }
            }
            if ($Event -eq 'approval') { $identity+='|'+[string]$HookInput.tool_name+'|'+($HookInput.tool_input | ConvertTo-Json -Depth 20 -Compress) }
            $eventKey=Get-NotifierDigest $identity
        }
    } elseif ($Event -eq 'done' -and -not $Strict) {
        Write-DeliveryLog 'skip/done: missing-hook-input'; return
    }
}
if ($Event -eq 'startup') { Write-DeliveryLog 'startup-ready'; return }
if ($Event -eq 'input') { Write-DeliveryLog 'input-hook-start' }
if ($Event -eq 'approval') { Write-DeliveryLog 'approval-hook-start' }
try {
    $settings = [IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json
    $channels = @('ntfy')
    if ($Channel -ne 'all') { $channels = @($Channel) }
    elseif ($null -ne $settings.PSObject.Properties['channels']) {
        $channels = @($settings.channels | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Select-Object -Unique)
    }
    if (@($channels | Where-Object { $_ -notin @('ntfy', 'wechat') }).Count -gt 0) { throw 'Invalid notification channels' }
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
        'approval' {
            $title = Read-TextOption $settings 'approvalTitle' 'Codex 等待你授权'
            $summary = 'Codex 正在等待你确认工具或插件的访问权限，请返回电脑处理。'
            $tags = 'computer,lock'
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
if ($channels.Count -eq 0) {
    Write-DeliveryLog 'notifications-paused'
    if ($Strict) { throw '所有通知渠道已关闭，请先启用 ntfy 或微信。' }
    return
}
$failures = @()
# 双通道各最多四秒，避免超过现有钩子的十五秒上限。
$timeoutSeconds = 8
if ($channels.Count -gt 1) { $timeoutSeconds = 4 }
foreach ($deliveryChannel in $channels) {
    $deliveryKey=''; if ($eventKey) { $deliveryKey=Get-NotifierDigest ($eventKey+'|'+$deliveryChannel) }
    if (-not (Set-EventReservation $deliveryKey 'reserve')) { Write-DeliveryLog ('skip/{0}/{1}: duplicate-or-busy' -f $Event,$deliveryChannel); continue }
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
            $null=Set-EventReservation $deliveryKey 'sent'
            Write-DeliveryLog ('sent/{0}: id={1}' -f $Event, $result.id)
            if ($Strict) { Write-Host ('ntfy 通知已发送：' + $title) }
        } else {
            $hint = '请检查 PushPlus 实名、密钥和微信 ClawBot 绑定激活状态；每十条消息及每二十四小时需要主动对话一次。'
            $token = Read-WechatToken
            if ([string]::IsNullOrWhiteSpace($token)) { throw 'Empty Wechat token' }
            $skipReason = Reserve-WechatRequest
            if ($skipReason) {
                $failureLabel = $skipReason
                $hint = '微信请求暂缓：每分钟最多五次；账号受限时暂停到次日。不要连续重试。'
                throw 'Wechat request paused'
            }
            # 不填写 topic 或 to；只发送给密钥所属的用户，不向群组或好友发消息。
            $payload = [ordered]@{ token=$token; title=$title; content=$message; template='txt'; channel='clawbot' }
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
            $null=Set-EventReservation $deliveryKey 'sent'
            Write-DeliveryLog ('queued/{0}/wechat: channel=clawbot id={1}' -f $Event, $receipt)
            if ($Strict) { Write-Host ('微信 ClawBot 聊天推送请求已提交：' + $title + '。请以手机和手环实际收到为准。') }
        }
    } catch {
        $token = $null
        $null=Set-EventReservation $deliveryKey 'release'
        if (-not $failureLabel) { $failureLabel = $_.Exception.GetType().Name }
        # 不记录密钥、主题、服务器返回正文或异常中的 URL。
        Write-DeliveryLog ('error/{0}/{1}: {2}' -f $Event, $deliveryChannel, $failureLabel)
        $failures += $deliveryChannel + '：' + $hint
    }
}
if ($Strict -and $failures.Count -gt 0) { throw ($failures -join [Environment]::NewLine) }
