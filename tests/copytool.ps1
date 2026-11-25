# g y 目录工具测试：在临时目录里驱动 copy-tool.ps1 的 4 个功能，Read-Host 按队列作答。
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$tool = Join-Path $root 'config/yazi/scripts/copy-tool.ps1'
function Assert($Condition, $Message) { if (-not $Condition) { Write-Host $global:LastOutput; throw "FAIL: $Message" } }
function Start-Sleep { }
$global:Answers = New-Object Collections.Generic.Queue[string]
function Read-Host { if ($global:Answers.Count) { $global:Answers.Dequeue() } else { '' } }

$temp = Join-Path ([IO.Path]::GetTempPath()) ('copytool-test-' + [guid]::NewGuid().ToString('N'))
function New-Tree([string[]]$Files) {
    if (Test-Path $temp) { Remove-Item $temp -Recurse -Force }
    foreach ($f in $Files) {
        $p = Join-Path $temp $f
        if ($f.EndsWith('\')) { $null = New-Item -ItemType Directory -Force $p; continue }
        $null = New-Item -ItemType Directory -Force (Split-Path $p -Parent)
        [IO.File]::WriteAllText($p, $f)
    }
}
function Invoke-Tool([string[]]$Selection, [string[]]$Inputs) {
    $global:Answers.Clear()
    foreach ($a in $Inputs) { $global:Answers.Enqueue($a) }
    $list = Join-Path $temp ('sel-' + [guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($list, (ConvertTo-Json -InputObject @($Selection | ForEach-Object { Join-Path $temp $_ }) -Compress))
    $global:LastOutput = (& $tool -ListPath $list *>&1 | Out-String)
    Assert (-not (Test-Path $list)) 'selection list not cleaned up'
}
function Get-Tree([string]$Sub) {
    $base = Join-Path $temp $Sub
    if (-not (Test-Path $base)) { return @() }
    return @(Get-ChildItem $base -Recurse -File | Where-Object { $_.Name -notlike 'sel-*' } |
        ForEach-Object { $_.FullName.Substring($base.Length + 1) } | Sort-Object)
}
function Same([string[]]$Actual, [string[]]$Expected) { return (($Actual -join '|') -eq (($Expected | Sort-Object) -join '|')) }

try {
    # ---- 功能 1：剪切 + .mp4 + 编号重复命中 + 平铺（无重名） ----
    New-Tree @('big\A\1.mp4', 'big\A\x.txt', 'big\B\2.MP4', 'big\B\y.txt')
    Invoke-Tool @('big') @('1', '2', '1', '1 .mp4', '2', '')
    Assert (Same (Get-Tree 'big-Move') @('1.mp4', '2.MP4')) "flat cut wrong: $(Get-Tree 'big-Move')"
    Assert (Same (Get-Tree 'big') @('A\x.txt', 'B\y.txt')) 'cut left wrong files'

    # ---- 功能 1：复制 + 平铺有重名 → p 加前缀 ----
    New-Tree @('big\A\1.mp4', 'big\B\1.mp4')
    Invoke-Tool @('big') @('1', '1', '1', '*.mp4', '2', 'p', '')
    Assert (Same (Get-Tree 'big-Copy') @('A_1.mp4', 'B_1.mp4')) "prefix flat wrong: $(Get-Tree 'big-Copy')"
    Assert (Same (Get-Tree 'big') @('A\1.mp4', 'B\1.mp4')) 'copy must keep sources'

    # ---- 功能 1：平铺有重名 → q 取消，不做改动 ----
    New-Tree @('big\A\1.mp4', 'big\B\1.mp4')
    Invoke-Tool @('big') @('1', '2', '1', '.mp4', '2', 'q')
    Assert (-not (Test-Path (Join-Path $temp 'big-Move'))) 'cancel must not create dest'
    Assert (Same (Get-Tree 'big') @('A\1.mp4', 'B\1.mp4')) 'cancel must not move'

    # ---- 功能 1：保留结构（回车）+ 目录项 + 含子目录名的项自动替换 + 已存在目标自动编号 ----
    New-Tree @('big\D1\images\a.png', 'big\D1\D1_pc.txt', 'big\D2\images\b.png', 'big\D2\D2_pc.txt', 'big-Copy\keep.txt')
    Invoke-Tool @('big') @('1', '1', '1', 'a', '', '')
    Assert (Same (Get-Tree 'big-Copy1') @('D1\D1_pc.txt', 'D1\images\a.png', 'D2\D2_pc.txt', 'D2\images\b.png')) "preserve copy wrong: $(Get-Tree 'big-Copy1')"

    # ---- 功能 1：多选大目录 → <共同母目录>_Copy ----
    New-Tree @('root\p\X\1.mp4', 'root\q\Y\2.mp4')
    Invoke-Tool @('root\p', 'root\q') @('1', '1', '1', '1', '.mp4', '', '')
    Assert (Same (Get-Tree 'root_Copy') @('p\X\1.mp4', 'q\Y\2.mp4')) "multi copy wrong: $(Get-Tree 'root_Copy')"

    # ---- 功能 2：目录重整 ----
    New-Tree @('big\20250101\K01\a.txt', 'big\20250101\K02\b.txt', 'big\20250202\K01\c.txt', 'big\20250101\loose.txt')
    Invoke-Tool @('big') @('2', '')
    Assert (Same (Get-Tree 'big-Reorg') @('K01\20250101\a.txt', 'K01\20250202\c.txt', 'K02\20250101\b.txt')) "reorg wrong: $(Get-Tree 'big-Reorg')"
    Assert (Same (Get-Tree 'big') @('20250101\loose.txt')) 'reorg must skip loose files'

    # ---- 功能 3：拼接成功 + 新一级目录 ----
    New-Tree @('A\L1\g1\a.txt', 'A\L2\g2\b.txt', 'B\L1\g0\c.txt')
    Invoke-Tool @('A', 'B') @('3', '1', '')
    Assert (Same (Get-Tree 'B') @('L1\g0\c.txt', 'L1\g1\a.txt', 'L2\g2\b.txt')) "merge wrong: $(Get-Tree 'B')"
    # ---- 功能 3：冲突 → 整体中止 ----
    New-Tree @('A\L1\g1\a.txt', 'A\L1\g2\b.txt', 'B\L1\g1\c.txt')
    Invoke-Tool @('A', 'B') @('3', '1', '')
    Assert (Same (Get-Tree 'A') @('L1\g1\a.txt', 'L1\g2\b.txt')) 'collision must not move anything'

    # ---- 功能 4：品种/日期广播（需要 Python） ----
    $hasPython = (Get-Command py -ErrorAction SilentlyContinue) -or (Get-Command python -ErrorAction SilentlyContinue)
    if ($hasPython) {
        New-Tree @('v\K01\d1\images\a.jpg', 'v\K02\d1\images\a.jpg', 'v\skipX\d1\images\a.jpg', 'v\K03\other\')
        [IO.File]::WriteAllText((Join-Path $temp 'v\K01\d1\transforms.json'), '{"frames":[{"file_path":"images/a.jpg"},{"file_path":"images/b.jpg"}],"名":"源"}')
        [IO.File]::WriteAllText((Join-Path $temp 'v\K02\d1\transforms.json'), '{"frames":[]}')
        Invoke-Tool @('v\K01') @('4', '')
        $new = Get-Content (Join-Path $temp 'v\K02\d1\transforms.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert ($new.frames.Count -eq 1) 'broadcast did not filter frames'
        Assert (@(Get-ChildItem (Join-Path $temp 'v\K02\d1') -Filter 'transforms_*.json').Count -eq 1) 'broadcast did not back up target'
        Assert (-not (Test-Path (Join-Path $temp 'v\skipX\d1\transforms.json'))) 'skip* target must be excluded'
        # 单层模式：只选中 transforms.json
        New-Tree @('img\R1\images\a.jpg', 'img\R2\images\a.jpg')
        [IO.File]::WriteAllText((Join-Path $temp 'img\R1\transforms.json'), '{"frames":[{"file_path":"images/a.jpg"}]}')
        Invoke-Tool @('img\R1\transforms.json') @('4', '')
        Assert (Test-Path (Join-Path $temp 'img\R2\transforms.json')) 'single-layer broadcast failed'
    } else { Write-Warning 'No Python: broadcast tests skipped.' }

    # ---- 分屏启动脚本 ----
    $global:TestPaneCommands = @()
    function psmux { $global:TestPaneCommands += $args[-1]; $global:LASTEXITCODE = 0 }
    $oldTemp = $env:TEMP; $env:TEMP = $temp
    try { & (Join-Path $root 'config/yazi/scripts/copy-tool-start.ps1') (Join-Path $temp 'big') } finally { $env:TEMP = $oldTemp }
    Assert ($global:TestPaneCommands.Count -eq 1) 'g y pane not requested'
    $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($global:TestPaneCommands[0] -split ' ')[-1]))
    Assert ($decoded -match "copy-tool\.ps1' -ListPath ") 'g y pane command wrong'

    Write-Host 'PASS: g y copy/cut (glob, dedupe, flat, prefix, cancel, preserve, multi), reorg, merge (+collision), broadcast (+single-layer), pane start.' -ForegroundColor Green
} finally {
    if (Test-Path $temp) { Remove-Item $temp -Recurse -Force }
}
