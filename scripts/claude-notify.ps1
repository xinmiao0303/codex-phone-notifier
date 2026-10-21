#requires -Version 5.1
[CmdletBinding()]
param(
    # hook：从标准输入读取 Claude Code 的钩子数据并自动判断；其余值用于手动预览或测试。
    [ValidateSet('hook', 'done', 'input', 'plan', 'approval', 'error', 'idle', 'test')]
    [string]$Event = 'hook',
    [string]$ConfigPath = '',
    [ValidateSet('all', 'ntfy', 'wechat')]
    [string]$Channel = 'all',
    [switch]$Strict,
    [object]$HookInput = $null,
    # 图形界面用：按当前配置发一条带“预览”前缀的消息；或只列出默认标题与正文。
    [switch]$Preview,
    [switch]$ListContent
)
$ErrorActionPreference = 'Stop'
# 每类提醒的默认标题与正文。配置里的同名键覆盖它们；正文中的占位符发送时替换。
$templates = [ordered]@{
    done = [ordered]@{ label='任务完成'; hint='Claude Code 完成这一轮回复时发送。{后台} 只在还有后台命令运行时有内容。'; titleKey='title'; bodyKey='body'; title='Claude Code 任务已完成'; body="Claude Code 已完成这一轮任务，你可以回来查看结果。`n{后台}`n电脑：{电脑}`n时间：{时间}"; placeholders=@('电脑','时间','项目','后台'); legacy=@() }
    input = [ordered]@{ label='等待回答'; hint='弹出选择题或 MCP 输入表单时发送。'; titleKey='inputTitle'; bodyKey='inputBody'; title='Claude Code 等待你回答'; body="Claude Code 正在等待你选择或回答，请返回电脑处理。`n电脑：{电脑}`n时间：{时间}"; placeholders=@('电脑','时间','项目'); legacy=@() }
    plan = [ordered]@{ label='确认计划'; hint='计划模式写好计划、等你批准时发送。'; titleKey='planTitle'; bodyKey='planBody'; title='Claude Code 等待你确认计划'; body="Claude Code 已写好执行计划，正在等待你批准或修改。`n电脑：{电脑}`n时间：{时间}"; placeholders=@('电脑','时间','项目'); legacy=@() }
    approval = [ordered]@{ label='等待授权'; hint='请求工具权限、约 6 秒仍未答复时发送。'; titleKey='approvalTitle'; bodyKey='approvalBody'; title='Claude Code 等待你授权'; body="Claude Code 请求使用工具的权限，几秒内仍未答复，请返回电脑查看授权窗口。`n电脑：{电脑}`n时间：{时间}"; placeholders=@('电脑','时间','项目'); legacy=@() }
    error = [ordered]@{ label='出错停止'; hint='因限流、登录失效等 API 错误中断时发送。{原因} 是错误类型的中文说明。'; titleKey='errorTitle'; bodyKey='errorBody'; title='Claude Code 出错停止'; body="Claude Code 这一轮因错误中断，需要你回来查看。`n原因：{原因}`n电脑：{电脑}`n时间：{时间}"; placeholders=@('电脑','时间','项目','原因'); legacy=@() }
    idle = [ordered]@{ label='仍在等你'; hint='回复完约 60 秒仍无操作时发送；需要安装时加 -IdleReminder 开启。'; titleKey='idleTitle'; bodyKey='idleBody'; title='Claude Code 仍在等你'; body="Claude Code 完成回复约一分钟后，仍在等待你的下一条指令。`n电脑：{电脑}`n时间：{时间}"; placeholders=@('电脑','时间','项目'); legacy=@() }
    # 测试只验证渠道，Codex 与 Claude Code 共用；旧版默认标题按新默认处理。
    test = [ordered]@{ label='通知测试'; hint='点击测试按钮时发送，Codex 与 Claude Code 共用。'; titleKey='testTitle'; bodyKey='testBody'; title='手机提醒测试'; body="这是一条测试通知。收到它，说明电脑到手机的发送通道可用。`n电脑：{电脑}`n时间：{时间}"; placeholders=@('电脑','时间'); legacy=@('Codex 通知测试','Claude Code 通知测试') }
}
if ($ListContent) { return $templates }
try { [Console]::InputEncoding = [Text.UTF8Encoding]::new($false) } catch { }
# 安装后独立运行；不依赖仓库中的其他文件。
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot 'config.json' }
$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
$configurationDirectory = [IO.Path]::GetDirectoryName($ConfigPath)
$logFile = Join-Path $configurationDirectory 'notifier.log'
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
function Format-NotifierText {
    param([string]$Template, [hashtable]$Values, [switch]$Title)
    # 替换占位符；正文里某一行的占位符全部为空时整行省略。标题只替换，不省略。
    $pattern = '\{(电脑|时间|项目|原因|后台)\}'
    $lines = @()
    foreach ($line in ($Template -replace "`r`n", "`n").Split("`n")) {
        $found = @([regex]::Matches($line, $pattern) | ForEach-Object { $_.Groups[1].Value })
        if (-not $Title -and $found.Count -gt 0 -and @($found | Where-Object { $Values[$_] }).Count -eq 0) { continue }
        $lines += [regex]::Replace($line, $pattern, { param($match) [string]$Values[$match.Groups[1].Value] })
    }
    if ($Title) { return ($lines -join ' ').Trim() }
    return ($lines -join [Environment]::NewLine).Trim()
}
function Read-SwitchOption {
    param([object]$Settings, [string]$Key)
    $entry = $Settings.PSObject.Properties[$Key]
    return ($null -ne $entry -and $entry.Value -eq $true)
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
function Get-NotifierDigest {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Reserve-WechatRequest {
    param([switch]$Suspend)
    # 多个 Claude Code 会话共享每分钟最多五次请求的限制；不睡眠、不重试。
    $stateFile = Join-Path $configurationDirectory 'wechat-send-state.json'
    $gate = [Threading.Mutex]::new($false, ('Local\ClaudePhoneWechat-' + (Get-NotifierDigest $ConfigPath.ToLowerInvariant())))
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
function Set-EventReservation {
    param([string]$Key, [ValidateSet('reserve','sent','release','recent')][string]$Action, [string]$Tag = '', [int]$Seconds = 0)
    if (-not $Key -and $Action -ne 'recent') { return $true }
    $stateFile = Join-Path $configurationDirectory 'event-state.json'
    $gate = [Threading.Mutex]::new($false, ('Local\ClaudePhoneEvents-' + (Get-NotifierDigest $ConfigPath.ToLowerInvariant())))
    $held = $false
    try {
        try { $held = $gate.WaitOne(500) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { return $false }
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $entries = @()
        if ([IO.File]::Exists($stateFile)) {
            $state = [IO.File]::ReadAllText($stateFile) | ConvertFrom-Json
            $entries = @($state.entries | Where-Object { $null -ne $_ -and (($_.status -eq 'sent' -and [long]$_.at -gt $now - 86400) -or ($_.status -eq 'pending' -and [long]$_.at -gt $now - 30)) })
        }
        if ($Action -eq 'recent') {
            # 只回答“这个会话最近是否刚发过某类提醒”，不修改状态。
            return (@($entries | Where-Object { $_.tag -eq $Tag -and [long]$_.at -gt $now - $Seconds }).Count -gt 0)
        }
        $existing = @($entries | Where-Object { $_.key -eq $Key })
        if ($Action -eq 'reserve') {
            if ($existing.Count -gt 0) { return $false }
            $entries += [pscustomobject]@{ key=$Key; at=$now; status='pending'; owner=$eventOwner; tag=$Tag }
        } else {
            $owned = @($existing | Where-Object { $_.owner -eq $eventOwner })
            if ($owned.Count -eq 0) { return $false }
            $entries = @($entries | Where-Object { $_.key -ne $Key })
            if ($Action -eq 'sent') { $entries += [pscustomobject]@{ key=$Key; at=$now; status='sent'; owner=''; tag=$Tag } }
        }
        $entries = @($entries | Sort-Object at -Descending | Select-Object -First 256)
        [IO.File]::WriteAllText($stateFile, ([pscustomobject]@{ entries=$entries } | ConvertTo-Json -Depth 5 -Compress), [Text.UTF8Encoding]::new($false))
        return $true
    } catch { Write-DeliveryLog 'event-state-unavailable'; return $false }
    finally { if ($held) { $gate.ReleaseMutex() }; $gate.Dispose() }
}
function Get-PendingTool {
    param([string]$Path)
    # 授权通知不带工具编号；从会话记录末尾找出还没有结果的那次工具调用。
    if (-not $Path -or -not [IO.File]::Exists($Path)) { return $null }
    try {
        # Claude Code 正在写入会话文件；共享读写，绝不锁住它。
        $stream = [IO.File]::Open($Path, 'Open', 'Read', [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        $offset = [Math]::Max(0, $stream.Length - 1048576)
        $null = $stream.Seek($offset, [IO.SeekOrigin]::Begin)
        $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false))
        $calls = [Collections.Specialized.OrderedDictionary]::new()
        try {
            if ($offset -gt 0) { $null = $reader.ReadLine() }
            while ($null -ne ($line = $reader.ReadLine())) {
                if ($line.IndexOf('"tool_use', [StringComparison]::Ordinal) -lt 0) { continue }
                try { $record = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
                if ([string]$record.type -notin @('assistant', 'user')) { continue }
                foreach ($part in @($record.message.content)) {
                    if ($null -eq $part) { continue }
                    if ($part.type -eq 'tool_use' -and $part.id) { $calls[[string]$part.id] = [string]$part.name }
                    elseif ($part.type -eq 'tool_result' -and $part.tool_use_id) { $calls.Remove([string]$part.tool_use_id) }
                }
            }
        } finally { $reader.Dispose() }
        if ($calls.Count -eq 0) { return $null }
        $id = @($calls.Keys)[-1]
        return [pscustomobject]@{ id=[string]$id; name=[string]$calls[$id] }
    } catch { return $null }
}
$errorNames = @{
    rate_limit = '达到速率或用量限制'; overloaded = '服务繁忙'; authentication_failed = '登录已失效'
    oauth_org_not_allowed = '当前组织不允许此登录'; account_on_hold = '账号受限'; billing_error = '账单或额度问题'
    invalid_request = '请求无效'; model_not_found = '找不到所选模型'; server_error = '服务器错误'
    max_output_tokens = '输出长度达到上限'; cloud_credential_error = '云服务凭证错误'
}
# Hook 标准输入只在本机解析，不写入日志或手机消息，尤其不泄漏 tool_input 和回复正文。
$eventKey = ''; $eventTag = ''; $eventOwner = [guid]::NewGuid().ToString('N')
$kind = $Event; $backgroundNote = ''; $errorReason = ''
try {
    $settings = [IO.File]::ReadAllText($ConfigPath).TrimStart([char]0xFEFF) | ConvertFrom-Json
} catch {
    Write-DeliveryLog ('error/{0}: config-unavailable {1}' -f $Event, $_.Exception.GetType().Name)
    if ($Strict) { throw ('通知配置无法读取，请检查：' + $ConfigPath) }
    return
}
# 图形界面关闭 Claude Code 提醒时保留钩子，这里静默返回；手动测试不受影响。
if ($Event -ne 'test' -and -not $Preview -and $null -ne $settings.PSObject.Properties['enabled'] -and $settings.enabled -eq $false) {
    Write-DeliveryLog ('skip/{0}: reminders-off' -f $Event); return
}
if ($Event -eq 'hook') {
    if ($null -eq $HookInput -and [Console]::IsInputRedirected) {
        $raw = [Console]::In.ReadToEnd()
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            try { $HookInput = $raw.TrimStart([char]0xFEFF) | ConvertFrom-Json -ErrorAction Stop }
            catch { Write-DeliveryLog ('skip/hook: invalid-hook-input length={0} error={1}' -f $raw.Length, $_.Exception.GetType().Name); return }
        }
    }
    if ($null -eq $HookInput) { Write-DeliveryLog 'skip/hook: missing-hook-input'; return }
    $hookName = [string]$HookInput.hook_event_name
    $kind = ''
    switch ($hookName) {
        'Stop' { $kind = 'done' }
        'StopFailure' { $kind = 'error' }
        'PreToolUse' {
            if ([string]$HookInput.tool_name -eq 'AskUserQuestion') { $kind = 'input' }
            elseif ([string]$HookInput.tool_name -eq 'ExitPlanMode') { $kind = 'plan' }
        }
        'Notification' {
            switch ([string]$HookInput.notification_type) {
                'permission_prompt' { $kind = 'approval' }
                'elicitation_dialog' { $kind = 'input' }
                'elicitation_url_dialog' { $kind = 'input' }
                'idle_prompt' { $kind = 'idle' }
            }
        }
    }
    if (-not $kind) { Write-DeliveryLog ('skip/hook: unsupported {0}' -f $hookName); return }
    # 脚本化的 claude -p / SDK 调用和无人值守会话不是“需要你回来看”的场景。
    if (-not (Read-SwitchOption $settings 'includeHeadless')) {
        $entrypoint = [string]$env:CLAUDE_CODE_ENTRYPOINT
        if ($entrypoint -match '^(sdk-|github-action|remote)') { Write-DeliveryLog ('skip/{0}: headless-session entrypoint={1}' -f $kind, $entrypoint); return }
        if ($env:CLAUDE_CODE_SESSION_ATTENDED -eq '0') { Write-DeliveryLog ('skip/{0}: unattended-session' -f $kind); return }
    }
    $session = [string]$HookInput.session_id
    $prompt = [string]$HookInput.prompt_id
    switch ($kind) {
        'done' {
            $tasks = @($HookInput.background_tasks | Where-Object { $null -ne $_ })
            $agents = @($tasks | Where-Object { [string]$_.type -in @('subagent', 'workflow', 'teammate', 'cloud session') })
            $crons = @($HookInput.session_crons | Where-Object { $null -ne $_ })
            # 后台代理或定时唤醒还会让 Claude 自动接着做，这只是暂停，不是完成。
            if (-not (Read-SwitchOption $settings 'notifyWhilePaused')) {
                if ($agents.Count -gt 0) { Write-DeliveryLog ('skip/done: background-agents={0}' -f $agents.Count); return }
                if ($crons.Count -gt 0) { Write-DeliveryLog ('skip/done: scheduled-wakeups={0}' -f $crons.Count); return }
            }
            if ($tasks.Count -gt 0) { $backgroundNote = '后台还有 {0} 个任务在运行。' -f $tasks.Count }
            $turn = $prompt
            if (-not $turn) { $turn = Get-NotifierDigest ([string]$HookInput.last_assistant_message) }
            if ($session) { $eventKey = Get-NotifierDigest ('done|' + $session + '|' + $turn) }
        }
        'error' {
            $code = [string]$HookInput.error
            $reason = $errorNames[$code]
            if (-not $reason) { $reason = '未知错误' }
            $errorReason = $reason
            if ($session) { $eventKey = Get-NotifierDigest ('error|' + $session + '|' + $prompt + '|' + $code) }
        }
        'approval' {
            # 桌面版和 VS Code 中，提问框也可能走授权通道；按待答工具归类，避免同一问题提醒两次。
            $pending = Get-PendingTool ([string]$HookInput.transcript_path)
            if ($null -ne $pending -and $pending.name -eq 'AskUserQuestion') { $kind = 'input' }
            elseif ($null -ne $pending -and $pending.name -eq 'ExitPlanMode') { $kind = 'plan' }
            if ($null -ne $pending -and $session) { $eventKey = Get-NotifierDigest ($kind + '|' + $session + '|' + $pending.id) }
            elseif ($session -and ((Set-EventReservation '' 'recent' ($session + '|input') 20) -or (Set-EventReservation '' 'recent' ($session + '|plan') 20))) {
                Write-DeliveryLog 'skip/approval: likely-same-question'; return
            }
        }
        { $_ -in @('input', 'plan') } {
            if ($hookName -eq 'Notification') {
                if ($session) { $eventKey = Get-NotifierDigest ('input|' + $session + '|elicitation|' + $prompt + '|' + [string]$HookInput.message) }
            } elseif ($session) {
                $call = [string]$HookInput.tool_use_id
                if (-not $call) { $call = Get-NotifierDigest ($HookInput.tool_input | ConvertTo-Json -Depth 20 -Compress) }
                $eventKey = Get-NotifierDigest ($kind + '|' + $session + '|' + $call)
            }
        }
        'idle' { if ($session) { $eventKey = Get-NotifierDigest ('idle|' + $session + '|' + $prompt) } }
    }
    if ($session) { $eventTag = $session + '|' + $kind }
    if ($kind -in @('input', 'plan', 'approval')) { Write-DeliveryLog ('{0}-hook-start' -f $kind) }
} elseif ($Event -ne 'test' -and -not $Strict) {
    Write-DeliveryLog ('skip/{0}: missing-hook-input' -f $Event); return
}
try {
    $channels = @('ntfy')
    if ($Channel -ne 'all') { $channels = @($Channel) }
    elseif ($null -ne $settings.PSObject.Properties['channels']) {
        $channels = @($settings.channels | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
    }
    if (@($channels | Where-Object { $_ -notin @('ntfy', 'wechat') }).Count -gt 0) { throw 'Invalid notification channels' }
    switch ($kind) {
        'done' { $tags = Read-TextOption $settings 'tags' 'computer,white_check_mark' }
        'input' { $tags = Read-TextOption $settings 'inputTags' 'computer,question' }
        'plan' { $tags = Read-TextOption $settings 'inputTags' 'computer,question' }
        'approval' { $tags = 'computer,lock' }
        'error' { $tags = 'computer,warning' }
        'idle' { $tags = 'computer,hourglass' }
        'test' { $tags = 'computer,test_tube' }
    }
    $template = $templates[$kind]
    $title = Read-TextOption $settings $template.titleKey ''
    if ($title -in $template.legacy) { $title = '' }
    if (-not $title) { $title = $template.title }
    $body = Read-TextOption $settings $template.bodyKey ''
    if (-not $body) {
        $body = $template.body
        # 旧配置的 showProject：没有自定义正文时，在时间前加一行项目名。
        if (Read-SwitchOption $settings 'showProject') { $body = $body.Replace('时间：{时间}', "项目：{项目}`n时间：{时间}") }
    }
    $computer = $env:COMPUTERNAME
    if ([string]::IsNullOrWhiteSpace($computer)) { $computer = '这台电脑' }
    $project = ''
    if ($null -ne $HookInput -and $HookInput.cwd) { $project = [IO.Path]::GetFileName(([string]$HookInput.cwd).TrimEnd('\', '/')) }
    if ($Preview) { $project = '示例项目'; $errorReason = '达到速率或用量限制'; $backgroundNote = '后台还有 1 个任务在运行。' }
    $values = @{ '电脑'=$computer; '时间'=(Get-Date -Format 'yyyy-MM-dd    HH:mm:ss'); '项目'=$project; '原因'=$errorReason; '后台'=$backgroundNote }
    # 自定义内容替换后为空时退回默认，避免发出空白通知。
    $title = Format-NotifierText $title $values -Title
    if (-not $title) { $title = Format-NotifierText $template.title $values -Title }
    $message = Format-NotifierText $body $values
    if (-not $message) { $message = Format-NotifierText $template.body $values }
    if ($Preview) { $title = '预览 · ' + $title }
} catch {
    Write-DeliveryLog ('error/{0}: {1}' -f $kind, $_.Exception.GetType().Name)
    if ($Strict) { throw ('通知配置无法读取，请检查：' + $ConfigPath) }
    return
}
if ($channels.Count -eq 0) {
    Write-DeliveryLog 'notifications-paused'
    if ($Strict) { throw '所有通知渠道已关闭，请先启用 ntfy 或微信。' }
    return
}
$failures = @()
# 双通道各最多四秒；钩子在后台运行，不会阻塞 Claude Code。
$timeoutSeconds = 8
if ($channels.Count -gt 1) { $timeoutSeconds = 4 }
foreach ($deliveryChannel in $channels) {
    $deliveryKey = ''; if ($eventKey) { $deliveryKey = Get-NotifierDigest ($eventKey + '|' + $deliveryChannel) }
    if (-not (Set-EventReservation $deliveryKey 'reserve' $eventTag)) { Write-DeliveryLog ('skip/{0}/{1}: duplicate-or-busy' -f $kind, $deliveryChannel); continue }
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
            $request = @{ Method='Post'; Uri=$server + '/'; Headers=$headers; Body=[Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 8 -Compress)); ContentType='application/json; charset=utf-8'; TimeoutSec=$timeoutSeconds }
            $result = Invoke-RestMethod @request
            if ($null -eq $result.PSObject.Properties['id'] -or $result.event -ne 'message') { throw 'Unexpected ntfy response' }
            $null = Set-EventReservation $deliveryKey 'sent' $eventTag
            Write-DeliveryLog ('sent/{0}: id={1}' -f $kind, $result.id)
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
            $null = Set-EventReservation $deliveryKey 'sent' $eventTag
            Write-DeliveryLog ('queued/{0}/wechat: channel=clawbot id={1}' -f $kind, $receipt)
            if ($Strict) { Write-Host ('微信 ClawBot 聊天推送请求已提交：' + $title + '。请以手机和手环实际收到为准。') }
        }
    } catch {
        $token = $null
        $null = Set-EventReservation $deliveryKey 'release' $eventTag
        if (-not $failureLabel) { $failureLabel = $_.Exception.GetType().Name }
        # 不记录密钥、主题、服务器返回正文或异常中的 URL。
        Write-DeliveryLog ('error/{0}/{1}: {2}' -f $kind, $deliveryChannel, $failureLabel)
        $failures += $deliveryChannel + '：' + $hint
    }
}
if ($Strict -and $failures.Count -gt 0) { throw ($failures -join [Environment]::NewLine) }
