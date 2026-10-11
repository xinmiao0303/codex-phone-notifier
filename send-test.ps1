#requires -Version 5.1
[CmdletBinding()]
param([string]$CodexHome = '', [ValidateSet('all', 'ntfy', 'wechat')][string]$Channel = 'all')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\common.ps1')
$directory = Resolve-NotifierDirectory $CodexHome
$script = Join-Path $directory 'scripts\codex-ntfy-notify.ps1'
if (-not [IO.File]::Exists($script)) { throw '尚未安装，请先运行 install.ps1。' }
& $script -Event test -Channel $Channel -ConfigPath (Join-Path $directory 'ntfy-codex.json') -Strict
Write-Host '请查看手机是否收到中文测试通知。此测试只验证发送通道，自动提醒还要用真实任务和选择题验证。'
