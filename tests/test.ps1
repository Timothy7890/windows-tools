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
        $parsed = Get-Content $list.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $expected = @($parsed | ForEach-Object { $_ })
        & (Join-Path $root 'config/yazi/scripts/transfer.ps1') -ListPath $list.FullName
        Assert ($global:TestScpArguments[-1] -eq 'macos-yx:~/Downloads/') 'Wrong transfer destination'
        Assert ($global:TestScpArguments.Count -eq ($expected.Count + 3)) 'File arguments split or lost'
        for ($i = 0; $i -lt $expected.Count; $i++) {
            Assert ($global:TestScpArguments[$i + 2] -eq $expected[$i]) 'File name changed'
        }
        Assert (-not (Test-Path $list.FullName)) 'Selection list not cleaned up'
    }
    # ---- g v：分屏启动 + 模式识别 ----
    $global:TestPaneCommands = @()
    & (Join-Path $root 'config/yazi/scripts/visualize-start.ps1') @files
    $vizLists = @(Get-ChildItem $temp -Filter 'yazi-visualize-*.json')
    Assert ($vizLists.Count -eq 1 -and $global:TestPaneCommands.Count -eq 1) 'g v pane not requested'
    $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($global:TestPaneCommands[0] -split ' ')[-1]))
    Assert ($decoded -match "visualize\.ps1' -ListPath ") 'g v pane command wrong'
    Remove-Item $vizLists[0].FullName

    # A fake interpreter records its arguments instead of starting a web server.
    $fakePython = Join-Path $temp 'python.cmd'
    $vizArgsFile = Join-Path $temp 'viz-args.txt'
    [IO.File]::WriteAllText($fakePython, "@echo off`r`n>`"$vizArgsFile`" echo %*`r`n")
    $env:YAZI_VIZ_PYTHON = $fakePython
    $oldLocalAppData = $env:LOCALAPPDATA
    function Invoke-Viz([string[]]$Selection) {
        Remove-Item $vizArgsFile -ErrorAction SilentlyContinue
        $vizList = Join-Path $temp ('viz-' + [guid]::NewGuid().ToString('N') + '.json')
        [IO.File]::WriteAllText($vizList, (ConvertTo-Json -InputObject @($Selection) -Compress))
        & (Join-Path $root 'config/yazi/scripts/visualize.ps1') -ListPath $vizList
        Assert (-not (Test-Path $vizList)) 'g v selection list not cleaned up'
        $global:TestVizArguments = if (Test-Path $vizArgsFile) { [IO.File]::ReadAllText($vizArgsFile, [Text.Encoding]::Default) } else { $null }
    }
    # cmd.exe 以 OEM 代码页回显参数，记录的路径保持 ASCII（仍覆盖空格）
    $sceneA = Join-Path $temp 'scene A'; $sceneB = Join-Path $temp 'scene_b'
    foreach ($scene in @($sceneA, $sceneB)) {
        $null = New-Item -ItemType Directory -Force $scene
        [IO.File]::WriteAllText((Join-Path $scene 'transforms.json'), '{"frames": []}')
    }
    $global:TestReadHost = [Collections.Generic.Queue[string]]::new()
    function Read-Host { if ($global:TestReadHost.Count) { $global:TestReadHost.Dequeue() } else { '' } }
    foreach ($a in @('', '1')) { $global:TestReadHost.Enqueue($a) }
    Invoke-Viz @($sceneA, (Join-Path $sceneB 'transforms.json'))
    Assert ($global:TestVizArguments -like '*visualize_transforms_web.py*') 'transforms mode not chosen'
    Assert ($global:TestVizArguments.Contains((Join-Path $sceneA 'transforms.json'))) 'folder selection not resolved to transforms.json'
    Assert ($global:TestVizArguments.Contains((Join-Path $sceneB 'transforms.json'))) 'file selection lost'
    Assert ($global:TestVizArguments.TrimEnd() -like '*--port 7007') 'port 1 should be 7007'

    $pngs = Join-Path $temp 'run\semantic\pngs'
    $null = New-Item -ItemType Directory -Force $pngs
    [IO.File]::WriteAllBytes((Join-Path $pngs '000.png'), [byte[]](1,2,3))
    foreach ($a in @('3', '17111')) { $global:TestReadHost.Enqueue($a) }
    Invoke-Viz @(Split-Path $pngs -Parent)
    Assert ($global:TestVizArguments -like '*visualize_masks_web.py*') 'mask mode not chosen'
    Assert ($global:TestVizArguments.Contains('--mask-type semantic') -and $global:TestVizArguments.Contains($pngs)) 'mask arguments wrong'
    Assert ($global:TestVizArguments.TrimEnd() -like '*--port 17111') 'custom port lost'

    $env:YAZI_VIZ_PYTHON = Join-Path $temp 'missing-python.exe'
    $env:LOCALAPPDATA = Join-Path $temp 'no-localappdata'
    Invoke-Viz @($sceneA)
    Assert ($null -eq $global:TestVizArguments) 'viewer started without Python'
    Remove-Item Env:YAZI_VIZ_PYTHON
    $env:LOCALAPPDATA = $oldLocalAppData
    function Read-Host { return '1' }

    $key = New-TransferKeyCommand "C:\Users\O'Brien\AppData\Roaming\yazi\config\scripts\transfer-start.ps1"
    [IO.File]::WriteAllText((Join-Path $temp 'key.txt'), $key)
    Assert ($key.EndsWith('transfer-start.ps1" %s' + [char]39)) 'Transfer key lost %s'
    $windowKey = New-TransferKeyCommand 'C:\yazi\scripts\new-window.ps1' -Arguments ''
    Assert ($windowKey -eq ('shell --orphan ' + [char]39 + 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\yazi\scripts\new-window.ps1"' + [char]39)) 'g l key command wrong'
    Write-Host 'PASS: syntax, proxy validation, config preservation/backup/idempotence, concurrent transfers, g v modes, Unicode/space/apostrophe filenames, cleanup.' -ForegroundColor Green
} finally {
    $env:TEMP = $oldTemp
    if ($oldLocalAppData) { $env:LOCALAPPDATA = $oldLocalAppData }
    Remove-Item $temp -Recurse -Force
}
