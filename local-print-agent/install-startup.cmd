@echo off
setlocal
cd /d "%~dp0"
where node.exe >nul 2>nul
if errorlevel 1 (
  echo Node.js is required. Install Node.js LTS first.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$w=New-Object -ComObject WScript.Shell; $s=$w.CreateShortcut($w.SpecialFolders('Startup')+'\Johns Print Service.lnk'); $s.TargetPath=(Get-Command node.exe).Source; $s.Arguments='\"%~dp0agent.cjs\"'; $s.WorkingDirectory='%~dp0'; $s.WindowStyle=7; $s.Description='Johns local kitchen printer routing service'; $s.Save()"
if errorlevel 1 (
  echo Failed to create startup shortcut.
  pause
  exit /b 1
)
start "Johns Print Service" /min node agent.cjs
timeout /t 2 /nobreak >nul
start "" http://127.0.0.1:17654/
echo Johns Print Service is installed for this Windows user and will start at sign-in.
pause
