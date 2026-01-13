# Micromamba on Windows (No Admin) + Secure Corporate SSL Fix (Team-Ready)

This repository provides **team-safe**, **no-admin** PowerShell automation for:

1. **Installing micromamba** for the current user (supports **side-by-side installs**, `-WhatIf`, and uninstall/rollback).
2. **Fixing corporate SSL trust issues** (e.g., TLS inspection / partial chain errors) securely by exporting trusted CA certs from the **CurrentUser** certificate store, creating a **PEM bundle**, and configuring `ssl_verify` in `.condarc` with **backup + rollback**.

> ✅ Security note: We **do not** disable SSL verification. We configure a corporate CA bundle instead.

---

## Contents

- Why this exists
- Prerequisites
- Quick Start (Safe Defaults)
- Install (Production / Team Adoption)
- Secure SSL Fix (Production)
- Testing Without Touching Existing Installations
- Dry Run / Planning Mode
- Rollback / Uninstall
- Customization
- FAQ / Troubleshooting
- References

---

## Why this exists

On corporate-managed Windows systems, you may not have admin rights. You may also be behind:

- TLS interception appliances (Zscaler, McAfee Web Gateway, Netskope, etc.)
- custom enterprise root CAs
- restricted certificate store policies

In those environments, micromamba installs can fail with errors like:

- `Download error (60) SSL peer certificate or SSH remote key was not OK`
- `schannel: CertGetCertificateChain trust error CERT_TRUST_IS_PARTIAL_CHAIN`

These scripts provide a secure, user-scope workflow that avoids requiring admin access.

---

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+
- Windows built-in tools:
  - `tar` (Windows 10/11 typically includes it)
  - `certutil` (standard on Windows)
- Network access to conda-forge endpoints (or access via corporate proxy)
- Ability to read certificates in your **CurrentUser** certificate store (`certmgr.msc`)

---

## Quick Start (Safe Defaults)

### A) Safe micromamba install test (side-by-side, no PATH/profile changes)

This will **NOT overwrite** any existing micromamba installation and does not change PATH/profile.

```powershell
.\Install-Micromamba.ps1 -InstallRoot "$HOME\micromamba" -SideBySide
````

After installation, run micromamba by **full path** (no PATH changes):

```powershell
# Replace timestamp folder with the one printed by the installer or found in install-manifest.json
& "$HOME\micromamba\micromamba-YYYYMMDD-HHMMSS\Library\bin\micromamba.exe" --version
```

✅ This is the recommended way to test safely in a team environment.

***

### B) Safe SSL fix test (generate bundle only; no `.condarc` changes)

This generates a CA bundle but does not modify `.condarc` unless you pass `-ApplyCondarc`.

```powershell
.\Fix-MicromambaSsl.ps1
```

Bundle output:

*   `$HOME\certs\corp-ca-bundle.pem`

***

## Install (Production / Team Adoption)

Once the side-by-side install is validated, you can optionally:

### Add micromamba to USER PATH (no admin)

```powershell
.\Install-Micromamba.ps1 -InstallRoot "$HOME\micromamba" -AddToUserPath
```

Restart PowerShell to pick up the PATH change.

### Initialize PowerShell profile for activation (optional)

If your team wants `micromamba activate` to work seamlessly in PowerShell, you can use profile init:

```powershell
.\Install-Micromamba.ps1 -InitProfile -RootPrefix "$HOME\micromamba_root"
```

> If your org prefers zero profile edits, skip this and use `micromamba run -p <env> <command>` instead.

***

## Secure SSL Fix (Production)

### Apply the fix securely (write `ssl_verify` to `.condarc`)

This backs up the existing `.condarc` before changing it:

```powershell
.\Fix-MicromambaSsl.ps1 -ApplyCondarc
```

Verify the configuration source:

```powershell
micromamba config list --sources
```

Expected output includes something like:

    ssl_verify: C:\Users\<you>\certs\corp-ca-bundle.pem  # '~\.condarc'

***

## Testing Without Touching Existing Installations

### 1) Side-by-side install (best practice)

*   Use `-SideBySide` for install testing.
*   Do **not** add to PATH or init profile.
*   Invoke by full path.

### 2) Test SSL config without editing real `~\.condarc`

Micromamba config search supports an override config file via the `CONDARC` environment variable.

Workflow:

```powershell
# 1) Generate the CA bundle only
.\Fix-MicromambaSsl.ps1

# 2) Create a temporary test condarc
$testCondarc = "$HOME\certs\test.condarc"
"ssl_verify: $HOME\certs\corp-ca-bundle.pem" | Set-Content $testCondarc -Encoding ASCII

# 3) Point this session at the test condarc
$Env:CONDARC = $testCondarc

# 4) Verify sources and test
micromamba config list --sources
micromamba search zlib -c conda-forge
```

Close the shell to discard the `CONDARC` override.

***

## Dry Run / Planning Mode

Both scripts support PowerShell `-WhatIf`:

```powershell
.\Install-Micromamba.ps1 -SideBySide -WhatIf
.\Fix-MicromambaSsl.ps1 -ApplyCondarc -WhatIf
```

Use `-Confirm` for extra safety in team usage.

***

## Rollback / Uninstall

### Uninstall micromamba PATH entry and optionally remove files

```powershell
.\Install-Micromamba.ps1 -Uninstall -RemoveFiles
```

If you used `-SideBySide`, add `-SideBySide` to target the newest side-by-side install under `InstallRoot`:

```powershell
.\Install-Micromamba.ps1 -InstallRoot "$HOME\micromamba" -SideBySide -Uninstall -RemoveFiles
```

### Roll back `.condarc` changes

Restore the newest `.condarc` backup for the chosen `-CondarcPath`:

```powershell
.\Fix-MicromambaSsl.ps1 -Rollback
```

Optionally purge generated cert artifacts:

```powershell
.\Fix-MicromambaSsl.ps1 -Rollback -PurgeGenerated
```

Backups are stored in:

*   `$HOME\certs\backups\`

***

## Customization

### Install location

```powershell
.\Install-Micromamba.ps1 -InstallRoot "D:\Tools\micromamba" -SideBySide
```

### SSL: match different corporate roots

Default root match is `*Zscaler Root CA*`.

To match other roots:

```powershell
.\Fix-MicromambaSsl.ps1 -RootSubjectLike @("*McAfee Web Gateway*", "*Netskope*", "*YourCorp Root CA*") -ApplyCondarc
```

### SSL: bundle-only mode (no `.condarc` changes)

```powershell
.\Fix-MicromambaSsl.ps1
```

### SSL: bundle + session env vars (optional)

Some toolchains respect `REQUESTS_CA_BUNDLE` / `CURL_CA_BUNDLE`:

```powershell
.\Fix-MicromambaSsl.ps1 -SetSessionEnvVars
```

***

## FAQ / Troubleshooting

### Q: I don’t want to modify my PowerShell profile.

A: Don’t use `-InitProfile`. Use `micromamba run -p <env> <command>` and call micromamba via full path (or user PATH).

### Q: `tar` is missing.

A: Use Git Bash, or install a tar-capable utility. Windows 10/11 typically includes `tar`.

### Q: SSL still fails after applying the fix.

A: Your network may use a different enterprise root or additional intermediates. Run:

```powershell
Get-ChildItem Cert:\CurrentUser\Root | Select Subject, Thumbprint
Get-ChildItem Cert:\CurrentUser\CA   | Select Subject, Issuer, Thumbprint
```

Then add additional patterns to `-RootSubjectLike` and re-run with `-ApplyCondarc`.

### Q: How do I confirm which config micromamba is using?

A: Run:

```powershell
micromamba config list --sources
```

This shows configuration values and their source file.

***

## References

*   Micromamba installation (PowerShell install path, self-contained executable):
    *   <https://mamba.readthedocs.io/en/latest/installation/micromamba-installation.html>
    *   <https://github.com/mamba-org/mamba/blob/main/docs/source/installation/micromamba-installation.rst>
*   Example Windows extraction workflow showing `Library\bin` layout:
    *   <https://kodu.ut.ee/~kmoch/geopython2025/Py_00/Installing_Micromamba.html>
*   Mamba/micromamba configuration search paths and `--sources`:
    *   <https://mamba.readthedocs.io/en/latest/user_guide/configuration.html>
*   Conda `.condarc` configuration file usage and location:
    *   <https://docs.conda.io/projects/conda/en/latest/user-guide/configuration/use-condarc.html>
*   Conda non-standard certificates (secure CA bundle workflow):
    *   <https://docs.conda.io/projects/conda/en/latest/user-guide/configuration/non-standard-certs.html>
*   PowerShell `Export-Certificate` cmdlet:
    *   <https://learn.microsoft.com/en-us/powershell/module/pki/export-certificate>

```

---

## If you want, I can also provide a “RELEASING.md” and “CONTRIBUTING.md”
For team repos, those two often help a lot (e.g., how to validate changes using `-WhatIf`, expected output examples, how to add new corporate CA match patterns safely).

**Quick check:** do you want the README to include a short “Copy/paste examples for Zscaler + McAfee + Netskope” section (so teammates don’t need to edit patterns), or keep it generic?
```
