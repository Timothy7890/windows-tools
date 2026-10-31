#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidatePattern('^[a-zA-Z0-9_.-]+$')][string]$MacUser,
    [ValidatePattern('^[a-zA-Z0-9_.:-]+$')][string]$HostName,
    [ValidatePattern('^[a-zA-Z0-9_.-]+$')][string]$Alias,
    [ValidatePattern('^[a-zA-Z0-9_.-]+$')][string]$KeyName,
    [ValidateRange(1,65535)][int]$Port,
    [switch]$NonInteractive
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run on Windows.' }
. (Join-Path $PSScriptRoot 'lib.ps1')
$script:ConfigResults = @()
Initialize-MacSsh -SshDir (Join-Path $env:USERPROFILE '.ssh') @PSBoundParameters
$script:ConfigResults | ForEach-Object { Write-Host $_ }
