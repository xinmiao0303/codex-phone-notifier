#requires -Version 5.1
$ErrorActionPreference='Stop'
$repository=Split-Path -Parent $PSScriptRoot
. (Join-Path $repository 'scripts/common.ps1')
$workspace=Join-Path ([IO.Path]::GetTempPath()) ('codex-hook-events-'+[guid]::NewGuid().ToString('N'))
$directory=Join-Path $workspace '用户 设置'
$notify=Join-Path $repository 'scripts/notify.ps1'
$config=Join-Path $directory 'ntfy-codex.json'
$transcript=Join-Path $workspace 'main.jsonl'
$script:checks=0
function Assert-Event([bool]$OK,[string]$Message) { if(-not $OK){throw ('验证失败：'+$Message)}; $script:checks++ }
function Write-Sample([string]$Session,[string]$Turn,[string]$Phase='final_answer',[object]$Source='vscode',[string]$Parent='', [switch]$NoComplete,[string]$ThreadSource='user',[string]$Reviewer='user') {
    $records=@(
        [pscustomobject]@{type='session_meta';payload=[pscustomobject]@{id=$Session;source=$Source;parent_thread_id=$Parent;thread_source=$ThreadSource}},
        [pscustomobject]@{type='event_msg';payload=[pscustomobject]@{type='task_started';turn_id=$Turn}},
        [pscustomobject]@{type='turn_context';payload=[pscustomobject]@{turn_id=$Turn;approvals_reviewer=$Reviewer}},
        [pscustomobject]@{type='response_item';payload=[pscustomobject]@{type='message';role='assistant';phase=$Phase;content=@([pscustomobject]@{type='output_text';text='示例消息'})}}
    )
    if ($Phase -in @('final','final_answer') -and -not $NoComplete) { $records+=[pscustomobject]@{type='event_msg';payload=[pscustomobject]@{type='task_complete';turn_id=$Turn}} }
    $lines=@($records | ForEach-Object {$_|ConvertTo-Json -Depth 10 -Compress})
    [IO.File]::WriteAllText($transcript,($lines -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
}
function New-Input([string]$Session='main',[string]$Turn='turn-1',[string]$Tool='', [string]$Use='') {
    return [pscustomobject]@{session_id=$Session;turn_id=$Turn;transcript_path=$transcript;stop_hook_active=$false;tool_name=$Tool;tool_use_id=$Use;tool_input=[pscustomobject]@{description='TEST_PRIVATE_ARGUMENT_NOT_FOR_PHONE'}}
}
$global:EventRequests=@();$global:EventFail=$false
function Invoke-RestMethod {
    param($Method,$Uri,$Headers,$Body,$ContentType,$TimeoutSec)
    $decoded=[Text.Encoding]::UTF8.GetString($Body)|ConvertFrom-Json
    $global:EventRequests+=[pscustomobject]@{payload=$decoded;uri=$Uri}
    if($global:EventFail){throw 'fake transport error'}
    if($Uri -eq 'https://www.pushplus.plus/send'){return [pscustomobject]@{code=200;data='fake-receipt'}}
    return [pscustomobject]@{id='fake-ntfy-id';event='message'}
}
try {
    & (Join-Path $repository 'install.ps1') -CodexHome $directory *> $null
    $settings=Read-NotifierJson $config
    $settings.server='https://example.invalid';Write-NotifierJson $config $settings
    $inputObject=New-Input
    Write-Sample 'main' 'turn-1' 'commentary'
    & $notify -Event done -ConfigPath $config -HookInput $inputObject *> $null
    Assert-Event ($global:EventRequests.Count -eq 0) '截图场景：仍在说明进度时不发送完成通知'
    Write-Sample 'main' 'turn-1' 'analysis'
    & $notify -Event done -ConfigPath $config -HookInput $inputObject *> $null
    Assert-Event ($global:EventRequests.Count -eq 0) '思考阶段不发送完成通知'
    Write-Sample 'main' 'turn-1' 'final_answer' ([pscustomobject]@{subagent=[pscustomobject]@{other='guardian'}}) 'parent'
    & $notify -Event done -ConfigPath $config -HookInput $inputObject *> $null
    Assert-Event ($global:EventRequests.Count -eq 0) '后台审核子会话不报告主任务完成'
    Write-Sample 'main' 'turn-1' 'final_answer' 'exec'
    & $notify -Event done -ConfigPath $config -HookInput $inputObject *> $null
    Assert-Event ($global:EventRequests.Count -eq 0) '内部非交互执行不报告聊天完成'
    Write-Sample 'main' 'turn-1' -ThreadSource 'ambient_suggestions'
    & $notify -Event done -ConfigPath $config -HookInput $inputObject *> $null
    Assert-Event ($global:EventRequests.Count -eq 0) '来源为内部建议的会话不发送完成提醒'
    $inputObject.transcript_path=$null
    & $notify -Event done -ConfigPath $config -HookInput $inputObject *> $null
    Assert-Event ($global:EventRequests.Count -eq 0) '缺少会话文件时不猜测已经完成'
    $inputObject=New-Input
    Write-Sample 'main' 'turn-1'
    & $notify -Event done -ConfigPath $config -HookInput $inputObject *> $null
    & $notify -Event done -ConfigPath $config -HookInput $inputObject *> $null
    Assert-Event ($global:EventRequests.Count -eq 1) '同一个真实主轮次完成只发送一次'
    Write-Sample 'main' 'turn-2'
    & $notify -Event done -ConfigPath $config -HookInput (New-Input 'main' 'turn-2') *> $null
    Assert-Event ($global:EventRequests.Count -eq 2) '紧接着完成的另一个真实轮次仍会提醒'
    Write-Sample 'other-main' 'turn-2'
    & $notify -Event done -ConfigPath $config -HookInput (New-Input 'other-main' 'turn-2') *> $null
    Assert-Event ($global:EventRequests.Count -eq 3) '两个主聊天不会互相抑制'
    & $notify -Event done -ConfigPath $config -HookInput (New-Input 'wrong-main' 'turn-2') *> $null
    & $notify -Event done -ConfigPath $config -HookInput (New-Input 'other-main' 'stale-turn') *> $null
    Assert-Event ($global:EventRequests.Count -eq 3) '忽略与当前会话或轮次不匹配的旧事件'
    Write-Sample 'main' 'continued' -NoComplete
    $inputObject=New-Input 'main' 'continued';$inputObject.stop_hook_active=$true
    & $notify -Event done -ConfigPath $config -HookInput $inputObject *> $null
    Assert-Event ($global:EventRequests.Count -eq 3) 'Stop 正在续跑时不宣称完成'
    Write-Sample 'main' 'interrupted'
    [IO.File]::AppendAllText($transcript,'{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"interrupted"}}'+"`n")
    & $notify -Event done -ConfigPath $config -HookInput (New-Input 'main' 'interrupted') *> $null
    Assert-Event ($global:EventRequests.Count -eq 3) '被中断的轮次不发送完成通知'
    Write-Sample 'main' 'retry'
    $global:EventFail=$true
    & $notify -Event done -ConfigPath $config -HookInput (New-Input 'main' 'retry') *> $null
    $global:EventFail=$false
    & $notify -Event done -ConfigPath $config -HookInput (New-Input 'main' 'retry') *> $null
    Assert-Event ($global:EventRequests.Count -eq 5) '发送失败释放占位，同一事件恢复后可以发送'
    Write-Sample 'main' 'questions' 'commentary'
    $inputObject=New-Input 'main' 'questions' 'functions.request_user_input_async' 'question-1'
    $inputObject.tool_input=[pscustomobject]@{questions=@([pscustomobject]@{title='纯文字输入，无选项'})}
    $before=$global:EventRequests.Count
    & $notify -Event input -ConfigPath $config -HookInput $inputObject *> $null
    & $notify -Event input -ConfigPath $config -HookInput $inputObject *> $null
    Assert-Event ($global:EventRequests.Count -eq $before+1 -and $global:EventRequests[-1].payload.title -eq 'Codex 等待你回答') '纯输入提醒仍有效，同一问题不重复发送'
    $inputObject.tool_use_id='question-2'
    & $notify -Event input -ConfigPath $config -HookInput $inputObject *> $null
    Assert-Event ($global:EventRequests.Count -eq $before+2) '同一轮次的另一个问题仍会提醒'
    $before=$global:EventRequests.Count
    foreach($reviewer in @('user','auto_review','')) {
        Write-Sample 'main' 'permissions' 'commentary' -Reviewer $reviewer
        foreach($tool in @('Bash','apply_patch','functions.request_permissions','mcp__computer_use__connect','mcp__node_repl__js')) {
            $inputObject=New-Input 'main' 'permissions' $tool
            $hookOutput=@(& $notify -Event approval -ConfigPath $config -HookInput $inputObject)
            Assert-Event ($global:EventRequests.Count -eq $before -and $hookOutput.Count -eq 0) ('关闭授权提醒且不输出审批决定：'+$reviewer+'/'+$tool)
        }
    }
    & $notify -Event approval -ConfigPath $config *> $null
    Assert-Event ($global:EventRequests.Count -eq $before) '旧进程缓存的审批钩子没有上下文时也静默返回'
    & $notify -Event input -ConfigPath $config -HookInput (New-Input 'main' 'permissions' 'functions.request_permissions') *> $null
    Assert-Event ($global:EventRequests.Count -eq $before) '旧权限申请不能被当成等待回答提醒'
    $inputObject=New-Input 'main' 'permissions' 'Bash'
    Add-Member -InputObject $inputObject -NotePropertyName hook_event_name -NotePropertyValue 'PermissionRequest'
    & $notify -Event input -ConfigPath $config -HookInput $inputObject *> $null
    Assert-Event ($global:EventRequests.Count -eq $before) '权限事件误标为 input 时仍不发送'
    $before=$global:EventRequests.Count
    $consentId=('c'*64)
    & $notify -Event consent -ConsentId $consentId -ConfigPath $config *> $null
    & $notify -Event consent -ConsentId $consentId -ConfigPath $config *> $null
    Assert-Event ($global:EventRequests.Count -eq $before+1 -and $global:EventRequests[-1].payload.title -eq 'Codex 等待你授权') '原生 MCP 授权事件发送一次，普通审批事件继续静默'
    & $notify -Event consent -ConsentId 'not-a-request-id' -ConfigPath $config *> $null
    & $notify -Event consent -ConfigPath $config *> $null
    Assert-Event ($global:EventRequests.Count -eq $before+1) '缺少真实请求摘要时不猜测有授权窗口'
    Assert-Event (($global:EventRequests[-1].payload|ConvertTo-Json -Depth 10) -notmatch 'TEST_PRIVATE_ARGUMENT|requestedSchema|PRIVATE_REQUEST') '原生授权手机消息不包含插件请求正文'
    $statePath=Join-Path $directory 'notifier-event-state.json'
    Assert-Event ([IO.File]::ReadAllText($statePath) -notmatch 'TEST_PRIVATE_ARGUMENT|questions|mcp__computer_use') '去重文件只保存摘要，不保存参数和会话正文'
    Assert-Event (@((Read-NotifierJson (Join-Path $directory 'hooks.json')).hooks.Stop.hooks | Where-Object { $_.async -eq $true }).Count -eq 1) '完成钩子后台运行，可以观察真正的轮次结束'
    # 每个通道独立记录结果，避免一个成功导致另一个被误判为已发送。
    $settings.channels=@('ntfy','wechat');Write-NotifierJson $config $settings
    $secure=ConvertTo-SecureString 'fake-token' -AsPlainText -Force
    try { $encrypted=ConvertFrom-SecureString $secure } finally { $secure.Dispose() }
    [IO.File]::WriteAllText((Join-Path $directory 'pushplus-token.dpapi'),$encrypted)
    Write-Sample 'main' 'dual'
    $before=$global:EventRequests.Count
    & $notify -Event done -ConfigPath $config -HookInput (New-Input 'main' 'dual') *> $null
    & $notify -Event done -ConfigPath $config -HookInput (New-Input 'main' 'dual') *> $null
    Assert-Event ($global:EventRequests.Count -eq $before+2) '双通道各发送一次，各自去重'
    # 两个独立进程同时收到同一事件时，第二个必须看见第一个的 pending 占位。
    $settings.channels=@('ntfy');Write-NotifierJson $config $settings
    Write-Sample 'main' 'concurrent'
    $contextFile=Join-Path $workspace 'context.json';Write-NotifierJson $contextFile (New-Input 'main' 'concurrent')
    $marker=Join-Path $workspace 'published.txt';$runner=Join-Path $workspace 'runner.ps1'
    $child=@"
param([string]`$Source,[string]`$Config,[string]`$Context,[string]`$Marker)
`$ErrorActionPreference='Stop'
function Invoke-RestMethod {
 param(`$Method,`$Uri,`$Headers,`$Body,`$ContentType,`$TimeoutSec)
 [IO.File]::AppendAllText(`$Marker,"sent``n")
 Start-Sleep -Milliseconds 700
 return [pscustomobject]@{id='concurrency-mock';event='message'}
}
`$data=[IO.File]::ReadAllText(`$Context)|ConvertFrom-Json
& `$Source -Event done -ConfigPath `$Config -HookInput `$data -Strict
"@
    [IO.File]::WriteAllText($runner,$child,[Text.UTF8Encoding]::new($true))
    $children=@()
    foreach($index in 1..2){
        $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'))
        $start.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$runner+'" "'+$notify+'" "'+$config+'" "'+$contextFile+'" "'+$marker+'"'
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        $start.EnvironmentVariables['PSModulePath']=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/Modules'
        $children+=[Diagnostics.Process]::Start($start)
    }
    foreach($childProcess in $children){$finished=$childProcess.WaitForExit(10000);Assert-Event ($finished -and $childProcess.ExitCode -eq 0) '并发测试子进程正常退出';$childProcess.Dispose()}
    Assert-Event (@([IO.File]::ReadAllLines($marker)).Count -eq 1) '跨进程同时触发也只发布一次'
    Write-Sample 'main' 'continued-final'
    $continued=New-Input 'main' 'continued-final';$continued.stop_hook_active=$true
    $before=$global:EventRequests.Count
    & $notify -Event done -ConfigPath $config -HookInput $continued *> $null
    Assert-Event ($global:EventRequests.Count -eq $before+1) '续跑之后真正结束的轮次仍能提醒'
    $hooks=Read-NotifierJson (Join-Path $directory 'hooks.json')
    Assert-Event (@($hooks.hooks.PermissionRequest.hooks | Where-Object {$_.command -like '*codex-ntfy-notify.ps1*'}).Count -eq 0) '全新安装不登记授权钩子'
    # 模拟从 0.5.0 升级；同一组中保留其他插件的审批处理器。
    $foreign=[pscustomobject]@{type='command';command='other-permission-hook'}
    $legacy=[pscustomobject]@{type='command';command=('powershell.exe -File "'+(Join-Path $directory 'scripts/codex-ntfy-notify.ps1')+'" -Event approval')}
    Set-NotifierProperty $hooks.hooks 'PermissionRequest' @([pscustomobject]@{hooks=@($legacy,$foreign)})
    $hooks.hooks.PreToolUse+=@([pscustomobject]@{matcher='(^|[._])request_permissions$';hooks=@($legacy,$foreign)})
    Write-NotifierJson (Join-Path $directory 'hooks.json') $hooks
    & (Join-Path $repository 'install.ps1') -CodexHome $directory *> $null
    & (Join-Path $repository 'install.ps1') -CodexHome $directory -NoApprovalReminder *> $null
    $hooks=Read-NotifierJson (Join-Path $directory 'hooks.json')
    Assert-Event (@($hooks.hooks.PermissionRequest.hooks | Where-Object {$_.command -like '*codex-ntfy-notify.ps1*'}).Count -eq 0) '升级移除旧版 PermissionRequest 通知钩子'
    Assert-Event (@($hooks.hooks.PreToolUse.hooks | Where-Object {$_.command -like '*-Event approval'}).Count -eq 0) '升级移除旧版权限申请通知钩子'
    Assert-Event (@($hooks.hooks.PermissionRequest.hooks | Where-Object {$_.command -eq $foreign.command}).Count -eq 1) '升级保留其他插件的 PermissionRequest 钩子'
    Assert-Event (@($hooks.hooks.PreToolUse.hooks | Where-Object {$_.command -eq $foreign.command}).Count -eq 1) '升级保留其他插件的权限申请钩子'
    & (Join-Path $repository 'uninstall.ps1') -CodexHome $directory -KeepConfig *> $null
    $hooks=Read-NotifierJson (Join-Path $directory 'hooks.json')
    Assert-Event (-not [IO.File]::Exists($statePath) -and [IO.File]::Exists($config)) '卸载保留配置时仍清理去重缓存'
    Assert-Event (@($hooks.hooks.PermissionRequest.hooks | Where-Object {$_.command -eq $foreign.command}).Count -eq 1) '卸载保留其他授权钩子'
    Write-Host ('PASS: hook events {0} checks; PowerShell {1}' -f $script:checks,$PSVersionTable.PSVersion)
} finally {
    Remove-Item Function:\Invoke-RestMethod -ErrorAction SilentlyContinue
    $target=[IO.Path]::GetFullPath($workspace);$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if($target.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($target).StartsWith('codex-hook-events-')) { if([IO.Directory]::Exists($target)){Remove-Item -LiteralPath $target -Recurse -Force} }
    else {throw '拒绝清理其他目录'}
}
