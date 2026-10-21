#requires -Version 5.1
[CmdletBinding()]
param([string]$ClaudeHome = '', [switch]$KeepConfig)
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
. (Join-Path $repository 'scripts\common.ps1')
. (Join-Path $repository 'scripts\claude-common.ps1')
$paths = Get-ClaudeNotifierPaths (Resolve-ClaudeDirectory $ClaudeHome)
$hasSettings = [IO.File]::Exists($paths.settings)
$document = Read-NotifierJson $paths.settings
$hooks = $document.PSObject.Properties['hooks']
if ($null -ne $hooks -and $hooks.Value -is [pscustomobject]) {
    Remove-ClaudeNotifierHandlers $hooks.Value $paths.script
    # 安装时新建的空 hooks 一并移除，让 settings.json 回到原样。
    if (@($hooks.Value.PSObject.Properties).Count -eq 0) { $document.PSObject.Properties.Remove('hooks') }
}
[IO.Directory]::CreateDirectory($paths.root) | Out-Null
# 只备份和移除明确的文件；不删除整个 .claude 目录，也不删除备份。
$backup = Backup-ClaudeNotifierFiles $paths.root @($paths.settings, $paths.config, $paths.script, $paths.token, $paths.wechatState, $paths.eventState)
if ($hasSettings) { Write-NotifierJson $paths.settings $document }
foreach ($ownedFile in @($paths.script, $paths.eventState)) {
    if ([IO.File]::Exists($ownedFile)) { Remove-Item -LiteralPath $ownedFile -Force }
}
if (-not $KeepConfig) {
    foreach ($ownedFile in @($paths.config, $paths.token, $paths.wechatState)) {
        if ([IO.File]::Exists($ownedFile)) { Remove-Item -LiteralPath $ownedFile -Force }
    }
}
Write-Host '本工具的完成、等待回答、确认计划、等待授权和出错提醒钩子已移除。'
Write-Host '保留其他钩子、Claude Code 设置、聊天记录和备份。新开的会话即不再提醒。'
Write-Host ('原文件备份：' + $backup)
