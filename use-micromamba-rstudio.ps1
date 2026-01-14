<# 
Use-MicromambaRStudio.ps1

Creates a launcher that runs RStudio inside a micromamba environment so it uses that env's:
- R.exe
- R.dll and other runtime DLLs (via PATH)
- R libraries (via R_HOME / R_LIBS_USER optional)

USAGE
  # Create launcher only (recommended)
  .\Use-MicromambaRStudio.ps1 -EnvName "r4-mamba" -RStudioExe "C:\Program Files\RStudio\bin\rstudio.exe"

  # Also set per-user env vars (RSTUDIO_WHICH_R, R_HOME, PATH prepend, optional R_LIBS_USER)
  .\Use-MicromambaRStudio.ps1 -EnvName "r4-mamba" -RStudioExe "C:\Program Files\RStudio\bin\rstudio.exe" -SetUserEnvVars

  # If env doesn't exist, create it (conda-forge R)
  .\Use-MicromambaRStudio.ps1 -EnvName "r4-mamba" -RStudioExe "C:\Program Files\RStudio\bin\rstudio.exe" -CreateEnvIfMissing
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [string]$EnvName,

  # Path to micromamba.exe. If it's on PATH, leave as default.
  [string]$MicromambaExe = "micromamba",

  # Full path to RStudio Desktop executable.
  [Parameter(Mandatory=$true)]
  [string]$RStudioExe,

  # Where to put the launcher (default: Desktop)
  [string]$LauncherDir = ([Environment]::GetFolderPath("Desktop")),

  # Create the env if missing (installs r-base + r-essentials from conda-forge)
  [switch]$CreateEnvIfMissing,

  # Also set per-user env vars so RStudio prefers micromamba R even when opened normally
  [switch]$SetUserEnvVars
)

function Fail([string]$msg) { Write-Error $msg; exit 1 }

# --- Check micromamba ---
try {
  $ver = & $MicromambaExe --version 2>$null
  if (-not $ver) { throw "no version" }
  Write-Host "micromamba OK: $ver"
} catch {
  Fail "Could not run micromamba. Put micromamba.exe on PATH or pass -MicromambaExe 'C:\path\micromamba.exe'."
}

# --- Check RStudio exe ---
if (-not (Test-Path $RStudioExe)) {
  Fail "RStudio not found at: $RStudioExe"
}

# --- Find env prefix ---
function Get-EnvPrefix([string]$name) {
  $json = & $MicromambaExe env list --json 2>$null
  if (-not $json) { return $null }
  $obj = $json | ConvertFrom-Json
  
  # For 'base', it's typically the first env or at micromamba_root
  if ($name -eq "base" -and $obj.envs.Count -gt 0) {
    # Return the first env that doesn't contain \envs\ (likely the root/base)
    $baseEnv = $obj.envs | Where-Object { $_ -notmatch "[\\\/]envs[\\\/]" } | Select-Object -First 1
    if ($baseEnv) { return $baseEnv }
  }
  
  foreach ($p in $obj.envs) {
    # Common layout: ...\envs\<EnvName>
    if ($p -match "[\\\/]envs[\\\/]$([Regex]::Escape($name))$") { return $p }
    # Also check if path ends with the env name
    if ($p -match "[\\\/]$([Regex]::Escape($name))$") { return $p }
  }
  return $null
}

$envPrefix = Get-EnvPrefix $EnvName

if (-not $envPrefix) {
  if (-not $CreateEnvIfMissing) {
    Fail "Env '$EnvName' not found. Create it or rerun with -CreateEnvIfMissing. Example: micromamba create -n $EnvName -c conda-forge r-base"
  }

  Write-Host "Creating micromamba env '$EnvName' with conda-forge R..."
  & $MicromambaExe create -y -n $EnvName -c conda-forge r-base r-essentials | Out-Host

  $envPrefix = Get-EnvPrefix $EnvName
  if (-not $envPrefix) { Fail "Env creation ran, but '$EnvName' still not found." }
}

Write-Host "Env prefix: $envPrefix"

# --- Find R_HOME first (RStudio needs this) ---
$rHome = Join-Path $envPrefix "Library\lib\R"
if (-not (Test-Path $rHome)) {
  $alt = Join-Path $envPrefix "Lib\R"
  if (Test-Path $alt) { $rHome = $alt }
}
if (Test-Path $rHome) {
  Write-Host "R_HOME: $rHome"
} else {
  Write-Warning "Could not confirm R_HOME folder. Launcher may not work reliably."
}

# --- Locate R.exe - prefer the one in R_HOME\bin for RStudio compatibility ---
$possibleR = @(
  (Join-Path $rHome "bin\R.exe"),
  (Join-Path $rHome "bin\x64\R.exe"),
  (Join-Path $envPrefix "Library\bin\R.exe"),
  (Join-Path $envPrefix "Scripts\R.exe"),
  (Join-Path $envPrefix "bin\R.exe")
)
$rExe = $possibleR | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $rExe) {
  Fail "Could not find R.exe in env. Looked in:`n  $($possibleR -join "`n  ")"
}
Write-Host "R exe: $rExe"

# Site library often: <R_HOME>\library
$rSiteLib = if (Test-Path $rHome) { Join-Path $rHome "library" } else { $null }

# --- Create a launcher that runs RStudio INSIDE the env (most reliable) ---
if (-not (Test-Path $LauncherDir)) { New-Item -ItemType Directory -Path $LauncherDir | Out-Null }

$launcherPath = Join-Path $LauncherDir ("RStudio (micromamba-" + $EnvName + ").cmd")

$launcherCmd = @"
@echo off
REM Launch RStudio inside micromamba env: $EnvName
REM Ensures micromamba R.exe + DLLs + libs are used (avoids corporate R).

set "RSTUDIO_WHICH_R=$rExe"
set "R_HOME=$rHome"

REM Add micromamba env paths to PATH so R DLLs can be found
REM CRITICAL: R\bin\x64 must be first for R.dll
set "PATH=$rHome\bin\x64;$envPrefix\Library\bin;$envPrefix\Scripts;$envPrefix\bin;%PATH%"

REM Launch RStudio with the environment set up
start "" "$RStudioExe"
"@

$launcherCmd | Set-Content -Path $launcherPath -Encoding ASCII
Write-Host "Launcher created: $launcherPath"

# --- Optional: set per-user environment variables ---
if ($SetUserEnvVars) {
  Write-Host ""
  Write-Host "Setting per-user env vars so RStudio prefers micromamba R (User scope)..."

  # RStudio Desktop uses this to choose which R to bind to
  [Environment]::SetEnvironmentVariable("RSTUDIO_WHICH_R", $rExe, "User")

  # Helpful for R’s internal layout
  if (Test-Path $rHome) {
    [Environment]::SetEnvironmentVariable("R_HOME", $rHome, "User")
  }

  # Ensure env DLL dirs come first (this is the big one on Windows)
  $prepend = @(
    (Join-Path $envPrefix "Library\bin"),
    (Join-Path $envPrefix "Scripts"),
    (Join-Path $envPrefix "bin")
  ) | Where-Object { Test-Path $_ }

  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  if (-not $userPath) { $userPath = "" }

  # Remove duplicates of the prepend entries (case-insensitive)
  $parts = $userPath -split ";" | Where-Object { $_ -and $_.Trim() -ne "" }
  $filtered = @()
  foreach ($p in $parts) {
    $keep = $true
    foreach ($q in $prepend) {
      if ($p.TrimEnd("\") -ieq $q.TrimEnd("\")) { $keep = $false; break }
    }
    if ($keep) { $filtered += $p }
  }

  $newPath = ($prepend + $filtered) -join ";"
  [Environment]::SetEnvironmentVariable("Path", $newPath, "User")

  # Optional: force user library into the env site-library (prevents leaking to corporate lib dir)
  if ($rSiteLib -and (Test-Path $rSiteLib)) {
    [Environment]::SetEnvironmentVariable("R_LIBS_USER", $rSiteLib, "User")
  }

  Write-Host "Done. Close all RStudio instances and start again (env vars load on process start)."
}

Write-Host ""
Write-Host "Verify in RStudio (Console):"
Write-Host "  R.version.string"
Write-Host "  Sys.getenv('R_HOME')"
Write-Host "  .libPaths()"
Write-Host "  Sys.getenv('RSTUDIO_WHICH_R')"
Write-Host ""
Write-Host "Recommended: start RStudio via the new launcher:"
Write-Host "  $launcherPath"

