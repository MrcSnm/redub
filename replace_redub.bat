@echo off
setlocal
set "NEW_REDUB=%~1"
set "OLD_REDUB=%~2"
for %%F in ("%OLD_REDUB%") do set "OLD_NAME=%%~nxF"
:WAIT_FOR_PARENT
tasklist /FI "IMAGENAME eq %OLD_NAME%" | findstr /i /c:"%OLD_NAME%" >nul
if %ERRORLEVEL%==0 (
    timeout /t 1 >nul
    goto WAIT_FOR_PARENT
)
copy /Y "%NEW_REDUB%" "%OLD_REDUB%" >nul 2>&1
if errorlevel 1 (
    echo Failed to replace Redub binary. > "%~dp0redub_update_error.log"
    exit /b 1
)
exit /b 0
