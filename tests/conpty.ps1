$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'lib.ps1')
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }

# Detection: only the build number decides; Windows 11 must be left alone.
Assert (Test-ConPtyFixNeeded -Build 19045 -PsmuxSelected) 'Windows 10 not detected'
Assert (-not (Test-ConPtyFixNeeded -Build 26200 -PsmuxSelected)) 'Windows 11 treated as Windows 10'
Assert (-not (Test-ConPtyFixNeeded -Build 22000 -PsmuxSelected)) 'First Windows 11 build treated as Windows 10'
Assert (-not (Test-ConPtyFixNeeded -Build 19045)) 'Fix deployed without psmux selected'
Assert (Test-ConPtyFixNeeded -Build 26200 -Force) '-ConPtyFix did not force'
Assert (-not (Test-ConPtyFixNeeded -Build 19045 -PsmuxSelected -Force -Skip)) '-SkipConPtyFix did not win'

Assert ((Get-ConPtyArch 'AMD64').Name -eq 'x64') 'x64 mapping wrong'
Assert ((Get-ConPtyArch 'x86').Framework -eq 'Framework') 'x86 mapping wrong'
$rejected = $false
try { $null = Get-ConPtyArch 'ARM64' } catch { $rejected = $true }
Assert $rejected 'Unsupported architecture accepted'

$temp = Join-Path ([IO.Path]::GetTempPath()) ('conpty-test-' + [guid]::NewGuid().ToString('N'))
try {
    $null = New-Item -ItemType Directory $temp
    $script:ConfigResults = @()

    # Only the exact compatibility block goes; the proxy block and other text stay, with a backup and BOM.
    $profilePath = Join-Path $temp 'profile.ps1'
    $before = "# keep before`r`n# >>> windows-tools proxy >>>`r`n# <<< windows-tools proxy <<<`r`n"
    $compat = @'
# Explicit Windows 10 SSH compatibility entry; default psmux is unchanged.
function global:psmux-safe {
    & "$env:LOCALAPPDATA\psmux-3.3.8\psmux.exe" -L win10-safe @args
}

# Default to the tested Windows 10 SSH compatibility configuration.
function global:psmux {
    psmux-safe @args
}
'@
    $after = "`r`n# keep after`r`n"
    [IO.File]::WriteAllText($profilePath, $before + $compat + $after)
    Assert (Test-PsmuxCompatProfileBlock $profilePath) 'Compatibility block not detected'
    Remove-PsmuxCompatProfileBlock $profilePath
    $text = [IO.File]::ReadAllText($profilePath)
    Assert ($text -notmatch 'psmux') 'Compatibility block not removed'
    Assert ($text.Contains('# keep before') -and $text.Contains('# keep after') -and $text.Contains('windows-tools proxy')) 'Other profile text lost'
    Assert ([IO.File]::ReadAllBytes($profilePath)[0] -eq 0xEF) 'BOM lost'
    Assert (@(Get-ChildItem $temp -Filter 'profile.ps1.bak-*').Count -eq 1) 'Profile not backed up'
    Assert (-not (Test-PsmuxCompatProfileBlock $profilePath)) 'Removal not idempotent'
    Assert (-not (Test-PsmuxCompatProfileBlock (Join-Path $temp 'missing.ps1'))) 'Missing profile detected'

    # A user's own function is reported but is not the compatibility block.
    $custom = Join-Path $temp 'custom.ps1'
    [IO.File]::WriteAllText($custom, "function psmux { 'mine' }`r`n")
    Assert (Test-PsmuxProfileOverride $custom) 'Custom psmux function not detected'
    Assert (-not (Test-PsmuxCompatProfileBlock $custom)) 'Custom function mistaken for compatibility block'
    $plain = Join-Path $temp 'plain.ps1'
    [IO.File]::WriteAllText($plain, "# psmux is great`r`nWrite-Host psmux`r`n")
    Assert (-not (Test-PsmuxProfileOverride $plain)) 'Mention of psmux treated as an override'

    # A tampered download must leave nothing installed or behind.
    function Invoke-WebRequest { param($Uri, $OutFile, $UseBasicParsing, $ErrorAction, $Proxy)
        $global:TestDownloadProxy = $Proxy
        [IO.File]::WriteAllText($OutFile, 'not the real package')
    }
    $directory = Join-Path $temp 'psmux-conpty\version'
    $rejected = $false
    try { Install-ConPtyFiles -Directory $directory -Arch (Get-ConPtyArch 'AMD64') -Proxy '127.0.0.1:17897' } catch { $rejected = "$_" -match '校验失败' }
    Assert $rejected 'Hash mismatch not rejected'
    Assert ($global:TestDownloadProxy -eq 'http://127.0.0.1:17897/') 'Proxy not used for download'
    Assert (-not (Test-Path $directory)) 'Files installed after hash mismatch'
    Assert (@(Get-ChildItem (Split-Path $directory)).Count -eq 0) 'Download not cleaned up'

    # Unsigned or missing files are not "ready", so they get downloaded again.
    Assert (-not (Test-ConPtyFilesReady $directory)) 'Missing files reported ready'
    function Get-AuthenticodeSignature { param($LiteralPath) [pscustomobject]@{ Status = $global:TestSignature; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, C=US' } } }
    $null = New-Item -ItemType Directory $directory
    foreach ($name in 'conpty.dll','OpenConsole.exe') { [IO.File]::WriteAllText((Join-Path $directory $name), 'x') }
    $global:TestSignature = 'Valid'
    Assert (Test-ConPtyFilesReady $directory) 'Signed files not ready'
    $global:TestSignature = 'NotSigned'
    Assert (-not (Test-ConPtyFilesReady $directory)) 'Unsigned files reported ready'

    Write-Host 'PASS: build detection, architecture mapping, compatibility profile removal, hash and signature rejection.' -ForegroundColor Green
} finally {
    Remove-Item $temp -Recurse -Force
}
