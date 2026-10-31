#requires -Version 5.1
<#
.SYNOPSIS
Install Windows terminal tools and Yazi configuration.
.EXAMPLE
.\install.ps1 -Proxy http://127.0.0.1:17897
.EXAMPLE
.\install.ps1 -Components yazi -Proxy http://127.0.0.1:17897
.EXAMPLE
.\install.ps1 -ConfigureOnly -ForceConfig
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Components,
    [string]$Proxy,
    [switch]$NonInteractive,
    [switch]$ConfigureOnly,
    [switch]$ForceConfig,
    [ValidateSet('powershell','pwsh')][string]$PsmuxShell,
    [ValidateSet('User','Machine')][string]$EnvironmentScope = 'User'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
if ($env:OS -ne 'Windows_NT') { throw 'Run this installer on Windows PowerShell 5.1 or PowerShell 7.' }
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if ($EnvironmentScope -eq 'Machine' -and -not $isAdmin) { throw '-EnvironmentScope Machine requires an administrator console.' }
Write-Host 'Windows 终端工具安装器' -ForegroundColor Cyan
$selected = if ($Components) {
    @(Resolve-Components $Components)
} elseif ($NonInteractive) {
    @('vim','psmux','yazi','chafa')
} else {
    @(Read-Components)
}
$scoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
$shims = Join-Path $scoopRoot 'shims'
if (Test-Path -LiteralPath $shims) { $env:PATH = "$shims;$env:PATH" }

Write-Host "已选择：$($selected -join ', ')"
$states = @($selected | ForEach-Object { Get-ToolState $_ $scoopRoot })
foreach ($state in $states) {
    switch ($state.State) {
        'Present' {
            Write-Host "[已存在，跳过下载] $($state.Name)：$($state.Path)" -ForegroundColor Green
            if ($state.AddToPath) {
                $env:PATH = (Split-Path $state.Path -Parent) + ';' + $env:PATH
                Write-Warning "$($state.Name) 未在 PATH 中，仅为本次安装临时加入；请将其目录加入用户 PATH，供新终端使用。"
            }
        }
        'ScoopInstalled' { Write-Host "[已安装，待修复命令入口] $($state.Name)：$($state.Path)" -ForegroundColor Yellow }
        'Missing' { Write-Host "[待安装] $($state.Name)" -ForegroundColor Yellow }
    }
}
# Detect preview support before offering Git. Git is optional, never silently added.
if ($selected -contains 'yazi' -and -not (Find-YaziFileExe $scoopRoot) -and $selected -notcontains 'git') {
    Write-Warning '未找到 file.exe；Yazi 文件类型识别及部分预览可能不可用。Git for Windows 可提供此文件。'
    if (-not $NonInteractive -and -not $ConfigureOnly) {
        if ((Read-Host '是否额外安装 Git？[y/N]').Trim() -match '^(y|yes)$') {
            $selected += 'git'
            $gitState = Get-ToolState 'git' $scoopRoot
            $states += $gitState
            Write-Host "Git：$($gitState.State) $($gitState.Path)"
            if ($gitState.AddToPath) { $env:PATH = (Split-Path $gitState.Path -Parent) + ';' + $env:PATH }
        }
    }
}
$toInstall = @($states | Where-Object State -eq 'Missing' | ForEach-Object Name)
$toRepair = @($states | Where-Object State -eq 'ScoopInstalled' | ForEach-Object Name)
if ($ConfigureOnly) {
    Write-Host '仅配置模式：不下载软件、不修复 Scoop 入口、不修改代理。'
} elseif ($toInstall.Count -or $toRepair.Count) {
    Write-Host '[1/3] 安装缺少的软件 / 修复入口' -ForegroundColor Cyan
    # Ask for network settings only after selection/detection, and only if a download may be needed.
    $scoopCommand = Get-Command scoop -ErrorAction SilentlyContinue
    $needBootstrap = -not $scoopCommand
    if ($needBootstrap) {
        Write-Host '未检测到 Scoop，将在网络设置完成后下载安装。' -ForegroundColor Yellow
    } else {
        Write-Host "已检测到 Scoop：$($scoopCommand.Source)，直接使用，无需重新下载。" -ForegroundColor Green
    }
    if (($toInstall.Count -or $needBootstrap) -and -not $PSBoundParameters.ContainsKey('Proxy') -and -not $NonInteractive) {
        $Proxy = Read-ProxyAddress
    }
    if ($Proxy) {
        $proxyUri = ConvertTo-ProxyUri $Proxy
        $env:http_proxy = $proxyUri.AbsoluteUri
        $env:https_proxy = $proxyUri.AbsoluteUri
        Write-Host "使用代理：$($proxyUri.AbsoluteUri)"
    } else {
        Write-Host '保留现有代理/网络设置（不强制直连）。'
    }
    Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
    if ($needBootstrap) {
        if ((Test-Path -LiteralPath $scoopRoot) -and @(Get-ChildItem -LiteralPath $scoopRoot -Force).Count -gt 0) {
            throw "Scoop 命令不可用，但 $scoopRoot 非空。请检查旧安装或 PATH；没有删除任何内容。"
        }
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $download = Join-Path $env:TEMP ('scoop-install-' + [guid]::NewGuid().ToString('N') + '.ps1')
        try {
            $request = @{ Uri = 'https://get.scoop.sh'; OutFile = $download; ErrorAction = 'Stop' }
            if ($Proxy) { $request.Proxy = $proxyUri.AbsoluteUri }
            Invoke-RestMethod @request
            $bootstrapArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$download)
            if ($isAdmin) { $bootstrapArgs += '-RunAsAdmin' }
            if ($Proxy) { $bootstrapArgs += @('-Proxy', $proxyUri.AbsoluteUri) }
            & powershell.exe @bootstrapArgs
            if ($LASTEXITCODE -ne 0) { throw "Scoop bootstrap failed: $LASTEXITCODE" }
        } finally {
            Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue
        }
        $env:PATH = "$shims;$env:PATH"
    }
    $script:ScoopCommand = (Get-Command scoop -ErrorAction Stop).Source
    if ($Proxy) { Invoke-ScoopChecked @('config','proxy', $proxyUri.Authority) }
    foreach ($name in $toRepair) {
        Write-Host "修复 Scoop 命令入口：$name"
        Invoke-ScoopChecked @('reset', $name)
    }
    if ($toInstall.Count) {
        Write-Host "本次只安装：$($toInstall -join ', ')"
        Invoke-ScoopChecked (@('install') + $toInstall)
    }
} else {
    Write-Host '所选软件均已存在：跳过下载、Scoop 引导和代理设置，继续检查配置。' -ForegroundColor Green
}

Write-Host '[2/3] Configuration' -ForegroundColor Cyan
$script:ConfigResults = @()
if ($selected -contains 'psmux') {
    Set-PsmuxShellConfig -Path (Join-Path $env:USERPROFILE '.psmux.conf') -NonInteractive:$NonInteractive -Shell $PsmuxShell
}
# Install proxy helpers for both Windows PowerShell and PowerShell 7, without enabling them.
$helperDir = Join-Path $env:LOCALAPPDATA 'windows-tools'
$helperPath = Join-Path $helperDir 'proxy.ps1'
Install-ConfigFile (Join-Path $PSScriptRoot 'config\proxy.ps1') $helperPath -Force:$ForceConfig
$settingsPath = Join-Path $helperDir 'proxy.json'
$defaultProxy = if ($Proxy) { (ConvertTo-ProxyUri $Proxy).AbsoluteUri } else { 'http://127.0.0.1:17897' }
if ($Proxy -or -not (Test-Path -LiteralPath $settingsPath)) {
    $settings = ConvertTo-Json @{ address = $defaultProxy }
    Install-ConfigFile '' $settingsPath -Content $settings -Force
}
$documents = [Environment]::GetFolderPath('MyDocuments')
if (-not $documents) { throw '无法确定 Documents 目录，不能写 PowerShell profile。' }
$profiles = @(
    (Join-Path $documents 'WindowsPowerShell\profile.ps1'),
    (Join-Path $documents 'PowerShell\profile.ps1'),
    $PROFILE.CurrentUserAllHosts
) | Select-Object -Unique
foreach ($profilePath in $profiles) { Add-ProxyProfileBlock $profilePath $helperPath }
Write-Host '已添加 proxy_on / proxy_off。新 PowerShell 会话自动加载函数，不会自动开启代理。'
Write-Host "当前窗口可执行：. '$helperPath'"

if ($selected -contains 'vim') {
    Install-ConfigFile (Join-Path $PSScriptRoot 'config\vimrc') (Join-Path $env:USERPROFILE '_vimrc') -Force:$ForceConfig
}
if ($selected -contains 'yazi') {
    $fileExe = Find-YaziFileExe $scoopRoot
    if ($fileExe) {
        $env:YAZI_FILE_ONE = $fileExe
        [Environment]::SetEnvironmentVariable('YAZI_FILE_ONE', $fileExe, $EnvironmentScope)
        Write-Host "已找到预览依赖：$fileExe"
    } else {
        Write-Warning '未配置 YAZI_FILE_ONE：缺少 file.exe。其余配置继续完成；可稍后安装 Git 或手动设置该变量。'
    }
    $configDir = if ($env:YAZI_CONFIG_HOME) { $env:YAZI_CONFIG_HOME } else { Join-Path $env:APPDATA 'yazi\config' }
    $sourceDir = Join-Path $PSScriptRoot 'config\yazi'
    foreach ($file in Get-ChildItem -LiteralPath $sourceDir -File -Recurse) {
        $relative = $file.FullName.Substring($sourceDir.Length + 1)
        $destination = Join-Path $configDir $relative
        if ($relative -eq 'keymap.toml') {
            $startScript = Join-Path $configDir 'scripts\transfer-start.ps1'
            $command = New-TransferKeyCommand $startScript
            $content = [IO.File]::ReadAllText($file.FullName).Replace('"@@TRANSFER_COMMAND@@"', (ConvertTo-Json -InputObject $command -Compress))
            if (-not (Get-Command lazygit -CommandType Application,ExternalScript -ErrorAction SilentlyContinue)) {
                $content = ($content -split '\r?\n' | Where-Object { $_ -notmatch 'desc = "Lazygit"' }) -join "`n"
            }
            Install-ConfigFile $file.FullName $destination -Content $content -Force:$ForceConfig
        } else {
            # Personal targets are never replaced, even with ForceConfig.
            $replace = $ForceConfig -and ($relative -ne 'scripts\targets.json')
            Install-ConfigFile $file.FullName $destination -Force:$replace
        }
    }
    Initialize-MacSsh -SshDir (Join-Path $env:USERPROFILE '.ssh') -NonInteractive:$NonInteractive
    Write-Host "Yazi config: $configDir"
    if ($fileExe) { Write-Host "YAZI_FILE_ONE ($EnvironmentScope): $fileExe" }
}

Write-Host '[3/3] Verify commands' -ForegroundColor Cyan
$missing = @()
foreach ($name in $selected) {
    $command = Get-Command $name -CommandType Application,ExternalScript -ErrorAction SilentlyContinue
    if ($command) { Write-Host ("{0}: {1}" -f $name, $command.Source) }
    else { $missing += $name; Write-Warning "Not found in PATH: $name" }
}
if ($selected -contains 'yazi' -and -not (Get-Command scp -ErrorAction SilentlyContinue)) {
    Write-Warning 'scp is missing. Enable the Windows OpenSSH Client before using R transfer.'
}
$script:ConfigResults | ForEach-Object { Write-Host $_ }
if ($missing.Count) { throw "Incomplete installation; missing commands: $($missing -join ', ')" }
if ($selected -contains 'yazi') {
    foreach ($optional in @('vim','psmux','chafa')) {
        if (-not (Get-Command $optional -CommandType Application,ExternalScript -ErrorAction SilentlyContinue)) {
            Write-Warning "未找到 $optional；对应的编辑、R 分屏传输或图片预览功能需安装后使用。"
        }
    }
}
Write-Host '安装与配置步骤完成。上面的待补依赖/保留配置提示如存在，请按需处理。' -ForegroundColor Green
Write-Host 'Existing psmux sessions keep old environment values. Save work before restarting them.'
Write-Host 'Mac 传输还需远端公钥授权及反向转发；本地 SSH 配置结果见上方。详见 README.md。'
