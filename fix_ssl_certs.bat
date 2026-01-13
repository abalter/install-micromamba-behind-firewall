
<#
.SYNOPSIS
  Securely fixes micromamba SSL chain errors on corporate networks (no admin).

.DESCRIPTION
  Builds a PEM CA bundle from certificates in the *CurrentUser* Windows cert store
  and configures micromamba/conda-family tools to use it via ~/.condarc:

    ssl_verify: C:\Users\<you>\certs\corp-ca-bundle.pem

  Default behavior targets Zscaler Root CA (common corporate TLS interception),
  but you can provide your own subject match pattern(s).

  Why this works:
    - The error CERT_TRUST_IS_PARTIAL_CHAIN typically indicates the TLS chain cannot be built.
    - On managed networks, HTTPS may be intercepted and re-signed by an enterprise root CA.
    - Conda documents using a custom CA bundle for "non-standard certificates" rather than disabling SSL. [conda docs]
    - Micromamba reads configuration from ~/.condarc and shows sources with `micromamba config list --sources`. [mamba docs]

  References:
    - Conda: Using non-standard certificates (CA bundles, REQUESTS_CA_BUNDLE guidance):
      https://docs.conda.io/projects/conda/en/latest/user-guide/configuration/non-standard-certs.html
    - Mamba/micromamba config search paths include ~/.condarc and source reporting:
      https://mamba.readthedocs.io/en/latest/user_guide/configuration.html
    - Export-Certificate cmdlet (exports public cert from cert store to file):
      https://learn.microsoft.com/en-us/powershell/module/pki/export-certificate

.NOTES
  This script does NOT disable SSL verification.
  It only changes trust roots used by micromamba/conda for outbound HTTPS.
#>

[CmdletBinding()]
param(
  # Match corporate root subject(s). Defaults to Zscaler Root CA.
  [string[]]$RootSubjectLike = @("*Zscaler Root CA*"),

  # Where to write exported certs and bundle (user-writable).
  [string]$OutDir = "$HOME\certs",

  # Bundle output file
  [string]$BundlePath = "$HOME\certs\corp-ca-bundle.pem",

  # Path to user .condarc
  [string]$CondarcPath = "$HOME\.condarc",

  # Also set per-session env vars (optional)
  [switch]$SetSessionEnvVars
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info($msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }

# 0) Preconditions
if (-not (Get-Command certutil -ErrorAction SilentlyContinue)) {
  throw "certutil not found (unexpected on Windows)."
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Write-Info "OutDir = $OutDir"

# 1) Find corporate root cert(s) in CurrentUser\Root
$roots = foreach ($pat in $RootSubjectLike) {
  Get-ChildItem Cert:\CurrentUser\Root |
    Where-Object { $_.Subject -like $pat }
}

$roots = $roots | Sort-Object Thumbprint -Unique
if (-not $roots) {
  throw "No matching root certs found in Cert:\CurrentUser\Root for patterns: $($RootSubjectLike -join ', ')"
}

Write-Info "Found $($roots.Count) matching root cert(s)."
$roots | Select-Object Subject, Thumbprint | Format-Table -Auto | Out-Host

# 2) Export root(s) to CER, then encode to PEM
$pems = @()
$idx = 0
foreach ($r in $roots) {
  $idx++
  $cer = Join-Path $OutDir ("corp-root-$idx.cer")
  $pem = Join-Path $OutDir ("corp-root-$idx.pem")

  Export-Certificate -Cert $r -FilePath $cer | Out-Null
  certutil -encode $cer $pem | Out-Null

  $pems += $pem
}

# 3) Find likely intermediates in CurrentUser\CA whose Issuer matches these roots OR whose Subject matches patterns
# (This helps avoid CERT_TRUST_IS_PARTIAL_CHAIN by including intermediate CA(s).)
$thumbprints = $roots.Thumbprint
$intermediates = Get-ChildItem Cert:\CurrentUser\CA |
  Where-Object {
    ($_.Issuer -match "Zscaler" -and ($RootSubjectLike -join ' ') -match "Zscaler") -or
    ($RootSubjectLike | ForEach-Object { $_.Trim('*') } | Where-Object { $_ -and $_ -ne " " } | ForEach-Object { $_ } | Measure-Object).Count -ge 0
  }

# More precise intermediate selection: include certs whose Issuer contains a root CN token
# (If you pass other patterns, you may want to adjust the Issuer test.)
if ($RootSubjectLike -join '' -match "Zscaler") {
  $intermediates = Get-ChildItem Cert:\CurrentUser\CA |
    Where-Object { $_.Issuer -like "*Zscaler Root CA*" -or $_.Subject -like "*Zscaler*" }
}

if ($intermediates) {
  Write-Info "Found $($intermediates.Count) intermediate candidate(s) in Cert:\CurrentUser\CA."
  $intermediates | Select-Object Subject, Issuer, Thumbprint | Format-Table -Auto | Out-Host

  $i = 0
  foreach ($c in $intermediates) {
    $i++
    $cer = Join-Path $OutDir ("corp-intermediate-$i.cer")
    $pem = Join-Path $OutDir ("corp-intermediate-$i.pem")

    Export-Certificate -Cert $c -FilePath $cer | Out-Null
    certutil -encode $cer $pem | Out-Null

    $pems += $pem
  }
}
else {
  Write-Warn "No intermediates found (this may still be OK if root is sufficient)."
}

# 4) Build the bundle (concatenate PEM files)
Write-Info "Writing bundle: $BundlePath"
Get-Content @($pems) | Set-Content -Path $BundlePath -Encoding ASCII

# 5) Update ~/.condarc: set or replace ssl_verify line
# Conda docs: .condarc is YAML config; user file typically lives in home directory. [conda docs]
Write-Info "Updating Condarc: $CondarcPath"
if (-not (Test-Path $CondarcPath)) {
  # Create new .condarc with ssl_verify
  "ssl_verify: $BundlePath" | Set-Content -Path $CondarcPath -Encoding ASCII
}
else {
  $text = Get-Content -Path $CondarcPath -Raw
  if ($text -match '(?m)^\s*ssl_verify\s*:') {
    $text = [regex]::Replace($text, '(?m)^\s*ssl_verify\s*:\s*.*$', "ssl_verify: $BundlePath")
  }
  else {
    # append with newline
    if (-not $text.EndsWith("`n")) { $text += "`n" }
    $text += "ssl_verify: $BundlePath`n"
  }
  Set-Content -Path $CondarcPath -Value $text -Encoding ASCII
}

# 6) Optional: set per-session env vars used by many TLS stacks (helpful in mixed tooling scenarios)
# Conda docs reference REQUESTS_CA_BUNDLE and CURL_CA_BUNDLE for non-standard cert workflows. [conda docs]
if ($SetSessionEnvVars) {
  $Env:REQUESTS_CA_BUNDLE = $BundlePath
  $Env:CURL_CA_BUNDLE = $BundlePath
  Write-Info "Set REQUESTS_CA_BUNDLE and CURL_CA_BUNDLE for this session."
}

Write-Info "Done."
Write-Info "Verify with: micromamba config list --sources"
