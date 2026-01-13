
<#
.SYNOPSIS
  Installs micromamba for the current user (no admin required).

.DESCRIPTION
  - Downloads the latest win-64 micromamba tarball from micro.mamba.pm
  - Extracts it into a user-writable install directory
  - Ensures micromamba.exe is available at <InstallDir>\Library\bin\micromamba.exe
  - Optionally adds that directory to the USER PATH (no admin)
    - Mamba-org repo copy of installation snippet:  - Optionally initializes PowerShell profile with MAMBA_ROOT_PREFIX and the shell hook
      https://github.com/mamba-org/mamba/blob/main/docs/source/installation/micromamba-installation.rst  (PowerShell install)  [mamba-org]
    - Common Windows extraction recipe showing Library\bin layout:
      https://kodu.ut.ee/~kmoch/geopython2025/Py_00/Installing_Micromamba.html  (tar extraction creates Library\bin)  [example recipe]

.NOTES
  Run in a normal (non-admin) PowerShell prompt.
#>

[CmdletBinding()]
param(
  [string]$InstallDir = "$HOME\micromamba",
  [string]$RootPrefix = "$HOME\micromamba_root",
  [switch]$AddToUserPath,
  [switch]$InitPowerShellProfile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info($msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }

# 1) Preconditions: tar must exist (Windows 10+ typically ships bsdtar as "tar")
if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
  throw "tar was not found. On Windows 10/11 it is usually available. If not, install a tar-capable tool (e.g., bsdtar) or use Git Bash."
}

# 2) Create install dir
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Write-Info "InstallDir = $InstallDir"

# 3) Download latest tarball
$tmp = New-Item -ItemType Directory -Force -Path (Join-Path $env:TEMP ("micromamba_" + [guid]::NewGuid().ToString())) 
$tarball = Join-Path $tmp.FullName "micromamba.tar.bz2"
$uri = "https://micro.mamba.pm/api/micromamba/win-64/latest"

Write-Info "Downloading: $uri"
Invoke-WebRequest -Uri $uri -OutFile $tarball

# 4) Extract tarball into InstallDir
# The archive typically unpacks into a conda-like prefix layout including Library\bin\micromamba.exe (as you've seen).
Write-Info "Extracting to: $InstallDir"
Push-Location $InstallDir
try {
  tar -xvjf $tarball
}
finally {
  Pop-Location
}

# 5) Locate micromamba.exe
$mmExe = Join-Path $InstallDir "Library\bin\micromamba.exe"
if (-not (Test-Path $mmExe)) {
  # Fallback search, just in case layout changes
  $found = Get-ChildItem -Path $InstallDir -Recurse -Filter micromamba.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $found) { throw "micromamba.exe not found after extraction in $InstallDir" }
  $mmExe = $found.FullName
  Write-Warn "micromamba.exe found at non-standard path: $mmExe"
}

Write-Info "micromamba.exe = $mmExe"
& $mmExe --version | Out-Host

# 6) Optionally add to USER PATH (no admin)
if ($AddToUserPath) {
  $binDir = Split-Path -Parent $mmExe
  $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
  if ($userPath -notmatch [regex]::Escape($binDir)) {
    Write-Info "Adding to USER PATH: $binDir"
    [System.Environment]::SetEnvironmentVariable("Path", ($userPath + ";" + $binDir), "User")
    Write-Info "Restart PowerShell to pick up updated PATH."
  }
  else {
    Write-Info "USER PATH already contains: $binDir"
  }
}

# 7) Optionally initialize PowerShell profile (no admin)
# Micromamba docs show shell init and hook usage in PowerShell. This writes to the user profile file.
if ($InitPowerShellProfile) {
  Write-Info "Initializing PowerShell profile for micromamba (user scope)."
  # Ensure the two key env vars are set in profile: MAMBA_EXE and MAMBA_ROOT_PREFIX.
  # mamba/micromamba shell init is documented by mamba-org. [mamba docs]
  $env:MAMBA_EXE = $mmExe
  $env:MAMBA_ROOT_PREFIX = $RootPrefix

  & $mmExe shell init --shell=powershell --prefix $RootPrefix | Out-Host
  Write-Info "Done. Open a new PowerShell session and run: micromamba --help"
}

Write-Info "Installation complete."
Write-Info "Tip: set MAMBA_ROOT_PREFIX to control where envs/cache live (micromamba uses it by default)."

  References:
    - Micromamba installation docs (PowerShell install, self-contained executable):
      https://mamba.readthedocs.io/en/latest/installation/micromamba-installation.html  (install.ps1 + overview)  [mamba docs]
