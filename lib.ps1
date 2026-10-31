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
        $answer = (Read-Host '代理地址 [127.0.0.1:17897]；输入 keep 保留现有网络设置').Trim()
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
