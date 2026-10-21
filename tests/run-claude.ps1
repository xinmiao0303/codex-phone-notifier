#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
. (Join-Path $repository 'scripts\common.ps1')
. (Join-Path $repository 'scripts\claude-common.ps1')
$script:checks = 0
function Assert-Check {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('验证失败：' + $Message) }
    $script:checks++
}
# 所有安装都使用独立临时目录，绝不操作测试者真正的 .claude 或 .codex。
$workspace = Join-Path ([IO.Path]::GetTempPath()) ('claude phone 测试-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($workspace) | Out-Null
$claudeHome = Join-Path $workspace '用户 设置\.claude'
$codexHome = Join-Path $workspace '用户 设置\.codex'
$installer = Join-Path $repository 'claude-code\install.ps1'
$uninstaller = Join-Path $repository 'claude-code\uninstall.ps1'
$notifySource = Join-Path $repository 'scripts\claude-notify.ps1'
$paths = Get-ClaudeNotifierPaths $claudeHome
$savedEnvironment = @{}
foreach ($name in @('CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_SESSION_ATTENDED')) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }
$env:CLAUDE_CODE_ENTRYPOINT = 'claude-desktop'
$env:CLAUDE_CODE_SESSION_ATTENDED = '1'
function Get-OwnedHandlers {
    param([object]$Document, [string]$Event)
    $member = $Document.hooks.PSObject.Properties[$Event]
    if ($null -eq $member) { return @() }
    return @(@($member.Value) | ForEach-Object { @($_.hooks) } | Where-Object { Test-ClaudeNotifierHandler $_ $paths.script })
}
function Get-OwnedMatcher {
    param([object]$Document, [string]$Event)
    $member = $Document.hooks.PSObject.Properties[$Event]
    if ($null -eq $member) { return $null }
    return @(@($member.Value) | Where-Object { @(@($_.hooks) | Where-Object { Test-ClaudeNotifierHandler $_ $paths.script }).Count -gt 0 })[0].matcher
}
function New-Transcript {
    param([string]$Name, [object[]]$Records)
    $file = Join-Path $workspace ($Name + '.jsonl')
    $lines = @($Records | ForEach-Object { $_ | ConvertTo-Json -Depth 10 -Compress })
    [IO.File]::WriteAllLines($file, $lines, [Text.UTF8Encoding]::new($false))
    return $file
}
function New-ToolUse { param([string]$Id, [string]$Name) [pscustomobject]@{ type='assistant'; isSidechain=$false; message=[pscustomobject]@{ role='assistant'; content=@([pscustomobject]@{ type='tool_use'; id=$Id; name=$Name; input=[pscustomobject]@{} }) } } }
function New-ToolResult { param([string]$Id) [pscustomobject]@{ type='user'; isSidechain=$false; message=[pscustomobject]@{ role='user'; content=@([pscustomobject]@{ type='tool_result'; tool_use_id=$Id; content='ok' }) } } }
$secret = '回复正文-绝不能出现在手机里-' + [guid]::NewGuid().ToString('N')
try {
    # 首次安装：独立随机主题、钩子格式正确、编码兼容两版 PowerShell。
    & $installer -ClaudeHome $claudeHome -NoImport *> $null
    $config = Read-NotifierJson $paths.config
    Assert-Check ($config.topic -match '^claude-[a-f0-9]{24}$') '首次安装生成随机主题'
    Assert-Check ($config.title -eq 'Claude Code 任务已完成' -and $config.inputTitle -eq 'Claude Code 等待你回答') '默认中文标题'
    Assert-Check (@($config.channels) -join ',' -eq 'ntfy') '默认只启用 ntfy'
    $bytes = [IO.File]::ReadAllBytes($paths.settings)
    Assert-Check (-not ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'settings.json 不能带 BOM'
    $bytes = [IO.File]::ReadAllBytes($paths.script)
    Assert-Check ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) '中文 ps1 兼容 PowerShell 5'
    $document = Read-NotifierJson $paths.settings
    foreach ($event in @('Stop', 'StopFailure', 'PreToolUse', 'Notification')) { Assert-Check (@(Get-OwnedHandlers $document $event).Count -eq 1) ('登记 ' + $event + ' 钩子') }
    $stop = @(Get-OwnedHandlers $document 'Stop')[0]
    Assert-Check ($stop.async -eq $true -and $stop.type -eq 'command') '钩子在后台运行，不阻塞 Claude'
    Assert-Check ($stop.command -like '*powershell.exe' -and @($stop.args) -contains $paths.script -and @($stop.args)[-1] -eq 'hook') '使用 exec 形式传递含空格中文的路径'
    $matcher = Get-OwnedMatcher $document 'PreToolUse'
    Assert-Check ($matcher -eq 'AskUserQuestion|ExitPlanMode') '只匹配提问与计划确认工具'
    $types = (Get-OwnedMatcher $document 'Notification').Split('|')
    Assert-Check ($types -contains 'permission_prompt' -and $types -contains 'elicitation_dialog' -and $types -notcontains 'idle_prompt') '默认提醒授权与 MCP 输入，不提醒闲置'

    # 与其他工具共存：重复安装不重复登记，不改动邻居、日期字符串和配置。
    $seed = Read-NotifierJson $paths.settings
    $foreign = [pscustomobject]@{ type='command'; command='echo other-hook' }
    $seed.hooks.Stop = @([pscustomobject]@{ hooks=@($stop, $foreign); marker='keep-me' })
    Set-NotifierProperty $seed.hooks 'PostToolUse' @([pscustomobject]@{ matcher='Bash'; hooks=@($foreign) })
    Set-NotifierProperty $seed 'model' 'opus'
    Set-NotifierProperty $seed 'cleanupNote' '2026-10-20T08:00:00Z'
    Set-NotifierProperty $seed 'permissions' ([pscustomobject]@{ allow=@('Bash(git status)') })
    Write-NotifierJson $paths.settings $seed
    $config.title = '自定义完成标题'
    $config.priority = 'high'
    Write-NotifierJson $paths.config $config
    $configHash = (Get-FileHash -LiteralPath $paths.config).Hash
    & $installer -ClaudeHome $claudeHome -NoImport *> $null
    & $installer -ClaudeHome $claudeHome -NoImport *> $null
    $after = Read-NotifierJson $paths.settings
    Assert-Check (@(Get-OwnedHandlers $after 'Stop').Count -eq 1) '重复安装不重复添加完成钩子'
    Assert-Check (@(Get-OwnedHandlers $after 'PreToolUse').Count -eq 1) '重复安装不重复添加提问钩子'
    Assert-Check (@(@($after.hooks.Stop) | ForEach-Object { @($_.hooks) } | Where-Object { $_.command -eq 'echo other-hook' }).Count -eq 1) '共享分组中的其他钩子被保留'
    Assert-Check (@($after.hooks.Stop | Where-Object { $_.marker -eq 'keep-me' }).Count -eq 1) '共享分组的其他字段被保留'
    Assert-Check ($after.hooks.PostToolUse[0].matcher -eq 'Bash') '其他事件的钩子被保留'
    Assert-Check ($after.model -eq 'opus' -and @($after.permissions.allow)[0] -eq 'Bash(git status)') '保留 Claude Code 的其他设置'
    Assert-Check ($after.cleanupNote -is [string] -and $after.cleanupNote -eq '2026-10-20T08:00:00Z') '日期样式的字符串逐字保留'
    Assert-Check ((Get-FileHash -LiteralPath $paths.config).Hash -eq $configHash) '重复安装逐字保留现有配置'
    Assert-Check (@(Get-ChildItem -LiteralPath (Join-Path $paths.root 'backups') -Filter settings.json -File -Recurse).Count -gt 0) '修改前备份 settings.json'
    & $installer -ClaudeHome $claudeHome -NoImport -NoInputReminder -IdleReminder *> $null
    $variant = Read-NotifierJson $paths.settings
    Assert-Check (@(Get-OwnedHandlers $variant 'PreToolUse').Count -eq 0) '-NoInputReminder 不登记提问钩子'
    $types = (Get-OwnedMatcher $variant 'Notification').Split('|')
    Assert-Check ($types -contains 'idle_prompt' -and $types -notcontains 'elicitation_dialog') '-IdleReminder 增加闲置提醒'
    & $installer -ClaudeHome $claudeHome -NoImport *> $null

    # 替换 HTTP 命令来检查真实脚本发出的内容，不向公共服务发测试消息。
    $global:NotifierTestRequests = @()
    function Invoke-RestMethod {
        param($Method, $Uri, $Headers, $Body, $ContentType, $TimeoutSec)
        $decoded = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
        $global:NotifierTestRequests += [pscustomobject]@{ payload=$decoded; uri=$Uri; headers=$Headers; contentType=$ContentType }
        if ($Uri -like '*pushplus*') { return [pscustomobject]@{ code=$global:PushPlusCode; data='receipt-1' } }
        return [pscustomobject]@{ id='local-test-id'; event='message' }
    }
    function Send-Hook { param([hashtable]$Data) & $notifySource -ConfigPath $paths.config -HookInput ([pscustomobject]$Data) *> $null }
    function Get-Sent { param([int]$From) return @($global:NotifierTestRequests | Select-Object -Skip $From) }

    $count = 0
    Send-Hook @{ hook_event_name='Stop'; session_id='s1'; prompt_id='p1'; last_assistant_message=$secret; background_tasks=@(); session_crons=@() }
    $sent = @(Get-Sent $count); $count = $global:NotifierTestRequests.Count
    Assert-Check ($sent.Count -eq 1 -and $sent[0].payload.title -eq '自定义完成标题') '完成事件使用自定义标题'
    Assert-Check ($sent[0].payload.priority -eq 4) '文字优先级映射为 JSON 数字'
    Assert-Check ($sent[0].payload.message -match '时间：\d{4}-\d{2}-\d{2} {4}\d{2}:\d{2}:\d{2}$') '通知时间没有时区，日期与时刻之间为四个空格'
    Assert-Check ($sent[0].contentType -eq 'application/json; charset=utf-8') '明确使用 UTF-8 JSON'
    Assert-Check ($null -eq $sent[0].payload.PSObject.Properties['click']) '空 click 不会写进通知'
    Send-Hook @{ hook_event_name='Stop'; session_id='s1'; prompt_id='p1'; last_assistant_message=$secret }
    Assert-Check ($global:NotifierTestRequests.Count -eq $count) '同一轮完成只提醒一次'
    Send-Hook @{ hook_event_name='Stop'; session_id='s1'; prompt_id='p2'; last_assistant_message='第二轮' }
    Assert-Check ($global:NotifierTestRequests.Count -eq $count + 1) '下一轮完成可以再次提醒'
    $count = $global:NotifierTestRequests.Count
    Send-Hook @{ hook_event_name='Stop'; session_id='s1'; last_assistant_message='没有 prompt_id 的旧版本' }
    Send-Hook @{ hook_event_name='Stop'; session_id='s1'; last_assistant_message='没有 prompt_id 的旧版本' }
    Assert-Check ($global:NotifierTestRequests.Count -eq $count + 1) '缺少 prompt_id 时按回复去重'
    $count = $global:NotifierTestRequests.Count
    Send-Hook @{ hook_event_name='Stop'; session_id='s2'; prompt_id='p1'; background_tasks=@([pscustomobject]@{ id='t1'; type='subagent'; status='running' }) }
    Assert-Check ($global:NotifierTestRequests.Count -eq $count) '后台子代理仍在运行时不报完成'
    Send-Hook @{ hook_event_name='Stop'; session_id='s2'; prompt_id='p2'; session_crons=@([pscustomobject]@{ id='c1'; schedule='*/5 * * * *'; recurring=$true }) }
    Assert-Check ($global:NotifierTestRequests.Count -eq $count) '定时唤醒等待中不报完成'
    Send-Hook @{ hook_event_name='Stop'; session_id='s2'; prompt_id='p3'; background_tasks=@([pscustomobject]@{ id='t2'; type='shell'; status='running'; command='npm run dev' }) }
    $sent = @(Get-Sent $count); $count = $global:NotifierTestRequests.Count
    Assert-Check ($sent.Count -eq 1 -and $sent[0].payload.message -match '后台还有 1 个任务在运行') '后台命令不阻止完成提醒，但会注明'
    Assert-Check ($sent[0].payload.message -notmatch 'npm') '不泄漏后台命令内容'

    Send-Hook @{ hook_event_name='PreToolUse'; session_id='s3'; tool_name='AskUserQuestion'; tool_use_id='toolu_ask'; tool_input=[pscustomobject]@{ questions=@([pscustomobject]@{ question=$secret }) } }
    $sent = @(Get-Sent $count); $count = $global:NotifierTestRequests.Count
    Assert-Check ($sent.Count -eq 1 -and $sent[0].payload.title -eq 'Claude Code 等待你回答') '选择题触发等待回答提醒'
    Assert-Check (@($sent[0].payload.tags) -contains 'question') '等待回答使用问号图标'
    Send-Hook @{ hook_event_name='PreToolUse'; session_id='s3'; tool_name='ExitPlanMode'; tool_use_id='toolu_plan'; tool_input=[pscustomobject]@{ plan=$secret } }
    $sent = @(Get-Sent $count); $count = $global:NotifierTestRequests.Count
    Assert-Check ($sent.Count -eq 1 -and $sent[0].payload.title -eq 'Claude Code 等待你确认计划') '计划确认触发提醒'
    Send-Hook @{ hook_event_name='PreToolUse'; session_id='s3'; tool_name='Bash'; tool_use_id='toolu_bash'; tool_input=[pscustomobject]@{ command='ls' } }
    Assert-Check ($global:NotifierTestRequests.Count -eq $count) '普通工具调用不提醒'

    # 桌面版的提问框也可能触发授权通知：按会话记录归到同一个问题，不重复提醒。
    $transcript = New-Transcript 'ask' @((New-ToolUse 'toolu_old' 'Read'), (New-ToolResult 'toolu_old'), (New-ToolUse 'toolu_ask' 'AskUserQuestion'))
    Send-Hook @{ hook_event_name='Notification'; notification_type='permission_prompt'; session_id='s3'; transcript_path=$transcript; message='Claude needs your permission' }
    Assert-Check ($global:NotifierTestRequests.Count -eq $count) '同一道选择题不会再报授权'
    $transcript = New-Transcript 'bash' @((New-ToolUse 'toolu_ask' 'AskUserQuestion'), (New-ToolResult 'toolu_ask'), (New-ToolUse 'toolu_rm' 'Bash'))
    Send-Hook @{ hook_event_name='Notification'; notification_type='permission_prompt'; session_id='s3'; transcript_path=$transcript; message='Claude needs your permission to use Bash' }
    $sent = @(Get-Sent $count); $count = $global:NotifierTestRequests.Count
    Assert-Check ($sent.Count -eq 1 -and $sent[0].payload.title -eq 'Claude Code 等待你授权') '真正的工具授权会提醒'
    Assert-Check (@($sent[0].payload.tags) -contains 'lock') '授权提醒使用锁图标'
    Assert-Check ($sent[0].payload.message -notmatch 'Bash') '授权提醒不包含弹窗内容'
    Send-Hook @{ hook_event_name='Notification'; notification_type='permission_prompt'; session_id='s3'; transcript_path=$transcript }
    Assert-Check ($global:NotifierTestRequests.Count -eq $count) '同一次授权只提醒一次'
    $transcript = New-Transcript 'plan' @((New-ToolUse 'toolu_plan2' 'ExitPlanMode'))
    Send-Hook @{ hook_event_name='Notification'; notification_type='permission_prompt'; session_id='s4'; transcript_path=$transcript }
    $sent = @(Get-Sent $count); $count = $global:NotifierTestRequests.Count
    Assert-Check ($sent.Count -eq 1 -and $sent[0].payload.title -eq 'Claude Code 等待你确认计划') '只收到授权通知时也能识别计划确认'
    Send-Hook @{ hook_event_name='PreToolUse'; session_id='s5'; tool_name='AskUserQuestion'; tool_use_id='toolu_q5' }
    Send-Hook @{ hook_event_name='Notification'; notification_type='permission_prompt'; session_id='s5'; transcript_path=(Join-Path $workspace 'missing.jsonl') }
    Assert-Check ($global:NotifierTestRequests.Count -eq $count + 1) '会话记录暂不可读时，刚提醒过的问题不重复'
    $count = $global:NotifierTestRequests.Count
    Send-Hook @{ hook_event_name='Notification'; notification_type='permission_prompt'; session_id='s6'; transcript_path=(Join-Path $workspace 'missing.jsonl') }
    Assert-Check ($global:NotifierTestRequests.Count -eq $count + 1) '会话记录不可读时仍然提醒授权'
    $count = $global:NotifierTestRequests.Count

    Send-Hook @{ hook_event_name='Notification'; notification_type='elicitation_dialog'; session_id='s7'; prompt_id='p1'; message='MCP 需要填写' }
    $sent = @(Get-Sent $count); $count = $global:NotifierTestRequests.Count
    Assert-Check ($sent.Count -eq 1 -and $sent[0].payload.title -eq 'Claude Code 等待你回答') 'MCP 输入表单触发等待回答'
    Send-Hook @{ hook_event_name='Notification'; notification_type='idle_prompt'; session_id='s7'; prompt_id='p1' }
    $sent = @(Get-Sent $count); $count = $global:NotifierTestRequests.Count
    Assert-Check ($sent.Count -eq 1 -and $sent[0].payload.title -eq 'Claude Code 仍在等你') '闲置提醒使用独立标题'
    Send-Hook @{ hook_event_name='Notification'; notification_type='auth_success'; session_id='s7' }
    Send-Hook @{ hook_event_name='SessionStart'; session_id='s7'; source='startup' }
    Assert-Check ($global:NotifierTestRequests.Count -eq $count) '登录成功和启动不发送提醒'
    Send-Hook @{ hook_event_name='StopFailure'; session_id='s8'; prompt_id='p1'; error='rate_limit'; last_assistant_message='API Error: Rate limit reached' }
    $sent = @(Get-Sent $count); $count = $global:NotifierTestRequests.Count
    Assert-Check ($sent.Count -eq 1 -and $sent[0].payload.title -eq 'Claude Code 出错停止' -and $sent[0].payload.message -match '达到速率或用量限制') 'API 错误中断会提醒并说明原因'
    Send-Hook @{ hook_event_name='StopFailure'; session_id='s8'; prompt_id='p1'; error='rate_limit' }
    Assert-Check ($global:NotifierTestRequests.Count -eq $count) '同一轮同一错误只提醒一次'

    $env:CLAUDE_CODE_ENTRYPOINT = 'sdk-cli'
    Send-Hook @{ hook_event_name='Stop'; session_id='h1'; prompt_id='p1' }
    $env:CLAUDE_CODE_ENTRYPOINT = 'cli'
    $env:CLAUDE_CODE_SESSION_ATTENDED = '0'
    Send-Hook @{ hook_event_name='Stop'; session_id='h2'; prompt_id='p1' }
    $env:CLAUDE_CODE_SESSION_ATTENDED = '1'
    Assert-Check ($global:NotifierTestRequests.Count -eq $count) '脚本化和无人值守会话不提醒'
    Send-Hook @{ hook_event_name='Stop'; session_id='h3'; prompt_id='p1' }
    Assert-Check ($global:NotifierTestRequests.Count -eq $count + 1) '终端交互会话正常提醒'
    $count = $global:NotifierTestRequests.Count
    Assert-Check (@($global:NotifierTestRequests | Where-Object { $_.payload.message -match [regex]::Escape($secret) }).Count -eq 0) '回复正文和工具参数不会发到手机'

    $config = Read-NotifierJson $paths.config
    Set-NotifierProperty $config 'showProject' $true
    Write-NotifierJson $paths.config $config
    Send-Hook @{ hook_event_name='Stop'; session_id='s9'; prompt_id='p1'; cwd='D:\UnityProjects\电池 项目' }
    $sent = @(Get-Sent $count); $count = $global:NotifierTestRequests.Count
    Assert-Check ($sent[0].payload.message -match '项目：电池 项目') 'showProject 只显示项目文件夹名'
    Set-NotifierProperty $config 'showProject' $false
    Set-NotifierProperty $config 'enabled' $false
    Write-NotifierJson $paths.config $config
    Send-Hook @{ hook_event_name='Stop'; session_id='off1'; prompt_id='p1' }
    Assert-Check ($global:NotifierTestRequests.Count -eq $count) '关闭 Claude Code 提醒后钩子静默返回'
    & $notifySource -Event test -ConfigPath $paths.config -Strict *> $null
    Assert-Check ($global:NotifierTestRequests.Count -eq $count + 1) '关闭提醒不影响手动测试'
    $count = $global:NotifierTestRequests.Count
    & $notifySource -Event error -ConfigPath $paths.config -Strict -Preview *> $null
    $sent = @(Get-Sent $count); $count = $global:NotifierTestRequests.Count
    Assert-Check ($sent.Count -eq 1 -and $sent[0].payload.title -eq '预览 · Claude Code 出错停止' -and $sent[0].payload.message -match '原因：达到速率或用量限制') '预览不受开关影响，带前缀和示例原因'
    Set-NotifierProperty $config 'enabled' $true

    # 自定义标题和正文：占位符替换，整行占位符为空时省略；旧版默认测试标题换成通用标题。
    $templates = & $notifySource -ListContent
    Assert-Check ((@($templates.Keys) -join ',') -eq 'done,input,plan,approval,error,idle,test') '列出七类可编辑提醒'
    $codexTemplates = & (Join-Path $repository 'scripts\notify.ps1') -ListContent
    Assert-Check ($templates.test.title -eq $codexTemplates.test.title -and $templates.test.body -eq $codexTemplates.test.body -and $templates.test.titleKey -eq $codexTemplates.test.titleKey) 'Codex 与 Claude Code 的通用测试内容一致'
    Set-NotifierProperty $config 'title' '{项目} 做完了'
    Set-NotifierProperty $config 'body' "活干完了`n{后台}`n项目：{项目}`n电脑 {电脑}"
    Set-NotifierProperty $config 'errorBody' "出错：{原因}"
    Set-NotifierProperty $config 'testTitle' 'Claude Code 通知测试'
    Write-NotifierJson $paths.config $config
    Send-Hook @{ hook_event_name='Stop'; session_id='c1'; prompt_id='p1'; cwd='D:\工程\电池 项目' }
    Send-Hook @{ hook_event_name='Stop'; session_id='c2'; prompt_id='p1' }
    Send-Hook @{ hook_event_name='StopFailure'; session_id='c3'; prompt_id='p1'; error='overloaded' }
    & $notifySource -Event test -ConfigPath $paths.config -Strict *> $null
    $sent = @(Get-Sent $count); $count = $global:NotifierTestRequests.Count
    Assert-Check ($sent[0].payload.title -eq '电池 项目 做完了' -and $sent[0].payload.message -eq ("活干完了`r`n项目：电池 项目`r`n电脑 " + $env:COMPUTERNAME)) '自定义完成提醒按模板替换，没有后台任务时省略该行'
    Assert-Check ($sent[1].payload.title -eq '做完了' -and $sent[1].payload.message -notmatch '项目') '没有项目时标题去掉占位符、正文省略项目行'
    Assert-Check ($sent[2].payload.title -eq 'Claude Code 出错停止' -and $sent[2].payload.message -eq '出错：服务繁忙') '只改正文时标题保持默认'
    Assert-Check ($sent[3].payload.title -eq '手机提醒测试') '旧版默认测试标题换成通用标题'
    foreach ($name in @('title','body','errorBody','testTitle')) { $config.PSObject.Properties.Remove($name) }
    Set-NotifierProperty $config 'channels' @()
    Write-NotifierJson $paths.config $config
    Send-Hook @{ hook_event_name='Stop'; session_id='s10'; prompt_id='p1' }
    Assert-Check ($global:NotifierTestRequests.Count -eq $count) '所有通道关闭时暂停提醒'
    $paused = $false
    try { & $notifySource -Event test -ConfigPath $paths.config -Strict *> $null } catch { $paused = $true }
    Assert-Check $paused '暂停时手动测试会明确报错'
    Set-NotifierProperty $config 'channels' @('ntfy')
    Write-NotifierJson $paths.config $config

    # 发送失败默认不影响 Claude；手动严格测试必须向调用者报告失败。
    function Invoke-RestMethod { throw [InvalidOperationException]::new('fake transport failure') }
    $quietFailed = $false
    try { Send-Hook @{ hook_event_name='Stop'; session_id='f1'; prompt_id='p1' } } catch { $quietFailed = $true }
    Assert-Check (-not $quietFailed) '发送失败不抛给钩子'
    $strictFailed = $false
    try { & $notifySource -Event test -ConfigPath $paths.config -Strict *> $null } catch { $strictFailed = $true }
    Assert-Check $strictFailed '严格测试不能把发送失败当成功'
    $log = [IO.File]::ReadAllText($paths.log)
    Assert-Check ($log -match 'error/done/ntfy: InvalidOperationException') '日志记录失败类型'
    Assert-Check ($log -notmatch [regex]::Escape($config.topic) -and $log -notmatch [regex]::Escape($secret)) '日志不记录主题和正文'
    function Invoke-RestMethod {
        param($Method, $Uri, $Headers, $Body, $ContentType, $TimeoutSec)
        $decoded = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
        $global:NotifierTestRequests += [pscustomobject]@{ payload=$decoded; uri=$Uri; headers=$Headers; contentType=$ContentType }
        if ($Uri -like '*pushplus*') { return [pscustomobject]@{ code=$global:PushPlusCode; data='receipt-1' } }
        return [pscustomobject]@{ id='local-test-id'; event='message' }
    }
    Send-Hook @{ hook_event_name='Stop'; session_id='f1'; prompt_id='p1' }
    Assert-Check ($global:NotifierTestRequests.Count -eq $count + 1) '失败后释放占位，下一次可以重发'
    $count = $global:NotifierTestRequests.Count

    # 微信只用模拟密钥和模拟 HTTP；本机加密存储也必须能正常解密。
    $fakeToken = 'test-token-never-a-real-account'
    $secureToken = ConvertTo-SecureString $fakeToken -AsPlainText -Force
    & (Join-Path $repository 'claude-code\enable-wechat.ps1') -ClaudeHome $claudeHome -Token $secureToken -NoTest *> $null
    $config = Read-NotifierJson $paths.config
    Assert-Check ((@($config.channels) -join ',') -eq 'ntfy,wechat') '连接微信后保留 ntfy'
    Assert-Check ([IO.File]::ReadAllText($paths.token) -notmatch $fakeToken) '密钥不以明文保存'
    $global:PushPlusCode = 200
    & $notifySource -Event test -ConfigPath $paths.config -Strict *> $null
    $sent = @(Get-Sent $count); $count = $global:NotifierTestRequests.Count
    $wechat = @($sent | Where-Object { $_.uri -like '*pushplus*' })
    Assert-Check ($sent.Count -eq 2 -and $wechat.Count -eq 1) '双通道各发送一次'
    Assert-Check ($wechat[0].payload.token -eq $fakeToken -and $wechat[0].payload.channel -eq 'clawbot' -and $wechat[0].payload.template -eq 'txt') '微信走 ClawBot 纯文本'
    Assert-Check ($null -eq $wechat[0].payload.PSObject.Properties['topic'] -and $null -eq $wechat[0].payload.PSObject.Properties['to']) '只发给密钥所属用户'
    Assert-Check ($wechat[0].payload.title -eq '手机提醒测试') '微信测试使用通用中文标题'
    $global:PushPlusCode = 903
    $rejected = $false
    try { & $notifySource -Event test -Channel wechat -ConfigPath $paths.config -Strict *> $null } catch { $rejected = $_.Exception.Message -match '密钥无效' }
    Assert-Check $rejected 'PushPlus 拒绝时给出密钥提示'
    $global:PushPlusCode = 200
    Remove-Item -LiteralPath $paths.wechatState -Force
    $count = $global:NotifierTestRequests.Count
    for ($i = 0; $i -lt 6; $i++) { & $notifySource -Event test -Channel wechat -ConfigPath $paths.config *> $null }
    $wechatSends = @(Get-Sent $count | Where-Object { $_.uri -like '*pushplus*' }).Count
    Assert-Check ($wechatSends -eq 5) ('微信每分钟最多请求五次，实际 ' + $wechatSends)
    $count = $global:NotifierTestRequests.Count
    & (Join-Path $repository 'claude-code\enable-wechat.ps1') -ClaudeHome $claudeHome -Disable *> $null
    Assert-Check ((@((Read-NotifierJson $paths.config).channels) -join ',') -eq 'ntfy' -and [IO.File]::Exists($paths.token)) '关闭微信保留 ntfy 和加密密钥'
    Remove-Item Function:\Invoke-RestMethod

    # 已装过 Codex 手机提醒：沿用通道、主题和加密密钥，标题仍是 Claude Code。
    [IO.Directory]::CreateDirectory($codexHome) | Out-Null
    Write-NotifierJson (Join-Path $codexHome 'ntfy-codex.json') ([pscustomobject]@{ channels=@('wechat'); server='https://ntfy.example.com'; topic='codex-shared-topic'; title='Codex 任务已完成'; priority='high' })
    [IO.File]::WriteAllText((Join-Path $codexHome 'pushplus-token.dpapi'), (ConvertFrom-SecureString $secureToken))
    $importHome = Join-Path $workspace '导入 测试\.claude'
    $importPaths = Get-ClaudeNotifierPaths $importHome
    & $installer -ClaudeHome $importHome -CodexHome $codexHome *> $null
    $imported = Read-NotifierJson $importPaths.config
    Assert-Check ((@($imported.channels) -join ',') -eq 'wechat' -and $imported.topic -eq 'codex-shared-topic' -and $imported.server -eq 'https://ntfy.example.com') '沿用 Codex 的通道和 ntfy 主题'
    Assert-Check ($imported.title -eq 'Claude Code 任务已完成' -and $imported.priority -eq 'high') '标题使用 Claude Code，优先级沿用'
    Assert-Check ([IO.File]::ReadAllText($importPaths.token) -eq [IO.File]::ReadAllText((Join-Path $codexHome 'pushplus-token.dpapi'))) '复制加密微信密钥'
    $codexHash = (Get-FileHash -LiteralPath (Join-Path $codexHome 'ntfy-codex.json')).Hash
    & $installer -ClaudeHome (Join-Path $workspace '独立\.claude') -CodexHome $codexHome -Topic 'claude-own-topic' *> $null
    Assert-Check ((Read-NotifierJson (Join-Path $workspace '独立\.claude\phone-notifier\config.json')).topic -eq 'claude-own-topic') '-Topic 可以使用独立主题'
    Assert-Check ((Get-FileHash -LiteralPath (Join-Path $codexHome 'ntfy-codex.json')).Hash -eq $codexHash) '不修改 Codex 的配置'

    # 真实子进程：标准输入带 BOM、中文和表情，验证 exec 钩子命令能完整发出请求。
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    $bodies = [Collections.Concurrent.ConcurrentQueue[string]]::new()
    $server = [PowerShell]::Create()
    $null = $server.AddScript({
        param($Listener, $Bodies)
        while ($true) {
            try { $client = $Listener.AcceptTcpClient() } catch { break }
            try {
                $stream = $client.GetStream()
                $buffer = [byte[]]::new(65536); $data = [IO.MemoryStream]::new()
                do {
                    $read = $stream.Read($buffer, 0, $buffer.Length); $data.Write($buffer, 0, $read)
                    $text = [Text.Encoding]::UTF8.GetString($data.ToArray())
                    $split = $text.IndexOf("`r`n`r`n")
                    $complete = $false
                    if ($split -ge 0 -and $text -match 'Content-Length:\s*(\d+)') { $complete = ($data.Length - [Text.Encoding]::UTF8.GetByteCount($text.Substring(0, $split + 4))) -ge [int]$Matches[1] }
                } while ($read -gt 0 -and -not $complete)
                $Bodies.Enqueue($text.Substring($split + 4))
                $reply = [Text.Encoding]::UTF8.GetBytes('{"id":"real-process","event":"message"}')
                $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($reply.Length)`r`nConnection: close`r`n`r`n")
                $stream.Write($head, 0, $head.Length); $stream.Write($reply, 0, $reply.Length)
            } finally { $client.Close() }
        }
    }).AddArgument($listener).AddArgument($bodies)
    $handle = $server.BeginInvoke()
    try {
        $config = Read-NotifierJson $paths.config
        $config.server = 'http://127.0.0.1:' + $port
        Write-NotifierJson $paths.config $config
        $installed = Read-NotifierJson $paths.settings
        $handler = @(Get-OwnedHandlers $installed 'Stop')[0]
        $shells = @($handler.command)
        $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
        if ($null -ne $pwsh) { $shells += $pwsh.Source }
        $index = 0
        foreach ($shell in $shells) {
            $index++
            $hookJson = [pscustomobject]@{ hook_event_name='Stop'; session_id=('real-' + $index); prompt_id='p1'; cwd='C:\项目 🚀'; last_assistant_message='完成了 ✅' } | ConvertTo-Json -Compress
            $start = [Diagnostics.ProcessStartInfo]::new($shell)
            $start.Arguments = (@($handler.args) | ForEach-Object { '"' + $_ + '"' }) -join ' '
            $start.UseShellExecute = $false; $start.RedirectStandardInput = $true; $start.CreateNoWindow = $true
            $process = [Diagnostics.Process]::Start($start)
            $bytes = [Text.UTF8Encoding]::new($true).GetPreamble() + [Text.Encoding]::UTF8.GetBytes($hookJson)
            $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
            $process.StandardInput.Close()
            Assert-Check ($process.WaitForExit(30000) -and $process.ExitCode -eq 0) ('真实子进程正常退出：' + [IO.Path]::GetFileName($shell))
        }
        $received = @()
        $body = $null
        while ($bodies.TryDequeue([ref]$body)) { $received += ($body | ConvertFrom-Json) }
        Assert-Check ($received.Count -eq $shells.Count) '每个 PowerShell 版本都发出一次请求'
        Assert-Check (@($received | Where-Object { $_.title -eq 'Claude Code 任务已完成' -or $_.title -eq '自定义完成标题' }).Count -eq $shells.Count) '真实标准输入的中文标题无乱码'
    } finally {
        $listener.Stop()
        $null = $handle.AsyncWaitHandle.WaitOne(3000)
        $server.Dispose()
    }

    # 卸载：只移除本工具，保留其他钩子和设置；-KeepConfig 保留配置。
    & $uninstaller -ClaudeHome $claudeHome -KeepConfig *> $null
    $removed = Read-NotifierJson $paths.settings
    foreach ($event in @('Stop', 'StopFailure', 'PreToolUse', 'Notification')) { Assert-Check (@(Get-OwnedHandlers $removed $event).Count -eq 0) ('卸载移除 ' + $event + ' 钩子') }
    Assert-Check (@(@($removed.hooks.Stop) | ForEach-Object { @($_.hooks) } | Where-Object { $_.command -eq 'echo other-hook' }).Count -eq 1) '卸载保留其他钩子'
    Assert-Check ($removed.model -eq 'opus') '卸载保留其他设置'
    Assert-Check (-not [IO.File]::Exists($paths.script) -and [IO.File]::Exists($paths.config) -and [IO.File]::Exists($paths.token)) '-KeepConfig 保留配置和密钥'
    & $uninstaller -ClaudeHome $importHome *> $null
    $clean = Read-NotifierJson $importPaths.settings
    Assert-Check ($null -eq $clean.PSObject.Properties['hooks']) '原本没有钩子时，卸载后恢复为空设置'
    Assert-Check (-not [IO.File]::Exists($importPaths.config) -and -not [IO.File]::Exists($importPaths.token)) '完整卸载移除配置和密钥'
    Assert-Check ([IO.File]::Exists((Join-Path $codexHome 'pushplus-token.dpapi'))) '卸载不影响 Codex 的密钥'
    Write-Host ('全部 {0} 项检查通过（PowerShell {1}）。' -f $script:checks, $PSVersionTable.PSVersion)
} finally {
    foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name]) }
    Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction SilentlyContinue
}
