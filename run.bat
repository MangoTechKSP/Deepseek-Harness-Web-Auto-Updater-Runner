@echo off
REM ---------------------------------------------------------------------
REM  run.bat -- start DSH. If an update is waiting it asks first.
REM
REM  Double-clicked by hand : the console stays, the browser opens.
REM  Started at logon       : tools\dsh-boot-hidden.vbs runs this with
REM                           DSH_NO_PAUSE=1 and DSH_OPEN_BROWSER=0, so
REM                           nothing appears on screen.
REM
REM  Set these before calling if you want to change one run:
REM    DSH_SKIP_UPDATE=1          skip the whole pre-flight
REM    DSH_OPEN_BROWSER=1|0       force the browser question
REM    DSH_UPDATE_APPROVED=1      somebody already said yes to the update
REM    DSH_UPDATE_DECLINED=1      somebody already said no
REM    DSH_FORCE_PLUGIN_UPDATE=1  update plugins even when DSH is current
REM    DSH_NO_PAUSE=1             never wait for a key press
REM ---------------------------------------------------------------------

@echo off
chcp 65001 >nul
cd /d "%~dp0"
if not exist "%~dp0tools\dsh-common.ps1" (
  echo ERROR: the tools folder is missing. Unpack the whole archive again.
  if not "%DSH_NO_PAUSE%"=="1" pause
  exit /b 1
)
for /f "usebackq delims=" %%i in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\dsh-env.ps1"`) do call :dsh_set "%%i"

REM ---- is DSH already running? -----------------------------------------
netstat -ano | findstr "LISTENING" | findstr ":%DSH_PORT% " >nul 2>&1
if not errorlevel 1 (
  echo [dsh] a DSH server is already listening on port %DSH_PORT%
  if "%DSH_OPEN_BROWSER%"=="1" (
    echo [dsh] opening http://127.0.0.1:%DSH_PORT%
    start "" "http://127.0.0.1:%DSH_PORT%"
  ) else (
    echo [dsh] open http://127.0.0.1:%DSH_PORT% in your browser when you need it
  )
  if not "%DSH_NO_PAUSE%"=="1" pause
  exit /b 0
)

REM ---- pre-flight: backup, update check, health, verify -----------------
REM Keep every argument line OUT of any ( ) block: cmd expands %VARS% once
REM when it parses a whole block, so a variable built inside one is empty.
if "%DSH_SKIP_UPDATE%"=="1" (
  echo [dsh] pre-flight skipped
  goto :start_server
)

set "BOOT_ARGS=-Mode preflight -Port %DSH_PORT% -Profile %DSH_PROFILE% -Tag %DSH_TAG%"
if "%DSH_FORCE_PLUGIN_UPDATE%"=="1" set "BOOT_ARGS=%BOOT_ARGS% -ForcePluginUpdate"
if "%DSH_UPDATE_APPROVED%"=="1" set "BOOT_ARGS=%BOOT_ARGS% -AssumeYes"
if "%DSH_UPDATE_DECLINED%"=="1" set "BOOT_ARGS=%BOOT_ARGS% -SkipUpdate"
if "%DSH_PROMPT_UPDATE%"=="1" if not "%DSH_UPDATE_APPROVED%"=="1" if not "%DSH_UPDATE_DECLINED%"=="1" set "BOOT_ARGS=%BOOT_ARGS% -PromptUpdate"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\dsh-boot.ps1" %BOOT_ARGS%
if errorlevel 1 (
  echo.
  echo [dsh] the pre-flight reported a problem - see logs\boot.log
  if not "%DSH_NO_PAUSE%"=="1" pause
)

:start_server
set "BIN=%~dp0dsh\node_modules\@deepseek-ai\dsh\lib\bin.js"
if not exist "%BIN%" (
  echo [dsh] DSH is not installed yet - double-click install.bat first
  if not "%DSH_NO_PAUSE%"=="1" pause
  exit /b 1
)
set "OPEN_ARGS=--no-open"
if "%DSH_OPEN_BROWSER%"=="1" set "OPEN_ARGS="

echo [dsh] starting DSH on port %DSH_PORT%
node "%BIN%" web --port %DSH_PORT% %OPEN_ARGS%
if errorlevel 1 (
  echo [dsh] DSH exited with an error - see logs\run.log
  if not "%DSH_NO_PAUSE%"=="1" pause
)
exit /b 0
exit /b 0

:dsh_set
REM Load one setting WITHOUT overwriting a variable the caller already set, so
REM "set DSH_OPEN_BROWSER=0 && run.bat" and the logon chain keep their choice.
for /f "tokens=1* delims==" %%a in ("%~1") do if not defined %%a set "%%a=%%b"
exit /b 0