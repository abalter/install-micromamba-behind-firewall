# Launch RStudio but force it to use micromamba R for all operations
$env:RSTUDIO_WHICH_R = "C:\Users\baltea7\micromamba_root\Scripts\R.exe"
$env:R_HOME = "C:\Users\baltea7\micromamba_root"
$env:R_USER = "$HOME"

# Kill any existing RStudio sessions
Get-Process rstudio -ErrorAction SilentlyContinue | Stop-Process -Force

# Launch RStudio
& "C:\Program Files\RStudio\rstudio.exe"

