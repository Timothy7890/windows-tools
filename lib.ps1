# Shared pure/configuration helpers; dot-source without installing anything.
function ConvertTo-ProxyUri {
    param([string]$Value)
    if ($Value -notmatch '^[a-z]+://') { $Value = 'http://' + $Value }
    $uri = [uri]$Value
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'http' -or -not $uri.Host -or
        $uri.UserInfo -or $uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment) {
        throw 'Proxy must be an HTTP proxy host:port, without credentials or a path.'
    }
    return $uri
}
function New-TransferKeyCommand {
    param([string]$ScriptPath)
    $command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '" %s'
    # Yazi parses shell command arguments using shell-style quoting.
    $quote = [string][char]39
    $escapedQuote = $quote + '"' + $quote + '"' + $quote
    return ('shell --orphan ' + $quote + $command.Replace($quote, $escapedQuote) + $quote)
}
function Invoke-ScoopChecked {
    param([string[]]$Arguments)
    # A separate process preserves Scoop's own exit code and prevents exit terminating install.ps1.
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:ScoopCommand @Arguments
    if ($LASTEXITCODE -ne 0) { throw "scoop $($Arguments -join ' ') failed (exit $LASTEXITCODE)." }
}
function Install-ConfigFile {
    param([string]$Source, [string]$Destination, [string]$Content, [switch]$Force)
    $hasContent = $PSBoundParameters.ContainsKey('Content')
    $bytes = if ($hasContent) { (New-Object Text.UTF8Encoding($false)).GetBytes($Content) } else { [IO.File]::ReadAllBytes($Source) }
    if (Test-Path -LiteralPath $Destination) {
        $old = [IO.File]::ReadAllBytes($Destination)
        if ([Convert]::ToBase64String($old) -eq [Convert]::ToBase64String($bytes)) {
            $script:ConfigResults += "Unchanged: $Destination"
            return
        }
        if (-not $Force) {
            $script:ConfigResults += "PRESERVED existing file: $Destination (merge manually or use -ForceConfig)"
            return
        }
        $backup = $Destination + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
        Copy-Item -LiteralPath $Destination -Destination $backup
        $script:ConfigResults += "Backup: $backup"
    }
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination)
    [IO.File]::WriteAllBytes($Destination, $bytes)
    $script:ConfigResults += "Written: $Destination"
}
