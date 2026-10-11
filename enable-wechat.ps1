#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$CodexHome = '',
    [Security.SecureString]$Token,
    [switch]$Gui,
    [switch]$OnlyWechat,
    [switch]$Disable,
    [switch]$NoTest
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\common.ps1')
$directory = Resolve-NotifierDirectory $CodexHome
$configFile = Join-Path $directory 'ntfy-codex.json'
$targetScript = Join-Path $directory 'scripts\codex-ntfy-notify.ps1'
$tokenFile = Join-Path $directory 'pushplus-token.dpapi'
$stateFile = Join-Path $directory 'wechat-send-state.json'
if (-not [IO.File]::Exists($configFile) -or -not [IO.File]::Exists($targetScript)) { throw '请先运行 install.ps1 安装通知工具。' }
$settings = Read-NotifierJson $configFile
if ($Disable) {
    $backup = Backup-NotifierFiles $directory @($configFile)
    Set-NotifierProperty $settings 'channels' @('ntfy')
    Write-NotifierJson $configFile $settings
    Write-Host '已关闭微信通道，ntfy 提醒继续使用；加密密钥保留在本机。'
    return
}
if ($null -eq $Token) {
    if ($Gui) {
        # 使用当前 PowerShell 自带的加密模块，避免新版模块路径被旧版继承时加载冲突。
        Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1') -ErrorAction Stop
        $convertTokenCommand = Get-Command -Name ConvertTo-SecureString -CommandType Cmdlet -ErrorAction Stop
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $form = [Windows.Forms.Form]::new()
        $form.Text = '连接 Codex 微信提醒'
        $form.ClientSize = [Drawing.Size]::new(500, 190)
        $form.StartPosition = 'CenterScreen'
        $form.FormBorderStyle = 'FixedDialog'
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false
        $form.TopMost = $true
        $label = [Windows.Forms.Label]::new()
        $label.Text = '粘贴 PushPlus 的用户 token 或消息 token（不是 AccessKey）。密钥只在本机加密保存。请先完成公众号关注和实名认证。'
        $label.Location = [Drawing.Point]::new(18, 16)
        $label.Size = [Drawing.Size]::new(465, 48)
        $box = [Windows.Forms.TextBox]::new()
        $box.Location = [Drawing.Point]::new(18, 76)
        $box.Size = [Drawing.Size]::new(465, 24)
        $box.UseSystemPasswordChar = $true
        $save = [Windows.Forms.Button]::new()
        $save.Text = '保存并测试'
        $save.Location = [Drawing.Point]::new(250, 133)
        $save.Size = [Drawing.Size]::new(112, 32)
        $save.DialogResult = [Windows.Forms.DialogResult]::OK
        $cancel = [Windows.Forms.Button]::new()
        $cancel.Text = '取消'
        $cancel.Location = [Drawing.Point]::new(373, 133)
        $cancel.Size = [Drawing.Size]::new(110, 32)
        $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
        $form.Controls.AddRange(@($label, $box, $save, $cancel))
        $form.AcceptButton = $save
        $form.CancelButton = $cancel
        try {
            if ($form.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { Write-Host '已取消，没有修改配置。'; return }
            $Token = & $convertTokenCommand -String ($box.Text.Trim()) -AsPlainText -Force
            $box.Clear()
        } catch {
            [Windows.Forms.MessageBox]::Show(('密钥尚未保存。Windows 密钥加密操作失败，错误类型：' + $_.Exception.GetType().Name + '。请保留 PowerShell 窗口，回到 Codex 继续排查。'), 'Codex 微信配置未完成', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            throw
        } finally { $box.Clear(); $form.Dispose() }
    } else {
        Write-Host '从 https://www.pushplus.plus/ 复制用户 token 或消息 token。不要粘贴到聊天或命令参数里。'
        $Token = Read-Host '在这里粘贴 token（不会显示内容）' -AsSecureString
    }
}
if ($null -eq $Token -or $Token.Length -eq 0) { throw '密钥不能为空；尚未修改配置。' }
$encrypted = ConvertFrom-SecureString -SecureString $Token
$paths = @($configFile, $tokenFile, $targetScript, $stateFile)
$originalFiles = @($paths | Where-Object { [IO.File]::Exists($_) })
$backup = Backup-NotifierFiles $directory $paths
try {
    [IO.File]::WriteAllText($tokenFile, $encrypted, [Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'scripts\notify.ps1') -Destination $targetScript -Force
    $channels = @('ntfy', 'wechat')
    if ($OnlyWechat) { $channels = @('wechat') }
    Set-NotifierProperty $settings 'channels' $channels
    Write-NotifierJson $configFile $settings
    if ([IO.File]::Exists($stateFile)) { Remove-Item -LiteralPath $stateFile -Force }
} catch {
    foreach ($path in $paths) {
        if ($originalFiles -contains $path) { Copy-Item -LiteralPath (Join-Path $backup ([IO.Path]::GetFileName($path))) -Destination $path -Force }
        elseif ([IO.File]::Exists($path)) { Remove-Item -LiteralPath $path -Force }
    }
    throw
}
Write-Host '微信配置已保存。密钥使用 Windows 加密，只能在当前电脑的当前用户下使用。'
Write-Host '没有改动钩子命令，下次事件即可读取新设置。'
Write-Host ('原文件备份：' + $backup)
if (-not $NoTest) {
    & $targetScript -Event test -Channel wechat -ConfigPath $configFile -Strict
    Write-Host '先确认微信和手环都收到，再关闭小米运动健康里的“其他”，保留“微信”。'
}
