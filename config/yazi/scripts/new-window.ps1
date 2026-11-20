# Open a psmux window in Yazi's current directory, like the Mac/Linux "g l" key.
# If the directory holds yazi_todo.yazi, its lines (e.g. conda activate env) run in the new window.
$ErrorActionPreference = 'Stop'
try {
    $cwd = (Get-Location).ProviderPath
    $pane = (& psmux new-window -c $cwd -P -F '#{pane_id}' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $pane -notmatch '^%\d+$') { throw "Cannot open psmux window. Run Yazi inside psmux. $pane" }
    $todo = Join-Path $cwd 'yazi_todo.yazi'
    if (Test-Path -LiteralPath $todo -PathType Leaf) {
        # Give the new shell time to load its profile; target the pane id so Yazi never receives the keys.
        Start-Sleep -Milliseconds 500
        foreach ($line in [IO.File]::ReadAllLines($todo, [Text.Encoding]::UTF8)) {
            if (-not $line.Trim()) { continue }
            & psmux send-keys -t $pane -l $line
            & psmux send-keys -t $pane Enter
        }
    }
} catch {
    Write-Host $_ -ForegroundColor Red
    Read-Host 'Press Enter to close' | Out-Null
    exit 1
}
