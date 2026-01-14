# RStudio with Micromamba R - Setup Notes

## Problem Statement

When trying to launch RStudio with a micromamba R environment, RStudio was either:
1. Not starting at all (terminal flashing and closing)
2. Starting but using the corporate/system R installation instead of micromamba R
3. Failing with exit code `3221225781` (0xC0000135 - "The application failed to initialize properly")

## Root Causes Discovered

### 1. Base Environment Path Pattern
**Issue:** The `base` micromamba environment doesn't follow the standard `...\envs\<name>` path pattern.

**Details:**
- Standard named environments: `C:\Users\<user>\micromamba_root\envs\<env_name>`
- Base environment: `C:\Users\<user>\micromamba_root`

**Solution:** Added special handling in `Get-EnvPrefix` function to detect the base environment by looking for paths that don't contain `\envs\` in them.

### 2. Wrong R.exe Location
**Issue:** Multiple R.exe files exist in a micromamba R installation, and not all are suitable for RStudio.

**Locations found:**
- `<micromamba_root>\Scripts\R.exe` ✗ (found first, but wrong for RStudio)
- `<micromamba_root>\Lib\R\bin\R.exe` ✓ (correct - inside R_HOME)

**Solution:** Changed search order to prioritize `R_HOME\bin\R.exe` first, as this is the standard R installation location that RStudio expects.

### 3. Missing R.dll in PATH
**Issue:** The critical `R.dll` file was not accessible to RStudio, causing the 0xC0000135 error.

**Location:** `C:\Users\<user>\micromamba_root\Lib\R\bin\x64\R.dll`

**Solution:** Added `R_HOME\bin\x64` to the PATH **first**, before other directories, to ensure R.dll is found.

## Required Environment Configuration

For RStudio to successfully use micromamba R, the following must be set:

### 1. RSTUDIO_WHICH_R
```cmd
set "RSTUDIO_WHICH_R=C:\Users\<user>\micromamba_root\Lib\R\bin\R.exe"
```
This tells RStudio which R executable to bind to.

### 2. R_HOME
```cmd
set "R_HOME=C:\Users\<user>\micromamba_root\Lib\R"
```
This is the standard R installation directory containing bin/, library/, etc.

### 3. PATH (Order Matters!)
```cmd
set "PATH=<R_HOME>\bin\x64;<micromamba_root>\Library\bin;<micromamba_root>\Scripts;<micromamba_root>\bin;%PATH%"
```

**Critical:** `R_HOME\bin\x64` MUST be first in PATH so that:
- `R.dll` is found (required for R to initialize)
- Other R-related DLLs are accessible
- Micromamba's R takes precedence over any system R installation

## Why micromamba run Didn't Work

Initial approach:
```cmd
micromamba run -n base "C:\Program Files\RStudio\rstudio.exe"
```

**Problem:** While `micromamba run` sets up the environment for the command it executes, RStudio then spawns a separate R process. This child process doesn't properly inherit all the environment variables, particularly the PATH modifications needed to find R.dll.

**Solution:** Set environment variables explicitly in the batch file before launching RStudio, rather than relying on `micromamba run`.

## Final Working Launcher

```cmd
@echo off
REM Launch RStudio inside micromamba env: base
REM Ensures micromamba R.exe + DLLs + libs are used (avoids corporate R).

set "RSTUDIO_WHICH_R=C:\Users\<user>\micromamba_root\Lib\R\bin\R.exe"
set "R_HOME=C:\Users\<user>\micromamba_root\Lib\R"

REM Add micromamba env paths to PATH so R DLLs can be found
REM CRITICAL: R\bin\x64 must be first for R.dll
set "PATH=C:\Users\<user>\micromamba_root\Lib\R\bin\x64;C:\Users\<user>\micromamba_root\Library\bin;C:\Users\<user>\micromamba_root\Scripts;C:\Users\<user>\micromamba_root\bin;%PATH%"

REM Launch RStudio with the environment set up
start "" "C:\Program Files\RStudio\rstudio.exe"
```

## Verification Commands

Once RStudio launches successfully, verify the configuration in the R console:

```r
# Should show R 4.5.2 (or your micromamba R version)
R.version.string

# Should point to micromamba R_HOME
Sys.getenv('R_HOME')

# Should point to micromamba R.exe
Sys.getenv('RSTUDIO_WHICH_R')

# Should show library paths under micromamba_root, NOT system R paths
.libPaths()
```

## Key Takeaways

1. **R.dll location is critical** - It must be in the PATH before RStudio starts
2. **R_HOME\bin\R.exe** is the correct R executable for RStudio, not Scripts\R.exe
3. **Base environment** requires special handling due to non-standard path
4. **PATH order matters** - Micromamba R paths must come before system R paths
5. **Environment variables must be set before launching RStudio**, not via `micromamba run`

## Date
Created: January 14, 2026
