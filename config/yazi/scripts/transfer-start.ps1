# Files are passed as separate arguments by Yazi's %s expansion.
$ErrorActionPreference = 'Stop'
$list = Join-Path $env:TEMP ('yazi-transfer-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    if ($args.Count -eq 0) { throw 'No files selected.' }
    # Unique file per invocation prevents concurrent transfers sharing a selection.
    $json = ConvertTo-Json -InputObject @($args) -Compress
    [IO.File]::WriteAllText($list, $json, (New-Object Text.UTF8Encoding($false)))
    $menu = Join-Path $PSScriptRoot 'transfer.ps1'
    $command = "& '" + $menu.Replace("'", "''") + "' -ListPath '" + $list.Replace("'", "''") + "'"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    & psmux split-window -h "powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
    if ($LASTEXITCODE -ne 0) { throw 'Cannot open psmux pane. Run Yazi inside psmux.' }
} catch {
    Remove-Item -LiteralPath $list -Force -ErrorAction SilentlyContinue
    Write-Host $_ -ForegroundColor Red
    Read-Host 'Press Enter to close' | Out-Null
    exit 1
}
