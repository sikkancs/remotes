@echo off
rem rms - starts the Remotes picker with every target.
rem remotes.ps1 sits next to this file (%~dp0 is the folder of this launcher).
rem All arguments are passed on, so typing a word after "rms" pre-fills the search.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0remotes.ps1" %*
exit /b %ERRORLEVEL%
