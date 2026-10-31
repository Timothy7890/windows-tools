#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-zA-Z0-9_.-]+$')][string]$MacUser,
    [ValidatePattern('^[a-zA-Z0-9_.-]+$')][string]$Alias = 'macos-yx',
    [ValidatePattern('^[a-zA-Z0-9_.-]+$')][string]$KeyName = 'windows-tools_ed25519',
    [ValidateRange(1,65535)][int]$Port = 12025
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run on Windows.' }
$null = Get-Command ssh-keygen -ErrorAction Stop
$dir = Join-Path $env:USERPROFILE '.ssh'
$null = New-Item -ItemType Directory -Force -Path $dir
$key = Join-Path $dir $KeyName
if (-not (Test-Path -LiteralPath $key)) {
    if (Test-Path -LiteralPath "$key.pub") { throw 'Public key already exists without private key. Choose another KeyName.' }
    # Interactive passphrase prompt; no private key or credential is shipped with this project.
    & ssh-keygen -t ed25519 -f $key -C 'windows-tools'
    if ($LASTEXITCODE -ne 0) { throw 'ssh-keygen failed.' }
}
$config = Join-Path $dir 'config'
$existing = if (Test-Path -LiteralPath $config) { [IO.File]::ReadAllText($config) } else { '' }
$hasAlias = $false
foreach ($line in ($existing -split '\r?\n')) {
    if ($line -match '^\s*Host\s+(.+)$') {
        if (($Matches[1] -split '\s+') -contains $Alias) { $hasAlias = $true }
    }
}
if ($hasAlias) {
    Write-Warning "Host $Alias already exists; preserved. Check User, Port and IdentityFile manually."
} else {
    if (Test-Path -LiteralPath $config) {
        Copy-Item -LiteralPath $config -Destination ($config + '.bak-' + [guid]::NewGuid().ToString('N'))
    }
    # Prepend so the explicit host takes precedence over an existing Host * block.
    $block = @"
Host $Alias
    HostName localhost
    Port $Port
    User $MacUser
    IdentityFile ~/.ssh/$KeyName
    IdentitiesOnly yes
    StrictHostKeyChecking ask

"@
    [IO.File]::WriteAllText($config, $block + "`r`n" + $existing, (New-Object Text.UTF8Encoding($false)))
}
Write-Host 'Append this PUBLIC key to the Mac ~/.ssh/authorized_keys:'
Get-Content -LiteralPath "$key.pub"
Write-Host "On the Mac, enable Remote Login and add RemoteForward $Port localhost:22 to the Windows SSH Host entry."
Write-Host "Reconnect from Mac to Windows, then test: ssh $Alias echo ok"
