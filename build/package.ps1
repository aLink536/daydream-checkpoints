# =====================================================================
# Daydream Checkpoints — packaging script
#
# Assembles a distributable zip laid out to extract straight into the
# Project Zomboid install folder:
#
#   dinput8.dll                                   (watcher auto-start)
#   mods\DaydreamCheckpoints\...                  (the mod)
#   mods\DaydreamCheckpoints\watcher\...          (companion watcher)
#   Play PZ (Daydream).bat                        (manual watcher launch)
#   README.md, LICENSE
#
# The DLL reads mods\DaydreamCheckpoints\watcher\DaydreamWatcher.ps1 via
# a cfg file we drop next to it, so everything lives under the mod folder
# and there are no absolute paths baked in.
#
# Run from the repo root:  powershell -File build\package.ps1
# =====================================================================

$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$staging = Join-Path $env:TEMP ("daydream_pkg_" + [Guid]::NewGuid().ToString("N"))
$version = (Select-String -Path (Join-Path $repo "mods\DaydreamCheckpoints\42\mod.info") -Pattern "modversion=(.+)").Matches[0].Groups[1].Value.Trim()
$outZip = Join-Path $repo ("dist\DaydreamCheckpoints_v{0}.zip" -f $version)

Write-Host "Packaging Daydream Checkpoints v$version"

# ---- assemble staging tree ------------------------------------------
New-Item -ItemType Directory -Force $staging | Out-Null
$modDest = Join-Path $staging "mods\DaydreamCheckpoints"
New-Item -ItemType Directory -Force $modDest | Out-Null

# mod files (42/ + common/)
Copy-Item (Join-Path $repo "mods\DaydreamCheckpoints\42")     $modDest -Recurse -Force
Copy-Item (Join-Path $repo "mods\DaydreamCheckpoints\common") $modDest -Recurse -Force

# watcher under the mod folder
$watcherDest = Join-Path $modDest "watcher"
New-Item -ItemType Directory -Force $watcherDest | Out-Null
Copy-Item (Join-Path $repo "watcher\DaydreamWatcher.ps1") $watcherDest -Force

# proxy DLL - defaults to the standard watcher path under mods\, so no
# cfg is needed for a normal install
Copy-Item (Join-Path $repo "proxy\dinput8.dll") (Join-Path $staging "dinput8.dll") -Force

# launcher (generated for the packaged layout: watcher lives under mods\)
$bat = @'
@echo off
rem Daydream Checkpoints - manual watcher launch (only needed if you
rem deleted dinput8.dll). Start the watcher, then the game.
start "Daydream Watcher" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0mods\DaydreamCheckpoints\watcher\DaydreamWatcher.ps1"
start "" "steam://rungameid/108600"
'@
Set-Content -Path (Join-Path $staging "Play PZ (Daydream).bat") -Value $bat -Encoding ASCII

# docs
Copy-Item (Join-Path $repo "README.md") $staging -Force
Copy-Item (Join-Path $repo "LICENSE")   $staging -Force

# ---- zip -------------------------------------------------------------
New-Item -ItemType Directory -Force (Split-Path $outZip) | Out-Null
if (Test-Path $outZip) { Remove-Item $outZip -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($staging, $outZip)
Remove-Item $staging -Recurse -Force

Write-Host "Wrote $outZip"
