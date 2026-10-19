#requires -Version 5.1
# 通过真实 Windows PowerShell 子进程的标准输入测试，不能用 -HookInput 绕过编码路径。
$ErrorActionPreference='Stop'
$repository=Split-Path -Parent $PSScriptRoot
$root=Join-Path ([IO.Path]::GetTempPath()) ('codex-stdin-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
$checks=0
try {
    $config=Join-Path $root 'config.json'
    [IO.File]::WriteAllText($config,'{"channels":["ntfy"],"server":"https://example.invalid","topic":"stdin-test"}')
    $marker=Join-Path $root 'received.json'; $runner=Join-Path $root 'runner.ps1'; $notify=Join-Path $repository 'scripts/notify.ps1'
    $code=@"
param([string]`$Source,[string]`$Config,[string]`$Marker,[string]`$Event)
`$ErrorActionPreference='Stop'
function Invoke-RestMethod {
    param(`$Method,`$Uri,`$Headers,`$Body,`$ContentType,`$TimeoutSec)
    [IO.File]::WriteAllText(`$Marker,[Text.Encoding]::UTF8.GetString(`$Body))
    return [pscustomobject]@{id='stdin-mock';event='message'}
}
& `$Source -Event `$Event -ConfigPath `$Config
"@
    [IO.File]::WriteAllText($runner,$code,[Text.UTF8Encoding]::new($true))
    $transcript=Join-Path $root '中文会话.jsonl'
    $cases=@(
        @{Name='utf8-input'; Event='input'; Title='Codex 等待你回答'; Reviewer='auto_review'},
        @{Name='bom-input'; Event='input'; Title='Codex 等待你回答'; Reviewer='auto_review'; Bom=$true},
        @{Name='utf8-done'; Event='done'; Title='Codex 任务已完成'; Reviewer='auto_review'},
        @{Name='bom-done'; Event='done'; Title='Codex 任务已完成'; Reviewer='user'; Bom=$true},
        @{Name='legacy-approval'; Event='approval'; Title=''; Reviewer='user'},
        @{Name='auto-review'; Event='approval'; Title=''; Reviewer='auto_review'},
        @{Name='permission-pretool'; Event='input'; Title=''; Reviewer='user'; PermissionTool=$true},
        @{Name='permission-event'; Event='input'; Title=''; Reviewer='user'; PermissionEvent=$true},
        @{Name='invalid-json'; Event='input'; Title=''; Reviewer='user'; Invalid=$true}
    )
    foreach($case in $cases) {
        if([IO.File]::Exists($marker)){Remove-Item -LiteralPath $marker -Force}
        $records=@(
            [pscustomobject]@{type='session_meta';payload=@{id='stdin-test';source='vscode';thread_source='user'}},
            [pscustomobject]@{type='event_msg';payload=@{type='task_started';turn_id=$case.Name}},
            [pscustomobject]@{type='turn_context';payload=@{turn_id=$case.Name;approvals_reviewer=$case.Reviewer}}
        )
        if($case.Event -eq 'done') {
            $records += [pscustomobject]@{type='response_item';payload=@{type='message';role='assistant';phase='final_answer'}}
            $records += [pscustomobject]@{type='event_msg';payload=@{type='task_complete';turn_id=$case.Name}}
        }
        $lines=@($records|ForEach-Object{$_|ConvertTo-Json -Depth 10 -Compress})
        [IO.File]::WriteAllText($transcript,($lines -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
        $inputObject=[pscustomobject]@{session_id='stdin-test';turn_id=$case.Name;transcript_path=$transcript;tool_name='mcp__example__read';tool_input=@{description='PRIVATE_STDIN_ARGUMENT 只读检查 / 中文与表情 🔔'}}
        if($case.Event -eq 'input'){$inputObject.tool_name='functions.request_user_input_async'}
        if($case.PermissionTool){$inputObject.tool_name='functions.request_permissions'}
        if($case.PermissionEvent){Add-Member -InputObject $inputObject -NotePropertyName hook_event_name -NotePropertyValue 'PermissionRequest'}
        $json=$inputObject|ConvertTo-Json -Depth 10 -Compress
        if($case.Bom){$json=([string][char]0xFEFF)+$json}
        if($case.Invalid){$json='{"tool_input":"PRIVATE_STDIN_ARGUMENT 中文 🔔"'}
        $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'))
        $start.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$runner+'" "'+$notify+'" "'+$config+'" "'+$marker+'" "'+$case.Event+'"'
        $start.UseShellExecute=$false; $start.CreateNoWindow=$true; $start.RedirectStandardInput=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
        $start.EnvironmentVariables['PSModulePath']=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/Modules'
        $child=[Diagnostics.Process]::Start($start)
        try {
            $stdout=$child.StandardOutput.ReadToEndAsync(); $stderr=$child.StandardError.ReadToEndAsync()
            $bytes=[Text.Encoding]::UTF8.GetBytes($json); $child.StandardInput.BaseStream.Write($bytes,0,$bytes.Length); $child.StandardInput.Close()
            if(-not $child.WaitForExit(10000)){$child.Kill();throw '标准输入测试超时'}
            $output=$stdout.GetAwaiter().GetResult(); $errorOutput=$stderr.GetAwaiter().GetResult()
            if($child.ExitCode -ne 0 -or $output.Trim() -or $errorOutput.Trim()){throw ('子进程异常或意外输出：'+$case.Name)}
        } finally { $child.Dispose() }
        if($case.Title) {
            if(-not [IO.File]::Exists($marker)){throw ('真实标准输入漏报：'+$case.Name)}
            $payload=[IO.File]::ReadAllText($marker)|ConvertFrom-Json
            if($payload.title -ne $case.Title){throw ('标题错误：'+$case.Name)}
            if([IO.File]::ReadAllText($marker) -match 'PRIVATE_STDIN_ARGUMENT'){throw '手机内容泄漏工具参数'}
        } elseif([IO.File]::Exists($marker)) { throw ('标准输入事件误报：'+$case.Name) }
        $checks++
    }
    $log=[IO.File]::ReadAllText((Join-Path $root 'ntfy-codex.log'))
    if($log -notmatch 'invalid-hook-input' -or $log -match 'PRIVATE_STDIN_ARGUMENT'){throw '错误输入没有安全跳过或日志泄漏参数'}
    $checks++
    Write-Host ('PASS: real hook stdin {0} checks; PowerShell {1}' -f $checks,$PSVersionTable.PSVersion)
} finally {
    $resolved=[IO.Path]::GetFullPath($root); $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if($resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('codex-stdin-')) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    else {throw '拒绝清理其他目录'}
}
