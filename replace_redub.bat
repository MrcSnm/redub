SET NEW_REDUB=%1
SET OLD_REDUB=%2

:WAIT_FOR_PARENT
tasklist | findstr /i "redub.exe" >nul
if %ERRORLEVEL%==0 (
    rem Redub is still running...
    timeout /t 1
    goto WAIT_FOR_PARENT
)
copy /Y %NEW_REDUB% %OLD_REDUB%