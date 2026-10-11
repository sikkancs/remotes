@echo off
rem webs - starts the Remotes picker limited to web targets.
rem remotes.ps1 sits next to this file (%~dp0 is the folder of this launcher).
rem All arguments are passed on, so typing a word after "webs" pre-fills the search.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0remotes.ps1" -Type web %*
exit /b %ERRORLEVEL%
