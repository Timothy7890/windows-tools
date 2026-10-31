# Loaded by the user's PowerShell profile. Loading does not enable a proxy.
function proxy_on {
    [CmdletBinding()]
    param([string]$Address)
    if (-not $Address) {
        $settings = Join-Path $env:LOCALAPPDATA 'windows-tools\proxy.json'
        $Address = if (Test-Path -LiteralPath $settings) {
            (Get-Content -LiteralPath $settings -Raw -Encoding UTF8 | ConvertFrom-Json).address
        } else { 'http://127.0.0.1:17897' }
    }
    if ($Address -notmatch '^[a-z]+://') { $Address = 'http://' + $Address }
    $uri = [uri]$Address
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'http' -or -not $uri.Host -or
        $uri.UserInfo -or $uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment) {
        throw '请输入 HTTP 代理 host:port，例如 127.0.0.1:17897。'
    }
    $env:http_proxy = $uri.AbsoluteUri
    $env:https_proxy = $uri.AbsoluteUri
    [Net.WebRequest]::DefaultWebProxy = New-Object Net.WebProxy($uri)
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        [Net.Http.HttpClient]::DefaultProxy = [Net.WebRequest]::DefaultWebProxy
    }
    $scoop = Get-Command scoop -CommandType ExternalScript -ErrorAction SilentlyContinue
    if ($scoop) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scoop.Source config proxy $uri.Authority
        if ($LASTEXITCODE -ne 0) { throw '当前会话已启用代理，但 Scoop 代理配置失败。' }
    }
    Write-Host "代理已开启：$($uri.AbsoluteUri)（当前会话；Scoop 配置会持久保存）"
}
function proxy_off {
    [CmdletBinding()]
    param()
    foreach ($name in @('http_proxy','https_proxy','all_proxy','HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')) {
        Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }
    [Net.WebRequest]::DefaultWebProxy = $null
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        [Net.Http.HttpClient]::DefaultProxy = New-Object Net.WebProxy
    }
    $scoop = Get-Command scoop -CommandType ExternalScript -ErrorAction SilentlyContinue
    if ($scoop) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scoop.Source config proxy none
        if ($LASTEXITCODE -ne 0) { throw '当前会话代理已清除，但 Scoop 代理关闭失败。' }
    }
    Write-Host '当前会话代理已关闭；Scoop 设为 none。未修改 Windows 系统代理或 Git 自身的代理配置。'
}
