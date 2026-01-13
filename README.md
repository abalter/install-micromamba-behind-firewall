# install_micromamba
Micromamba on Windows (No Admin) + Secure SSL Fix for Corporate Networks
## Overview

This guide shows how to:

1.  Install **micromamba** in a **user-writable folder** on Windows (no admin).
2.  Fix common corporate-network SSL errors such as  
    `schannel: CertGetCertificateChain trust error CERT_TRUST_IS_PARTIAL_CHAIN`  
    by building a **custom CA bundle** and configuring micromamba via `~\.condarc`—**without disabling SSL verification**.

Micromamba is a statically linked, self-contained executable that can be installed without admin rights by downloading and extracting it. [\[research.i...astate.edu\]](https://research.it.iastate.edu/micromamba-usage-guide), [\[stackoverflow.com\]](https://stackoverflow.com/questions/66855895/how-to-modify-the-location-of-condarc-file), [\[dmyersturn....github.io\]](https://dmyersturnbull.github.io/guide/mamba-and-conda/)

***

## Part A — Install micromamba (no admin)

### Why this works

Micromamba is distributed as a **standalone executable** and the docs explicitly provide a PowerShell installation path for Windows.   
A common Windows tarball extraction layout places `micromamba.exe` under `Library\bin`, which matches the workflow we used. [\[research.i...astate.edu\]](https://research.it.iastate.edu/micromamba-usage-guide), [\[docs.conda.io\]](https://docs.conda.io/projects/conda/en/latest/user-guide/configuration/use-condarc.html) [\[dmyersturn....github.io\]](https://dmyersturnbull.github.io/guide/mamba-and-conda/), [\[stackoverflow.com\]](https://stackoverflow.com/questions/66855895/how-to-modify-the-location-of-condarc-file)

### Use the script

1.  Save `Install-Micromamba.ps1` somewhere (e.g., `C:\Users\<you>\Scripts`).
2.  Run:

```powershell
# Example: install to ~/micromamba, add to user PATH, initialize PowerShell profile
.\Install-Micromamba.ps1 -AddToUserPath -InitPowerShellProfile
```

### Notes

*   Adding to **User PATH** modifies only the current user’s environment variables—no admin rights needed.
*   Setting `MAMBA_ROOT_PREFIX` controls where micromamba stores environments and caches by default. This behavior is described in the installation docs and is central to micromamba’s configuration model. [\[research.i...astate.edu\]](https://research.it.iastate.edu/micromamba-usage-guide), [\[docs.conda.io\]](https://docs.conda.io/projects/conda/en/latest/user-guide/configuration/use-condarc.html)

***

## Part B — Secure SSL certificate fix (corporate TLS interception)

### Symptoms

After initial success, subsequent installs fail with messages like:

*   `Download error (60) SSL peer certificate or SSH remote key was not OK`
*   `schannel: CertGetCertificateChain trust error CERT_TRUST_IS_PARTIAL_CHAIN`

This is common on corporate networks that use **TLS inspection** and re-sign external HTTPS traffic with a corporate root CA (e.g., Zscaler, McAfee Web Gateway, etc.). A secure fix is to use your organization’s CA certificate chain as the trust bundle used by conda-family tools. [\[howtouselinux.com\]](https://www.howtouselinux.com/post/curl-60-ssl-certificate-problem-unable-to-get-local-issuer-certificate), [\[stackoverflow.com\]](https://stackoverflow.com/questions/70264976/error-cannot-bind-argument-to-parameter-name-because-it-is-null-when-running)

### Why the CA-bundle approach is secure

Conda explicitly documents that when you are behind a firewall or have **non-standard certificates**, you should point your tooling at the **company-provided root certificate** (or a CA bundle) rather than disabling SSL verification.   
Micromamba reads configuration from `~\.condarc` (and other rc locations), and it can show where a config value came from using `micromamba config list --sources`. [\[howtouselinux.com\]](https://www.howtouselinux.com/post/curl-60-ssl-certificate-problem-unable-to-get-local-issuer-certificate), [\[kodu.ut.ee\]](https://kodu.ut.ee/~kmoch/geopython2023/Py_00/Installing_Micromamba.html) [\[stackoverflow.com\]](https://stackoverflow.com/questions/70264976/error-cannot-bind-argument-to-parameter-name-because-it-is-null-when-running), [\[kodu.ut.ee\]](https://kodu.ut.ee/~kmoch/geopython2023/Py_00/Installing_Micromamba.html)

### Approach we used

1.  Identify the corporate root CA in the **CurrentUser** certificate store (no admin).
2.  Export the root (and any intermediates) to files.
3.  Convert/export to PEM and concatenate into a single bundle file.
4.  Set in `~\.condarc`:

```yaml
ssl_verify: C:\Users\<you>\certs\corp-ca-bundle.pem
```

Exporting a certificate to disk is supported by PowerShell’s `Export-Certificate` cmdlet.   
Using `ssl_verify` in `.condarc` is part of conda’s configuration model (YAML runtime config file in your home directory). [\[mamba.readthedocs.io\]](https://mamba.readthedocs.io/en/stable/) [\[kodu.ut.ee\]](https://kodu.ut.ee/~kmoch/geopython2023/Py_00/Installing_Micromamba.html), [\[lancelqf.github.io\]](https://lancelqf.github.io/tech/mamba/)

### Use the script

1.  Save `Fix-MicromambaSsl.ps1`.
2.  Run with defaults (targets Zscaler Root CA by default):

```powershell
.\Fix-MicromambaSsl.ps1
```

If your org uses something else, pass a different subject pattern:

```powershell
.\Fix-MicromambaSsl.ps1 -RootSubjectLike @("*McAfee Web Gateway*", "*Nationwide Root CA*")
```

### Verify

```powershell
micromamba config list --sources
```

You should see something like:

    ssl_verify: C:\Users\<you>\certs\corp-ca-bundle.pem  # '~\.condarc'

This confirms micromamba is reading your **user `.condarc`** and applying the secure CA-bundle configuration. [\[stackoverflow.com\]](https://stackoverflow.com/questions/70264976/error-cannot-bind-argument-to-parameter-name-because-it-is-null-when-running), [\[kodu.ut.ee\]](https://kodu.ut.ee/~kmoch/geopython2023/Py_00/Installing_Micromamba.html)

***

## Troubleshooting

### “micromamba.exe not found after extraction”

*   Ensure `tar` is available and extraction succeeded.
*   Re-run the install script and confirm `InstallDir\Library\bin\micromamba.exe` exists.
    The Windows extraction recipe using `tar` is a known working approach. [\[dmyersturn....github.io\]](https://dmyersturnbull.github.io/guide/mamba-and-conda/), [\[stackoverflow.com\]](https://stackoverflow.com/questions/66855895/how-to-modify-the-location-of-condarc-file)

### “CERT\_TRUST\_IS\_PARTIAL\_CHAIN” persists

*   Add additional corporate root CAs / intermediates from your CurrentUser store into the bundle.
*   Corporate setups often include multiple inspection roots, and missing intermediates can cause partial-chain trust errors.
    Conda’s “non-standard certificates” guidance covers these enterprise scenarios and emphasizes using an appropriate CA bundle rather than disabling verification. [\[howtouselinux.com\]](https://www.howtouselinux.com/post/curl-60-ssl-certificate-problem-unable-to-get-local-issuer-certificate), [\[stackoverflow.com\]](https://stackoverflow.com/questions/70264976/error-cannot-bind-argument-to-parameter-name-because-it-is-null-when-running)

### Where is `.condarc` on Windows?

*   Typically: `C:\Users\<you>\.condarc` (shown as `~\.condarc`)
*   Conda docs confirm it lives in your home directory by default and is created when you use `conda config` (or you can create it manually). [\[kodu.ut.ee\]](https://kodu.ut.ee/~kmoch/geopython2023/Py_00/Installing_Micromamba.html), [\[lancelqf.github.io\]](https://lancelqf.github.io/tech/mamba/)

***

## References

*   Micromamba installation docs (PowerShell install; self-contained executable): [\[research.i...astate.edu\]](https://research.it.iastate.edu/micromamba-usage-guide), [\[docs.conda.io\]](https://docs.conda.io/projects/conda/en/latest/user-guide/configuration/use-condarc.html)
*   Example Windows extraction to `Library\bin` using tar: [\[dmyersturn....github.io\]](https://dmyersturnbull.github.io/guide/mamba-and-conda/), [\[stackoverflow.com\]](https://stackoverflow.com/questions/66855895/how-to-modify-the-location-of-condarc-file)
*   Mamba/micromamba configuration search paths and `--sources`: [\[stackoverflow.com\]](https://stackoverflow.com/questions/70264976/error-cannot-bind-argument-to-parameter-name-because-it-is-null-when-running)
*   Conda `.condarc` location/behavior (home directory YAML config): [\[kodu.ut.ee\]](https://kodu.ut.ee/~kmoch/geopython2023/Py_00/Installing_Micromamba.html), [\[lancelqf.github.io\]](https://lancelqf.github.io/tech/mamba/)
*   Conda “non-standard certificates” (CA bundle workflow): [\[howtouselinux.com\]](https://www.howtouselinux.com/post/curl-60-ssl-certificate-problem-unable-to-get-local-issuer-certificate)
*   PowerShell `Export-Certificate` cmdlet reference: [\[mamba.readthedocs.io\]](https://mamba.readthedocs.io/en/stable/)

***

## Quick follow-up (to tailor the scripts to your environment)

1.  Do you want the install script to **avoid touching your PowerShell profile** (no `shell init`) and instead use `micromamba run -p <env>` patterns? (Some orgs prefer zero profile changes.)
2.  Where would you like your environments and package cache to live (e.g., not under OneDrive/profile quotas)? I can add `envs_dirs` and `pkgs_dirs` updates to the scripts in a safe “merge” way using the same config precedence model micromamba documents. [\[stackoverflow.com\]](https://stackoverflow.com/questions/70264976/error-cannot-bind-argument-to-parameter-name-because-it-is-null-when-running), [\[kodu.ut.ee\]](https://kodu.ut.ee/~kmoch/geopython2023/Py_00/Installing_Micromamba.html)
