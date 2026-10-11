#requires -Version 5.1
[CmdletBinding()]
param([string]$CodexHome = '', [switch]$KeepConfig)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\common.ps1')
$directory = Resolve-NotifierDirectory $CodexHome
$hooksFile = Join-Path $directory 'hooks.json'
$configFile = Join-Path $directory 'ntfy-codex.json'
$targetScript = Join-Path $directory 'scripts\codex-ntfy-notify.ps1'
$tokenFile = Join-Path $directory 'pushplus-token.dpapi'
$stateFile = Join-Path $directory 'wechat-send-state.json'
$hasHooksFile = [IO.File]::Exists($hooksFile)
$document = Read-NotifierJson $hooksFile
$hooks = $document.PSObject.Properties['hooks']
if ($null -ne $hooks -and $null -ne $hooks.Value) { Remove-NotifierHandlers $hooks.Value $targetScript }
# 只备份和移除明确的文件；不删除整个 .codex 目录。
$backup = Backup-NotifierFiles $directory @($hooksFile, $configFile, $targetScript, $tokenFile, $stateFile)
if ($hasHooksFile) { Write-NotifierJson $hooksFile $document }
if ([IO.File]::Exists($targetScript)) { Remove-Item -LiteralPath $targetScript -Force }
if (-not $KeepConfig) {
    foreach ($ownedFile in @($configFile, $tokenFile, $stateFile)) {
        if ([IO.File]::Exists($ownedFile)) { Remove-Item -LiteralPath $ownedFile -Force }
    }
}
Write-Host '本工具的完成、等待输入、启动钩子已移除。'
Write-Host '其他钩子、config.toml、聊天记录和备份不会删除。'
Write-Host '请完整退出并重新打开 Codex。'
Write-Host ('原文件备份：' + $backup)
