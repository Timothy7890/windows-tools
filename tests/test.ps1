$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
Get-ChildItem $root -Filter *.ps1 -Recurse | ForEach-Object {
    $tokens = $null; $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
    Assert ($errors.Count -eq 0) "Syntax error in $($_.FullName): $errors"
}
. (Join-Path $root 'lib.ps1')
Assert ((ConvertTo-ProxyUri '127.0.0.1:17897').Port -eq 17897) 'Proxy port normalization failed'
foreach ($invalid in @('socks5://localhost:1080','http://user:pass@localhost:80','http://localhost/path')) {
    $rejected = $false
    try { $null = ConvertTo-ProxyUri $invalid } catch { $rejected = $true }
    Assert $rejected "Invalid proxy accepted: $invalid"
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ('windows-tools-test-' + [guid]::NewGuid().ToString('N'))
$oldTemp = $env:TEMP
try {
    $null = New-Item -ItemType Directory $temp
    $source = Join-Path $temp 'source'; $dest = Join-Path $temp 'nested/config'
    [IO.File]::WriteAllText($source, 'original')
    $script:ConfigResults = @()
    Install-ConfigFile $source $dest
    Assert ((Get-Content $dest -Raw) -eq 'original') 'Fresh config not installed'
    [IO.File]::WriteAllText($source, 'new')
    Install-ConfigFile $source $dest
    Assert ((Get-Content $dest -Raw) -eq 'original') 'Existing custom config overwritten'
    Install-ConfigFile $source $dest -Force
    $backups = @(Get-ChildItem (Split-Path $dest) -Filter '*.bak-*')
    Assert ($backups.Count -eq 1) 'Missing backup'
    Assert ((Get-Content $backups[0].FullName -Raw) -eq 'original') 'Backup lost original content'
    Install-ConfigFile $source $dest -Force
    Assert (@(Get-ChildItem (Split-Path $dest) -Filter '*.bak-*').Count -eq 1) 'Unchanged file backed up again'

    $env:TEMP = $temp
    $global:TestPaneCommands = @()
    function psmux { $global:TestPaneCommands += $args[-1]; $global:LASTEXITCODE = 0 }
    $files = @((Join-Path $temp '中文 空格.txt'), (Join-Path $temp "O'Brien.txt"))
    foreach ($file in $files) { [IO.File]::WriteAllText($file, 'test') }
    & (Join-Path $root 'config/yazi/scripts/transfer-start.ps1') @files
    & (Join-Path $root 'config/yazi/scripts/transfer-start.ps1') $files[0]
    $lists = @(Get-ChildItem $temp -Filter 'yazi-transfer-*.json')
    Assert ($lists.Count -eq 2) 'Concurrent selections collide'
    Assert ($global:TestPaneCommands.Count -eq 2) 'Pane not requested'
    foreach ($command in $global:TestPaneCommands) {
        $encoded = ($command -split ' ')[-1]
        $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
        $tokens = $null; $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseInput($decoded, [ref]$tokens, [ref]$errors)
        Assert ($errors.Count -eq 0) 'Pane command does not parse'
    }
    function Read-Host { return '1' }
    function Start-Sleep { }
    function scp { $global:TestScpArguments = @($args); $global:LASTEXITCODE = 0 }
    foreach ($list in $lists) {
        $expected = @(Get-Content $list.FullName -Raw | ConvertFrom-Json)
        & (Join-Path $root 'config/yazi/scripts/transfer.ps1') -ListPath $list.FullName
        Assert ($global:TestScpArguments[-1] -eq 'macos-yx:~/Downloads/') 'Wrong transfer destination'
        Assert ($global:TestScpArguments.Count -eq ($expected.Count + 3)) 'File arguments split or lost'
        for ($i = 0; $i -lt $expected.Count; $i++) {
            Assert ($global:TestScpArguments[$i + 2] -eq $expected[$i]) 'File name changed'
        }
        Assert (-not (Test-Path $list.FullName)) 'Selection list not cleaned up'
    }
    $key = New-TransferKeyCommand "C:\Users\O'Brien\AppData\Roaming\yazi\config\scripts\transfer-start.ps1"
    [IO.File]::WriteAllText((Join-Path $temp 'key.txt'), $key)
    Write-Host 'PASS: syntax, proxy validation, config preservation/backup/idempotence, concurrent transfers, Unicode/space/apostrophe filenames, cleanup.' -ForegroundColor Green
} finally {
    $env:TEMP = $oldTemp
    Remove-Item $temp -Recurse -Force
}
