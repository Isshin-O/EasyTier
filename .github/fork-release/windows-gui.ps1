# Fork only: install the Windows GUI silently and check that it starts and
# shows a window. Fork Release Check reports this but does not block a release
# on it: a CI desktop has no real user session, antivirus or tray.
param([Parameter(Mandatory = $true)][string]$Installer)

$ErrorActionPreference = 'Stop'
$out = Join-Path $env:GITHUB_WORKSPACE 'windows-gui'
New-Item -ItemType Directory -Force $out | Out-Null

# NSIS installer from Tauri: /S installs silently.
$p = Start-Process -FilePath $Installer -ArgumentList '/S' -Wait -PassThru
if ($p.ExitCode -ne 0) { throw "installer exited with $($p.ExitCode)" }

$exe = @(
  "$env:ProgramFiles\easytier-gui\easytier-gui.exe",
  "$env:LOCALAPPDATA\easytier-gui\easytier-gui.exe",
  "$env:LOCALAPPDATA\Programs\easytier-gui\easytier-gui.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $exe) {
  $exe = Get-ChildItem "$env:ProgramFiles", "$env:LOCALAPPDATA" -Recurse -Filter easytier-gui.exe -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
}
if (-not $exe) { throw 'easytier-gui.exe not found after install' }
Write-Host "installed: $exe"

$gui = Start-Process -FilePath $exe -PassThru
Start-Sleep -Seconds 25
$gui.Refresh()
if ($gui.HasExited) { throw "easytier-gui exited with $($gui.ExitCode)" }
$window = Get-Process -Id $gui.Id | Select-Object -ExpandProperty MainWindowTitle
Write-Host "running, window title: '$window'"

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp = New-Object System.Drawing.Bitmap $screen.Width, $screen.Height
[System.Drawing.Graphics]::FromImage($bmp).CopyFromScreen($screen.Location, [System.Drawing.Point]::Empty, $screen.Size)
$bmp.Save("$out\gui.png")

Stop-Process -Id $gui.Id -Force
if (-not $window) { throw 'easytier-gui is running but shows no window' }
