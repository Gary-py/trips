@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\_tools\Publish-Trip.ps1" -TripName "okinawa-2026"
pause
