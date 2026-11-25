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
    [ValidateSet('User','Machine')][string]$EnvironmentScope = 'User',
    [switch]$ConPtyFix,
    [switch]$SkipConPtyFix
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
    @('vim','psmux','yazi','chafa','poppler')
} else {
    @(Read-Components)
}
if ($selected -contains 'btop-lhm' -and -not $isAdmin) {
    $fallback = if ($NonInteractive) {
        Write-Warning '当前终端没有管理员权限，btop-gpu 无法运行；无交互模式自动改装普通版 btop。'
        'btop'
    } else { Read-BtopFallback }
    $selected = @($selected | ForEach-Object { if ($_ -eq 'btop-lhm') { $fallback } else { $_ } } | Where-Object { $_ })
    if ($fallback) { Write-Host '已改为普通版 btop。需要显卡监控时，请在管理员终端重新运行：.\install.ps1 btop-gpu' -ForegroundColor Yellow }
    else { Write-Host '已跳过 btop。需要显卡监控时，请在管理员终端重新运行：.\install.ps1 btop-gpu' -ForegroundColor Yellow }
    if (-not $selected.Count) { Write-Host '没有剩余要安装的软件，退出。'; return }
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
# The plain and GPU btop packages share the btop shim, so only one may stay installed.
$removePlainBtop = $false
if (($states | Where-Object { $_.Name -eq 'btop-lhm' -and $_.State -eq 'Missing' }) -and -not $ConfigureOnly) {
    $plainBtop = Join-Path $scoopRoot 'apps\btop\current\manifest.json'
    if (Test-Path -LiteralPath $plainBtop) {
        Write-Host '检测到 Scoop 普通版 btop；换成 btop-gpu 需先卸载它（btop.conf 保留在 Scoop persist 目录）。' -ForegroundColor Yellow
        $removePlainBtop = (-not $NonInteractive) -and ((Read-Host '是否卸载普通版并改装 btop-gpu？[Y/n]').Trim() -notmatch '^(n|no)$')
        if (-not $removePlainBtop) {
            Write-Warning '保留普通版 btop，跳过 btop-gpu。'
            $selected = @($selected | Where-Object { $_ -ne 'btop-lhm' })
            $states = @($states | Where-Object { $_.Name -ne 'btop-lhm' })
        }
    } elseif (Get-Command btop -CommandType Application,ExternalScript -ErrorAction SilentlyContinue) {
        Write-Warning "已有非 Scoop 安装的 btop：$((Get-Command btop).Source)。安装 btop-gpu 后，PATH 中靠前的那个生效。"
    }
}
$toInstall = @($states | Where-Object State -eq 'Missing' | ForEach-Object Name)
$toRepair = @($states | Where-Object State -eq 'ScoopInstalled' | ForEach-Object Name)
$proxyDecided = $PSBoundParameters.ContainsKey('Proxy')
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
        $proxyDecided = $true
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
    if ($removePlainBtop) {
        Write-Host '卸载普通版 btop'
        Invoke-ScoopChecked @('uninstall', 'btop')
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
if ($selected -contains 'btop-lhm') {
    $btopConf = Join-Path $scoopRoot 'persist\btop-lhm\btop.conf'
    if (-not (Test-Path -LiteralPath $btopConf)) { $btopConf = Join-Path $scoopRoot 'apps\btop-lhm\current\btop.conf' }
    $gpuNames = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object Name)
    $preferredGpu = Get-PreferredGpuName $gpuNames
    if ($gpuNames.Count -gt 1 -and $preferredGpu -and (Test-Path -LiteralPath (Split-Path $btopConf -Parent))) {
        # btop falls back to Auto by itself if this name differs from what LibreHardwareMonitor reports.
        Set-BtopSelectedGpu -Path $btopConf -GpuName $preferredGpu
    }
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

$conptyReady = $false
$windowsBuild = Get-WindowsBuild
if (Test-ConPtyFixNeeded -Build $windowsBuild -PsmuxSelected:($selected -contains 'psmux') -Force:$ConPtyFix -Skip:$SkipConPtyFix) {
    Write-Host "Windows build $windowsBuild：部署 psmux 残留修复（新版 ConPTY）。" -ForegroundColor Cyan
    try {
        $conptyArch = Get-ConPtyArch
        $conptyDir = Join-Path $env:LOCALAPPDATA "psmux-conpty\$script:ConPtyVersion"
        if (Test-ConPtyFilesReady $conptyDir) {
            Write-Host "[已存在，跳过下载] ConPTY：$conptyDir" -ForegroundColor Green
        } elseif ($ConfigureOnly) {
            throw '仅配置模式不下载 ConPTY；去掉 -ConfigureOnly 后重新运行。'
        } else {
            if (-not $proxyDecided -and -not $NonInteractive) {
                $Proxy = Read-ProxyAddress
                $proxyDecided = $true
            }
            Install-ConPtyFiles -Directory $conptyDir -Arch $conptyArch -Proxy $Proxy
            Write-Host "已安装 ConPTY $script:ConPtyVersion（微软签名已校验）：$conptyDir"
        }
        $relayResult = Build-ConPtyRelay -Source (Join-Path $PSScriptRoot 'config\conpty\relay.cs') -Directory $conptyDir -Arch $conptyArch
        Write-Host "relay.exe：$relayResult"
        $env:PSMUX_CONPTY_DIR = $conptyDir
        [Environment]::SetEnvironmentVariable('PSMUX_CONPTY_DIR', $conptyDir, $EnvironmentScope)
        Write-Host "PSMUX_CONPTY_DIR ($EnvironmentScope)：$conptyDir"
        $conptyReady = $true
    } catch {
        Write-Warning "psmux 残留修复未完成，其余配置继续：$_"
    }
    # A profile function named psmux would bypass the version this fix was verified with.
    foreach ($profilePath in @($profiles + $PROFILE.CurrentUserCurrentHost | Select-Object -Unique)) {
        if (Test-PsmuxCompatProfileBlock $profilePath) {
            Write-Warning "$profilePath 把 psmux 重定向到了 psmux-3.3.8 兼容入口。"
            $removeCompat = -not $NonInteractive -and (Read-Host '是否移除这段 profile（会先备份）？[Y/n]').Trim() -notmatch '^(n|no)$'
            if ($removeCompat) {
                Remove-PsmuxCompatProfileBlock $profilePath
                Write-Host '已移除；新开的 PowerShell 将使用 Scoop 的 psmux。'
            }
        } elseif (Test-PsmuxProfileOverride $profilePath) {
            Write-Warning "$profilePath 自定义了 psmux 命令，可能绕过本修复；请自行确认。"
        }
    }
} elseif ($selected -contains 'psmux' -and -not $SkipConPtyFix) {
    Write-Host "Windows build $windowsBuild：不需要 psmux 残留修复。如需强制部署，请加 -ConPtyFix。"
}

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
    $yaziFiles = @(foreach ($file in Get-ChildItem -LiteralPath $sourceDir -File -Recurse) {
        $relative = $file.FullName.Substring($sourceDir.Length + 1)
        $content = $null
        if ($relative -eq 'keymap.toml') {
            $startScript = Join-Path $configDir 'scripts\transfer-start.ps1'
            $command = New-TransferKeyCommand $startScript
            $content = [IO.File]::ReadAllText($file.FullName).Replace('"@@TRANSFER_COMMAND@@"', (ConvertTo-Json -InputObject $command -Compress))
            $windowCommand = New-TransferKeyCommand (Join-Path $configDir 'scripts\new-window.ps1') -Arguments ''
            $content = $content.Replace('"@@NEW_WINDOW_COMMAND@@"', (ConvertTo-Json -InputObject $windowCommand -Compress))
            $vizCommand = New-TransferKeyCommand (Join-Path $configDir 'scripts\visualize-start.ps1')
            $content = $content.Replace('"@@VISUALIZE_COMMAND@@"', (ConvertTo-Json -InputObject $vizCommand -Compress))
            if (-not (Get-Command lazygit -CommandType Application,ExternalScript -ErrorAction SilentlyContinue)) {
                $content = ($content -split '\r?\n' | Where-Object { $_ -notmatch 'desc = "Lazygit"' }) -join "`n"
            }
        }
        [pscustomobject]@{ Relative = $relative; Source = $file.FullName; Destination = (Join-Path $configDir $relative); Content = $content }
    })
    # Personal targets are never replaced, even with ForceConfig or an accepted update.
    $managed = @($yaziFiles | Where-Object { $_.Relative -ne 'scripts\targets.json' })
    $updateYazi = [bool]$ForceConfig
    if (-not $ForceConfig) {
        $changed = @($managed | Where-Object { Test-ConfigFileChanged -Source $_.Source -Destination $_.Destination -Content $_.Content })
        if ($changed.Count) {
            $updateYazi = Read-ConfigUpdate -Names @($changed | ForEach-Object Relative) -NonInteractive:$NonInteractive
        }
    }
    foreach ($entry in $yaziFiles) {
        $force = $updateYazi -and ($entry.Relative -ne 'scripts\targets.json')
        if ($null -ne $entry.Content) { Install-ConfigFile $entry.Source $entry.Destination -Content $entry.Content -Force:$force }
        else { Install-ConfigFile $entry.Source $entry.Destination -Force:$force }
    }
    Initialize-VizEnv -Path (Join-Path $env:LOCALAPPDATA 'yazi-viz') -Proxy $Proxy -NonInteractive:$NonInteractive -NoDownload:$ConfigureOnly
    Initialize-MacSsh -SshDir (Join-Path $env:USERPROFILE '.ssh') -NonInteractive:$NonInteractive
    Write-Host "Yazi config: $configDir"
    if ($fileExe) { Write-Host "YAZI_FILE_ONE ($EnvironmentScope): $fileExe" }
}

Write-Host '[3/3] Verify commands' -ForegroundColor Cyan
$missing = @()
foreach ($name in $selected) {
    $command = Get-Command (Get-ComponentCommand $name) -CommandType Application,ExternalScript -ErrorAction SilentlyContinue
    if ($command) { Write-Host ("{0}: {1}" -f $name, $command.Source) }
    else { $missing += $name; Write-Warning "Not found in PATH: $name" }
}
if ($selected -contains 'yazi' -and -not (Get-Command scp -ErrorAction SilentlyContinue)) {
    Write-Warning 'scp is missing. Enable the Windows OpenSSH Client before using R transfer.'
}
$script:ConfigResults | ForEach-Object { Write-Host $_ }
if ($missing.Count) { throw "Incomplete installation; missing commands: $($missing -join ', ')" }
if ($selected -contains 'btop' -or $selected -contains 'btop-lhm') {
    # btop4win only ships x64 builds and links against the Visual C++ 2015-2022 runtime.
    $system32 = Join-Path $env:WINDIR 'System32'
    if (-not ((Test-Path -LiteralPath (Join-Path $system32 'vcruntime140.dll')) -and (Test-Path -LiteralPath (Join-Path $system32 'msvcp140.dll')))) {
        Write-Warning '未检测到 Visual C++ 2015-2022 运行库，btop 可能无法启动。可执行：scoop bucket add extras; scoop install vcredist2022'
    }
    if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64' -and $env:PROCESSOR_ARCHITEW6432 -ne 'AMD64') {
        Write-Warning 'btop4win 只提供 x64 版本；ARM64 设备需依赖 Windows 11 的 x64 仿真。'
    }
    if ($selected -contains 'btop-lhm') {
        Write-Host 'btop-gpu：请在管理员终端运行 btop。首次运行会注册传感器驱动服务 R0btop（WinRing0）；' -ForegroundColor Yellow
        Write-Host '  若杀毒软件拦截或显卡数据为空，可换回普通版：scoop uninstall btop-lhm; .\install.ps1 btop' -ForegroundColor Yellow
    }
}
if ($selected -contains 'yazi') {
    foreach ($optional in @('vim','psmux','chafa','pdftoppm')) {
        if (-not (Get-Command $optional -CommandType Application,ExternalScript -ErrorAction SilentlyContinue)) {
            Write-Warning "未找到 $optional；对应的编辑、R 分屏传输、图片或 PDF 预览功能需安装后使用。"
        }
    }
}
Write-Host '安装与配置步骤完成。上面的待补依赖/保留配置提示如存在，请按需处理。' -ForegroundColor Green
Write-Host 'Existing psmux sessions keep old environment values. Save work before restarting them.'
Write-Host 'Mac 传输还需远端公钥授权及反向转发；本地 SSH 配置结果见上方。详见 README.md。'
if ($conptyReady) {
    Write-Host '残留修复还差 Mac 端一步，请在 Mac 的 windows-tools 目录运行：' -ForegroundColor Yellow
    Write-Host '  ./mac/enable-host.sh <这台机器的 SSH 别名>'
    Write-Host '已有 psmux 服务继续使用旧 ConPTY；保存工作后重新启动 psmux 才会用新版。'
    Write-Host '重新连接后，复制下面的命令检查，应输出 ConPTY 目录：' -ForegroundColor Yellow
    Write-Host '  $env:PSMUX_CONPTY_DIR'
    Write-Host "  应输出：$conptyDir"
}
