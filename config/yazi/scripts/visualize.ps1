# Web 可视化 Yazi 选中的 transforms.json 或 semantic/instance 标签图（g v）。
#   - 只选一个 semantic / instance / instance_g 目录（或其 pngs\）→ 彩色 Mask 图库
#   - transforms.json 文件或含它的文件夹，可多选                     → 相机位姿 3D 视图
# Python 查找顺序：$env:YAZI_VIZ_PYTHON → %LOCALAPPDATA%\yazi-viz\Scripts\python.exe（install.ps1 创建）
param([Parameter(Mandatory = $true)][string]$ListPath)
$ErrorActionPreference = 'Stop'

function Get-VizPython {
    $candidates = @($env:YAZI_VIZ_PYTHON, (Join-Path $env:LOCALAPPDATA 'yazi-viz\Scripts\python.exe'))
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    return $null
}
function Read-Confirm {
    $answer = (Read-Host '是否继续? [Y/n] (回车=是)').Trim()
    return (-not $answer -or $answer -match '^(y|yes)$')
}
function Read-Port {
    Write-Host ''
    Write-Host '==============================='
    Write-Host '  选择端口'
    Write-Host '==============================='
    Write-Host '  1) 7007'
    Write-Host '  2) 7008'
    Write-Host '  3) 自定义输入'
    Write-Host '  q) 取消'
    Write-Host ''
    $choice = (Read-Host '请选择 [1-3/q]').Trim()
    $port = switch ($choice) {
        '1' { '7007' }
        '2' { '7008' }
        '3' { (Read-Host '请输入端口').Trim() }
        default { return $null }
    }
    $number = 0
    if (-not [int]::TryParse($port, [ref]$number) -or $number -lt 1 -or $number -gt 65535) {
        throw "无效端口：$port，已取消。"
    }
    return $number
}
function Start-Viewer {
    param([string]$Python, [string[]]$Arguments, [int]$Port)
    Write-Host ''
    Write-Host "→ 端口: $Port"
    Write-Host "→ Python: $Python"
    Write-Host "→ 本机打开 http://localhost:$Port ；远程查看: ssh -L ${Port}:localhost:$Port <这台机器>"
    Write-Host '→ 启动中... (Ctrl-C 停止)'
    Write-Host ''
    & $Python @Arguments --host 0.0.0.0 --port $Port
    Write-Host ''
    Read-Host '已退出，按回车关闭窗口' | Out-Null
}

try {
    $paths = @(Get-Content -LiteralPath $ListPath -Raw -Encoding UTF8 | ConvertFrom-Json |
        Where-Object { $_ } | ForEach-Object { ([string]$_).TrimEnd('\', '/') })
    if ($paths.Count -eq 0) { throw '没有选中文件，已取消。' }

    $python = Get-VizPython
    if (-not $python) {
        Write-Host "找不到可视化 Python：$(Join-Path $env:LOCALAPPDATA 'yazi-viz\Scripts\python.exe')" -ForegroundColor Yellow
        Write-Host '请先运行 .\install.ps1 yazi 并选择安装 gv 可视化依赖，'
        Write-Host '或指定已有环境：$env:YAZI_VIZ_PYTHON = ''C:\path\to\python.exe'''
        Read-Host '按回车关闭' | Out-Null
        return  # return（而不是 exit）保证 finally 清理选中列表
    }

    # ---- 单选 semantic / instance / instance_g（或其 pngs）→ 彩色 Mask 图库 ----
    $maskTypes = @('semantic', 'instance', 'instance_g')
    if ($paths.Count -eq 1 -and (Test-Path -LiteralPath $paths[0] -PathType Container)) {
        $dir = $paths[0]
        $name = Split-Path $dir -Leaf
        $maskType = $null; $pngDir = $null
        if ($maskTypes -contains $name) { $maskType = $name; $pngDir = Join-Path $dir 'pngs' }
        elseif ($name -eq 'pngs' -and $maskTypes -contains (Split-Path (Split-Path $dir -Parent) -Leaf)) {
            $maskType = Split-Path (Split-Path $dir -Parent) -Leaf; $pngDir = $dir
        }
        if ($maskType) {
            if (-not (Test-Path -LiteralPath $pngDir -PathType Container)) { throw "找不到 PNG 目录：$pngDir" }
            $pngs = @(Get-ChildItem -LiteralPath $pngDir -File | Where-Object { $_.Extension -ieq '.png' })
            if ($pngs.Count -eq 0) { throw "目录中没有 PNG：$pngDir" }
            Write-Host '==============================='
            Write-Host "  $maskType 彩色 Mask 图库"
            Write-Host '==============================='
            Write-Host "  目录: $pngDir"
            Write-Host "  图像: $($pngs.Count) 张"
            $port = Read-Port
            if (-not $port) { Write-Host '已取消'; return }
            Start-Viewer $python @((Join-Path $PSScriptRoot 'visualize_masks_web.py'), '--png-dir', $pngDir, '--mask-type', $maskType) $port
            return
        }
    }

    # ---- transforms.json 相机位姿可视化 ----
    $files = @(foreach ($p in $paths) {
        $t = if (Test-Path -LiteralPath $p -PathType Container) { Join-Path $p 'transforms.json' } else { $p }
        if (Test-Path -LiteralPath $t -PathType Leaf) { (Get-Item -LiteralPath $t -Force).FullName }
        else { Write-Host "[跳过] 未找到: $t" -ForegroundColor Yellow }
    })
    if ($files.Count -eq 0) { throw '没有可用的 transforms.json，已取消。' }
    Write-Host '==============================='
    Write-Host "  即将可视化以下 transforms.json (共 $($files.Count) 个)"
    Write-Host '==============================='
    for ($i = 0; $i -lt $files.Count; $i++) {
        Write-Host ('  {0,2}) {1,-24} {2}' -f ($i + 1), (Split-Path (Split-Path $files[$i] -Parent) -Leaf), $files[$i])
    }
    Write-Host ''
    if (-not (Read-Confirm)) { Write-Host '已取消'; return }
    $port = Read-Port
    if (-not $port) { Write-Host '已取消'; return }
    Start-Viewer $python (@(Join-Path $PSScriptRoot 'visualize_transforms_web.py') + $files) $port
} catch {
    Write-Host $_ -ForegroundColor Red
    Read-Host '按回车关闭' | Out-Null
    exit 1
} finally {
    Remove-Item -LiteralPath $ListPath -Force -ErrorAction SilentlyContinue
}
