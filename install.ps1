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
[CmdletBinding()]
param(
    [ValidateSet('git','vim','psmux','yazi','chafa','lazygit')]
    [string[]]$Components = @('git','vim','psmux','yazi','chafa','lazygit'),
    [string]$Proxy,
    [switch]$ConfigureOnly,
    [switch]$ForceConfig,
    [ValidateSet('User','Machine')][string]$EnvironmentScope = 'User'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
if ($env:OS -ne 'Windows_NT') { throw 'Run this installer on Windows PowerShell 5.1 or PowerShell 7.' }
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if ($EnvironmentScope -eq 'Machine' -and -not $isAdmin) { throw '-EnvironmentScope Machine requires an administrator console.' }
$selected = @($Components)
if ($selected -contains 'yazi') {
    $selected += @('git','vim','psmux','chafa','lazygit')
}
$selected = @($selected | Select-Object -Unique)
$scoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
$shims = Join-Path $scoopRoot 'shims'
if (Test-Path -LiteralPath $shims) { $env:PATH = "$shims;$env:PATH" }

if ($Proxy) {
    $proxyUri = ConvertTo-ProxyUri $Proxy
    $env:http_proxy = $proxyUri.AbsoluteUri
    $env:https_proxy = $proxyUri.AbsoluteUri
}
if (-not $ConfigureOnly) {
    Write-Host '[1/3] Scoop and packages' -ForegroundColor Cyan
    Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
    if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
        if ((Test-Path -LiteralPath $scoopRoot) -and @(Get-ChildItem -LiteralPath $scoopRoot -Force).Count -gt 0) {
            throw "Scoop is unavailable but $scoopRoot is not empty. Inspect/restore the existing installation first; nothing was deleted."
        }
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $download = Join-Path $env:TEMP ('scoop-install-' + [guid]::NewGuid().ToString('N') + '.ps1')
        try {
            $request = @{ Uri = 'https://get.scoop.sh'; OutFile = $download; ErrorAction = 'Stop' }
            if ($Proxy) { $request.Proxy = $proxyUri.AbsoluteUri }
            Invoke-RestMethod @request
            # Isolate installer's exit calls from this orchestration script.
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
    # Scoop skips packages already installed. Do not silently update them.
    Invoke-ScoopChecked (@('install') + $selected)
}

Write-Host '[2/3] Configuration' -ForegroundColor Cyan
$script:ConfigResults = @()
if ($selected -contains 'vim') {
    Install-ConfigFile (Join-Path $PSScriptRoot 'config\vimrc') (Join-Path $env:USERPROFILE '_vimrc') -Force:$ForceConfig
}
if ($selected -contains 'yazi') {
    $gitPrefix = Join-Path $scoopRoot 'apps\git\current'
    $fileExe = Join-Path $gitPrefix 'usr\bin\file.exe'
    if (-not (Test-Path -LiteralPath $fileExe)) {
        if ($env:YAZI_FILE_ONE -and (Test-Path -LiteralPath $env:YAZI_FILE_ONE)) {
            $fileExe = $env:YAZI_FILE_ONE
        } else { throw 'Cannot find Git file.exe. Install Scoop git or set YAZI_FILE_ONE to an existing file.exe.' }
    }
    $env:YAZI_FILE_ONE = $fileExe
    [Environment]::SetEnvironmentVariable('YAZI_FILE_ONE', $fileExe, $EnvironmentScope)
    $configDir = if ($env:YAZI_CONFIG_HOME) { $env:YAZI_CONFIG_HOME } else { Join-Path $env:APPDATA 'yazi\config' }
    $sourceDir = Join-Path $PSScriptRoot 'config\yazi'
    foreach ($file in Get-ChildItem -LiteralPath $sourceDir -File -Recurse) {
        $relative = $file.FullName.Substring($sourceDir.Length + 1)
        $destination = Join-Path $configDir $relative
        if ($relative -eq 'keymap.toml') {
            $startScript = Join-Path $configDir 'scripts\transfer-start.ps1'
            $command = New-TransferKeyCommand $startScript
            $content = [IO.File]::ReadAllText($file.FullName).Replace('"@@TRANSFER_COMMAND@@"', (ConvertTo-Json -InputObject $command -Compress))
            Install-ConfigFile $file.FullName $destination -Content $content -Force:$ForceConfig
        } else {
            # Personal targets are never replaced, even with ForceConfig.
            $replace = $ForceConfig -and ($relative -ne 'scripts\targets.json')
            Install-ConfigFile $file.FullName $destination -Force:$replace
        }
    }
    Write-Host "Yazi config: $configDir"
    Write-Host "YAZI_FILE_ONE ($EnvironmentScope): $fileExe"
}

Write-Host '[3/3] Verify commands' -ForegroundColor Cyan
$missing = @()
foreach ($name in $selected) {
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if ($command) { Write-Host ("{0}: {1}" -f $name, $command.Source) }
    else { $missing += $name; Write-Warning "Not found in PATH: $name" }
}
if ($selected -contains 'yazi' -and -not (Get-Command scp -ErrorAction SilentlyContinue)) {
    Write-Warning 'scp is missing. Enable the Windows OpenSSH Client before using R transfer.'
}
$script:ConfigResults | ForEach-Object { Write-Host $_ }
if ($missing.Count) { throw "Incomplete installation; missing commands: $($missing -join ', ')" }
Write-Host 'Finished. Start a NEW psmux session, then run yazi.' -ForegroundColor Green
Write-Host 'Existing psmux sessions keep old environment values. Save work before restarting them.'
Write-Host 'SSH transfer still requires your SSH host alias, authorized key and (for Mac) reverse forwarding. See README.md.'
