# Shared pure/configuration helpers; dot-source without installing anything.
function ConvertTo-ProxyUri {
    param([string]$Value)
    if ($Value -notmatch '^[a-z]+://') { $Value = 'http://' + $Value }
    $uri = [uri]$Value
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'http' -or -not $uri.Host -or
        $uri.UserInfo -or $uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment) {
        throw 'Proxy must be an HTTP proxy host:port, without credentials or a path.'
    }
    return $uri
}
function New-TransferKeyCommand {
    param([string]$ScriptPath, [string]$Arguments = ' %s')
    $command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '"' + $Arguments
    # Yazi parses shell command arguments using shell-style quoting.
    $quote = [string][char]39
    $escapedQuote = $quote + '"' + $quote + '"' + $quote
    return ('shell --orphan ' + $quote + $command.Replace($quote, $escapedQuote) + $quote)
}
function Invoke-ScoopChecked {
    param([string[]]$Arguments)
    # A separate process preserves Scoop's own exit code and prevents exit terminating install.ps1.
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:ScoopCommand @Arguments
    if ($LASTEXITCODE -ne 0) { throw "scoop $($Arguments -join ' ') failed (exit $LASTEXITCODE)." }
}
function Install-ConfigFile {
    param([string]$Source, [string]$Destination, [string]$Content, [switch]$Force)
    $hasContent = $PSBoundParameters.ContainsKey('Content')
    $bytes = if ($hasContent) { (New-Object Text.UTF8Encoding($false)).GetBytes($Content) } else { [IO.File]::ReadAllBytes($Source) }
    if (Test-Path -LiteralPath $Destination) {
        $old = [IO.File]::ReadAllBytes($Destination)
        if ([Convert]::ToBase64String($old) -eq [Convert]::ToBase64String($bytes)) {
            $script:ConfigResults += "Unchanged: $Destination"
            return
        }
        if (-not $Force) {
            $script:ConfigResults += "PRESERVED existing file: $Destination (merge manually or use -ForceConfig)"
            return
        }
        $backup = $Destination + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
        Copy-Item -LiteralPath $Destination -Destination $backup
        $script:ConfigResults += "Backup: $backup"
    }
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination)
    [IO.File]::WriteAllBytes($Destination, $bytes)
    $script:ConfigResults += "Written: $Destination"
}


function Test-ConfigFileChanged {
    # True only when an installed file exists and differs from the new template; missing files are just installed.
    # Content stays untyped: a [string] parameter would turn $null into '' and compare against an empty file.
    param([string]$Source, [string]$Destination, $Content = $null)
    if (-not (Test-Path -LiteralPath $Destination)) { return $false }
    $new = if ($null -ne $Content) { (New-Object Text.UTF8Encoding($false)).GetBytes($Content) } else { [IO.File]::ReadAllBytes($Source) }
    return [Convert]::ToBase64String([IO.File]::ReadAllBytes($Destination)) -ne [Convert]::ToBase64String($new)
}
function Read-ConfigUpdate {
    param([string[]]$Names, [switch]$NonInteractive)
    Write-Host '以下 Yazi 配置与新版不同：' -ForegroundColor Yellow
    $Names | ForEach-Object { Write-Host "  $_" }
    if ($NonInteractive) {
        Write-Host '无交互模式保留现有文件；如需更新，加 -ForceConfig 重新运行。' -ForegroundColor Yellow
        return $false
    }
    while ($true) {
        $answer = (Read-Host '是否更新为新版？旧文件会先备份 [Y/n]').Trim()
        if (-not $answer -or $answer -match '^(y|yes)$') { return $true }
        if ($answer -match '^(n|no)$') { return $false }
        Write-Warning '请输入 y 或 n。'
    }
}
function Resolve-Components {
    param([string[]]$Names)
    $allowed = @('vim','psmux','yazi','chafa','poppler','git','lazygit','btop-gpu','btop')
    $result = @()
    foreach ($value in $Names) {
        foreach ($name in ($value -split '[,\s]+')) {
            if (-not $name) { continue }
            $name = $name.ToLowerInvariant()
            # btop-gpu is the menu name; btop-lhm is the Scoop package that provides it.
            if ($name -eq 'btop-gpu') { $name = 'btop-lhm' }
            if ($allowed -notcontains $name -and $name -ne 'btop-lhm') { throw "未知软件：$name。可选：$($allowed -join ', ')" }
            if ($result -notcontains $name) { $result += $name }
        }
    }
    # Both packages provide the btop command; the GPU build wins when both are chosen.
    if ($result -contains 'btop-lhm' -and $result -contains 'btop') {
        Write-Warning 'btop-gpu 与 btop 只能二选一，已保留 btop-gpu（显卡版）。'
        $result = @($result | Where-Object { $_ -ne 'btop' })
    }
    if (-not $result.Count) { throw '至少选择一个软件。' }
    return $result
}
function Get-ComponentCommand {
    param([string]$Name)
    if ($Name -eq 'btop-lhm') { return 'btop' }
    # poppler has no poppler.exe; Yazi's PDF preview calls pdftoppm from it.
    if ($Name -eq 'poppler') { return 'pdftoppm' }
    return $Name
}
function Get-PreferredGpuName {
    # btop4win shows one GPU and "Auto" means the first one LibreHardwareMonitor lists (often the iGPU).
    param([string[]]$Names)
    $ignored = 'Microsoft Basic|Remote Display|Virtual|Parsec|Meta Virtual|Citrix|DisplayLink|Mirage'
    $integrated = '^Intel|Radeon\(TM\) Graphics$|Radeon Graphics$|Radeon\(TM\) \d+M? Graphics$'
    $real = @($Names | Where-Object { $_ -and $_ -notmatch $ignored } | ForEach-Object { $_.Trim() } | Select-Object -Unique)
    $discrete = @($real | Where-Object { $_ -notmatch $integrated })
    if (-not $discrete.Count) { return '' }
    $nvidia = @($discrete | Where-Object { $_ -match '^NVIDIA' })
    if ($nvidia.Count) { return $nvidia[0] }
    return $discrete[0]
}
function Set-BtopSelectedGpu {
    param([string]$Path, [string]$GpuName)
    $lines = @()
    if (Test-Path -LiteralPath $Path) { $lines = @([IO.File]::ReadAllLines($Path)) }
    $current = $lines | Where-Object { $_ -match '^\s*selected_gpu\s*=' } | Select-Object -First 1
    if ($current -and $current -notmatch '=\s*"Auto"\s*$') {
        $script:ConfigResults += "PRESERVED btop selected_gpu: $($current.Trim())"
        return
    }
    $setting = 'selected_gpu = "' + $GpuName + '"'
    if ($current) { $lines = @($lines | ForEach-Object { if ($_ -match '^\s*selected_gpu\s*=') { $setting } else { $_ } }) }
    else { $lines += $setting }
    if ((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -gt 0) {
        Copy-Item -LiteralPath $Path -Destination ($Path + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    }
    # Truncate in place so Scoop's persist hard link keeps pointing at the same file.
    [IO.File]::WriteAllText($Path, (($lines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($false)))
    $script:ConfigResults += "btop selected_gpu -> $GpuName ($Path)"
}
function Read-BtopFallback {
    # Returns the package to install instead of btop-lhm, or '' to skip btop.
    Write-Warning '当前终端没有管理员权限：btop-gpu（显卡版 btop-lhm）必须以管理员身份运行，否则无法启动。'
    while ($true) {
        $answer = (Read-Host '需要改装低权限的普通版 btop（不显示显卡和 CPU 温度），是否继续？[Y/n]').Trim()
        if (-not $answer -or $answer -match '^(y|yes)$') { return 'btop' }
        if ($answer -match '^(n|no)$') { return '' }
        Write-Warning '请输入 y 或 n。'
    }
}
function Read-Components {
    Write-Host '请选择软件（回车使用默认；输入编号或名称，空格分隔）：' -ForegroundColor Cyan
    Write-Host '  1 vim [默认]   2 psmux [默认]   3 yazi [默认]   4 chafa [默认]   5 poppler [默认，PDF 预览]'
    Write-Host '  6 git [可选]   7 lazygit [可选]'
    Write-Host '  8 btop-gpu [可选，含显卡监控，需管理员]   9 btop [可选，普通版，无需管理员]'
    Write-Host '  all 全部（btop 使用显卡版）   q 退出'
    $names = @('vim','psmux','yazi','chafa','poppler','git','lazygit','btop-gpu','btop')
    while ($true) {
        $answer = (Read-Host '软件').Trim()
        if (-not $answer) { return @('vim','psmux','yazi','chafa','poppler') }
        if ($answer -eq 'q') { throw '用户取消安装。' }
        if ($answer -eq 'all') { $answer = $names -join ' ' }
        $mapped = @($answer -split '[,\s]+' | ForEach-Object {
            if ($_ -match '^[1-9]$') { $names[[int]$_ - 1] } else { $_ }
        })
        try { return @(Resolve-Components $mapped) } catch { Write-Warning $_ }
    }
}
function Read-ProxyAddress {
    while ($true) {
        $answer = (Read-Host '请输入代理地址（直接回车使用 127.0.0.1:17897；输入 keep 跳过代理设置）').Trim()
        if ($answer -eq 'keep') { return '' }
        if (-not $answer) { $answer = '127.0.0.1:17897' }
        try { return (ConvertTo-ProxyUri $answer).AbsoluteUri } catch { Write-Warning $_ }
    }
}
function Get-ToolState {
    param([string]$Name, [string]$ScoopRoot)
    if ($Name -eq 'btop-lhm') {
        # A btop command alone may be the plain build, so trust only the Scoop package directory.
        $current = Join-Path $ScoopRoot 'apps\btop-lhm\current'
        if (-not (Test-Path -LiteralPath (Join-Path $current 'manifest.json'))) {
            return [pscustomobject]@{ Name = $Name; State = 'Missing'; Path = ''; AddToPath = $false }
        }
        $command = Get-Command btop -CommandType Application,ExternalScript -ErrorAction SilentlyContinue
        $state = if ($command) { 'Present' } else { 'ScoopInstalled' }
        return [pscustomobject]@{ Name = $Name; State = $state; Path = $current; AddToPath = $false }
    }
    $commands = @(Get-Command (Get-ComponentCommand $Name) -CommandType Application,ExternalScript -All -ErrorAction SilentlyContinue)
    if ($commands.Count) {
        return [pscustomobject]@{ Name = $Name; State = 'Present'; Path = $commands[0].Source; AddToPath = $false }
    }
    $current = Join-Path $ScoopRoot "apps\$Name\current"
    if (Test-Path -LiteralPath (Join-Path $current 'manifest.json')) {
        return [pscustomobject]@{ Name = $Name; State = 'ScoopInstalled'; Path = $current; AddToPath = $false }
    }
    # Common standalone installations, including the user's existing Vim installation.
    $candidates = @()
    if ($Name -eq 'vim') {
        if ($env:LOCALAPPDATA) { $candidates += Join-Path $env:LOCALAPPDATA 'Programs\Vim\vim.exe' }
        foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
            if ($base) { $candidates += @(Get-ChildItem -Path (Join-Path $base 'Vim\vim*\vim.exe') -File -ErrorAction SilentlyContinue | ForEach-Object FullName) }
        }
    }
    if ($Name -eq 'git') {
        foreach ($base in @($env:ProgramFiles, $env:LOCALAPPDATA)) {
            if ($base) { $candidates += Join-Path $base 'Git\cmd\git.exe' }
        }
        foreach ($registry in @('HKCU:\Software\GitForWindows','HKLM:\Software\GitForWindows')) {
            $item = Get-ItemProperty -LiteralPath $registry -ErrorAction SilentlyContinue
            if ($item -and $item.InstallPath) { $candidates += Join-Path $item.InstallPath 'cmd\git.exe' }
        }
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [pscustomobject]@{ Name = $Name; State = 'Present'; Path = $candidate; AddToPath = $true }
        }
    }
    return [pscustomobject]@{ Name = $Name; State = 'Missing'; Path = ''; AddToPath = $false }
}
function Find-YaziFileExe {
    param([string]$ScoopRoot)
    $candidates = @($env:YAZI_FILE_ONE)
    foreach ($scope in @('User','Machine')) {
        $candidates += [Environment]::GetEnvironmentVariable('YAZI_FILE_ONE', $scope)
    }
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue
    if ($git) {
        $parent = Split-Path (Split-Path $git.Source -Parent) -Parent
        $candidates += Join-Path $parent 'usr\bin\file.exe'
    }
    $candidates += Join-Path $ScoopRoot 'apps\git\current\usr\bin\file.exe'
    foreach ($registry in @('HKCU:\Software\GitForWindows','HKLM:\Software\GitForWindows')) {
        $item = Get-ItemProperty -LiteralPath $registry -ErrorAction SilentlyContinue
        if ($item -and $item.InstallPath) { $candidates += Join-Path $item.InstallPath 'usr\bin\file.exe' }
    }
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if ($base) { $candidates += Join-Path $base 'Git\usr\bin\file.exe' }
    }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    return $null
}


function Set-PsmuxShellConfig {
    param([string]$Path, [switch]$NonInteractive, [string]$Shell)
    $text = if (Test-Path -LiteralPath $Path) { [IO.File]::ReadAllText($Path) } else { '' }
    $pattern = '(?m)^[ \t]*(?:set|set-option)[ \t]+(?:-\S+[ \t]+)*default-shell[ \t]+[^\r\n]+\r?$'
    $settings = [regex]::Matches($text, $pattern)
    if ($settings.Count) {
        Write-Host "psmux 当前 default-shell 配置："
        $settings | ForEach-Object { Write-Host ('  ' + $_.Value.Trim()) }
        if (-not $Shell) {
            if ($NonInteractive) {
                Write-Host '非交互模式：保留已有 psmux shell。'
                return
            }
            while ($true) {
                $answer = (Read-Host '回车/1 保留；2 改用 Windows PowerShell；3 改用 PowerShell 7').Trim()
                if (-not $answer -or $answer -eq '1') { return }
                if ($answer -eq '2') { $Shell = 'powershell'; break }
                if ($answer -eq '3') {
                    if (Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue) { $Shell = 'pwsh'; break }
                    Write-Warning '未检测到 pwsh，请先安装 PowerShell 7。'
                } else { Write-Warning '请输入 1、2 或 3。' }
            }
        }
    }
    if (-not $Shell) { $Shell = 'powershell' }
    if ($Shell -eq 'pwsh' -and -not (Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue)) {
        throw '未检测到 pwsh，无法设置 PowerShell 7 为默认 shell。'
    }
    $line = "set -g default-shell $Shell"
    # Preserve other settings; collapse direct duplicate default-shell settings to one.
    $newText = if ($settings.Count) { [regex]::Replace($text, $pattern + '(?:\r?\n)?', '') } else { $text }
    $newText = $newText.TrimEnd("`r", "`n") + "`r`n" + $line + "`r`n"
    if (-not $text) { $newText = $line + "`r`n" }
    if ($settings.Count -eq 1 -and $settings[0].Value.Trim() -eq $line) {
        Write-Host 'psmux 默认 shell 已符合设置，无需修改。'
        return
    }
    Install-ConfigFile '' $Path -Content $newText -Force
    Write-Host "psmux 默认 shell 已设置为 $Shell；新服务启动后生效。不会自动关闭当前会话。"
}
function Add-ProxyProfileBlock {
    param([string]$Path, [string]$HelperPath)
    $text = if (Test-Path -LiteralPath $Path) { [IO.File]::ReadAllText($Path) } else { '' }
    $begin = '# >>> windows-tools proxy >>>'
    $end = '# <<< windows-tools proxy <<<'
    $loader = ". '" + $HelperPath.Replace("'", "''") + "'"
    $block = @"
$begin
# Preserve existing functions with the same names.
if (-not (Get-Command proxy_on -ErrorAction SilentlyContinue) -and -not (Get-Command proxy_off -ErrorAction SilentlyContinue)) {
    $loader
}
$end
"@
    $pattern = '(?ms)^' + [regex]::Escape($begin) + '\r?\n.*?^' + [regex]::Escape($end)
    if ($text.Contains($begin) -xor $text.Contains($end)) { throw "Profile 标记不完整，请先检查：$Path" }
    $newText = if ([regex]::IsMatch($text, $pattern)) {
        [regex]::Replace($text, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($m) $block })
    } else { $text.TrimEnd("`r", "`n") + "`r`n" + $block + "`r`n" }
    # A BOM allows Windows PowerShell 5.1 to read existing Chinese profile text.
    Install-ConfigFile '' $Path -Content ([string][char]0xFEFF + $newText) -Force
}


$script:VizPackages = @('numpy','pillow','plotly','fastapi','uvicorn')
function Find-SystemPython {
    # Returns @(exe, args...) for a real Python 3; the WindowsApps alias only opens the Store.
    # Windows PowerShell turns native stderr into errors under 'Stop'; probe failures are expected here.
    $ErrorActionPreference = 'Continue'
    $py = Get-Command py -CommandType Application -ErrorAction SilentlyContinue
    if ($py) {
        & $py.Source -3 -c 'import sys' 2>$null
        if ($LASTEXITCODE -eq 0) { return @($py.Source, '-3') }
    }
    foreach ($name in @('python','python3')) {
        foreach ($cmd in @(Get-Command $name -CommandType Application -All -ErrorAction SilentlyContinue)) {
            if ($cmd.Source -match '\\WindowsApps\\') { continue }
            & $cmd.Source -c 'import sys; assert sys.version_info >= (3, 8)' 2>$null
            if ($LASTEXITCODE -eq 0) { return @($cmd.Source) }
        }
    }
    return @()
}
function Test-VizEnv {
    param([string]$Path)
    $ErrorActionPreference = 'Continue'
    $python = Join-Path $Path 'Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { return $false }
    & $python -c 'import numpy, PIL, plotly, fastapi, uvicorn' 2>$null
    return ($LASTEXITCODE -eq 0)
}
function Initialize-VizEnv {
    # Dedicated venv for Yazi "g v"; never touches conda or the system site-packages.
    param([string]$Path, [string]$Proxy, [switch]$NonInteractive, [switch]$NoDownload)
    # pip writes warnings to stderr; keep them as output instead of terminating install.ps1.
    $ErrorActionPreference = 'Continue'
    if (Test-VizEnv $Path) {
        Write-Host "[已存在] gv 可视化环境：$Path" -ForegroundColor Green
        return
    }
    if ($NoDownload) {
        Write-Host "gv 可视化依赖未安装（-ConfigureOnly 不下载）；需要时运行 .\install.ps1 yazi。" -ForegroundColor Yellow
        return
    }
    if ($NonInteractive) {
        Write-Host '无交互模式跳过 gv 可视化依赖；需要时交互运行 .\install.ps1 yazi。' -ForegroundColor Yellow
        return
    }
    while ($true) {
        $answer = (Read-Host 'Yazi g v 需要 Python 可视化依赖（约 150MB），是否安装？[Y/n]').Trim()
        if ($answer -match '^(n|no)$') { Write-Host '已跳过 gv 可视化依赖，按 g v 时会提示安装。'; return }
        if (-not $answer -or $answer -match '^(y|yes)$') { break }
        Write-Warning '请输入 y 或 n。'
    }
    $system = @(Find-SystemPython)
    if (-not $system.Count) {
        Write-Warning '未找到 Python 3.8+。可执行 scoop install python 后重跑 .\install.ps1 yazi；其余配置不受影响。'
        return
    }
    $pyArgs = @()
    if ($system.Count -gt 1) { $pyArgs = $system[1..($system.Count - 1)] }
    $python = Join-Path $Path 'Scripts\python.exe'
    $pip = @('-m','pip','install','-q','--disable-pip-version-check')
    if ($Proxy) { $pip += @('--proxy', (ConvertTo-ProxyUri $Proxy).AbsoluteUri) }
    Write-Host "创建 venv：$Path（Python：$($system[0])）"
    & $system[0] @pyArgs -m venv $Path
    if ($LASTEXITCODE -ne 0) { Write-Warning 'venv 创建失败，已跳过 gv 依赖。'; return }
    Write-Host "安装 $($script:VizPackages -join ' ') ..."
    & $python @pip --upgrade pip
    & $python @pip @script:VizPackages
    if ($LASTEXITCODE -ne 0 -or -not (Test-VizEnv $Path)) {
        Write-Warning 'gv 依赖安装失败；请检查代理后重跑 .\install.ps1 yazi。'
        return
    }
    $script:ConfigResults += "gv 可视化环境：$Path"
    Write-Host 'gv 可视化依赖安装完成。' -ForegroundColor Green
}


function Initialize-MacSsh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SshDir,
        [ValidatePattern('^[a-zA-Z0-9_.-]+$')][string]$MacUser = 'timo',
        [ValidatePattern('^[a-zA-Z0-9_.:-]+$')][string]$HostName = '127.0.0.1',
        [ValidatePattern('^[a-zA-Z0-9_.-]+$')][string]$Alias = 'macos-yx',
        [ValidatePattern('^[a-zA-Z0-9_.-]+$')][string]$KeyName,
        [ValidateRange(1,65535)][int]$Port = 12025,
        [switch]$NonInteractive
    )
    $config = Join-Path $SshDir 'config'
    $existing = if (Test-Path -LiteralPath $config) { [IO.File]::ReadAllText($config) } else { '' }
    foreach ($line in ($existing -split '\r?\n')) {
        if ($line -match '^\s*Host\s+(.+)$') {
            $names = ($Matches[1] -split '#',2)[0] -split '\s+'
            if ($names -contains $Alias) {
                Write-Host "[已存在] SSH Host $Alias，保留配置，不生成或更换密钥。" -ForegroundColor Green
                return
            }
        }
    }
    Write-Host "[未配置] SSH Host $Alias，准备创建。" -ForegroundColor Cyan
    if (-not (Get-Command ssh-keygen -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Warning '未找到 ssh-keygen；请安装 Windows OpenSSH 客户端后运行 setup-ssh.ps1。其他软件配置不受影响。'
        return
    }
    if (-not $NonInteractive) {
        foreach ($field in @('HostName','MacUser','Port','KeyName')) {
            if ($PSBoundParameters.ContainsKey($field)) { continue }
            $label = switch ($field) {
                'HostName' { 'Mac 主机地址' }
                'MacUser' { 'Mac 用户名' }
                'Port' { 'SSH 端口' }
                'KeyName' { '本机 SSH 密钥文件名（已有则复用）' }
            }
            while ($true) {
                $default = Get-Variable $field -ValueOnly
                $prompt = if ($field -eq 'KeyName') { "$label（必填）" } else { "$label [$default]，回车使用默认" }
                $answer = (Read-Host $prompt).Trim()
                if (-not $answer) {
                    if ($field -eq 'KeyName') { Write-Warning '密钥文件名不能为空，请自行输入。'; continue }
                    break
                }
                $valid = switch ($field) {
                    'HostName' { $answer -match '^[a-zA-Z0-9_.:-]+$' }
                    'Port' { $answer -match '^\d{1,5}$' -and [int]$answer -ge 1 -and [int]$answer -le 65535 }
                    default { $answer -match '^[a-zA-Z0-9_.-]+$' }
                }
                if ($valid) { Set-Variable $field $answer; break }
                Write-Warning '输入格式无效，请重试。'
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($KeyName)) {
        throw '必须指定 SSH 密钥文件名：非交互模式请传入 -KeyName。'
    }
    $key = Join-Path $SshDir $KeyName
    if (-not (Test-Path -LiteralPath $key)) {
        if (Test-Path -LiteralPath "$key.pub") { throw '仅公钥存在，私钥缺失；请换一个 KeyName，避免覆盖。' }
        if ($NonInteractive) {
            Write-Warning "SSH 配置暂未创建：密钥 $key 不存在。请交互运行 setup-ssh.ps1 创建密钥，或指定已有 -KeyName。"
            return
        }
        $null = New-Item -ItemType Directory -Force -Path $SshDir
        Write-Host '创建 ed25519 密钥；接下来可输入密钥口令，或回车留空。不会覆盖已有密钥。'
        & ssh-keygen -t ed25519 -f $key -C $KeyName
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $key)) { throw 'SSH 密钥生成失败，未修改 config。' }
    } else { Write-Host "复用已有密钥：$key" }
    $block = @"
Host $Alias
    HostName $HostName
    User $MacUser
    Port $Port
    IdentityFile ~/.ssh/$KeyName
    IdentitiesOnly yes
    StrictHostKeyChecking ask

"@
    # Prepend before Host * so explicit host values take precedence.
    Install-ConfigFile '' $config -Content ($block + "`r`n" + $existing) -Force
    Write-Host "已创建 SSH Host $Alias：${MacUser}@${HostName}:$Port" -ForegroundColor Green
    if (Test-Path -LiteralPath "$key.pub") {
        Write-Host '请将以下公钥追加到 Mac 的 ~/.ssh/authorized_keys：'
        Get-Content -LiteralPath "$key.pub" | Write-Host
    } else { Write-Warning '已有私钥没有对应 .pub 文件；请自行确认远端授权，不会自动修改私钥。' }
    if ($HostName -in @('127.0.0.1','localhost','::1')) {
        Write-Host "Mac 端需开启远程登录，并在连接 Windows 的 Host 段添加：RemoteForward $Port localhost:22"
    }
    Write-Host "连接准备好后测试：ssh $Alias echo ok"
}


# Windows 10's inbox conhost corrupts wide characters between psmux and sshd. The fix side-loads
# Microsoft's ConPTY package: see "Windows 10 残留修复" in README.md.
$script:ConPtyVersion = '1.25.260930003'
$script:ConPtySha256 = '02B07B349AF66D801159BDF9E440D4A1CE78BB951F37FC8609731665AFDAE7EE'
function Get-WindowsBuild {
    # ProductName still says "Windows 10" on Windows 11, so only the build number is reliable.
    return [int](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild
}
function Test-ConPtyFixNeeded {
    param([int]$Build, [switch]$PsmuxSelected, [switch]$Force, [switch]$Skip)
    if ($Skip) { return $false }
    if ($Force) { return $true }
    return ($PsmuxSelected -and $Build -lt 22000)
}
function Get-ConPtyArch {
    param([string]$Architecture = $(if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }))
    switch ($Architecture) {
        'AMD64' { return [pscustomobject]@{ Name = 'x64'; Framework = 'Framework64' } }
        'x86' { return [pscustomobject]@{ Name = 'x86'; Framework = 'Framework' } }
        default { throw "暂不支持的 CPU 架构：$Architecture" }
    }
}
function Test-MicrosoftSigned {
    param([string]$Path)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    return ($signature.Status -eq 'Valid' -and $signature.SignerCertificate.Subject -match 'O=Microsoft Corporation')
}
function Test-ConPtyFilesReady {
    param([string]$Directory)
    foreach ($name in @('conpty.dll','OpenConsole.exe')) {
        $path = Join-Path $Directory $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or -not (Test-MicrosoftSigned $path)) { return $false }
    }
    return $true
}
function Install-ConPtyFiles {
    param([string]$Directory, [object]$Arch, [string]$Proxy)
    $id = [guid]::NewGuid().ToString('N')
    $archive = "$Directory-$id.zip"
    $extracted = "$Directory-$id"
    $url = "https://api.nuget.org/v3-flatcontainer/microsoft.windows.console.conpty/$script:ConPtyVersion/microsoft.windows.console.conpty.$script:ConPtyVersion.nupkg"
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Directory)
    $progress = $ProgressPreference
    try {
        $ProgressPreference = 'SilentlyContinue'
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $request = @{ Uri = $url; OutFile = $archive; UseBasicParsing = $true; ErrorAction = 'Stop' }
        if ($Proxy) { $request.Proxy = (ConvertTo-ProxyUri $Proxy).AbsoluteUri }
        Invoke-WebRequest @request
        $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
        if ($hash -ne $script:ConPtySha256) { throw "ConPTY 安装包校验失败：$hash" }
        Expand-Archive -LiteralPath $archive -DestinationPath $extracted -Force
        $files = @(
            (Join-Path $extracted "runtimes\win-$($Arch.Name)\native\conpty.dll"),
            (Join-Path $extracted "build\native\runtimes\$($Arch.Name)\OpenConsole.exe")
        )
        foreach ($file in $files) {
            if (-not (Test-MicrosoftSigned $file)) { throw "文件没有有效的微软签名：$file" }
        }
        $null = New-Item -ItemType Directory -Force -Path $Directory
        Copy-Item -LiteralPath $files -Destination $Directory -Force
    } finally {
        $ProgressPreference = $progress
        Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $extracted -Recurse -Force -ErrorAction SilentlyContinue
    }
}
function Build-ConPtyRelay {
    param([string]$Source, [string]$Directory, [object]$Arch)
    $relay = Join-Path $Directory 'relay.exe'
    $stamp = Join-Path $Directory 'relay.source.sha256'
    $hash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
    if ((Test-Path -LiteralPath $relay) -and (Test-Path -LiteralPath $stamp) -and ((Get-Content -LiteralPath $stamp -Raw).Trim() -eq $hash)) {
        return 'Unchanged'
    }
    $csc = Join-Path $env:WINDIR "Microsoft.NET\$($Arch.Framework)\v4.0.30319\csc.exe"
    if (-not (Test-Path -LiteralPath $csc)) { throw "未找到 .NET Framework 编译器：$csc" }
    $output = Join-Path $Directory ('relay-' + [guid]::NewGuid().ToString('N') + '.exe')
    try {
        # Windows PowerShell turns stderr from native commands into errors when redirected under 'Stop'.
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $log = & $csc /nologo /optimize "/platform:$($Arch.Name)" "/out:$output" $Source 2>&1
        $exit = $LASTEXITCODE
        $ErrorActionPreference = $previous
        if ($exit -ne 0) { throw "relay 编译失败：$($log -join ' ')" }
        # A running relay locks the old file; the caller reports this and the old relay keeps working.
        Move-Item -LiteralPath $output -Destination $relay -Force
        [IO.File]::WriteAllText($stamp, $hash)
    } finally {
        Remove-Item -LiteralPath $output -Force -ErrorAction SilentlyContinue
    }
    return 'Built'
}
$script:PsmuxCompatPattern = '(?ms)^[ \t]*# Explicit Windows 10 SSH compatibility entry.*?^function global:psmux \{\s*psmux-safe @args\s*\}[ \t]*(?:\r?\n)?'
function Test-PsmuxCompatProfileBlock {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    return [regex]::IsMatch([IO.File]::ReadAllText($Path), $script:PsmuxCompatPattern)
}
function Remove-PsmuxCompatProfileBlock {
    param([string]$Path)
    $text = [regex]::Replace([IO.File]::ReadAllText($Path), $script:PsmuxCompatPattern, '')
    # Keep the BOM so Windows PowerShell 5.1 still reads Chinese profile text.
    Install-ConfigFile '' $Path -Content ([string][char]0xFEFF + $text) -Force
}
function Test-PsmuxProfileOverride {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    return [regex]::IsMatch([IO.File]::ReadAllText($Path), '(?mi)^[ \t]*(?:function[ \t]+(?:global:)?psmux\b|(?:Set|New)-Alias\b.*\bpsmux\b)')
}
