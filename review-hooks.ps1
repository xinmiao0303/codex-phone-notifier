#requires -Version 5.1
# 打开 Codex 自带的审查界面；不会自动信任，也不会发送模型任务。
$ErrorActionPreference = 'Stop'
$command = Get-Command codex.exe -ErrorAction SilentlyContinue
$executable = $null
if ($null -ne $command) { $executable = $command.Source }
if (-not $executable) {
    $bin = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    if (Test-Path -LiteralPath $bin) {
        $candidate = Get-ChildItem -LiteralPath $bin -Filter codex.exe -File -Recurse | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($null -ne $candidate) { $executable = $candidate.FullName }
    }
}
if (-not $executable) { throw '找不到 codex 命令。请安装 Codex CLI，或在它所在目录运行 codex，再输入 /hooks。' }
Write-Host '进入后输入 /hooks，审查指向 codex-ntfy-notify.ps1 的本工具钩子。'
Write-Host '确认这些命令后再信任；不要直接信任不认识的其他钩子。'
Write-Host '完成后关闭这个终端界面，并完整退出重开 Codex 桌面应用。'
& $executable --no-daemon -C $PSScriptRoot
