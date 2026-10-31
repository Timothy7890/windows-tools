$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'lib.ps1')
function Assert($Condition,$Message) { if (-not $Condition) { throw $Message } }
$temp = Join-Path ([IO.Path]::GetTempPath()) ('shell-proxy-test-' + [guid]::NewGuid().ToString('N'))
$oldLocal = $env:LOCALAPPDATA
$oldProxy = [Net.WebRequest]::DefaultWebProxy
$httpProxy = if ($PSVersionTable.PSVersion.Major -ge 7) { [Net.Http.HttpClient]::DefaultProxy }
$savedEnv = @{}
foreach ($name in @('http_proxy','https_proxy','all_proxy')) { $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name) }
try {
    $null = New-Item -ItemType Directory $temp
    $script:ConfigResults = @()
    $config = Join-Path $temp '.psmux.conf'
    Set-PsmuxShellConfig $config -NonInteractive
    Assert ((Get-Content $config -Raw).Trim() -eq 'set -g default-shell powershell') 'Missing default not added'
    Set-PsmuxShellConfig $config -NonInteractive
    Assert (@(Get-ChildItem $temp -Force -Filter '*.bak-*').Count -eq 0) 'Unchanged config backed up'
    [IO.File]::WriteAllText($config, "# custom`r`nset -g mouse on`r`nset -g default-shell cmd.exe`r`n")
    $original = [IO.File]::ReadAllText($config)
    function Read-Host { return '' }
    Set-PsmuxShellConfig $config
    Assert ([IO.File]::ReadAllText($config) -eq $original) 'Interactive default did not preserve shell'
    function Read-Host { return '2' }
    Set-PsmuxShellConfig $config
    Assert ((Get-Content $config -Raw) -match 'mouse on') 'Other psmux settings lost'
    Assert ((Get-Content $config -Raw) -notmatch 'cmd.exe') 'CRLF shell not replaced'
    $backup = @(Get-ChildItem $temp -Force -Filter '*.bak-*')
    Assert ($backup.Count -eq 1 -and [IO.File]::ReadAllText($backup[0].FullName) -eq $original) 'Original shell config not backed up'

    $profile = Join-Path $temp 'profile.ps1'
    [IO.File]::WriteAllText($profile, '# existing profile')
    $helper = Join-Path $root 'config/proxy.ps1'
    Add-ProxyProfileBlock $profile $helper
    Add-ProxyProfileBlock $profile $helper
    $content = [IO.File]::ReadAllText($profile)
    Assert ($content.Contains('# existing profile')) 'Profile content lost'
    Assert ([regex]::Matches($content, '# >>> windows-tools proxy >>>').Count -eq 1) 'Duplicate profile block'
    Assert (@(Get-ChildItem $temp -Force -Filter 'profile.ps1.bak-*').Count -eq 1) 'Profile not idempotent'
    . $profile
    Assert ($null -ne (Get-Command proxy_on)) 'Profile failed to load helper'
    function proxy_on { return 'custom' }
    . $profile
    Assert ((proxy_on) -eq 'custom') 'Existing function overwritten by profile loader'
    . $helper

    # Scoop calls are mocked; no real user configuration/network changes.
    function Get-Command { param($Name,$CommandType,$ErrorAction); if ($Name -eq 'scoop') { [pscustomobject]@{Source = 'test-scoop.ps1'} } }
    function powershell.exe { $global:TestScoopArgs = @($args); $global:LASTEXITCODE = 0 }
    $env:LOCALAPPDATA = $temp
    $null = New-Item -ItemType Directory (Join-Path $temp 'windows-tools')
    [IO.File]::WriteAllText((Join-Path $temp 'windows-tools/proxy.json'), '{"address":"http://127.0.0.1:17897"}')
    proxy_on
    Assert ($env:https_proxy -eq 'http://127.0.0.1:17897/') 'Saved proxy not loaded'
    Assert ($global:TestScoopArgs[-1] -eq '127.0.0.1:17897') 'Scoop proxy not synchronized'
    proxy_on localhost:8888
    Assert ($env:http_proxy -eq 'http://localhost:8888/') 'Custom proxy not used'
    Assert ([Net.WebRequest]::DefaultWebProxy.GetProxy([uri]'https://example.com').Port -eq 8888) '.NET proxy not changed'
    proxy_off
    Assert (-not $env:http_proxy -and -not $env:https_proxy) 'Proxy env not cleared'
    Assert ($global:TestScoopArgs[-1] -eq 'none') 'Scoop proxy not disabled'
    Assert ($null -eq [Net.WebRequest]::DefaultWebProxy) '.NET proxy not disabled'
    Write-Host 'PASS: psmux new/preserve/replace/CRLF/backup; profile merge/idempotence/function preservation; proxy defaults/custom/on/off/Scoop synchronization.'
} finally {
    $env:LOCALAPPDATA = $oldLocal
    foreach ($name in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($name,$savedEnv[$name]) }
    [Net.WebRequest]::DefaultWebProxy = $oldProxy
    if ($PSVersionTable.PSVersion.Major -ge 7) { [Net.Http.HttpClient]::DefaultProxy = $httpProxy }
    Remove-Item $temp -Recurse -Force
}
