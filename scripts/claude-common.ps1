#requires -Version 5.1
# Claude Code 提醒的安装、卸载共用处理；JSON 读写沿用 common.ps1。
# 只改本工具在 settings.json 里的钩子和 phone-notifier 目录。
function Resolve-ClaudeDirectory {
    param([string]$Directory)
    if ([string]::IsNullOrWhiteSpace($Directory)) { $Directory = $env:CLAUDE_CONFIG_DIR }
    if ([string]::IsNullOrWhiteSpace($Directory)) { $Directory = Join-Path $env:USERPROFILE '.claude' }
    return [IO.Path]::GetFullPath($Directory)
}
function Get-ClaudeNotifierPaths {
    param([string]$ClaudeHome)
    $root = Join-Path $ClaudeHome 'phone-notifier'
    return [pscustomobject]@{
        home = $ClaudeHome
        root = $root
        settings = Join-Path $ClaudeHome 'settings.json'
        script = Join-Path $root 'notify.ps1'
        config = Join-Path $root 'config.json'
        token = Join-Path $root 'pushplus-token.dpapi'
        wechatState = Join-Path $root 'wechat-send-state.json'
        eventState = Join-Path $root 'event-state.json'
        log = Join-Path $root 'notifier.log'
    }
}
function Copy-NotifierScript {
    param([string]$Source, [string]$Destination)
    # 带 BOM 保存，Windows PowerShell 5.1 才能正确读取脚本里的中文。
    $text = [IO.File]::ReadAllText($Source).TrimStart([char]0xFEFF)
    [IO.File]::WriteAllText($Destination, $text, [Text.UTF8Encoding]::new($true))
}
function Backup-ClaudeNotifierFiles {
    param([string]$Root, [string[]]$Paths)
    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $backup = Join-Path $Root ('backups\' + $stamp)
    [IO.Directory]::CreateDirectory($backup) | Out-Null
    foreach ($path in $Paths) {
        if ([IO.File]::Exists($path)) { Copy-Item -LiteralPath $path -Destination (Join-Path $backup ([IO.Path]::GetFileName($path))) }
    }
    return $backup
}
function Restore-NotifierFiles {
    param([string]$Backup, [string[]]$Paths, [string[]]$Existing)
    foreach ($path in $Paths) {
        if ($Existing -contains $path) { Copy-Item -LiteralPath (Join-Path $Backup ([IO.Path]::GetFileName($path))) -Destination $path -Force }
        elseif ([IO.File]::Exists($path)) { Remove-Item -LiteralPath $path -Force }
    }
}
function Test-ClaudeNotifierHandler {
    param([object]$Handler, [string]$ScriptPath)
    if ($null -eq $Handler) { return $false }
    foreach ($key in @('command', 'args')) {
        $member = $Handler.PSObject.Properties[$key]
        if ($null -eq $member) { continue }
        foreach ($value in @($member.Value)) {
            if (([string]$value).IndexOf($ScriptPath, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
        }
    }
    return $false
}
function Remove-ClaudeNotifierHandlers {
    param([object]$Hooks, [string]$ScriptPath)
    # 遍历全部事件；同一组里属于其他工具的命令原样保留。
    foreach ($eventName in @($Hooks.PSObject.Properties | ForEach-Object { $_.Name })) {
        $event = $Hooks.PSObject.Properties[$eventName]
        if ($event.Value -isnot [array] -and $event.Value -isnot [pscustomobject]) { continue }
        $groups = @()
        foreach ($group in @($event.Value)) {
            $handlers = $null
            if ($null -ne $group) { $handlers = $group.PSObject.Properties['hooks'] }
            if ($null -eq $handlers) { $groups += $group; continue }
            $remaining = @(@($handlers.Value) | Where-Object { -not (Test-ClaudeNotifierHandler $_ $ScriptPath) })
            if ($remaining.Count -gt 0) { $handlers.Value = $remaining; $groups += $group }
        }
        if ($groups.Count -eq 0) { $Hooks.PSObject.Properties.Remove($eventName) } else { $event.Value = $groups }
    }
}
function Add-ClaudeNotifierHandler {
    param([object]$Hooks, [string]$Event, [string]$ScriptPath, [string]$Matcher)
    # exec 形式不经过 shell，路径里的空格和中文无需转义；async 保证不拖慢 Claude。
    $shell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $handler = [pscustomobject][ordered]@{
        type = 'command'
        command = $shell
        args = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath, '-Event', 'hook')
        async = $true
        timeout = 30
    }
    $group = [pscustomobject][ordered]@{}
    if (-not [string]::IsNullOrWhiteSpace($Matcher)) { Add-Member -InputObject $group -NotePropertyName matcher -NotePropertyValue $Matcher }
    Add-Member -InputObject $group -NotePropertyName hooks -NotePropertyValue @($handler)
    $property = $Hooks.PSObject.Properties[$Event]
    $existing = @()
    if ($null -ne $property) { $existing = @($property.Value) }
    Set-NotifierProperty $Hooks $Event (@($existing) + @($group))
}
function Get-ClaudeNotifierHookSummary {
    param([object]$Hooks, [string]$ScriptPath)
    $summary = @()
    foreach ($event in @($Hooks.PSObject.Properties)) {
        foreach ($group in @($event.Value)) {
            if ($null -eq $group -or $null -eq $group.PSObject.Properties['hooks']) { continue }
            if (@(@($group.hooks) | Where-Object { Test-ClaudeNotifierHandler $_ $ScriptPath }).Count -gt 0) {
                $label = $event.Name
                if ($group.PSObject.Properties['matcher'] -and $group.matcher) { $label += '（' + $group.matcher + '）' }
                $summary += $label
            }
        }
    }
    return $summary
}
function Test-ClaudeNotifierInstalled {
    param([object]$Paths)
    if (-not [IO.File]::Exists($Paths.script) -or -not [IO.File]::Exists($Paths.config)) { return $false }
    $document = Read-NotifierJson $Paths.settings
    if ($null -eq $document.PSObject.Properties['hooks'] -or $document.hooks -isnot [pscustomobject]) { return $false }
    return @(Get-ClaudeNotifierHookSummary $document.hooks $Paths.script) -contains 'Stop'
}
