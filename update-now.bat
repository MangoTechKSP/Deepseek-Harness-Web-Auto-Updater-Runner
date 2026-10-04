@echo off
chcp 65001 >nul
cd /d "%~dp0"
if not exist "%~dp0tools\dsh-common.ps1" (
  echo ERROR: the tools folder is missing. Unpack the whole archive again.
  if not "%DSH_NO_PAUSE%"=="1" pause
  exit /b 1
)
for /f "usebackq delims=" %%i in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\dsh-env.ps1"`) do call :dsh_set "%%i"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\dsh-boot.ps1" -Mode preflight -Port %DSH_PORT% -Profile %DSH_PROFILE% -Tag %DSH_TAG% %*
if not "%DSH_NO_PAUSE%"=="1" (
  echo.
  pause
)
exit /b 0

:dsh_set
REM Load one setting WITHOUT overwriting a variable the caller already set, so
REM "set DSH_OPEN_BROWSER=0 && run.bat" and the logon chain keep their choice.
for /f "tokens=1* delims==" %%a in ("%~1") do if not defined %%a set "%%a=%%b"
exit /b 0