@echo off
rem sshs - starts the Remotes picker limited to SSH targets.
rem remotes.ps1 sits next to this file (%~dp0 is the folder of this launcher).
rem All arguments are passed on, so typing a word after "sshs" pre-fills the search.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0remotes.ps1" -Type ssh %*
exit /b %ERRORLEVEL%
