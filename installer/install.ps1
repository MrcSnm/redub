#Requires -Version 5.1
<#
.SYNOPSIS
  Install redub to a per-user Programs folder and add it to User PATH.

.DESCRIPTION
  Default install root: %LOCALAPPDATA%\Programs\redub
  Copies redub.exe (and LICENSE if present), updates User PATH, refreshes
  the current session Path.

  Looks for the binary next to this script as redub.exe, or a release-named
  asset such as redub-*-windows-*.exe.

.PARAMETER Prefix
  Install directory (contains redub.exe).

.PARAMETER SkipPath
  Install files only; do not modify User PATH.
#>
[CmdletBinding()]
param(
    [string] $Prefix = $(Join-Path $env:LOCALAPPDATA "Programs\redub"),
    [switch] $SkipPath
)

$ErrorActionPreference = "Stop"

function Get-SourceExe {
    $here = $PSScriptRoot
    $candidates = @(
        (Join-Path $here "redub.exe")
    )
    $candidates += Get-ChildItem -LiteralPath $here -Filter "redub-*-windows-*.exe" -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName }
    $parent = Split-Path $here -Parent
    $candidates += @(
        (Join-Path $parent "redub.exe"),
        (Join-Path (Get-Location) "redub.exe")
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return (Resolve-Path $c).Path }
    }
    throw "redub.exe (or redub-*-windows-*.exe) not found next to this script, repo root, or cwd."
}

$exeSrc = Get-SourceExe
New-Item -ItemType Directory -Force -Path $Prefix | Out-Null
Copy-Item -LiteralPath $exeSrc -Destination (Join-Path $Prefix "redub.exe") -Force

$licenseSrc = Join-Path (Split-Path $exeSrc -Parent) "LICENSE"
if (Test-Path -LiteralPath $licenseSrc) {
    Copy-Item -LiteralPath $licenseSrc -Destination (Join-Path $Prefix "LICENSE") -Force
}

$uninstall = Join-Path $Prefix "uninstall.ps1"
@'
#Requires -Version 5.1
$ErrorActionPreference = "Stop"
$Prefix = Split-Path -Parent $MyInvocation.MyCommand.Path
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($null -eq $userPath) { $userPath = "" }
$parts = $userPath -split ";" | Where-Object { $_ -and ($_ -ne $Prefix) }
[Environment]::SetEnvironmentVariable("Path", ($parts -join ";"), "User")
Remove-Item -LiteralPath $Prefix -Recurse -Force
Write-Host "Removed $Prefix and User PATH entry."
Write-Host "Open a new shell (or refresh Path) so redub disappears from PATH."
'@ | Set-Content -LiteralPath $uninstall -Encoding UTF8

if (-not $SkipPath) {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($null -eq $userPath) { $userPath = "" }
    $parts = @($userPath -split ";" | Where-Object { $_ })
    if ($parts -notcontains $Prefix) {
        $parts += $Prefix
        [Environment]::SetEnvironmentVariable("Path", ($parts -join ";"), "User")
        Write-Host "Added to User PATH: $Prefix"
    } else {
        Write-Host "User PATH already contains: $Prefix"
    }
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
        [Environment]::GetEnvironmentVariable("Path", "User")
}

Write-Host "Installed: $(Join-Path $Prefix 'redub.exe')"
try {
    & (Join-Path $Prefix "redub.exe") --version
} catch {
    Write-Host "(version check skipped: $_)"
}

Write-Host ""
Write-Host "Refresh PATH in other open shells:"
Write-Host "  PowerShell:  `$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')"
Write-Host ('  nushell:     $env.PATH = ($env.PATH | prepend ''' + $Prefix + ''')')
Write-Host ('  bash/zsh:    export PATH="' + $Prefix + ':$PATH"')
Write-Host ""
Write-Host "Uninstall: powershell -File `"$uninstall`""
Write-Host ('Or from nushell:  nu -c "powershell -File ''' + $uninstall + '''"')
