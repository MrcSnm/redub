@echo off
setlocal
set "NEW_REDUB=%~1"
set "OLD_REDUB=%~2"

rem Windows allows renaming a running executable, just not overwriting it.
if not exist "%OLD_REDUB%" goto :copy
set "OLD_BACKUP=%OLD_REDUB%.old.%RANDOM%"
move /Y "%OLD_REDUB%" "%OLD_BACKUP%" >nul 2>&1
if not exist "%OLD_BACKUP%" (
    echo Failed to move the current Redub binary out of the way. > "%~dp0redub_update_error.log"
    exit /b 1
)

:copy
copy /Y "%NEW_REDUB%" "%OLD_REDUB%" >nul 2>&1
if errorlevel 1 (
    if exist "%OLD_BACKUP%" move /Y "%OLD_BACKUP%" "%OLD_REDUB%" >nul 2>&1
    echo Failed to replace Redub binary. Check if it is in use. > "%~dp0redub_update_error.log"
    exit /b 1
)

if defined OLD_BACKUP del /f /q "%OLD_BACKUP%" >nul 2>&1
rem Leftovers from earlier updates become deletable once their process exits.
del /f /q "%OLD_REDUB%.old.*" >nul 2>&1
exit /b 0
