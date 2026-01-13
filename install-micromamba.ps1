
<#
.SYNOPSIS
  Install micromamba for the current user (no admin). Supports side-by-side installs,
  dry-run (-WhatIf), confirmation (-Confirm), and uninstall/rollback.

.DESCRIPTION
  Downloads the latest win-64 micromamba tarball from micro.mamba.pm and extracts it into
  a user-writable directory. On Windows, the tarball commonly extracts into a prefix layout
  that includes Library\bin\micromamba.exe (as observed in practice). Example recipes show this layout.  [1][2]

  Optional actions:
    - Add micromamba's bin folder to USER PATH (no admin required; user-scoped env var).
    - Initialize PowerShell profile using micromamba's shell init (writes into profile). [1]
    - Uninstall/rollback: remove PATH entry and optionally delete install directory.

  References:
    [1] Micromamba installation docs (PowerShell install; self-contained executable; shell init):
        https://mamba.readthedocs.io/en/latest/installation/micromamba-installation.html
    [2] Example Windows extraction recipe showing Library\bin structure after tar extract:
        https://kodu.ut.ee/~kmoch/geopython2025/Py_00/Installing_Micromamba.html

.NOTES
  - Run as a normal user; no admin required.
  - For safest testing, use -SideBySide and omit -AddToUserPath and -InitProfile.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
  # Root folder where micromamba will be installed.
  [string]$InstallRoot = "$HOME\micromamba",

  # When set, installs into a timestamped subfolder (side-by-side) under InstallRoot.
  [switch]$SideBySide,

  # Root prefix for micromamba envs/cache (used only if you InitProfile).
  [string]$RootPrefix = "$HOME\micromamba_root",

  # Add micromamba's bin directory to the USER PATH (no admin). Recommended only after validation.
  [switch]$AddToUserPath,

  # Run "micromamba shell init --shell=powershell" to enable activation in PowerShell profiles. [1]
  [switch]$InitProfile,

  # Which PowerShell profile(s) to update when -InitProfile is used.
  [ValidateSet('WindowsPowerShell', 'PowerShell7', 'Both')]
  [string]$ProfileScope = 'Both',

  # Overwrite an existing non-empty install directory (dangerous; requires -Confirm unless -Force).
  [switch]$Force,

  # Uninstall/rollback: remove from PATH and optionally delete the install directory (or newest side-by-side dir).
  [switch]$Uninstall,

  # When uninstalling, delete the install directory after PATH removal.
  [switch]$RemoveFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info($m) { Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Write-Warn($m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }

function Get-UserPath() {
  [System.Environment]::GetEnvironmentVariable("Path", "User")
}

function Set-UserPath([string]$value) {
  [System.Environment]::SetEnvironmentVariable("Path", $value, "User")
}

function Remove-PathEntry([string]$pathEntry) {
  $userPath = Get-UserPath
  if (-not $userPath) { return $false }
  $parts = $userPath -split ';' | Where-Object { $_ -and $_.Trim() -ne '' }
  $newParts = $parts | Where-Object { $_.TrimEnd('\') -ne $pathEntry.TrimEnd('\') }
  if ($newParts.Count -eq $parts.Count) { return $false }
  Set-UserPath(($newParts -join ';'))
  return $true
}

function Add-PathEntry([string]$pathEntry) {
  $userPath = Get-UserPath
  $parts = @()
  if ($userPath) { $parts = $userPath -split ';' | Where-Object { $_ -and $_.Trim() -ne '' } }
  if ($parts | Where-Object { $_.TrimEnd('\') -eq $pathEntry.TrimEnd('\') }) { return $false }
  Set-UserPath(($parts + $pathEntry) -join ';')
  return $true
}

function Get-InstallDir() {
  if ($SideBySide) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    return Join-Path $InstallRoot "micromamba-$stamp"
  }
  return $InstallRoot
}

function Get-LatestSideBySideDir() {
  if (-not (Test-Path $InstallRoot)) { return $null }
  Get-ChildItem -Path $InstallRoot -Directory -Filter "micromamba-*" -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending |
    Select-Object -First 1
}

# --- Uninstall mode ---
if ($Uninstall) {
  $targetDir = $InstallRoot
  if ($SideBySide) {
    $latest = Get-LatestSideBySideDir
    if (-not $latest) { throw "No side-by-side installs found under $InstallRoot" }
    $targetDir = $latest.FullName
  }

  $exe = Join-Path $targetDir "Library\bin\micromamba.exe"
  $binDir = Split-Path -Parent $exe

  if ($PSCmdlet.ShouldProcess("USER PATH", "Remove $binDir")) {
    $removed = Remove-PathEntry $binDir
    if ($removed) { Write-Info "Removed from USER PATH: $binDir" } else { Write-Info "USER PATH did not contain: $binDir" }
  }

  if ($RemoveFiles -and (Test-Path $targetDir)) {
    if ($PSCmdlet.ShouldProcess($targetDir, "Delete install directory")) {
      Remove-Item -Recurse -Force $targetDir
      Write-Info "Deleted: $targetDir"
    }
  }

  Write-Info "Uninstall/rollback complete."
  exit 0
}

# --- Install mode ---
if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
  throw "tar not found. Windows 10/11 typically includes tar. If missing, use Git Bash or install a tar-capable utility. [1]"
}

$installDir = Get-InstallDir
Write-Info "InstallRoot = $InstallRoot"
Write-Info "InstallDir  = $installDir"

# Create or validate install dir
if (Test-Path $installDir) {
  $hasFiles = (Get-ChildItem -Path $installDir -Force -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0
  if ($hasFiles -and -not $Force) {
    throw "InstallDir is not empty: $installDir. Use -SideBySide for safe testing, or -Force (with -Confirm) to overwrite."
  }
} else {
  if ($PSCmdlet.ShouldProcess($installDir, "Create directory")) {
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
  }
}

# Download to temp
$tmp = Join-Path $env:TEMP ("micromamba_" + [guid]::NewGuid().ToString())
if ($PSCmdlet.ShouldProcess($tmp, "Create temp directory")) {
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
}
$tarball = Join-Path $tmp "micromamba.tar.bz2"
$uri = "https://micro.mamba.pm/api/micromamba/win-64/latest"

if ($PSCmdlet.ShouldProcess($uri, "Download micromamba tarball")) {
  Invoke-WebRequest -Uri $uri -OutFile $tarball
}

# Extract
if ($PSCmdlet.ShouldProcess($installDir, "Extract tarball")) {
  Push-Location $installDir
  try {
    tar -xvjf $tarball
  } finally {
    Pop-Location
  }
}

# Locate micromamba.exe
$mmExe = Join-Path $installDir "Library\bin\micromamba.exe"
if (-not (Test-Path $mmExe)) {
  $found = Get-ChildItem -Path $installDir -Recurse -Filter micromamba.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $found) { throw "micromamba.exe not found after extraction in $installDir. [2]" }
  $mmExe = $found.FullName
  Write-Warn "micromamba.exe found at non-standard path: $mmExe"
}

Write-Info "micromamba.exe = $mmExe"

# Record a small manifest to help teams track what was installed
$manifest = [pscustomobject]@{
  InstallDir  = $installDir
  Micromamba  = $mmExe
  InstalledAt = (Get-Date).ToString("o")
}
$manifestPath = Join-Path $installDir "install-manifest.json"
if ($PSCmdlet.ShouldProcess($manifestPath, "Write manifest")) {
  $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8
}

# Version check (safe)
if ($PSCmdlet.ShouldProcess($mmExe, "Run --version")) {
  & $mmExe --version | Out-Host
}

# Optionally add to USER PATH
if ($AddToUserPath) {
  $binDir = Split-Path -Parent $mmExe
  if ($PSCmdlet.ShouldProcess("USER PATH", "Add $binDir")) {
    $added = Add-PathEntry $binDir
    if ($added) {
      Write-Info "Added to USER PATH: $binDir"
      Write-Info "Restart PowerShell to pick up PATH changes."
    } else {
      Write-Info "USER PATH already contains: $binDir"
    }
  }
}

# Optionally initialize PowerShell profile(s)
# Micromamba docs provide 'shell init --shell=powershell' for activation support. [1]
if ($InitProfile) {
  $env:MAMBA_EXE = $mmExe
  $env:MAMBA_ROOT_PREFIX = $RootPrefix

  if ($ProfileScope -in @('WindowsPowerShell', 'Both')) {
    if ($PSCmdlet.ShouldProcess("WindowsPowerShell profile", "micromamba shell init")) {
      & $mmExe shell init --shell=powershell --prefix $RootPrefix | Out-Host
    }
  }

  if ($ProfileScope -in @('PowerShell7', 'Both')) {
    if ($PSCmdlet.ShouldProcess("PowerShell 7 profile", "micromamba shell init")) {
      & $mmExe shell init --shell=powershell --prefix $RootPrefix | Out-Host
    }
  }

  Write-Info "Profile init done. Open a new PowerShell and verify: micromamba --help"
}

Write-Info "Install complete."
Write-Info "For safest team adoption: validate with full path first, then enable PATH/profile changes."
