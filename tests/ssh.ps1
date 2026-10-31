$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'lib.ps1')
function Assert($Condition,$Message) { if (-not $Condition) { throw $Message } }
$temp = Join-Path ([IO.Path]::GetTempPath()) ('ssh-config-test-' + [guid]::NewGuid().ToString('N'))
try {
    $null = New-Item -ItemType Directory $temp
    $script:ConfigResults = @()
    function Get-Command { param($Name,$CommandType,$ErrorAction); [pscustomobject]@{Source = 'ssh-keygen.exe'} }
    function ssh-keygen {
        $key = $args[[array]::IndexOf($args, '-f') + 1]
        [IO.File]::WriteAllText($key, 'test-private')
        [IO.File]::WriteAllText("$key.pub", 'ssh-ed25519 test-public')
        $global:LASTEXITCODE = 0
        $global:KeyCalls++
    }
    $global:KeyCalls = 0
    function Read-Host { return '' }
    Initialize-MacSsh -SshDir $temp
    $config = Join-Path $temp 'config'
    $first = [IO.File]::ReadAllText($config)
    Assert ($first -match 'Host macos-yx' -and $first -match 'User timo' -and $first -match 'Port 12025') 'Default SSH config incorrect'
    Assert ($global:KeyCalls -eq 1) 'Key not generated once'
    function Read-Host { throw 'Should not prompt for an existing alias' }
    Initialize-MacSsh -SshDir $temp
    Assert ($global:KeyCalls -eq 1 -and [IO.File]::ReadAllText($config) -eq $first) 'Repeat changed config or key'
    Assert (@(Get-ChildItem $temp -Filter 'config.bak-*').Count -eq 0) 'Repeat created unnecessary backup'
    [IO.File]::WriteAllText($config, "# personal`r`nHost other`r`n  HostName example.org`r`nHost *`r`n  User fallback`r`n")
    $previous = [IO.File]::ReadAllText($config)
    Initialize-MacSsh -SshDir $temp -MacUser alice -HostName 192.168.1.10 -Port 22 -KeyName windows-tools_ed25519 -NonInteractive
    $changed = [IO.File]::ReadAllText($config)
    Assert ($changed.StartsWith('Host macos-yx') -and $changed.Contains($previous)) 'Existing hosts lost / precedence wrong'
    Assert ($changed -match 'User alice' -and $changed -match 'Port 22') 'Custom parameters ignored'
    $backup = @(Get-ChildItem $temp -Filter 'config.bak-*')
    Assert ($backup.Count -eq 1 -and [IO.File]::ReadAllText($backup[0].FullName) -eq $previous) 'Missing original config backup'
    Assert ($global:KeyCalls -eq 1) 'Existing private key regenerated'
    $empty = Join-Path $temp 'unattended'
    Initialize-MacSsh -SshDir $empty -NonInteractive
    Assert (-not (Test-Path (Join-Path $empty 'config'))) 'Unattended missing key wrote unusable config'
    [IO.File]::WriteAllText($config, "Host other macos-yx # comment`n User bob`n")
    Initialize-MacSsh -SshDir $temp
    Assert ($global:KeyCalls -eq 1) 'Multi-alias config not detected'
    Write-Host 'PASS: SSH defaults, key generation/reuse, alias preservation, backup, custom host/user/port, unattended no-prompt behavior.'
} finally { Remove-Item $temp -Recurse -Force }
