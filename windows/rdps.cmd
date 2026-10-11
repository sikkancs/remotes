@echo off
rem rdps - starts the Remotes picker limited to RDP targets.
rem remotes.ps1 sits next to this file (%~dp0 is the folder of this launcher).
rem All arguments are passed on, so typing a word after "rdps" pre-fills the search.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0remotes.ps1" -Type rdp %*
exit /b %ERRORLEVEL%
