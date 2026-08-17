@echo off
title Package Deployer Studio
cd /d "%~dp0"
powershell.exe -NoProfile -NoLogo -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0PackageDeployerStudio.ps1"
if errorlevel 1 (
  echo.
  echo Package Deployer Studio exited with an error.
  pause
)
