
<#
.SYNOPSIS
  Make micromamba "base" (root prefix) Python and R the default on Windows (user scope).

.DESCRIPTION
  - Determines micromamba root prefix (base prefix).
  - Optionally installs python and r-base into that prefix.
  - Prepends prefix, Scripts, and Library\bin to USER PATH (so `python` resolves to micromamba first).
  - Backs up USER PATH for rollback.
  - Optionally removes PowerShell alias `r` -> Invoke-History (so `R` can resolve to R.exe in PowerShell).

  IMPORTANT NOTES
  - PowerShell: `where` is an alias for Where-Object; use `where.exe` or `Get-Command`. [Ref 1,2,3]
  - PowerShell: alias `r` -> Invoke-History can shadow `R` (case-insensitive command lookup). [Ref 2]
  - After PATH changes: restart Explorer or log out/in so Start-menu apps inherit PATH. [Ref 5]
  - Disable Windows App execution aliases for python.exe/python3.exe if they hijack `python`. [Ref 6]
  - RStudio can be pointed at a specific R via RSTUDIO_WHICH_R if needed. [Ref 7]
  - VS Code Python uses PATH for defaults, but workspaces may “stick” to a previously chosen interpreter. [Ref 8]

.REFERENCES
  [1] StackOverflow: PowerShell where vs where.exe
      https://stackoverflow.com/questions/67693360/command-where-python-does-not-return-anything-in-powershell
  [2] Microsoft Learn: PowerShell aliases (incl. Windows compatibility aliases)
      https://learn.microsoft.com/en-us/powershell/scripting/learn/shell/using-aliases?view=powershell-7.5
  [3] Microsoft Learn: Get-Command docs
      https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/get-command?view=powershell-7.5
  [4] Microsoft Learn: about_Environment_Variables (User/Machine/Process scope & persistence)
      https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_environment_variables?view=powershell-7.5
  [5] PATH propagation / restart explorer guidance:
      https://superuser.com/questions/107521/why-are-changes-to-my-path-not-being-recognised
      https://connect.diligent.com/s/article/Refresh-Environment-Variables-Without-Restarting-Windows?language=en_US
  [6] Windows App execution aliases for python.exe/python3.exe:
      https://learn.microsoft.com/en-us/answers/questions/5601306/how-do-i-change-the-settings-so-i-can-modify-the-e
      https://www.matthewyang.io/blog/2024/12/27/python-aliases/
  [7] Posit Support: RSTUDIO_WHICH_R
      https://support.posit.co/hc/en-us/articles/200486138-Changing-R-versions-for-the-RStudio-Desktop-IDE
  [8] VS Code: python.defaultInterpreterPath behavior
      https://code.visualstudio.com/docs/python/settings-reference
      https://stackoverflow.com/questions/58498746/vscode-python-select-interpreter-add-a-custom-path
  [9] Micromamba install docs (self-contained; MAMBA_ROOT_PREFIX model)
      https://mamba.readthedocs.io/en/latest/installation/micromamba-installation.html

.PARAMETER MicromambaExe
  Optional full path to micromamba.exe. If not provided, tries `micromamba` from PATH.

.PARAMETER RootPrefix
  Optional micromamba root prefix. If not provided:
    1) $Env:MAMBA_ROOT_PREFIX
    2) Parse `micromamba info`
    3) Default: $HOME\micromamba_root

.PARAMETER InstallBasePackages
  If set, installs python and r-base into base prefix (conda-forge).

.PARAMETER Rollback
  Restore USER PATH from newest backup JSON in BackupDir.

.PARAMETER RemovePowerShellRAlias
  If set, appends a line to your PowerShell profile to remove alias `r`.

#>

[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param(
  [string]$MicromambaExe,
  [string]$RootPrefix,
  [switch]$InstallBasePackages,
  [string]$BackupDir = "$HOME\micromamba-defaults-backups",
  [switch]$Rollback,
  [string]$BackupFile,
  [switch]$RemovePowerShellRAlias
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info($m) { Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Write-Warn($m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }

function Get-UserPath() {
  [System.Environment]::GetEnvironmentVariable("Path","User")
}

function Set-UserPath([string]$value) {
  [System.Environment]::SetEnvironmentVariable("Path",$value,"User")
}

function Norm([string]$p) {
  if (-not $p) { return $p }
  return $p.Trim().TrimEnd('\')
}

New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

if ($Rollback) {
  if (-not $BackupFile) {
    $latest = Get-ChildItem -Path $BackupDir -Filter "UserPathBackup-*.json" -ErrorAction SilentlyContinue |
      Sort-Object Name -Descending |
      Select-Object -First 1
    if (-not $latest) { throw "No backup files found in $BackupDir" }
    $BackupFile = $latest.FullName
  }

  $data = Get-Content -Raw $BackupFile | ConvertFrom-Json
  if ($PSCmdlet.ShouldProcess("USER PATH", "Restore from $BackupFile")) {
    Set-UserPath $data.UserPath
    Write-Info "Restored USER PATH from: $BackupFile"
    Write-Info "Open a NEW PowerShell/CMD to pick up the change."
  }
  exit 0
}

# Locate micromamba.exe
if (-not $MicromambaExe) {
  $cmd = Get-Command micromamba -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.CommandType -eq 'Application') {
    $MicromambaExe = $cmd.Source
  }
}

if ($MicromambaExe) {
  $MicromambaExe = (Resolve-Path $MicromambaExe).Path
  Write-Info "micromamba.exe = $MicromambaExe"
} else {
  Write-Warn "micromamba.exe not found on PATH. Pass -MicromambaExe explicitly if needed."
}

# Determine root prefix (base prefix)
if (-not $RootPrefix) {
  if ($Env:MAMBA_ROOT_PREFIX) {
    $RootPrefix = $Env:MAMBA_ROOT_PREFIX
    Write-Info "Using RootPrefix from MAMBA_ROOT_PREFIX: $RootPrefix"
  } elseif ($MicromambaExe) {
    $info = & $MicromambaExe info 2>$null
    $line = $info | Where-Object { $_ -match 'base env location\s*:\s*(.+)$' } | Select-Object -First 1
    if ($line -and $line -match 'base env location\s*:\s*(.+)$') {
      $RootPrefix = $Matches[1].Trim()
      Write-Info "Parsed RootPrefix from micromamba info: $RootPrefix"
    }
  }
}

if (-not $RootPrefix) {
  $RootPrefix = "$HOME\micromamba_root"
  Write-Warn "Falling back to default RootPrefix: $RootPrefix"
}

$RootPrefix = Norm $RootPrefix

# Optionally install python + r-base into base prefix
if ($InstallBasePackages) {
  if (-not $MicromambaExe) { throw "InstallBasePackages requires micromamba.exe." }
  Write-Info "Installing into base prefix: $RootPrefix"
  $args = @("install", "--prefix", $RootPrefix, "-c", "conda-forge", "-y", "python", "r-base")
  if ($PSCmdlet.ShouldProcess("$MicromambaExe $($args -join ' ')", "Install python and r-base")) {
    & $MicromambaExe @args
  }
}

# PATH entries to prepend
$entriesToPrepend = @(
  (Norm $RootPrefix),
  (Norm (Join-Path $RootPrefix "Scripts")),
  (Norm (Join-Path $RootPrefix "Library\bin"))
) | Select-Object -Unique

Write-Info "Will prepend to USER PATH (in order):"
$entriesToPrepend | ForEach-Object { Write-Host "  - $_" }

# Backup USER PATH
$userPath = Get-UserPath
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupPath = Join-Path $BackupDir "UserPathBackup-$stamp.json"

$backupObj = [pscustomobject]@{
  CreatedAt = (Get-Date).ToString("o")
  UserPath  = $userPath
  RootPrefix= $RootPrefix
  Prepended = $entriesToPrepend
}

if ($PSCmdlet.ShouldProcess($backupPath, "Write USER PATH backup")) {
  $backupObj | ConvertTo-Json -Depth 5 | Set-Content -Path $backupPath -Encoding UTF8
  Write-Info "Backed up USER PATH to: $backupPath"
}

# Compute new USER PATH, de-duping
$existing = @()
if ($userPath) {
  $existing = $userPath -split ';' | Where-Object { $_ -and $_.Trim() } | ForEach-Object { Norm $_ }
}

$newParts = @()
$newParts += $entriesToPrepend
$newParts += ($existing | Where-Object { $entriesToPrepend -notcontains $_ })

$newUserPath = ($newParts -join ';')

if ($PSCmdlet.ShouldProcess("USER PATH", "Set USER PATH (micromamba base first)")) {
  Set-UserPath $newUserPath
  Write-Info "Updated USER PATH (user scope)."
  Write-Info "Open a NEW PowerShell/CMD to see the change."
}

# Optional: remove PowerShell alias 'r' so 'R' can resolve to R.exe in PowerShell
if ($RemovePowerShellRAlias) {
  $profilePath = $PROFILE
  $line = 'Remove-Item Alias:r -ErrorAction SilentlyContinue'
  if ($PSCmdlet.ShouldProcess($profilePath, "Add line to remove alias r")) {
    if (-not (Test-Path $profilePath)) {
      New-Item -ItemType File -Force -Path $profilePath | Out-Null
    }
    $content = Get-Content -Raw $profilePath
    if ($content -notmatch [regex]::Escape($line)) {
      Add-Content -Path $profilePath -Value "`n# Allow R.exe to be invoked as 'R' in PowerShell`n$line`n"
      Write-Info "Updated profile: $profilePath"
    } else {
      Write-Info "Profile already contains alias removal line."
    }
  }
}

Write-Info "Next steps:"
Write-Host "  1) Disable Windows App execution aliases for python.exe/python3.exe if needed." -ForegroundColor Yellow
Write-Host "  2) Restart Explorer or log out/in so GUI apps inherit PATH." -ForegroundColor Yellow
Write-Host "  3) Verify in a NEW shell using where.exe / Get-Command:" -ForegroundColor Yellow
Write-Host "       where.exe python" -ForegroundColor Yellow
Write-Host "       python --version" -ForegroundColor Yellow
Write-Host "       where.exe R" -ForegroundColor Yellow
Write-Host "       where.exe Rscript" -ForegroundColor Yellow
