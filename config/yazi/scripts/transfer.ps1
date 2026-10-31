param([Parameter(Mandatory = $true)][string]$ListPath)
$ErrorActionPreference = 'Stop'
try {
    $files = @(Get-Content -LiteralPath $ListPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    if ($files.Count -eq 0) { throw '没有选中文件，已取消。' }
    $targets = @(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'targets.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
    Write-Host '==============================='
    Write-Host '  选择目标服务器'
    Write-Host '==============================='
    Write-Host ''
    for ($i = 0; $i -lt $targets.Count; $i++) {
        $displayPath = ([string]$targets[$i].destination -split ':', 2)[1]
        Write-Host ('  {0}) {1,-12} {2}' -f ($i + 1), $targets[$i].name, $displayPath)
    }
    Write-Host '  q) 取消'
    Write-Host ''
    $choice = Read-Host ('请选择 [1-{0}/q]' -f $targets.Count)
    if ($choice -eq 'q') { Write-Host '已取消'; return }
    $index = 0
    if (-not [int]::TryParse($choice, [ref]$index) -or $index -lt 1 -or $index -gt $targets.Count) {
        throw '选择无效，已取消。'
    }
    $destination = [string]$targets[$index - 1].destination
    if ($destination -notmatch '^[A-Za-z0-9_.-]+:.+$') { throw '目标格式应为 SSH 别名:目标路径。' }
    # Resolve paths to avoid interpreting a selected name beginning with '-' as an option.
    $sources = @($files | ForEach-Object {
        if (-not (Test-Path -LiteralPath $_)) { throw "文件不存在：$_" }
        (Get-Item -LiteralPath $_ -Force).FullName
    })
    Write-Host ''
    Write-Host "→ 目标: $destination"
    Write-Host "→ 文件: $($sources -join ', ')"
    Write-Host ''
    & scp -r -p @sources $destination
    if ($LASTEXITCODE -ne 0) { throw "传输失败（退出码 $LASTEXITCODE），请检查 SSH 配置、授权及端口转发；传回 Mac 时确认 Mac 仍通过 SSH 登录这台机器。" }
    Write-Host '传输完成，2秒后关闭...' -ForegroundColor Green
    Start-Sleep -Seconds 2
} catch {
    Write-Host $_ -ForegroundColor Red
    Read-Host '按回车关闭' | Out-Null
    exit 1
} finally {
    Remove-Item -LiteralPath $ListPath -Force -ErrorAction SilentlyContinue
}
