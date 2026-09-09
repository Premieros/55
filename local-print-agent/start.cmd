@echo off
cd /d "%~dp0"
where node >nul 2>nul
if errorlevel 1 (
  echo Node.js is required to run Johns Print Service.
  pause
  exit /b 1
)
start "Johns Print Service" /min node agent.cjs
timeout /t 2 /nobreak >nul
start "" http://127.0.0.1:17654/
