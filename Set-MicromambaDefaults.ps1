
<#
.SYNOPSIS
  Make micromamba base (root prefix) Python and R the default for CLI + IDEs (user scope).

.DESCRIPTION
  - Ensures micromamba base paths come before system Python on USER PATH.
  - Optionally removes PowerShell alias 'r' so typing 'R' launches R (PowerShell is case-insensitive).
  - Optionally sets RSTUDIO_WHICH_R so RStudio uses micromamba R without changing RStudio settings.
  - Creates a backup of USER PATH for rollback.
  - Supports -WhatIf / -Confirm natively.

REFERENCES
  PowerShell aliases (r -> Invoke-History; alias precedence):
    https://learn.microsoft.com/en-us/powershell/scripting/learn/shell/using-aliases?view=powershell-7.5
  Get-Command (executable discovery on PATH):
    https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/get-command?view=powershell-7.5
  VS Code python.defaultInterpreterPath behavior:
    https://code.visualstudio.com/docs/python/settings-reference
  RStudio: overriding R with RSTUDIO_WHICH_R:
    https://support.posit.co/hc/en-us/articles/200486138-Changing-R-versions-for-the-RStudio-Desktop-IDE
  PATH updates may require restarting Explorer/logoff to affect GUI apps:
    https://superuser.com/questions/107521/why-are-changes-to-my-path-not-being-recognised
#>

[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param(
  # Your micromamba base prefix (root prefix)
  [string]$RootPrefix = "$HOME\micromamba_root",

  # Backup directory for PATH rollback
  [string]$BackupDir = "$HOME\micromamba-defaults-backups",

  # Roll back USER PATH from newest backup
  [switch]$Rollback,

  # If set, remove PowerShell alias 'r' in your profile so `R` runs R.exe (PowerShell is case-insensitive)
  [switch]$FixPowerShellRAlias,

  # If set, configure RStudio to use micromamba R via RSTUDIO_WHICH_R (no RStudio UI settings)
  [switch]$SetRStudioWhichR
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info($m) { Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Write-Warn($m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Norm([string]$p) { if (-not $p) { return $p }; $p.Trim().TrimEnd('\') }

function Get-UserPath() {
  [System.Environment]::GetEnvironmentVariable("Path","User")
}
function Set-UserPath([string]$value) {
  [System.Environment]::SetEnvironmentVariable("Path",$value,"User")
}

New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
$RootPrefix = Norm $RootPrefix

if ($Rollback) {
  $latest = Get-ChildItem -Path $BackupDir -Filter "UserPathBackup-*.json" -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending |
    Select-Object -First 1
  if (-not $latest) { throw "No backups found in $BackupDir" }

  $data = Get-Content -Raw $latest.FullName | ConvertFrom-Json
  if ($PSCmdlet.ShouldProcess("USER PATH", "Restore from $($latest.FullName)")) {
    Set-UserPath $data.UserPath
    Write-Info "Restored USER PATH. Open a NEW shell and re-test."
  }
  return
}

# Directories to ensure are first (typical conda-style Windows layout)
$prepend = @(
  (Norm $RootPrefix),
  (Norm (Join-Path $RootPrefix "Scripts")),
  (Norm (Join-Path $RootPrefix "Library\bin"))
) | Select-Object -Unique

Write-Info "Will prepend these directories to USER PATH (in order):"
$prepend | ForEach-Object { Write-Host "  - $_" }

# Backup current USER PATH
$userPath = Get-UserPath
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupPath = Join-Path $BackupDir "UserPathBackup-$stamp.json"
$backupObj = [pscustomobject]@{
  CreatedAt  = (Get-Date).ToString("o")
  UserPath   = $userPath
  RootPrefix = $RootPrefix
  Prepended  = $prepend
}
if ($PSCmdlet.ShouldProcess($backupPath, "Write USER PATH backup")) {
  $backupObj | ConvertTo-Json -Depth 5 | Set-Content -Path $backupPath -Encoding UTF8
  Write-Info "Backed up USER PATH to: $backupPath"
}

# Build new PATH: AGGRESSIVELY remove all micromamba paths first, then prepend fresh
$existing = @()
if ($userPath) {
  $existing = $userPath -split ';' | Where-Object { $_ -and $_.Trim() } | ForEach-Object { Norm $_ }
}

# Remove ANY path containing micromamba_root or condabin (cleanup old/stale entries)
$micromambaRelated = @($existing | Where-Object { $_ -match 'micromamba' })
if ($micromambaRelated.Count -gt 0) {
  Write-Warn "Removing stale micromamba entries:"
  $micromambaRelated | ForEach-Object { Write-Host "  - $_" }
}

$cleanedExisting = @($existing | Where-Object { $_ -notmatch 'micromamba' })

# Now prepend fresh in correct order
$newParts = @($prepend + $cleanedExisting)
$newUserPath = ($newParts -join ';')

Write-Info "New USER PATH order (first 5 entries):"
($newParts | Select-Object -First 5) | ForEach-Object { Write-Host "  - $_" }

if ($PSCmdlet.ShouldProcess("USER PATH", "Set USER PATH with micromamba base first")) {
  Set-UserPath $newUserPath
  Write-Info "Updated USER PATH. IMPORTANT: open a NEW PowerShell/CMD to see changes."
}

# Fix PowerShell R alias (optional)
if ($FixPowerShellRAlias) {
  $profilePath = $PROFILE
  $line = 'Remove-Item Alias:r -ErrorAction SilentlyContinue'
  if ($PSCmdlet.ShouldProcess($profilePath, "Persistently remove alias 'r' so 'R' can run R.exe")) {
    if (-not (Test-Path $profilePath)) { New-Item -ItemType File -Force -Path $profilePath | Out-Null }
    $content = Get-Content -Raw $profilePath
    if ($content -notmatch [regex]::Escape($line)) {
      Add-Content -Path $profilePath -Value "`n# Allow R.exe to be invoked as 'R' in PowerShell`n$line`n"
      Write-Info "Updated PowerShell profile: $profilePath"
    } else {
      Write-Info "Profile already contains alias removal line."
    }
  }
}

# Configure RStudio to use micromamba R (optional)
if ($SetRStudioWhichR) {
  $rExe = Join-Path $RootPrefix "Scripts\R.exe"
  if (-not (Test-Path $rExe)) {
    Write-Warn "Could not find $rExe. If your R.exe lives elsewhere, set RSTUDIO_WHICH_R to that path."
  } else {
    if ($PSCmdlet.ShouldProcess("User env var", "Set RSTUDIO_WHICH_R=$rExe")) {
      [System.Environment]::SetEnvironmentVariable("RSTUDIO_WHICH_R", $rExe, "User")
      Write-Info "Set RSTUDIO_WHICH_R for user."
    }
  }
}

Write-Info "Next steps (important for GUI apps):"
Write-Host "  1) Restart Explorer or log out/in so Start-menu apps inherit updated USER PATH." -ForegroundColor Yellow
Write-Host "  2) Verify in a NEW PowerShell:" -ForegroundColor Yellow
Write-Host "       where.exe python" -ForegroundColor Yellow
Write-Host "       where.exe R" -ForegroundColor Yellow
Write-Host "  3) In PowerShell, run R as: R.exe (or enable -FixPowerShellRAlias)" -ForegroundColor Yellow
