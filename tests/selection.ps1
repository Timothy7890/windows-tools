$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'lib.ps1')
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Read-Host {
    param($Prompt)
    if (-not $global:Answers.Count) { throw "Unexpected prompt: $Prompt" }
    return $global:Answers.Dequeue()
}
function Answers([string[]]$Values) {
    $global:Answers = New-Object 'System.Collections.Generic.Queue[string]'
    foreach ($value in $Values) { $global:Answers.Enqueue($value) }
}
Answers @('')
Assert (((Read-Components) -join ',') -eq 'vim,psmux,yazi,chafa') 'Wrong interactive default'
Answers @('1 3 5')
Assert (((Read-Components) -join ',') -eq 'vim,yazi,git') 'Number selection failed'
Answers @('vim,chafa')
Assert (((Read-Components) -join ',') -eq 'vim,chafa') 'Name selection failed'
Answers @('bad','2')
Assert (((Read-Components) -join ',') -eq 'psmux') 'Invalid selection did not retry'
Answers @('7')
Assert (((Read-Components) -join ',') -eq 'btop-lhm') 'btop-gpu number selection failed'
Answers @('8')
Assert (((Read-Components) -join ',') -eq 'btop') 'btop number selection failed'
Answers @('all')
Assert (((Read-Components) -join ',') -eq 'vim,psmux,yazi,chafa,git,lazygit,btop-lhm') 'all selection should use btop-gpu only'
Answers @('')
Assert ((Read-BtopFallback) -eq 'btop') 'Non-admin fallback default should be plain btop'
Answers @('n')
Assert ((Read-BtopFallback) -eq '') 'Declining fallback should skip btop'
Answers @('maybe','y')
Assert ((Read-BtopFallback) -eq 'btop') 'Invalid fallback answer did not retry'
Answers @('')
Assert ((Read-ProxyAddress) -eq 'http://127.0.0.1:17897/') 'Wrong default proxy'
Answers @('http://localhost:9999')
Assert ((Read-ProxyAddress) -eq 'http://localhost:9999/') 'Custom proxy lost'
Answers @('keep')
Assert ((Read-ProxyAddress) -eq '') 'Keep existing settings failed'
Answers @('socks5://localhost:1234','localhost:8888')
Assert ((Read-ProxyAddress) -eq 'http://localhost:8888/') 'Invalid proxy did not retry'
Assert (((Resolve-Components @('yazi')) -join ',') -eq 'yazi') 'Yazi added unwanted packages'
Assert (((Resolve-Components @('vim','VIM','psmux')) -join ',') -eq 'vim,psmux') 'Duplicate selection'
Assert (((Resolve-Components @('BTOP')) -join ',') -eq 'btop') 'btop name selection failed'
Assert (((Resolve-Components @('btop-gpu')) -join ',') -eq 'btop-lhm') 'btop-gpu alias failed'
Assert (((Resolve-Components @('btop','btop-gpu','vim')) -join ',') -eq 'vim,btop-lhm') 'btop conflict should keep btop-gpu'
Assert ((Get-ComponentCommand 'btop-lhm') -eq 'btop') 'btop-gpu command name wrong'

$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'install.ps1'), [ref]$tokens, [ref]$errors)
$binder = [scriptblock]::Create($ast.ParamBlock.ToString() + "`n" + 'ConvertTo-Json -InputObject @($Components) -Compress')
Assert ((& $binder vim psmux | ConvertFrom-Json) -join ',' -eq 'vim,psmux') 'Space-separated positional binding failed'
Assert ((& $binder -Components vim,chafa -NonInteractive | ConvertFrom-Json) -join ',' -eq 'vim,chafa') 'Named array binding failed'

$temp = Join-Path ([IO.Path]::GetTempPath()) ('windows-tools-detect-' + [guid]::NewGuid().ToString('N'))
$oldLocal = $env:LOCALAPPDATA; $oldFile = $env:YAZI_FILE_ONE
try {
    $null = New-Item -ItemType Directory -Path $temp
    # Mock the discovery layer; do not depend on software installed on the test host.
    function Get-Command {
        param($Name, $CommandType, [switch]$All, $ErrorAction)
        if ($Name -eq 'chafa') { return [pscustomobject]@{Source = 'C:\existing\chafa.exe'} }
    }
    function Get-ItemProperty { param($LiteralPath, $ErrorAction) }
    $state = Get-ToolState chafa $temp
    Assert ($state.State -eq 'Present' -and $state.Path -eq 'C:\existing\chafa.exe') 'Existing command not recognized'
    Assert ((Get-ToolState lazygit $temp).State -eq 'Missing') 'Missing tool not recognized'
    $current = Join-Path $temp 'apps\psmux\current'
    $null = New-Item -ItemType Directory -Path $current -Force
    [IO.File]::WriteAllText((Join-Path $current 'manifest.json'), '{}')
    Assert ((Get-ToolState psmux $temp).State -eq 'ScoopInstalled') 'Broken Scoop shim not recognized'
    Assert ((Get-ToolState btop-lhm $temp).State -eq 'Missing') 'Missing btop-lhm not recognized'
    $lhm = Join-Path $temp 'apps\btop-lhm\current'
    $null = New-Item -ItemType Directory -Path $lhm -Force
    [IO.File]::WriteAllText((Join-Path $lhm 'manifest.json'), '{}')
    Assert ((Get-ToolState btop-lhm $temp).State -eq 'ScoopInstalled') 'btop-lhm without shim not recognized'
    $env:LOCALAPPDATA = Join-Path $temp 'local'
    $vim = Join-Path $env:LOCALAPPDATA 'Programs\Vim\vim.exe'
    $null = New-Item -ItemType Directory -Path (Split-Path $vim) -Force
    [IO.File]::WriteAllText($vim, '')
    $state = Get-ToolState vim $temp
    Assert ($state.State -eq 'Present' -and $state.AddToPath -and $state.Path -eq $vim) 'Standalone Vim not recognized'
    $env:YAZI_FILE_ONE = Join-Path $temp 'file.exe'
    [IO.File]::WriteAllText($env:YAZI_FILE_ONE, '')
    Assert ((Find-YaziFileExe $temp) -eq $env:YAZI_FILE_ONE) 'Existing preview dependency not reused'
    Assert ((Get-PreferredGpuName @('Intel(R) UHD Graphics 770','NVIDIA GeForce RTX 3090')) -eq 'NVIDIA GeForce RTX 3090') 'iGPU preferred over 3090'
    Assert ((Get-PreferredGpuName @('AMD Radeon(TM) Graphics','NVIDIA GeForce RTX 4090')) -eq 'NVIDIA GeForce RTX 4090') 'AMD iGPU preferred over 4090'
    Assert ((Get-PreferredGpuName @('Intel(R) Iris(R) Xe Graphics','Microsoft Basic Display Adapter')) -eq '') 'iGPU-only machine should keep Auto'
    Assert ((Get-PreferredGpuName @('Intel(R) UHD Graphics','AMD Radeon RX 7900 XTX')) -eq 'AMD Radeon RX 7900 XTX') 'AMD dGPU not preferred'
    $conf = Join-Path $temp 'btop.conf'
    [IO.File]::WriteAllText($conf, '')
    $script:ConfigResults = @()
    Set-BtopSelectedGpu -Path $conf -GpuName 'NVIDIA GeForce RTX 3090'
    Assert ((Get-Content $conf -Raw).Trim() -eq 'selected_gpu = "NVIDIA GeForce RTX 3090"') 'selected_gpu not written to empty btop.conf'
    [IO.File]::WriteAllText($conf, "show_gpu = True`r`nselected_gpu = `"Auto`"`r`n")
    Set-BtopSelectedGpu -Path $conf -GpuName 'NVIDIA GeForce RTX 3090'
    $text = Get-Content $conf -Raw
    Assert ($text -match 'show_gpu = True' -and $text -match 'selected_gpu = "NVIDIA GeForce RTX 3090"' -and $text -notmatch 'Auto') 'Auto selected_gpu not replaced'
    [IO.File]::WriteAllText($conf, "selected_gpu = `"Intel(R) UHD Graphics`"`r`n")
    Set-BtopSelectedGpu -Path $conf -GpuName 'NVIDIA GeForce RTX 3090'
    Assert ((Get-Content $conf -Raw) -match 'Intel') 'User-chosen selected_gpu overwritten'
    $src = Join-Path $temp 'tpl.toml'; $dst = Join-Path $temp 'installed.toml'
    [IO.File]::WriteAllText($src, 'new')
    Assert (-not (Test-ConfigFileChanged -Source $src -Destination $dst)) 'Missing file reported as changed'
    [IO.File]::WriteAllText($dst, 'new')
    Assert (-not (Test-ConfigFileChanged -Source $src -Destination $dst)) 'Identical file reported as changed'
    Assert (Test-ConfigFileChanged -Source $src -Destination $dst -Content 'generated') 'Generated content difference missed'
    Assert (-not (Test-ConfigFileChanged -Source $src -Destination $dst -Content 'new')) 'Generated identical content reported as changed'
    [IO.File]::WriteAllText($dst, 'old')
    Assert (Test-ConfigFileChanged -Source $src -Destination $dst) 'Outdated file not detected'
    Answers @('')
    Assert (Read-ConfigUpdate -Names @('keymap.toml')) 'Config update default should be yes'
    Answers @('maybe','n')
    Assert (-not (Read-ConfigUpdate -Names @('keymap.toml'))) 'Declined config update or retry failed'
    Assert (-not (Read-ConfigUpdate -Names @('keymap.toml') -NonInteractive)) 'NonInteractive must keep files'
} finally {
    $env:LOCALAPPDATA = $oldLocal; $env:YAZI_FILE_ONE = $oldFile
    Remove-Item $temp -Force -Recurse
    Remove-Variable Answers -Scope Global -ErrorAction SilentlyContinue
}
Write-Host 'PASS: interactive defaults/custom input/retry, CLI positional/named binding, no forced dependencies, command/standalone/Scoop detection, preview reuse, btop GPU selection, config update prompt.' -ForegroundColor Green
