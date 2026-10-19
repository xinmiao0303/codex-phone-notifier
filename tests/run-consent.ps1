#requires -Version 5.1
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'scripts/common.ps1')
. (Join-Path $repo 'scripts/mcp-consent.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('codex-consent-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
$checks=0
function Assert-Consent([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
try{
 $compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
 $proxy=Join-Path $root 'proxy.exe';$client=Join-Path $root 'node_repl.exe'
 & $compiler /nologo /target:exe /optimize+ /reference:System.dll /reference:System.Core.dll /reference:System.Web.Extensions.dll ('/out:'+$proxy) (Join-Path $repo 'desktop/McpConsentProxy.cs')
 if($LASTEXITCODE -ne 0){throw '代理编译失败'}
 & $compiler /nologo /target:exe /optimize+ /reference:System.dll /reference:System.Core.dll /reference:System.Web.Extensions.dll ('/out:'+$client) (Join-Path $repo 'tests/ConsentProxyTests.cs')
 if($LASTEXITCODE -ne 0){throw '测试程序编译失败'}
 $marker=Join-Path $root 'notifications.txt';$notify=Join-Path $root 'notify.ps1'
 $code=@"
param([string]`$Event,[string]`$ConsentId,[string]`$ConfigPath)
`$ErrorActionPreference='Stop'
`if([IO.File]::Exists(`$ConfigPath+'.delay')){[IO.File]::WriteAllText(`$ConfigPath+'.started','started');Start-Sleep -Seconds 2}
`$mutex=[Threading.Mutex]::new(`$false,'Local\CodexConsentTest-$([guid]::NewGuid().ToString('N'))')
try{if(-not `$mutex.WaitOne(5000)){throw 'busy'};[IO.File]::AppendAllText(`$ConfigPath,`$ConsentId+"``n")}finally{try{`$mutex.ReleaseMutex()}catch{};`$mutex.Dispose()}
"@
 [IO.File]::WriteAllText($notify,$code,[Text.UTF8Encoding]::new($true))
 & $client $proxy $marker $notify
 if($LASTEXITCODE -ne 0){throw 'MCP 消息和提醒时序检查失败'}
 $directory=Join-Path $root '用户 配置';[IO.Directory]::CreateDirectory($directory)|Out-Null
 $config=Join-Path $directory 'config.toml'
 $text="keep = true`r`n[mcp_servers.node_repl]`r`nargs = []`r`ncommand = '$client'`r`nstartup_timeout_sec = 120`r`n[mcp_servers.node_repl.env]`r`nTEST_VALUE = 'keep'`r`n[windows]`r`nsandbox = 'elevated'`r`n"
 [IO.File]::WriteAllText($config,$text,[Text.UTF8Encoding]::new($false))
 $source=Join-Path $repo 'desktop/McpConsentProxy.cs'
 Assert-Consent (Enable-ConsentProxy $directory $source) '安装原生授权连接失败'
 $after=[IO.File]::ReadAllText($config);$info=Get-ConsentMcpBlock $after
 Assert-Consent ([IO.File]::Exists($info.Command) -and $info.Command -ne $client -and $info.Args.Count -eq 0 -and (Read-NotifierJson (Join-Path $directory 'mcp-consent-proxy.json')).originalCommand -eq $client) '插件原程序和空参数未保留'
 Assert-Consent ($after.Contains("startup_timeout_sec = 120`r`n[mcp_servers.node_repl.env]`r`nTEST_VALUE = 'keep'`r`n[windows]`r`nsandbox = 'elevated'")) '其他配置或插件环境变量被修改'
 Assert-Consent (Enable-ConsentProxy $directory $source) '重复更新失败'
 Assert-Consent ([IO.File]::ReadAllText($config) -eq $after) '重复更新不能再次套一层代理'
 Disable-ConsentProxy $directory
 Assert-Consent ([IO.File]::ReadAllText($config) -eq $text) '卸载未逐字恢复原插件启动配置'
 Assert-Consent (-not [IO.File]::Exists((Join-Path $directory 'mcp-consent-proxy.json'))) '卸载未清理本工具状态'
 [IO.File]::WriteAllText($config,$text,[Text.UTF8Encoding]::new($false))
 & (Join-Path $repo 'install.ps1') -CodexHome $directory *> $null
 Assert-Consent ([IO.File]::Exists((Join-Path $directory 'mcp-consent-proxy.json'))) '安装器没有自动启用原生授权连接'
 & (Join-Path $repo 'install.ps1') -CodexHome $directory -NoApprovalReminder *> $null
 Assert-Consent ([IO.File]::ReadAllText($config) -eq $text) '显式关闭授权提醒时未恢复原启动配置'
 & (Join-Path $repo 'install.ps1') -CodexHome $directory *> $null
 $changed=[IO.File]::ReadAllText($config)+"`r`n[custom]`r`nkeep_new_value = true`r`n"
 [IO.File]::WriteAllText($config,$changed,[Text.UTF8Encoding]::new($false))
 & (Join-Path $repo 'uninstall.ps1') -CodexHome $directory -KeepConfig *> $null
 Assert-Consent ([IO.File]::ReadAllText($config) -eq ($text+"`r`n[custom]`r`nkeep_new_value = true`r`n")) '卸载必须保留安装后用户新增的其他配置'
 $missingArgs=$text.Replace("args = []`r`n",'')
 [IO.File]::WriteAllText($config,$missingArgs,[Text.UTF8Encoding]::new($false))
 Assert-Consent (Enable-ConsentProxy $directory $source) '缺省 args 时安装失败'
 Disable-ConsentProxy $directory
 Assert-Consent ([IO.File]::ReadAllText($config) -eq $missingArgs) '缺省 args 卸载未恢复原配置'
 # 用内存环境模拟桌面启动入口，绝不改测试机器真实环境。
 $runtime=@{}
 Assert-Consent (Enable-ConsentProxy $directory $source $runtime) '桌面运行入口安装失败'
 $info=Get-ConsentMcpBlock ([IO.File]::ReadAllText($config))
 Assert-Consent ($runtime.CODEX_NODE_REPL_PATH -eq $info.Command -and $info.Args.Count -eq 0) '桌面重新生成的空参数命令不能启动转发器'
 [IO.File]::WriteAllText($config,$missingArgs,[Text.UTF8Encoding]::new($false))
 Assert-Consent (Enable-ConsentProxy $directory $source $runtime) '旧桌面环境覆盖配置后升级失败'
 $record=Read-NotifierJson (Join-Path $directory 'mcp-consent-proxy.json')
 Assert-Consent ($record.originalCommand -eq $client -and -not $record.originalUserOverride) '升级丢失原程序或把代理作为原程序'
 Disable-ConsentProxy $directory $runtime
 Assert-Consent (-not $runtime.ContainsKey('CODEX_NODE_REPL_PATH') -and [IO.File]::ReadAllText($config) -eq $missingArgs) '卸载未恢复环境与配置'
 $runtime.CODEX_NODE_REPL_PATH='custom-user-runtime.exe';$rejected=$false
 try{Enable-ConsentProxy $directory $source $runtime|Out-Null}catch{$rejected=$_.Exception.Message.Contains('CODEX_NODE_REPL_PATH')}
 Assert-Consent ($rejected -and $runtime.CODEX_NODE_REPL_PATH -eq 'custom-user-runtime.exe' -and [IO.File]::ReadAllText($config) -eq $missingArgs) '不应覆盖其他自定义运行程序'
 $runtime.Clear();Enable-ConsentProxy $directory $source $runtime|Out-Null
 $runtime.CODEX_NODE_REPL_PATH='later-user-runtime.exe'
 Disable-ConsentProxy $directory $runtime
 Assert-Consent ($runtime.CODEX_NODE_REPL_PATH -eq 'later-user-runtime.exe') '卸载应保留用户后来设置的运行程序'
 [IO.File]::WriteAllText($config,'keep = true',[Text.UTF8Encoding]::new($false))
 Assert-Consent (-not (Enable-ConsentProxy $directory $source) -and [IO.File]::ReadAllText($config) -eq 'keep = true') '未安装对应插件时不应改写配置'
 Write-Host ('PASS: consent installation {0} checks; PowerShell {1}' -f $checks,$PSVersionTable.PSVersion)
}finally{
 $target=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if($target.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($target).StartsWith('codex-consent-')){Remove-Item -LiteralPath $target -Recurse -Force}
}