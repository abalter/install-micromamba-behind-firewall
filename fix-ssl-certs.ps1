
<#
.SYNOPSIS
  Securely fix micromamba SSL certificate chain errors on corporate Windows (no admin).

.DESCRIPTION
  Builds a PEM CA bundle from certificates in the CurrentUser Windows certificate store and
  configures micromamba/conda to use it via ~/.condarc (ssl_verify).

  This addresses errors like:
    schannel: CertGetCertificateChain trust error CERT_TRUST_IS_PARTIAL_CHAIN

  Key design points for team robustness:
    - Supports -WhatIf / -Confirm via ShouldProcess.
    - Creates a timestamped backup of the existing .condarc before modifying it.
    - Supports rollback (restores backup and optionally deletes generated files).
    - Supports "Test mode" by writing to an alternate condarc path without touching the real ~/.condarc.
      (You can then point micromamba at it using the CONDARC env var; mamba config search includes $CONDARC.) [mamba config docs]

  References:
    - Conda: Using non-standard certificates (recommended secure approach):
      https://docs.conda.io/projects/conda/en/latest/user-guide/configuration/non-standard-certs.html
    - Conda: .condarc file usage and home-directory location:
      https://docs.conda.io/projects/conda/en/latest/user-guide/configuration/use-condarc.html
    - Mamba/micromamba config search path includes ~/.condarc and $CONDARC, and --sources reporting:
      https://mamba.readthedocs.io/en/latest/user_guide/configuration.html
    - Export-Certificate cmdlet (export public cert from store to file):
      https://learn.microsoft.com/en-us/powershell/module/pki/export-certificate

.NOTES
  This does NOT disable SSL verification; it configures a trusted CA bundle instead (secure). [conda non-standard certs]
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
  # One or more patterns to match corporate Root CA subjects in Cert:\CurrentUser\Root
  [string[]]$RootSubjectLike = @("*Zscaler Root CA*"),

  # Output directory for exported certs and bundle
  [string]$OutDir = "$HOME\certs",

  # Bundle path (PEM)
  [string]$BundlePath = "$HOME\certs\corp-ca-bundle.pem",

  # Which .condarc to modify (default is user home). Use an alternate path for test mode.
  [string]$CondarcPath = "$HOME\.condarc",

  # Where to store backups of .condarc
  [string]$BackupDir = "$HOME\certs\backups",

  # Apply changes to Condarc (default). If false, only generates the bundle.
  [switch]$ApplyCondarc,

  # Also set per-session environment variables (REQUESTS_CA_BUNDLE/CURL_CA_BUNDLE). [conda non-standard certs]
  [switch]$SetSessionEnvVars,

  # Rollback: restore the most recent backup for the chosen CondarcPath and optionally delete generated files.
  [switch]$Rollback,

  # Delete generated bundle and exported PEM/CER files during rollback.
  [switch]$PurgeGenerated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info($m) { Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Write-Warn($m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }

if (-not (Get-Command certutil -ErrorAction SilentlyContinue)) {
  throw "certutil not found (unexpected on Windows)."
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

# Helper: extract CN=... from a Subject string if present
function Get-CnToken([string]$dn) {
  $m = [regex]::Match($dn, 'CN=([^,]+)')
  if ($m.Success) { return $m.Groups[1].Value.Trim() }
  return $null
}

# --- Rollback mode ---
if ($Rollback) {
  # Find newest backup for this condarc
  $safeName = ($CondarcPath -replace '[:\\\/]', '_')
  $pattern = "condarc-backup-$safeName-*.yml"
  $latest = Get-ChildItem -Path $BackupDir -Filter $pattern -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending |
    Select-Object -First 1

  if (-not $latest) {
    throw "No backup found for CondarcPath=$CondarcPath in $BackupDir (pattern=$pattern)."
  }

  if ($PSCmdlet.ShouldProcess($CondarcPath, "Restore backup from $($latest.FullName)")) {
    Copy-Item -Force -Path $latest.FullName -Destination $CondarcPath
    Write-Info "Restored: $CondarcPath"
  }

  if ($PurgeGenerated) {
    if ($PSCmdlet.ShouldProcess($OutDir, "Delete generated cert artifacts and bundle")) {
      Get-ChildItem -Path $OutDir -Filter "*.cer" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
      Get-ChildItem -Path $OutDir -Filter "*.pem" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
      if (Test-Path $BundlePath) { Remove-Item -Force $BundlePath -ErrorAction SilentlyContinue }
      Write-Info "Purged generated files in: $OutDir"
    }
  }

  Write-Info "Rollback complete."
  exit 0
}

# --- Apply mode (default) ---
Write-Info "Searching CurrentUser Root store for: $($RootSubjectLike -join ', ')"

$roots = foreach ($pat in $RootSubjectLike) {
  Get-ChildItem Cert:\CurrentUser\Root | Where-Object { $_.Subject -like $pat }
}
$roots = $roots | Sort-Object Thumbprint -Unique

if (-not $roots) {
  throw "No matching root cert(s) found in Cert:\CurrentUser\Root."
}

$roots | Select Subject, Thumbprint | Format-Table -Auto | Out-Host

# Export roots + derive CN tokens for intermediate matching
$pems = New-Object System.Collections.Generic.List[string]
$rootCns = New-Object System.Collections.Generic.List[string]

$i = 0
foreach ($r in $roots) {
  $i++
  $cn = Get-CnToken $r.Subject
  if ($cn) { $rootCns.Add($cn) | Out-Null }

  $cer = Join-Path $OutDir ("corp-root-$i.cer")
  $pem = Join-Path $OutDir ("corp-root-$i.pem")

  if ($PSCmdlet.ShouldProcess($cer, "Export root cert (public)")) {
    Export-Certificate -Cert $r -FilePath $cer | Out-Null
  }

  if ($PSCmdlet.ShouldProcess($pem, "Encode to PEM")) {
    certutil -encode $cer $pem | Out-Null
  }

  $pems.Add($pem) | Out-Null
}

# Find intermediates whose Issuer mentions any root CN token
$intermediates = @()
if ($rootCns.Count -gt 0) {
  $intermediates = Get-ChildItem Cert:\CurrentUser\CA |
    Where-Object {
      $issuer = $_.Issuer
      foreach ($cn in $rootCns) {
        if ($issuer -like "*$cn*") { return $true }
      }
      return $false
    }
}

if ($intermediates) {
  Write-Info "Found $($intermediates.Count) intermediate candidate(s) in CurrentUser\CA."
  $intermediates | Select Subject, Issuer, Thumbprint | Format-Table -Auto | Out-Host

  $j = 0
  foreach ($c in $intermediates) {
    $j++
    $cer = Join-Path $OutDir ("corp-intermediate-$j.cer")
    $pem = Join-Path $OutDir ("corp-intermediate-$j.pem")

    if ($PSCmdlet.ShouldProcess($cer, "Export intermediate cert (public)")) {
      Export-Certificate -Cert $c -FilePath $cer | Out-Null
    }
    if ($PSCmdlet.ShouldProcess($pem, "Encode to PEM")) {
      certutil -encode $cer $pem | Out-Null
    }

    $pems.Add($pem) | Out-Null
  }
} else {
  Write-Warn "No intermediates found. Root-only may still work, but some networks require intermediates (partial chain errors)."
}

# Build bundle (concatenate PEM files)
if ($PSCmdlet.ShouldProcess($BundlePath, "Write CA bundle")) {
  Get-Content @($pems.ToArray()) | Set-Content -Path $BundlePath -Encoding ASCII
  Write-Info "Bundle written: $BundlePath"
}

# Optionally write to .condarc (default behavior is OFF unless -ApplyCondarc is passed, for safety)
if ($ApplyCondarc) {
  # Backup condarc if exists
  if (Test-Path $CondarcPath) {
    $safeName = ($CondarcPath -replace '[:\\\/]', '_')
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backup = Join-Path $BackupDir "condarc-backup-$safeName-$stamp.yml"
    if ($PSCmdlet.ShouldProcess($backup, "Backup existing .condarc")) {
      Copy-Item -Force -Path $CondarcPath -Destination $backup
      Write-Info "Backed up $CondarcPath -> $backup"
    }
  }

  # Update or append ssl_verify in YAML
  $line = "ssl_verify: $BundlePath"
  if (-not (Test-Path $CondarcPath)) {
    if ($PSCmdlet.ShouldProcess($CondarcPath, "Create new .condarc with ssl_verify")) {
      $line | Set-Content -Path $CondarcPath -Encoding ASCII
    }
  } else {
    $raw = Get-Content -Path $CondarcPath -Raw
    if ($raw -match '(?m)^\s*ssl_verify\s*:') {
      $raw = [regex]::Replace($raw, '(?m)^\s*ssl_verify\s*:\s*.*$', $line)
    } else {
      if (-not $raw.EndsWith("`n")) { $raw += "`n" }
      $raw += $line + "`n"
    }

    if ($PSCmdlet.ShouldProcess($CondarcPath, "Update ssl_verify in .condarc")) {
      Set-Content -Path $CondarcPath -Value $raw -Encoding ASCII
    }
  }

  Write-Info "Updated ssl_verify in: $CondarcPath"
  Write-Info "Verify with: micromamba config list --sources (shows source file) [mamba config docs]"
} else {
  Write-Info "Skipped .condarc modification (use -ApplyCondarc to write ssl_verify)."
}

# Optional per-session env vars for tooling compatibility (requests/curl stacks; described by conda docs). [conda non-standard certs]
if ($SetSessionEnvVars) {
  if ($PSCmdlet.ShouldProcess("Current session", "Set REQUESTS_CA_BUNDLE and CURL_CA_BUNDLE")) {
    $Env:REQUESTS_CA_BUNDLE = $BundlePath
    $Env:CURL_CA_BUNDLE = $BundlePath
  }
  Write-Info "Session env vars set."
}

Write-Info "Done."
Write-Info "Suggested test: micromamba search zlib -c conda-forge"
``
