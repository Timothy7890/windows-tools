# g y → 目录工具集（与 linux-tools 的 copy_tool.sh 功能一致）。
# 触发：Yazi 中选中文件夹后按 g 再按 y（见 keymap.toml），在 psmux 右侧分屏运行。
#
#   1) 挑选子文件夹复制 / 剪切：以某个子目录为参考勾选项（编号、a 全选，或 .mp4 / *_mask* 按名字匹配），
#      对每个直接子目录处理，放到同级 <名>-Copy / <名>-Move；可保留结构或平铺一层（重名时可加前缀）。
#   2) 目录重整：<大>\L1\L2 → <大>-Reorg\L2\L1（移动），日期/品种 ↔ 品种/日期。
#   3) 拼接：两个同结构文件夹，把源的孙目录移动到目标对应一级目录下；有冲突则整体中止。
#   4) transforms 广播：源品种各日期的 transforms.json → 同级其他品种同日期（use_existed_trans.py，
#      按目标 images\ 过滤帧并备份原文件）；源目录自身含 transforms.json 时为单层模式。
#
# 依赖：psmux；功能 4 需要 Python 3（$env:YAZI_TT_PYTHON 可指定解释器）。
param([Parameter(Mandatory = $true)][string]$ListPath)
$ErrorActionPreference = 'Stop'

function Stop-Tool([string]$Message, [int]$Seconds = 1) {
    if ($Message) { Write-Host $Message -ForegroundColor Yellow }
    Start-Sleep -Seconds $Seconds
    exit 0
}
function Read-Yes([string]$Prompt) {
    $answer = (Read-Host "$Prompt [Y/n] (回车=是)").Trim()
    return (-not $answer -or $answer -match '^(y|yes)$')
}
function Read-Index([string]$Prompt, [int]$Count) {
    $answer = (Read-Host "$Prompt [默认 1]").Trim()
    if (-not $answer) { return 0 }
    $n = 0
    if (-not [int]::TryParse($answer, [ref]$n) -or $n -lt 1 -or $n -gt $Count) { Stop-Tool "无效选择：$answer" 2 }
    return $n - 1
}
function Get-SubDirs([string]$Path) {
    return @(Get-ChildItem -LiteralPath $Path -Directory | Sort-Object Name)
}
function Get-Entries([string]$Path) {
    return @(Get-ChildItem -LiteralPath $Path | Sort-Object Name)
}
# 生成同级目标目录名（重名自动追加数字）
function Get-FreeDest([string]$Parent, [string]$Name, [string]$Suffix) {
    $dest = Join-Path $Parent ($Name + $Suffix)
    $n = 1
    while (Test-Path -LiteralPath $dest) { $dest = Join-Path $Parent ($Name + $Suffix + $n); $n++ }
    return $dest
}
# 多个绝对路径的最深公共祖先（Windows 路径不区分大小写）
function Get-CommonAncestor([string[]]$Paths) {
    $common = $Paths[0]
    foreach ($p in $Paths) {
        while ($p -ne $common -and -not $p.StartsWith($common.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
            $parent = Split-Path $common -Parent
            if (-not $parent) { break }
            $common = $parent
        }
    }
    return $common
}
function Show-List([string[]]$Items, [int]$Max, [string]$Prefix) {
    $show = [Math]::Min($Items.Count, $Max)
    for ($k = 0; $k -lt $show; $k++) { Write-Host "$Prefix$($Items[$k])" }
    if ($Items.Count -gt $Max) { Write-Host "      ... 其余 $($Items.Count - $Max) 项" }
}
function Get-RelativePath([string]$Root, [string]$Path) {
    return $Path.Substring($Root.TrimEnd('\').Length + 1)
}
function Find-TtPython {
    $ErrorActionPreference = 'Continue'
    if ($env:YAZI_TT_PYTHON) { return @($env:YAZI_TT_PYTHON) }
    $py = Get-Command py -CommandType Application -ErrorAction SilentlyContinue
    if ($py) {
        & $py.Source -3 -c 'import sys' 2>$null
        if ($LASTEXITCODE -eq 0) { return @($py.Source, '-3') }
    }
    foreach ($name in @('python', 'python3')) {
        foreach ($cmd in @(Get-Command $name -CommandType Application -All -ErrorAction SilentlyContinue)) {
            # WindowsApps 下的 python.exe 只会打开应用商店
            if ($cmd.Source -match '\\WindowsApps\\') { continue }
            & $cmd.Source -c 'import sys' 2>$null
            if ($LASTEXITCODE -eq 0) { return @($cmd.Source) }
        }
    }
    return @()
}

# =====================================================================
# 功能 1：挑选子文件夹复制 / 剪切
# =====================================================================
function Invoke-CopyFeature {
    Write-Host ''
    Write-Host '  1) 复制'
    Write-Host '  2) 剪切'
    Write-Host '  q) 取消'
    Write-Host ''
    switch ((Read-Host '请选择 [1-2/q]').Trim()) {
        '1' { $action = 'copy'; $verb = '复制'; $suffixSingle = '-Copy'; $suffixMulti = '_Copy' }
        '2' { $action = 'cut'; $verb = '剪切'; $suffixSingle = '-Move'; $suffixMulti = '_Move' }
        default { Stop-Tool '已取消' }
    }
    $multi = $script:Dirs.Count -gt 1

    # 选择参考大目录（多选时）
    $refBig = $script:Dirs[0]
    if ($multi) {
        Write-Host ''
        Write-Host '==============================='
        Write-Host '  选择参考大目录（用它的某个子目录来决定要处理哪些项）'
        Write-Host '==============================='
        for ($i = 0; $i -lt $script:Dirs.Count; $i++) { Write-Host ('  {0,2}) {1}' -f ($i + 1), (Split-Path $script:Dirs[$i] -Leaf)) }
        Write-Host ''
        $refBig = $script:Dirs[(Read-Index '请选择参考大目录' $script:Dirs.Count)]
    }

    $subDirs = Get-SubDirs $refBig
    if (-not $subDirs.Count) { Stop-Tool "参考大目录下没有子目录：$refBig" 3 }
    Write-Host ''
    Write-Host '==============================='
    Write-Host "  选择参考子目录（用于列出可勾选的内容，来自: $(Split-Path $refBig -Leaf)）"
    Write-Host '==============================='
    for ($i = 0; $i -lt $subDirs.Count; $i++) { Write-Host ('  {0,2}) {1}' -f ($i + 1), $subDirs[$i].Name) }
    Write-Host ''
    $ref = $subDirs[(Read-Index '请选择参考子目录' $subDirs.Count)]
    $refName = $ref.Name   # 参考子目录名（如日期 20250915 或品种 K02）

    $entries = Get-Entries $ref.FullName
    if (-not $entries.Count) { Stop-Tool "参考子目录为空：$($ref.FullName)" 3 }
    Write-Host ''
    Write-Host '==============================='
    Write-Host "  勾选要${verb}的项（参考自: $refName）"
    Write-Host '==============================='
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $mark = if ($entries[$i].PSIsContainer) { '[目录]' } else { '[文件]' }
        $hint = if ($entries[$i].Name.Contains($refName)) { "   （含子目录名「$refName」，将按各子目录自动替换）" } else { '' }
        Write-Host ('  {0,2}) {1} {2}{3}' -f ($i + 1), $mark, $entries[$i].Name, $hint)
    }
    # 列出参考子目录里出现的文件后缀，方便按后缀匹配
    $extCount = [ordered]@{}
    foreach ($e in $entries) {
        if ($e.PSIsContainer -or -not $e.Extension) { continue }
        $ext = $e.Extension.TrimStart('.').ToLowerInvariant()
        $extCount[$ext] = 1 + $(if ($extCount.Contains($ext)) { $extCount[$ext] } else { 0 })
    }
    Write-Host ''
    Write-Host '  输入编号（空格或逗号分隔，如: 1 2），或输入 a 选择全部'
    Write-Host '  也可按名字匹配（每个子目录各自匹配，可与编号混用）：'
    Write-Host '    .mp4 或 *.mp4  → 所有 mp4 文件；  *_mask*  → 名字含 _mask 的项'
    if ($extCount.Count) {
        Write-Host ('  本参考目录中的后缀: ' + (($extCount.Keys | ForEach-Object { "*.$_($($extCount[$_]))" }) -join '  '))
    }
    $picks = (Read-Host '请勾选').Trim()
    if (-not $picks) { Stop-Tool '未勾选任何项，已取消' }

    $patterns = New-Object Collections.Generic.List[string]
    if ($picks -match '^(a|all)$') {
        foreach ($e in $entries) { $patterns.Add($e.Name) }
    } else {
        foreach ($n in ($picks -split '[,\s]+' | Where-Object { $_ })) {
            $idx = 0
            if ([int]::TryParse($n, [ref]$idx)) {
                if ($idx -lt 1 -or $idx -gt $entries.Count) { Write-Host "  编号越界: $n"; continue }
                $name = $entries[$idx - 1].Name
            } else {
                # 名字匹配：.mp4 → *.mp4；其余含通配符的原样使用
                if ($n -match '^\.[^.\\/*?]+$') { $n = '*' + $n }
                if ($n -notmatch '[*?\[]') { Write-Host "  忽略无效输入: $n（通配请写成 *.mp4 或 .mp4）"; continue }
                $name = $n
            }
            if (-not $patterns.Contains($name)) { $patterns.Add($name) }
        }
    }
    if (-not $patterns.Count) { Stop-Tool '未勾选任何有效项，已取消' }

    # 目标文件夹：单选 <大目录>-Copy/-Move；多选 <共同母目录>_Copy/_Move，各大目录按相对结构放入
    $common = ''
    if ($multi) {
        $common = Get-CommonAncestor $script:Dirs
        $dest = Get-FreeDest (Split-Path $common -Parent) (Split-Path $common -Leaf) $suffixMulti
    } else {
        $dest = Get-FreeDest (Split-Path $refBig -Parent) (Split-Path $refBig -Leaf) $suffixSingle
    }

    # 生成计划 & 检查缺失
    $planSrc = New-Object Collections.Generic.List[string]
    $planRel = New-Object Collections.Generic.List[string]
    $missing = New-Object Collections.Generic.List[string]
    $emptyBig = New-Object Collections.Generic.List[string]
    $planned = @{}   # 编号与通配可能命中同一文件，去重（哈希表不区分大小写，与 Windows 路径一致）
    foreach ($big in $script:Dirs) {
        $relPrefix = if ($multi) { (Get-RelativePath $common $big) + '\' } else { '' }
        $bigSubs = Get-SubDirs $big
        if (-not $bigSubs.Count) { $emptyBig.Add((Split-Path $big -Leaf)); continue }
        foreach ($s in $bigSubs) {
            $sn = $s.Name
            foreach ($pat in $patterns) {
                # 勾选项名字里含参考子目录名（如 <日期>_psnppcuda.txt）时，换成当前子目录名
                $realPat = if ($pat.Contains($refName)) { $pat.Replace($refName, $sn) } else { $pat }
                if ($realPat -match '[*?\[]') {
                    $hits = @(Get-Entries $s.FullName | Where-Object { $_.Name -like $realPat })
                    if (-not $hits.Count) { $missing.Add("$relPrefix$sn\$realPat"); continue }
                    $names = @($hits | ForEach-Object Name)
                } elseif (Test-Path -LiteralPath (Join-Path $s.FullName $realPat)) {
                    $names = @($realPat)
                } else {
                    $missing.Add("$relPrefix$sn\$realPat"); continue
                }
                foreach ($name in $names) {
                    $full = Join-Path $s.FullName $name
                    if ($planned.ContainsKey($full)) { continue }
                    $planned[$full] = $true
                    $planSrc.Add($full); $planRel.Add("$relPrefix$sn\$name")
                }
            }
        }
    }
    if (-not $planSrc.Count) { Stop-Tool '所有子目录都找不到勾选的项，无事可做。' 3 }

    # 目标结构：保留结构 / 平铺到同一层（平铺前必须确认无重名）
    $destName = Split-Path $dest -Leaf
    Write-Host ''
    Write-Host '  目标结构：'
    Write-Host "  1) 保留结构  $destName\$($planRel[0])   （默认，回车）"
    Write-Host "  2) 平铺一层  $destName\$(Split-Path $planRel[0] -Leaf)"
    $layoutDesc = '保留结构'
    if ((Read-Host '请选择 [1-2]').Trim() -eq '2') {
        $layoutDesc = '平铺一层'
        $from = [ordered]@{}   # 不区分大小写：Windows 上 1.MP4 与 1.mp4 也算重名
        foreach ($r in $planRel) {
            $leaf = Split-Path $r -Leaf
            if (-not $from.Contains($leaf)) { $from[$leaf] = New-Object Collections.Generic.List[string] }
            $from[$leaf].Add((Split-Path $r -Parent))
        }
        $dups = @($from.Keys | Where-Object { $from[$_].Count -gt 1 })
        $flat = New-Object Collections.Generic.List[string]
        if ($dups.Count) {
            Write-Host ''
            Write-Host "  ⚠ 平铺后有 $($dups.Count) 个名字重复，不能直接平铺：" -ForegroundColor Yellow
            Show-List @($dups | ForEach-Object { "$_  ←  $($from[$_] -join '、')" }) 20 '      - '
            Write-Host ''
            $example = ((Split-Path $planRel[0] -Parent) -replace '\\', '_') + '_' + (Split-Path $planRel[0] -Leaf)
            Write-Host "  p) 文件名加子目录名前缀（如 $example）"
            Write-Host '  q) 取消（不做任何改动）'
            if ((Read-Host '请选择 [p/q]').Trim() -ne 'p') { Stop-Tool '已取消，未做任何改动' }
            $layoutDesc = '平铺一层（加子目录名前缀）'
            foreach ($r in $planRel) { $flat.Add(((Split-Path $r -Parent) -replace '\\', '_') + '_' + (Split-Path $r -Leaf)) }
            # 加前缀后仍重名（极少见）则放弃
            $seen = @{}
            foreach ($f in $flat) { if ($seen.ContainsKey($f)) { Stop-Tool '加前缀后仍有重名，已取消，未做任何改动。' 4 }; $seen[$f] = $true }
        } else {
            foreach ($r in $planRel) { $flat.Add((Split-Path $r -Leaf)) }
        }
        $planRel = $flat
    }

    # 预览
    Write-Host ''
    Write-Host '==============================='
    Write-Host "  操作预览（$verb）"
    Write-Host '==============================='
    if ($multi) {
        Write-Host "  选中大目录: $($script:Dirs.Count) 个"
        Write-Host "  共同母目录: $common"
    } else {
        Write-Host "  大文件夹  : $refBig"
    }
    Write-Host "  目标文件夹: $dest"
    Write-Host "  目标结构  : $layoutDesc"
    Write-Host "  勾选项    : $($patterns -join ' ')"
    Write-Host "  待${verb}项 : $($planSrc.Count)"
    Write-Host ''
    Show-List @($planRel | ForEach-Object { "$dest\$_" }) 20 '    + '
    if ($emptyBig.Count) {
        Write-Host ''
        Write-Host "  ℹ 以下 $($emptyBig.Count) 个大目录没有子目录，已跳过： $($emptyBig -join ' ')"
    }
    if ($missing.Count) {
        Write-Host ''
        Write-Host "  ⚠ 警告：以下 $($missing.Count) 个项在对应子目录中缺失，将被跳过：" -ForegroundColor Yellow
        Show-List $missing 20 '      - '
    }
    Write-Host ''
    if (-not (Read-Yes "是否继续执行 $verb ?")) { Stop-Tool '已取消' }

    Write-Host ''
    Write-Host "开始$verb ..."
    $ok = 0; $fail = 0
    for ($k = 0; $k -lt $planSrc.Count; $k++) {
        $target = Join-Path $dest $planRel[$k]
        try {
            $null = New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent)
            if ($action -eq 'copy') { Copy-Item -LiteralPath $planSrc[$k] -Destination $target -Recurse }
            else { Move-Item -LiteralPath $planSrc[$k] -Destination $target }
            $ok++
        } catch { $fail++; Write-Host "  [失败] $($planRel[$k])：$($_.Exception.Message)" -ForegroundColor Red }
    }
    Write-Host ''
    Write-Host "完成：成功 $ok，失败 $fail"
    Write-Host "目标：$dest"
}

# =====================================================================
# 功能 2：目录重整（前两层级互换，移动方式）
# =====================================================================
function Invoke-ReorgFeature {
    $big = $script:Dirs[0]
    $l1s = Get-SubDirs $big
    if (-not $l1s.Count) { Stop-Tool '大文件夹下没有一级子目录。' 3 }

    # big\L1\L2 → dest\L2\L1；散文件记录到 loose
    $planSrc = New-Object Collections.Generic.List[string]
    $planRel = New-Object Collections.Generic.List[string]
    $loose = New-Object Collections.Generic.List[string]
    foreach ($l1 in $l1s) {
        foreach ($e in (Get-Entries $l1.FullName)) {
            if ($e.PSIsContainer) { $planSrc.Add($e.FullName); $planRel.Add("$($e.Name)\$($l1.Name)") }
            else { $loose.Add("$($l1.Name)\$($e.Name)") }
        }
    }
    if (-not $planSrc.Count) { Stop-Tool '没有可重整的二级目录。' 3 }

    $allDate = -not @($l1s | Where-Object { $_.Name -notmatch '^\d{8}$' }).Count
    $layout = if ($allDate) { '日期/品种  →  品种/日期' } else { '品种/日期  →  日期/品种' }
    $dest = Get-FreeDest (Split-Path $big -Parent) (Split-Path $big -Leaf) '-Reorg'
    $bigName = Split-Path $big -Leaf

    Write-Host ''
    Write-Host '==============================='
    Write-Host '  目录重整预览（移动 / 前两层互换）'
    Write-Host '==============================='
    Write-Host "  大文件夹  : $big"
    Write-Host "  目标文件夹: $dest"
    Write-Host "  转换方向  : $layout"
    Write-Host "  一级目录数: $($l1s.Count)"
    Write-Host "  待移动项  : $($planSrc.Count)"
    Write-Host ''
    $lines = for ($k = 0; $k -lt $planSrc.Count; $k++) { "$bigName\$(Get-RelativePath $big $planSrc[$k])  ->  $($planRel[$k])" }
    Show-List @($lines) 20 '    '
    if ($loose.Count) {
        Write-Host ''
        Write-Host "  ⚠ 警告：以下 $($loose.Count) 个散文件直接位于一级目录下（不是二级目录），将被跳过不搬：" -ForegroundColor Yellow
        Show-List $loose 20 '      - '
    }
    Write-Host ''
    Write-Host '  说明：采用【移动】方式，完成后原大文件夹里的一级目录会变空（结构保留）。'
    Write-Host '        确认新目录无误后可自行删除原文件夹。'
    Write-Host ''
    if (-not (Read-Yes '是否继续执行 目录重整 ?')) { Stop-Tool '已取消' }

    Write-Host ''
    Write-Host '开始重整（移动）...'
    $ok = 0; $fail = 0
    for ($k = 0; $k -lt $planSrc.Count; $k++) {
        $target = Join-Path $dest $planRel[$k]
        try {
            $null = New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent)
            Move-Item -LiteralPath $planSrc[$k] -Destination $target
            $ok++
        } catch { $fail++; Write-Host "  [失败] $($planRel[$k])：$($_.Exception.Message)" -ForegroundColor Red }
    }
    Write-Host ''
    Write-Host "完成：成功 $ok，失败 $fail"
    Write-Host "目标：$dest"
}

# =====================================================================
# 功能 3：拼接（合并两个结构一致的文件夹，移动孙目录，就地合并）
# =====================================================================
function Invoke-MergeFeature {
    $a = $script:Dirs[0]; $b = $script:Dirs[1]
    $an = Split-Path $a -Leaf; $bn = Split-Path $b -Leaf
    Write-Host ''
    Write-Host '==============================='
    Write-Host '  选择拼接方向（把[源]的孙目录移动到[目标]对应一级目录下）'
    Write-Host '==============================='
    Write-Host "  1) 源: $an  ->  目标: $bn   （$an 将被搬空）"
    Write-Host "  2) 源: $bn  ->  目标: $an   （$bn 将被搬空）"
    Write-Host '  q) 取消'
    Write-Host ''
    switch ((Read-Host '请选择 [1-2/q]').Trim()) {
        '1' { $src = $a; $tgt = $b }
        '2' { $src = $b; $tgt = $a }
        default { Stop-Tool '已取消' }
    }
    $srcL1 = Get-SubDirs $src
    if (-not $srcL1.Count) { Stop-Tool '源没有一级目录。' 3 }
    $tgtHas = @{}
    foreach ($d in (Get-SubDirs $tgt)) { $tgtHas[$d.Name] = $true }

    $planSrc = New-Object Collections.Generic.List[string]
    $planTgt = New-Object Collections.Generic.List[string]
    $collisions = New-Object Collections.Generic.List[string]
    $loose = New-Object Collections.Generic.List[string]
    $newL1 = New-Object Collections.Generic.List[string]
    foreach ($l1 in $srcL1) {
        if (-not $tgtHas.ContainsKey($l1.Name)) { $newL1.Add($l1.Name) }
        foreach ($e in (Get-Entries $l1.FullName)) {
            if (-not $e.PSIsContainer) { $loose.Add("$($l1.Name)\$($e.Name)"); continue }
            $to = Join-Path (Join-Path $tgt $l1.Name) $e.Name
            if (Test-Path -LiteralPath $to) { $collisions.Add("$($l1.Name)\$($e.Name)") }
            else { $planSrc.Add($e.FullName); $planTgt.Add($to) }
        }
    }
    # 冲突 → 中止（不覆盖、不改动）
    if ($collisions.Count) {
        Write-Host ''
        Write-Host "  ✗ 检测到 $($collisions.Count) 个孙目录在目标中已存在（冲突），已中止，未做任何改动：" -ForegroundColor Red
        Show-List $collisions 30 '      - '
        Stop-Tool '' 4
    }
    if (-not $planSrc.Count) { Stop-Tool '没有可移动的孙目录。' 3 }

    Write-Host ''
    Write-Host '==============================='
    Write-Host '  拼接预览（移动 / 就地合并）'
    Write-Host '==============================='
    Write-Host "  源      : $src"
    Write-Host "  目标    : $tgt"
    Write-Host "  一级目录: 源 $($srcL1.Count) 个"
    Write-Host "  待移动项: $($planSrc.Count)"
    Write-Host ''
    $tn = Split-Path $tgt -Leaf
    $lines = for ($k = 0; $k -lt $planSrc.Count; $k++) { "$(Get-RelativePath $src $planSrc[$k])  ->  $tn\$(Get-RelativePath $tgt $planTgt[$k])" }
    Show-List @($lines) 20 '    '
    if ($newL1.Count) {
        Write-Host ''
        Write-Host "  ℹ 以下 $($newL1.Count) 个一级目录目标中没有，将自动新建并搬入： $($newL1 -join ' ')"
    }
    if ($loose.Count) {
        Write-Host ''
        Write-Host "  ⚠ 警告：以下 $($loose.Count) 个散文件直接位于源的一级目录下（不是孙目录），将被跳过不搬：" -ForegroundColor Yellow
        Show-List $loose 20 '      - '
    }
    Write-Host ''
    Write-Host '  说明：采用【移动】方式就地合并，完成后源文件夹的一级目录会变空（结构保留）。'
    Write-Host ''
    if (-not (Read-Yes '是否继续执行 拼接 ?')) { Stop-Tool '已取消' }

    Write-Host ''
    Write-Host '开始拼接（移动）...'
    $ok = 0; $fail = 0
    for ($k = 0; $k -lt $planSrc.Count; $k++) {
        try {
            $null = New-Item -ItemType Directory -Force -Path (Split-Path $planTgt[$k] -Parent)
            Move-Item -LiteralPath $planSrc[$k] -Destination $planTgt[$k]
            $ok++
        } catch { $fail++; Write-Host "  [失败] $(Get-RelativePath $src $planSrc[$k])：$($_.Exception.Message)" -ForegroundColor Red }
    }
    Write-Host ''
    Write-Host "完成：成功 $ok，失败 $fail"
    Write-Host "目标：$tgt"
}

# =====================================================================
# 功能 4：transforms 广播（use_existed_trans.py：按目标 images\ 过滤帧、备份原文件）
# =====================================================================
function Invoke-BroadcastFeature {
    $src = $script:Dirs[0]
    $vroot = Split-Path $src -Parent
    $ttScript = Join-Path $PSScriptRoot 'use_existed_trans.py'
    if (-not (Test-Path -LiteralPath $ttScript)) { Stop-Tool "找不到 $ttScript，请重跑 .\install.ps1 yazi。" 4 }
    $python = @(Find-TtPython)
    if (-not $python.Count) { Stop-Tool '找不到 Python 3：功能 4 需要 Python（可设置 $env:YAZI_TT_PYTHON）。' 4 }

    # 源日期：源品种下含 transforms.json 的直接子目录；源目录自身含 transforms.json 时为单层模式（日期为空）
    $layout = '品种/日期'
    if (Test-Path -LiteralPath (Join-Path $src 'transforms.json') -PathType Leaf) {
        $dates = @('')
        $layout = '单层（源目录自身含 transforms.json）'
    } else {
        $dates = @(Get-SubDirs $src | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'transforms.json') -PathType Leaf } | ForEach-Object Name)
    }
    if (-not $dates.Count) { Stop-Tool "源目录自身及其子目录下都没有 transforms.json：$src" 4 }

    # 目标品种：同级目录，排除源自身与名字以 skip 开头的目录
    $targets = New-Object Collections.Generic.List[string]
    $skipped = New-Object Collections.Generic.List[string]
    foreach ($d in (Get-SubDirs $vroot)) {
        if ($d.FullName -eq $src) { continue }
        if ($d.Name -clike 'skip*') { $skipped.Add($d.Name); continue }
        $targets.Add($d.Name)
    }
    if (-not $targets.Count) { Stop-Tool '没有可用的目标品种（同级目录）。' 4 }

    $planTgt = New-Object Collections.Generic.List[string]
    $planSrc = New-Object Collections.Generic.List[string]
    $missing = New-Object Collections.Generic.List[string]
    foreach ($dt in $dates) {
        foreach ($v in $targets) {
            $t = if ($dt) { Join-Path (Join-Path $vroot $v) $dt } else { Join-Path $vroot $v }
            $rel = if ($dt) { "$v\$dt" } else { $v }
            $from = if ($dt) { Join-Path (Join-Path $src $dt) 'transforms.json' } else { Join-Path $src 'transforms.json' }
            if (Test-Path -LiteralPath $t -PathType Container) { $planTgt.Add($t); $planSrc.Add($from) }
            else { $missing.Add($rel) }
        }
    }
    if (-not $planTgt.Count) { Stop-Tool '目标品种都没有与源匹配的日期目录，无事可做。' 4 }

    Write-Host ''
    Write-Host '==============================='
    Write-Host '  transforms 广播预览（use_existed_trans / 按目标 images 过滤帧）'
    Write-Host '==============================='
    Write-Host "  源品种  : $src"
    Write-Host "  品种根  : $vroot"
    Write-Host "  结构    : $layout"
    if ($dates[0]) { Write-Host "  源日期数: $($dates.Count)（均含 transforms.json）" }
    Write-Host "  目标品种: $($targets.Count) 个 -> $($targets -join ' ')"
    Write-Host "  待写入项: $($planTgt.Count)"
    if ($skipped.Count) { Write-Host "  已排除  : $($skipped -join ' ')" }
    Write-Host ''
    $lines = for ($k = 0; $k -lt $planTgt.Count; $k++) { "$(Get-RelativePath $vroot $planSrc[$k])  ->  $(Get-RelativePath $vroot $planTgt[$k])\transforms.json" }
    Show-List @($lines) 15 '    '
    if ($missing.Count) {
        Write-Host ''
        Write-Host "  ⚠ 警告：以下 $($missing.Count) 个 目标品种/日期 不存在，将被跳过：" -ForegroundColor Yellow
        Show-List $missing 15 '      - '
    }
    Write-Host ''
    Write-Host '  说明：目标若已有 transforms.json 会被自动改名备份为 transforms_<时间戳>.json（不会丢）。'
    Write-Host '        帧会按目标 images\ 过滤，指向不存在图片的帧会被删除。'
    Write-Host ''
    if (-not (Read-Yes '是否继续执行 广播 ?')) { Stop-Tool '已取消' }

    Write-Host ''
    Write-Host "开始广播（$($python -join ' ') use_existed_trans.py）..."
    $pyArgs = @(); if ($python.Count -gt 1) { $pyArgs = $python[1..($python.Count - 1)] }
    $ok = 0; $fail = 0
    # Python 的 stderr 不应终止本脚本
    $ErrorActionPreference = 'Continue'
    $env:PYTHONIOENCODING = 'utf-8'
    for ($k = 0; $k -lt $planTgt.Count; $k++) {
        Write-Host "---- [$($k + 1)/$($planTgt.Count)] $(Get-RelativePath $vroot $planTgt[$k]) ----"
        & $python[0] @pyArgs $ttScript -i $planTgt[$k] -t $planSrc[$k] -L 1
        if ($LASTEXITCODE -eq 0) { $ok++ } else { $fail++; Write-Host "  [失败] $(Get-RelativePath $vroot $planTgt[$k])" -ForegroundColor Red }
    }
    Write-Host ''
    Write-Host "完成：成功 $ok，失败 $fail"
    Write-Host "目标根：$vroot"
}

# =====================================================================
# 主菜单
# =====================================================================
try {
    # PowerShell 5.1 的 ConvertFrom-Json 把整个数组当成一个对象输出，先赋值再展开
    $raw = Get-Content -LiteralPath $ListPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Remove-Item -LiteralPath $ListPath -Force -ErrorAction SilentlyContinue
    $sel = @($raw | Where-Object { $_ } | ForEach-Object { ([string]$_).TrimEnd('\', '/') })
    if (-not $sel.Count) { Stop-Tool '没有选中任何文件，已取消' }

    # 选中项中的目录；只选中一个 transforms.json 时以其所在目录为源（功能 4 单层模式）
    $script:Dirs = @($sel | Where-Object { Test-Path -LiteralPath $_ -PathType Container } |
        ForEach-Object { (Get-Item -LiteralPath $_ -Force).FullName.TrimEnd('\') })
    if (-not $script:Dirs.Count -and $sel.Count -eq 1 -and (Split-Path $sel[0] -Leaf) -eq 'transforms.json') {
        $script:Dirs = @((Split-Path (Get-Item -LiteralPath $sel[0] -Force).FullName -Parent))
    }
    if (-not $script:Dirs.Count) { Stop-Tool '请选中文件夹后再按 g y。' 3 }

    Write-Host '==============================='
    Write-Host '  g y  目录工具'
    Write-Host '==============================='
    Write-Host "  已选目录 ($($script:Dirs.Count) 个):"
    foreach ($d in $script:Dirs) { Write-Host "    - $d" }
    Write-Host ''
    Write-Host '  1) 挑选子文件夹复制or剪切          （可选中 1 个或多个文件夹）'
    Write-Host '  2) 目录重整（前两层级互换：日期 <-> 品种） （需选中 1 个文件夹）'
    Write-Host '  3) 拼接（合并两个一致结构，移动孙目录）    （需选中 2 个文件夹）'
    Write-Host '  4) transforms 广播（源品种各日期 -> 其他品种同日期；或单层：源 -> 同级目录）（选中 1 个源目录或其 transforms.json）'
    Write-Host '  q) 取消'
    Write-Host ''
    $count = $script:Dirs.Count
    switch ((Read-Host '请选择 [1-4/q]').Trim()) {
        '1' { Invoke-CopyFeature }
        '2' { if ($count -ne 1) { Stop-Tool "功能2 需要且只需选中 1 个文件夹（当前 $count 个）。" 3 }; Invoke-ReorgFeature }
        '3' { if ($count -ne 2) { Stop-Tool "功能3 需要选中 2 个文件夹（当前 $count 个）。" 3 }; Invoke-MergeFeature }
        '4' { if ($count -ne 1) { Stop-Tool "功能4 需要且只需选中 1 个源品种目录（当前 $count 个）。" 3 }; Invoke-BroadcastFeature }
        default { Stop-Tool '已取消' }
    }
    Write-Host ''
    Read-Host '按回车关闭窗口' | Out-Null
} catch {
    Write-Host $_ -ForegroundColor Red
    Read-Host '按回车关闭' | Out-Null
    exit 1
} finally {
    Remove-Item -LiteralPath $ListPath -Force -ErrorAction SilentlyContinue
}
