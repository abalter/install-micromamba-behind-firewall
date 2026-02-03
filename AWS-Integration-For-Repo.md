# AWS CLI integration (SSO + S3) for this micromamba setup

This repo already sets up **micromamba on a corporate network** (certs, proxies, RStudio launcher, etc.).
This document adds a **compatible** AWS CLI configuration so you can:

- authenticate via **IAM Identity Center (SSO)**
- access AWS services like **S3**
- **without micromamba certificate settings breaking AWS CLI TLS**

The key idea is to **scope certificate settings per tool**:

- Keep micromamba doing whatever it needs (often via `SSL_CERT_FILE`).
- For AWS CLI, **explicitly point AWS CLI at the corporate CA bundle** using `AWS_CA_BUNDLE` (or `--ca-bundle`). This is a standard way to fix AWS CLI `CERTIFICATE_VERIFY_FAILED` errors behind corporate TLS inspection. citeturn10search49turn10search48

---

## Repo context / assumptions

From your local checkout, you have scripts like:

- `fix-ssl-certs.ps1`
- `Set-MicromambaDefaults.ps1`
- `install-micromamba.ps1`
- `use-micromamba-rstudio.ps1`

…and you also have a corporate CA bundle (PEM) available locally (example path used below):

- `C:\Users\baltea7\certs\corp-ca-bundle.pem`

If your CA bundle lives elsewhere, update the paths accordingly.

---

## What broke (and why this fix works)

Some micromamba setups set `SSL_CERT_FILE` to point at a conda/mamba-managed CA bundle. That can be OK for micromamba/Python, but AWS CLI can still fail TLS validation against AWS endpoints (e.g., the OIDC endpoint used by `aws configure sso`) with:

```
[SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed: unable to get local issuer certificate
```

AWS CLI supports supplying a CA bundle for TLS verification (via global `--ca-bundle` or equivalent environment-based configuration) and that’s the correct enterprise fix. citeturn10search49turn10search48

---

## Recommended: add an `aws` wrapper function to your PowerShell profile

Instead of permanently changing global environment variables, define a small wrapper function that:

1. Temporarily sets `AWS_CA_BUNDLE` to your corporate CA bundle
2. Temporarily clears `SSL_CERT_FILE` (so micromamba’s CA override doesn’t interfere)
3. Runs the real `aws.exe`
4. Restores your environment variables

This keeps the micromamba setup intact and makes AWS CLI “just work.” citeturn10search49turn10search48

### 1) Edit your PowerShell profile

In PowerShell, the profile path is stored in `$PROFILE`.

Show it:

```powershell
$PROFILE
```

Create it if missing:

```powershell
if (-not (Test-Path $PROFILE)) {
  New-Item -ItemType File -Path $PROFILE -Force | Out-Null
}
```

Open it:

```powershell
notepad $PROFILE
```

### 2) Add this AWS wrapper (tailored to your paths)

Paste this into your profile:

```powershell
function aws {
  param(
    [Parameter(ValueFromRemainingArguments=$true)]
    $Args
  )

  # Update this if your CA bundle is elsewhere.
  $caBundle = "C:\Users\baltea7\certs\corp-ca-bundle.pem"

  # Resolve the actual aws.exe on PATH.
  $awsCmd = Get-Command aws.exe -ErrorAction SilentlyContinue
  if (-not $awsCmd) {
    throw "aws.exe not found on PATH. Install AWS CLI v2 and reopen PowerShell."
  }

  $oldAwsCa       = $env:AWS_CA_BUNDLE
  $oldSslCertFile = $env:SSL_CERT_FILE

  try {
    # Tell AWS CLI which CA bundle to use for TLS verification.
    $env:AWS_CA_BUNDLE = $caBundle

    # Prevent micromamba’s SSL_CERT_FILE from confusing AWS CLI’s TLS chain validation.
    $env:SSL_CERT_FILE = $null

    & $awsCmd.Source @Args
  }
  finally {
    $env:AWS_CA_BUNDLE = $oldAwsCa
    $env:SSL_CERT_FILE = $oldSslCertFile
  }
}
```

Why this works:

- `AWS_CA_BUNDLE` provides AWS CLI with the corporate trust chain it needs behind TLS inspection. citeturn10search49
- Avoiding `--no-verify-ssl` keeps certificate validation enabled (recommended). AWS CLI does support `--no-verify-ssl`, but it disables verification. citeturn10search48

### 3) Load the updated profile (no restart required)

```powershell
. $PROFILE
```

---

## Optional: also dot-source your repo defaults from the profile

If you want your micromamba defaults available in every new shell, you can also dot-source repo scripts.

Example (edit path to your repo checkout):

```powershell
$mmRepo = "C:\Users\baltea7\Documents\install_micromamba"

. "$mmRepo\Set-MicromambaDefaults.ps1"
# . "$mmRepo\fix-ssl-certs.ps1"  # Only if you normally run this each session
```

Put this above/below the `aws` wrapper in the same profile.

---

## Configure AWS CLI using IAM Identity Center (SSO)

Once the wrapper is in place, SSO config should stop failing due to TLS chain issues.

### 1) Configure SSO

```powershell
aws configure sso
```

The AWS CLI will prompt for:

- SSO start URL (your AWS access portal, e.g. `https://<org>.awsapps.com/start`)
- SSO region
- registration scopes (default is typically fine)

and will open a browser for authorization. citeturn10search55

### 2) Log in

```powershell
aws sso login --profile <your-profile-name>
```

### 3) Verify identity

```powershell
aws sts get-caller-identity --profile <your-profile-name>
```

This is the standard “who am I?” sanity check. citeturn1search19

### 4) Test S3 access

```powershell
aws s3 ls --profile <your-profile-name>
```

This lists buckets/objects depending on what permissions your role has. citeturn1search13

---

## Common outcomes

### “No AWS accounts are available to you.”

This means authentication succeeded, but your Identity Center user has **no AWS account + permission set assignments**. You’ll need your cloud/IAM team to assign you to at least one AWS account and permission set, then rerun `aws configure sso`. citeturn10search55

### Still getting SSL errors

If you still see TLS failures, your CA bundle likely doesn’t include the right corporate root/intermediate.

If you have multiple PEMs (e.g., Zscaler root + corporate root), create a combined bundle:

```powershell
Get-Content C:\Users\baltea7\certs\zscaler-root.pem, C:\Users\baltea7\certs\corp-ca-bundle.pem |
  Set-Content C:\Users\baltea7\certs\aws-cli-ca-bundle.pem
```

Then update `$caBundle` in the wrapper to point at `aws-cli-ca-bundle.pem`.

As a one-off check you can also use the global option:

```powershell
aws --ca-bundle C:\Users\baltea7\certs\corp-ca-bundle.pem sts get-caller-identity
```

The `--ca-bundle` option is supported as a global AWS CLI option. citeturn10search48

---

## Quick sanity checklist

- [ ] `aws` runs from your shell and uses the wrapper (no TLS errors during SSO config) citeturn10search49turn10search55
- [ ] `aws sts get-caller-identity` works under your SSO profile citeturn1search19
- [ ] You have at least one AWS account assignment in the portal (otherwise CLI will say none are available) citeturn10search55

