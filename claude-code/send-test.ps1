#requires -Version 5.1
[CmdletBinding()]
param([string]$ClaudeHome = '', [ValidateSet('all', 'ntfy', 'wechat')][string]$Channel = 'all')
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
. (Join-Path $repository 'scripts\common.ps1')
. (Join-Path $repository 'scripts\claude-common.ps1')
$paths = Get-ClaudeNotifierPaths (Resolve-ClaudeDirectory $ClaudeHome)
if (-not [IO.File]::Exists($paths.script)) { throw '尚未安装，请先运行 install.ps1。' }
& $paths.script -Event test -Channel $Channel -ConfigPath $paths.config -Strict
Write-Host '请查看手机是否收到中文测试通知。此测试只验证发送通道，自动提醒还要用真实任务和选择题验证。'
