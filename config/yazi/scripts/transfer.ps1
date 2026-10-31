param([Parameter(Mandatory = $true)][string]$ListPath)
$ErrorActionPreference = 'Stop'
try {
    $files = @(Get-Content -LiteralPath $ListPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    if ($files.Count -eq 0) { throw 'No files selected.' }
    $targets = @(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'targets.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
    Write-Host '===== Transfer destination ====='
    for ($i = 0; $i -lt $targets.Count; $i++) {
        Write-Host ('{0}) {1}  {2}' -f ($i + 1), $targets[$i].name, $targets[$i].destination)
    }
    Write-Host 'q) Cancel'
    $choice = Read-Host 'Select'
    if ($choice -eq 'q') { return }
    $index = 0
    if (-not [int]::TryParse($choice, [ref]$index) -or $index -lt 1 -or $index -gt $targets.Count) {
        throw 'Invalid selection.'
    }
    $destination = [string]$targets[$index - 1].destination
    if ($destination -notmatch '^[A-Za-z0-9_.-]+:.+$') { throw 'Use an SSH alias followed by : and destination path.' }
    # Resolve paths to avoid interpreting a selected name beginning with '-' as an option.
    $sources = @($files | ForEach-Object {
        if (-not (Test-Path -LiteralPath $_)) { throw "Missing file: $_" }
        (Get-Item -LiteralPath $_ -Force).FullName
    })
    & scp -r -p @sources $destination
    if ($LASTEXITCODE -ne 0) { throw "scp failed with exit code $LASTEXITCODE. Check SSH alias and forwarding." }
    Write-Host 'Transfer complete.' -ForegroundColor Green
    Start-Sleep -Seconds 2
} catch {
    Write-Host $_ -ForegroundColor Red
    Read-Host 'Press Enter to close' | Out-Null
    exit 1
} finally {
    Remove-Item -LiteralPath $ListPath -Force -ErrorAction SilentlyContinue
}
