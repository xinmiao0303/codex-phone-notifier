#requires -Version 5.1
# 安装和卸载共用的文件处理；不会读取或修改 config.toml。
function Resolve-NotifierDirectory {
    param([string]$Directory)
    if ([string]::IsNullOrWhiteSpace($Directory)) { $Directory = $env:CODEX_HOME }
    if ([string]::IsNullOrWhiteSpace($Directory)) { $Directory = Join-Path $env:USERPROFILE '.codex' }
    return [IO.Path]::GetFullPath($Directory)
}
function Read-NotifierJson {
    param([string]$Path)
    if (-not [IO.File]::Exists($Path)) { return [pscustomobject]@{} }
    try {
        $document = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
        if ($null -eq $document -or $document -is [array] -or $document -is [string] -or $document -is [ValueType]) { throw 'JSON root must be an object' }
        return $document
    } catch { throw ('无法读取配置文件，请先修复它，再重新运行：' + $Path) }
}
function Set-NotifierProperty {
    param([object]$Object, [string]$Name, [object]$Value)
    $member = $Object.PSObject.Properties[$Name]
    if ($null -eq $member) {
        Add-Member -InputObject $Object -NotePropertyName $Name -NotePropertyValue $Value
    } else { $member.Value = $Value }
}
function Write-NotifierJson {
    param([string]$Path, [object]$Object)
    # Codex 的 JSON 解析器需要没有 BOM 的 UTF-8。
    $json = ConvertTo-Json -InputObject $Object -Depth 32
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}
function Backup-NotifierFiles {
    param([string]$Directory, [string[]]$Paths)
    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $backup = Join-Path $Directory ('backups\codex-phone-notifier\' + $stamp)
    [IO.Directory]::CreateDirectory($backup) | Out-Null
    foreach ($path in $Paths) {
        if ([IO.File]::Exists($path)) { Copy-Item -LiteralPath $path -Destination (Join-Path $backup ([IO.Path]::GetFileName($path))) }
    }
    return $backup
}
function Remove-NotifierHandlers {
    param([object]$Hooks, [string]$ScriptPath)
    # 保留同一组里属于其他工具的命令，不删除整个钩子文件。
    foreach ($eventName in @('Stop', 'PreToolUse', 'PermissionRequest', 'SessionStart')) {
        $event = $Hooks.PSObject.Properties[$eventName]
        if ($null -eq $event) { continue }
        $groups = @()
        foreach ($group in @($event.Value)) {
            $handlers = $group.PSObject.Properties['hooks']
            if ($null -eq $handlers) { $groups += $group; continue }
            $remaining = @()
            foreach ($handler in @($handlers.Value)) {
                $owned = $false
                foreach ($key in @('command', 'commandWindows', 'command_windows')) {
                    $command = $handler.PSObject.Properties[$key]
                    if ($null -ne $command -and ([string]$command.Value).IndexOf($ScriptPath, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $owned = $true }
                }
                if (-not $owned) { $remaining += $handler }
            }
            if ($remaining.Count -gt 0) { $handlers.Value = $remaining; $groups += $group }
        }
        if ($groups.Count -eq 0) { $Hooks.PSObject.Properties.Remove($eventName) } else { $event.Value = $groups }
    }
}
function Add-NotifierHandler {
    param([object]$Hooks, [string]$Event, [string]$Command, [string]$Matcher, [string]$Status, [switch]$Async)
    $group = [pscustomobject]@{ hooks = @([pscustomobject]@{ type = 'command'; command = $Command; timeout = 15; statusMessage = $Status }) }
    if ($Async) { Add-Member -InputObject $group.hooks[0] -NotePropertyName async -NotePropertyValue $true; $group.hooks[0].timeout=30 }
    if (-not [string]::IsNullOrWhiteSpace($Matcher)) { Add-Member -InputObject $group -NotePropertyName matcher -NotePropertyValue $Matcher }
    $property = $Hooks.PSObject.Properties[$Event]
    $existing = @()
    if ($null -ne $property) { $existing = @($property.Value) }
    Set-NotifierProperty $Hooks $Event (@($existing) + @($group))
}
