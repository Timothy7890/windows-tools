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
    $env:LOCALAPPDATA = Join-Path $temp 'local'
    $vim = Join-Path $env:LOCALAPPDATA 'Programs\Vim\vim.exe'
    $null = New-Item -ItemType Directory -Path (Split-Path $vim) -Force
    [IO.File]::WriteAllText($vim, '')
    $state = Get-ToolState vim $temp
    Assert ($state.State -eq 'Present' -and $state.AddToPath -and $state.Path -eq $vim) 'Standalone Vim not recognized'
    $env:YAZI_FILE_ONE = Join-Path $temp 'file.exe'
    [IO.File]::WriteAllText($env:YAZI_FILE_ONE, '')
    Assert ((Find-YaziFileExe $temp) -eq $env:YAZI_FILE_ONE) 'Existing preview dependency not reused'
} finally {
    $env:LOCALAPPDATA = $oldLocal; $env:YAZI_FILE_ONE = $oldFile
    Remove-Item $temp -Force -Recurse
    Remove-Variable Answers -Scope Global -ErrorAction SilentlyContinue
}
Write-Host 'PASS: interactive defaults/custom input/retry, CLI positional/named binding, no forced dependencies, command/standalone/Scoop detection, preview reuse.' -ForegroundColor Green
