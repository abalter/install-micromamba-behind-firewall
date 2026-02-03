# AWS CLI + micromamba on a corporate laptop (no SSL conflicts)

This note documents a **robust** way to use the AWS CLI (especially **IAM Identity Center / SSO**) from the same PowerShell sessions where you also use **micromamba**, without tripping over certificate environment variables.

## Why this is needed

On many corporate laptops:

- The network does HTTPS/TLS inspection (e.g., Zscaler), so tools need a **corporate CA bundle** to validate TLS.
- micromamba (or its Python runtime) may set `SSL_CERT_FILE` to point at its own CA bundle.
- AWS CLI uses Python/SSL libraries that may **not** use the Windows trust store, and can fail with:

```
SSL validation failed ... CERTIFICATE_VERIFY_FAILED ... unable to get local issuer certificate
```

A standard fix for AWS CLI TLS issues is to provide a CA bundle explicitly via the AWS CLI CA bundle override mechanisms (environment variable or the `--ca-bundle` option). citeturn10search49turn10search48

The goal is: **keep micromamba working**, and make AWS CLI always work by ensuring it uses the **right CA bundle**, without permanently mutating your shell.

---

## Prerequisites

1. **AWS CLI v2 installed**.
2. A **corporate CA bundle** in PEM format (example path used below):

   - `C:\Users\<you>\certs\corp-ca-bundle.pem`

   This file usually contains your corporate root (and sometimes intermediate) certificate(s) needed to validate HTTPS through your company network.

3. You know your IAM Identity Center portal URL (your “AWS access portal”), e.g.

   - `https://<org>.awsapps.com/start`

---

## Recommended solution: an `aws` wrapper function in your PowerShell profile

Create a function named `aws` that:

- **temporarily sets** `AWS_CA_BUNDLE` so AWS CLI trusts your corporate CA bundle,
- **temporarily clears** `SSL_CERT_FILE` (so micromamba’s CA override doesn’t confuse AWS CLI),
- runs the real `aws.exe`,
- then **restores** the previous environment variables.

This keeps micromamba behavior intact while guaranteeing AWS CLI TLS succeeds.

### Wrapper function

Add the following to your PowerShell profile (instructions below):

```powershell
function aws {
  param(
    [Parameter(ValueFromRemainingArguments=$true)]
    $Args
  )

  # Path to your CA bundle (PEM). Update if yours lives elsewhere.
  $caBundle = "C:\Users\baltea7\certs\corp-ca-bundle.pem"

  # Resolve the real aws.exe (works even if PATH changes).
  $awsCmd = Get-Command aws.exe -ErrorAction SilentlyContinue
  if (-not $awsCmd) {
    throw "aws.exe not found on PATH. Install AWS CLI v2 and reopen PowerShell."
  }

  $oldAwsCa       = $env:AWS_CA_BUNDLE
  $oldSslCertFile = $env:SSL_CERT_FILE

  try {
    # Tell AWS CLI which CA bundle to use for TLS validation.
    $env:AWS_CA_BUNDLE = $caBundle

    # Avoid micromamba/conda injecting a CA bundle that AWS CLI can't use.
    $env:SSL_CERT_FILE = $null

    & $awsCmd.Source @Args
  }
  finally {
    $env:AWS_CA_BUNDLE  = $oldAwsCa
    $env:SSL_CERT_FILE  = $oldSslCertFile
  }
}
```

**Why `AWS_CA_BUNDLE`?** It’s the normal way to point AWS tooling at a certificate bundle when you’re behind a corporate proxy/TLS inspection and see certificate chain errors. citeturn10search49

**Why not `--no-verify-ssl`?** AWS CLI supports it, but it disables certificate validation. Prefer a CA bundle. citeturn10search48

---

## How to add the function to your PowerShell profile

PowerShell loads a profile script at startup. You can put the function there.

### 1) Find your profile path

Run:

```powershell
$PROFILE
```

You’ll see something like:

- `C:\Users\<you>\Documents\PowerShell\Microsoft.PowerShell_profile.ps1`

### 2) Create the profile file if it doesn’t exist

```powershell
if (-not (Test-Path $PROFILE)) {
  New-Item -ItemType File -Path $PROFILE -Force | Out-Null
}
```

### 3) Edit the profile

Open it in Notepad:

```powershell
notepad $PROFILE
```

Paste the wrapper function into the file and save.

### 4) Load it in your current session (no restart required)

```powershell
. $PROFILE
```

Now `aws ...` in that shell will use the wrapper.

---

## Configure AWS CLI with IAM Identity Center (SSO)

Once the wrapper is in place, you can do the normal SSO setup.

### 1) Configure SSO

Run:

```powershell
aws configure sso
```

AWS CLI will prompt for Start URL, SSO region, etc., and will open a browser for authorization. citeturn10search55

### 2) Log in

If you created a profile name during setup (e.g. `nwd-foo`), you can explicitly login:

```powershell
aws sso login --profile nwd-foo
```

### 3) Verify credentials

```powershell
aws sts get-caller-identity --profile nwd-foo
```

`sts get-caller-identity` is the standard “who am I?” check for AWS credentials. citeturn1search19

### 4) Test S3 access

```powershell
aws s3 ls --profile nwd-foo
```

This lists buckets if your role allows it. citeturn1search13

---

## Common outcomes and what they mean

### “No AWS accounts are available to you.”

SSO authentication succeeded, but your Identity Center user has **no AWS account/permission set assignments**.

Fix: ask your IAM/Cloud team to assign you to at least one AWS account + permission set.

### “SSL validation failed … CERTIFICATE_VERIFY_FAILED …”

Usually means the CA bundle you pointed AWS CLI at is missing the required corporate root/intermediate.

Steps:

1. Confirm your `corp-ca-bundle.pem` contains one or more certs:

   ```powershell
   Select-String -Path C:\Users\baltea7\certs\corp-ca-bundle.pem -Pattern "BEGIN CERTIFICATE" -SimpleMatch
   ```

2. If your org has multiple relevant roots/intermediates (e.g., Zscaler + corporate root), concatenate them into a single PEM file:

   ```powershell
   Get-Content C:\Users\baltea7\certs\zscaler-root.pem, C:\Users\baltea7\certs\corp-ca-bundle.pem |
     Set-Content C:\Users\baltea7\certs\aws-cli-ca-bundle.pem
   ```

   Then update the wrapper’s `$caBundle` path.

3. As a one-off test, you can also pass the AWS CLI global option:

   ```powershell
   aws --ca-bundle C:\Users\baltea7\certs\corp-ca-bundle.pem sts get-caller-identity
   ```

   The `--ca-bundle` option is a supported global CLI option. citeturn10search48

---

## Notes for micromamba users

- It’s fine for micromamba to manage its own certs; the key is not letting those settings break other tooling.
- The wrapper scopes AWS CA settings to **only** AWS CLI calls.

---

## Quick checklist

- [ ] Corporate CA bundle exists (PEM) and includes the right root/intermediate certs.
- [ ] PowerShell profile contains the `aws` wrapper function.
- [ ] `aws configure sso` works without certificate errors. citeturn10search55turn10search49
- [ ] `aws sts get-caller-identity` works. citeturn1search19
- [ ] You have at least one AWS account assignment (portal “Accounts” tab not empty).

