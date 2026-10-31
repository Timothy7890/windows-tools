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
    param([string]$ScriptPath)
    $command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '" %s'
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


function Resolve-Components {
    param([string[]]$Names)
    $allowed = @('vim','psmux','yazi','chafa','git','lazygit')
    $result = @()
    foreach ($value in $Names) {
        foreach ($name in ($value -split '[,\s]+')) {
            if (-not $name) { continue }
            $name = $name.ToLowerInvariant()
            if ($allowed -notcontains $name) { throw "未知软件：$name。可选：$($allowed -join ', ')" }
            if ($result -notcontains $name) { $result += $name }
        }
    }
    if (-not $result.Count) { throw '至少选择一个软件。' }
    return $result
}
function Read-Components {
    Write-Host '请选择软件（回车使用默认；输入编号或名称，空格分隔）：' -ForegroundColor Cyan
    Write-Host '  1 vim [默认]   2 psmux [默认]   3 yazi [默认]   4 chafa [默认]'
    Write-Host '  5 git [可选]   6 lazygit [可选]   all 全部   q 退出'
    $names = @('vim','psmux','yazi','chafa','git','lazygit')
    while ($true) {
        $answer = (Read-Host '软件').Trim()
        if (-not $answer) { return @('vim','psmux','yazi','chafa') }
        if ($answer -eq 'q') { throw '用户取消安装。' }
        if ($answer -eq 'all') { return $names }
        $mapped = @($answer -split '[,\s]+' | ForEach-Object {
            if ($_ -match '^[1-6]$') { $names[[int]$_ - 1] } else { $_ }
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
    $commands = @(Get-Command $Name -CommandType Application,ExternalScript -All -ErrorAction SilentlyContinue)
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
        & ssh-keygen -t ed25519 -f $key -C 'windows-tools'
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
