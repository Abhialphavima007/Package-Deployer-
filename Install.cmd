@echo off
title Install Package Deployer Studio
powershell.exe -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%~dp0Install.ps1" %*
echo.
pause
