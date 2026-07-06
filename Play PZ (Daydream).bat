@echo off
rem Daydream Checkpoints launcher: start the watcher, then the game.
start "Daydream Watcher" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0watcher\DaydreamWatcher.ps1"
start "" "steam://rungameid/108600"
