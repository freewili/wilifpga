@echo off
rem fwfpga launcher (Windows). Python 3.11+ required (tomllib); prefers the py launcher.
where py >nul 2>nul
if %ERRORLEVEL%==0 (
  py -3 "%~dp0fwfpga.py" %*
) else (
  python "%~dp0fwfpga.py" %*
)
exit /b %ERRORLEVEL%
