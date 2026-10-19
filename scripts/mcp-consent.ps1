#requires -Version 5.1
# 仅为 node_repl 的 MCP 启动器增加透明转发；保留其他配置、环境变量及审批决定。
function Get-ConsentMcpBlock {
    param([string]$Text)
    $block=[regex]::Match($Text,'(?ms)^\[mcp_servers\.(?:node_repl|"node_repl")\][^\r\n]*\r?\n(?<body>.*?)(?=^\[|\z)')
    if(-not $block.Success){return $null}
    $body=$block.Groups['body'].Value
    $commands=[regex]::Matches($body,'(?m)^[ \t]*command[ \t]*=[ \t]*(?<value>[^\r\n]*)(?:\r?\n|$)')
    $arguments=[regex]::Matches($body,'(?m)^[ \t]*args[ \t]*=[ \t]*(?<value>[^\r\n]*)(?:\r?\n|$)')
    if($commands.Count -ne 1 -or $arguments.Count -gt 1){throw 'node_repl 启动配置格式无法识别，已保留原配置。'}
    $literal=$commands[0].Groups['value'].Value.Trim()
    if($literal -match "^'([^']*)'\s*(?:#.*)?$"){$command=$Matches[1]}
    elseif($literal -match '^("(?:[^"\\]|\\.)*")\s*(?:#.*)?$'){$command=ConvertFrom-Json $Matches[1]}
    else{throw 'node_repl 的程序路径无法识别，已保留原配置。'}
    $serverArguments=@()
    if($arguments.Count){try{$parsedArguments=$arguments[0].Groups['value'].Value.Trim()|ConvertFrom-Json;foreach($argument in $parsedArguments){$serverArguments+=[string]$argument}}catch{throw 'node_repl 的参数格式无法识别，已保留原配置。'}}
    return [pscustomobject]@{Match=$block;Body=$body;Command=[string]$command;Args=$serverArguments;CommandLine=$commands[0].Value;ArgsLine=$(if($arguments.Count){$arguments[0].Value}else{''})}
}
function Set-ConsentMcpLines {
    param([string]$Text,[object]$Info,[string]$CommandLine,[string]$ArgsLine)
    $body=$Info.Body
    if($Info.ArgsLine){$body=$body.Replace($Info.ArgsLine,$ArgsLine)}
    elseif($ArgsLine){$CommandLine+=$ArgsLine}
    $body=$body.Replace($Info.CommandLine,$CommandLine)
    return $Text.Substring(0,$Info.Match.Groups['body'].Index)+$body+$Text.Substring($Info.Match.Groups['body'].Index+$Info.Body.Length)
}
function Get-ConsentProxySource {
    param([string]$Directory,[string]$Source)
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if(-not [IO.File]::Exists($compiler)){$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'}
    if(-not [IO.File]::Exists($compiler)){throw '启用插件授权提醒需要 Windows 自带的 .NET Framework 编译器。'}
    $digest=(Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash.Substring(0,12).ToLowerInvariant()
    $target=Join-Path $Directory ('scripts\CodexMcpConsentProxy-'+$digest+'.exe')
    if(-not [IO.File]::Exists($target)){
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))|Out-Null
        & $compiler /nologo /target:exe /optimize+ /reference:System.dll /reference:System.Core.dll /reference:System.Web.Extensions.dll ('/out:'+$target) $Source *> $null
        if($LASTEXITCODE -ne 0 -or -not [IO.File]::Exists($target)){throw '插件授权提醒辅助程序编译失败，原插件配置未修改。'}
    }
    return $target
}
function Get-ConsentRuntimeOverride {
    param([hashtable]$RuntimeEnvironment)
    if($null -ne $RuntimeEnvironment){return $RuntimeEnvironment['CODEX_NODE_REPL_PATH']}
    return [Environment]::GetEnvironmentVariable('CODEX_NODE_REPL_PATH','User')
}
function Set-ConsentRuntimeOverride {
    param([AllowNull()][string]$Value,[hashtable]$RuntimeEnvironment)
    if($null -ne $RuntimeEnvironment){
        if([string]::IsNullOrEmpty($Value)){$RuntimeEnvironment.Remove('CODEX_NODE_REPL_PATH')}else{$RuntimeEnvironment['CODEX_NODE_REPL_PATH']=$Value}
        return
    }
    [Environment]::SetEnvironmentVariable('CODEX_NODE_REPL_PATH',$Value,'User')
    # 标准环境变更通知，让资源管理器启动的新 Codex 进程读取新值。
    try{
        if(-not ('CodexNotifier.EnvironmentBroadcast' -as [type])){
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace CodexNotifier {
 public static class EnvironmentBroadcast {
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  private static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint msg, UIntPtr wp, string lp, uint flags, uint timeout, out UIntPtr result);
  public static void Refresh() { UIntPtr result; SendMessageTimeout(new IntPtr(65535), 26, UIntPtr.Zero, "Environment", 2, 1000, out result); }
 }
}
"@ | Out-Null
        }
        [CodexNotifier.EnvironmentBroadcast]::Refresh()
    }catch{}
}
function Enable-ConsentProxy {
    param([string]$Directory,[string]$Source,[hashtable]$RuntimeEnvironment=$null)
    $config=Join-Path $Directory 'config.toml';$statePath=Join-Path $Directory 'mcp-consent-proxy.json'
    if(-not [IO.File]::Exists($config)){return $false}
    $text=[IO.File]::ReadAllText($config);$info=Get-ConsentMcpBlock $text
    if($null -eq $info){return $false}
    $priorState=$null
    if([IO.File]::Exists($statePath)){$priorState=Read-NotifierJson $statePath}
    $owned=$null -ne $priorState -and $info.Command -eq $priorState.proxyCommand
    if($owned){
        if(($info.Args|ConvertTo-Json -Compress) -ne (@($priorState.proxyArgs)|ConvertTo-Json -Compress)){throw '插件启动参数已被手动修改，已保留现有配置。'}
        $originalCommand=[string]$priorState.originalCommand
        $originalCommandLine=[string]$priorState.originalCommandLine
        $originalArgsLine=[string]$priorState.originalArgsLine
    }else{
        if([IO.Path]::GetFileName($info.Command) -ne 'node_repl.exe'){return $false}
        if($info.Args.Count -gt 0){throw '目前仅支持 node_repl 的标准空参数启动方式，已保留自定义参数。'}
        $originalCommand=$info.Command;$originalCommandLine=$info.CommandLine;$originalArgsLine=$info.ArgsLine
    }
    if(-not [IO.File]::Exists($originalCommand)){throw '找不到原来的 node_repl 程序，插件启动配置未修改。'}
    # 自定义目录的隔离测试/CLI 安装不改变全局环境；当前 Codex 主目录才配置桌面入口。
    $useRuntime=$null -ne $RuntimeEnvironment -or [IO.Path]::GetFullPath($Directory).TrimEnd('\') -eq [IO.Path]::GetFullPath((Resolve-NotifierDirectory '')).TrimEnd('\')
    $oldOverride=$null;$originalOverride=$null
    if($useRuntime){
        $oldOverride=Get-ConsentRuntimeOverride $RuntimeEnvironment
        $runtimeOwned=$null -ne $priorState -and $priorState.runtimeOverride -and $oldOverride -eq $priorState.proxyCommand
        if($oldOverride -and -not $runtimeOwned){throw 'CODEX_NODE_REPL_PATH 已有自定义运行程序，已保留；请先处理该设置再启用应用授权提醒。'}
        if($runtimeOwned){$originalOverride=$priorState.originalUserOverride}else{$originalOverride=$oldOverride}
    }
    $proxy=Get-ConsentProxySource $Directory $Source
    $newline="`n";if($text.Contains("`r`n")){$newline="`r`n"}
    $commandLine='command = '+(ConvertTo-Json -InputObject $proxy -Compress)+$newline
    $argsLine='args = []'+$newline
    $updated=Set-ConsentMcpLines $text $info $commandLine $argsLine
    $record=[pscustomobject]@{version=2;server='node_repl';originalCommand=$originalCommand;originalCommandLine=$originalCommandLine;originalArgsLine=$originalArgsLine;proxyCommand=$proxy;proxyArgs=@();runtimeOverride=$useRuntime;originalUserOverride=$originalOverride}
    $backup=Backup-NotifierFiles $Directory @($config,$statePath)
    $hadState=[IO.File]::Exists($statePath)
    try{
        if([IO.File]::ReadAllText($config) -ne $text){throw 'Codex 配置正在被其他程序修改，请稍后重试。'}
        Write-NotifierJson $statePath $record
        [IO.File]::WriteAllText($config,$updated,[Text.UTF8Encoding]::new($false))
        if($useRuntime){Set-ConsentRuntimeOverride $proxy $RuntimeEnvironment}
    }catch{
        Copy-Item -LiteralPath (Join-Path $backup 'config.toml') -Destination $config -Force
        if($hadState){Copy-Item -LiteralPath (Join-Path $backup 'mcp-consent-proxy.json') -Destination $statePath -Force}
        elseif([IO.File]::Exists($statePath)){Remove-Item -LiteralPath $statePath -Force}
        if($useRuntime -and (Get-ConsentRuntimeOverride $RuntimeEnvironment) -ne $oldOverride){Set-ConsentRuntimeOverride $oldOverride $RuntimeEnvironment}
        throw
    }
    return $true
}
function Disable-ConsentProxy {
    param([string]$Directory,[hashtable]$RuntimeEnvironment=$null)
    $statePath=Join-Path $Directory 'mcp-consent-proxy.json';$config=Join-Path $Directory 'config.toml'
    if(-not [IO.File]::Exists($statePath)){return}
    $record=Read-NotifierJson $statePath
    $backup=Backup-NotifierFiles $Directory @($config,$statePath)
    if([IO.File]::Exists($config)){
        $text=[IO.File]::ReadAllText($config);$info=Get-ConsentMcpBlock $text
        if($null -ne $info -and $info.Command -eq $record.proxyCommand){
            if(($info.Args|ConvertTo-Json -Compress) -ne (@($record.proxyArgs)|ConvertTo-Json -Compress)){throw '插件启动参数已被手动修改，卸载前请先恢复原插件启动器。'}
            $updated=Set-ConsentMcpLines $text $info ([string]$record.originalCommandLine) ([string]$record.originalArgsLine)
            if([IO.File]::ReadAllText($config) -ne $text){throw 'Codex 配置正在被修改，请稍后卸载。'}
            [IO.File]::WriteAllText($config,$updated,[Text.UTF8Encoding]::new($false))
        }
    }
    # 仅恢复仍指向本工具的环境设置，保留用户后来换用的其他运行程序。
    if($record.runtimeOverride -and (Get-ConsentRuntimeOverride $RuntimeEnvironment) -eq $record.proxyCommand){Set-ConsentRuntimeOverride ([string]$record.originalUserOverride) $RuntimeEnvironment}
    Remove-Item -LiteralPath $statePath -Force
    $proxy=[string]$record.proxyCommand
    $scripts=[IO.Path]::GetFullPath((Join-Path $Directory 'scripts'))
    if($proxy -and [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($proxy)) -eq $scripts -and [IO.Path]::GetFileName($proxy) -match '^CodexMcpConsentProxy-[a-f0-9]{12}\.exe$'){
        # 活动 MCP 连接可能仍占用旧文件，退出后可清理。
        if([IO.File]::Exists($proxy)){try{Remove-Item -LiteralPath $proxy -Force -ErrorAction Stop}catch{}}
    }
}
