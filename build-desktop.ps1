#requires -Version 5.1
[CmdletBinding()]
param([string]$OutputDirectory = '')
$ErrorActionPreference = 'Stop'
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot 'dist' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not [IO.File]::Exists($compiler)) { $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not [IO.File]::Exists($compiler)) { throw '找不到 Windows .NET Framework 编译器。请安装 .NET Framework 4.8。' }
$output = Join-Path $OutputDirectory 'CodexPhoneNotifier.exe'
$arguments = @('/nologo', '/target:winexe', '/optimize+', '/platform:anycpu', '/utf8output', ('/out:' + $output), '/reference:System.dll', '/reference:System.Core.dll', '/reference:System.Drawing.dll', '/reference:System.Windows.Forms.dll', '/reference:System.Web.Extensions.dll')
foreach ($relative in @('install.ps1','uninstall.ps1','review-hooks.ps1','scripts/common.ps1','scripts/notify.ps1','desktop/desktop-backend.ps1')) {
    $arguments += '/resource:' + (Join-Path $PSScriptRoot $relative) + ',payload.' + $relative.Replace('/', '.')
}
$arguments += Join-Path $PSScriptRoot 'desktop/Program.cs'
& $compiler @arguments
if ($LASTEXITCODE -ne 0) { throw '图形程序编译失败。' }
Write-Host ('已生成：' + $output)
