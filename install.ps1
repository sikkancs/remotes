<#
.SYNOPSIS
    Remotes installer (Windows).

.DESCRIPTION
    Installs everything into ONE folder, %USERPROFILE%\.config\remotes:

      bin\remotes.ps1                 the picker itself
      bin\rms.cmd, remotes.cmd        launchers: every target
      bin\sshs.cmd, rdps.cmd, webs.cmd  launchers: one type only
      samples\*.sample                reference files for new records
      hosts\                          YOUR records (the installer never changes their content)

    The folder bin\ is added to your USER path (no administrator rights needed),
    so rms, remotes, sshs, rdps and webs work in cmd, PowerShell and Windows Terminal.

    Behaviour:
      - Dependencies are never installed automatically. If something is missing,
        the installer lists what and how to install it, and copies NO files.
      - Files are downloaded to a temporary folder first and verified; nothing
        is touched unless every download succeeded.
      - An existing file with different content is kept as <name>.bak.<timestamp>.

.PARAMETER Uninstall
    Remove the installed files and the path entry (your records are kept).

.PARAMETER NoPath
    Do not change the user path.

.EXAMPLE
    irm https://raw.githubusercontent.com/sikkancs/remotes/main/install.ps1 | iex

.EXAMPLE
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/sikkancs/remotes/main/install.ps1))) -NoPath
#>

param(
    [switch]$Uninstall,
    [switch]$NoPath,
    [switch]$Help
)

function Invoke-RemotesInstall {
    param([bool]$DoUninstall, [bool]$SkipPath, [bool]$ShowHelp)

    $ErrorActionPreference = 'Stop'

    # -------------------------------------------------------------------------
    # Settings
    # -------------------------------------------------------------------------

    # Where the files are downloaded from (always the main branch).
    $RawBase = 'https://raw.githubusercontent.com/sikkancs/remotes/main'

    # The one folder of the whole application.
    $RootDir = Join-Path (Join-Path $HOME '.config') 'remotes'
    $BinDir = Join-Path $RootDir 'bin'
    $HostsDir = Join-Path $RootDir 'hosts'
    $SamplesDir = Join-Path $RootDir 'samples'

    # The entry added to the user path (kept unexpanded, so it follows the profile).
    $PathEntry = '%USERPROFILE%\.config\remotes\bin'

    # Files to install: source path in the repository, destination, kind.
    $Files = @(
        @{ Source = 'windows/remotes.ps1';  Dest = (Join-Path $BinDir 'remotes.ps1');   Kind = 'script' },
        @{ Source = 'windows/rms.cmd';      Dest = (Join-Path $BinDir 'rms.cmd');       Kind = 'cmd' },
        @{ Source = 'windows/remotes.cmd';  Dest = (Join-Path $BinDir 'remotes.cmd');   Kind = 'cmd' },
        @{ Source = 'windows/sshs.cmd';     Dest = (Join-Path $BinDir 'sshs.cmd');      Kind = 'cmd' },
        @{ Source = 'windows/rdps.cmd';     Dest = (Join-Path $BinDir 'rdps.cmd');      Kind = 'cmd' },
        @{ Source = 'windows/webs.cmd';     Dest = (Join-Path $BinDir 'webs.cmd');      Kind = 'cmd' },
        @{ Source = 'samples/ssh.sample';   Dest = (Join-Path $SamplesDir 'ssh.sample'); Kind = 'sample' },
        @{ Source = 'samples/rdp.sample';   Dest = (Join-Path $SamplesDir 'rdp.sample'); Kind = 'sample' },
        @{ Source = 'samples/web.sample';   Dest = (Join-Path $SamplesDir 'web.sample'); Kind = 'sample' }
    )

    # -------------------------------------------------------------------------
    # Helpers
    # -------------------------------------------------------------------------

    function Write-Info {
        param([string]$Text)
        Write-Host $Text
    }

    function Write-Failure {
        param([string]$Text)
        Write-Host $Text -ForegroundColor Red
    }

    function Test-WindowsPlatform {
        return ([Environment]::OSVersion.Platform -eq 'Win32NT')
    }

    function Get-StaleLauncherNotes {
        # Launchers named like ours that live somewhere else (for example the
        # older standalone sshs.cmd / rdps.cmd / webs.cmd).
        $Notes = New-Object System.Collections.Generic.List[string]

        foreach ($Name in @('rms', 'remotes', 'sshs', 'rdps', 'webs')) {
            foreach ($Found in @(Get-Command $Name -All -ErrorAction SilentlyContinue)) {
                if ($Found.CommandType -ne 'Application') { continue }

                $Where = [string]$Found.Source
                if ($Where -ne '' -and -not $Where.StartsWith($BinDir, [StringComparison]::OrdinalIgnoreCase)) {
                    $Notes.Add(('  {0} is also found at {1}' -f $Name, $Where))
                }
            }
        }

        return @($Notes.ToArray())
    }

    function Update-UserPath {
        # Add ($true) or remove ($false) the bin folder in the USER path, directly
        # in the registry so that unexpanded entries such as %USERPROFILE% stay
        # unexpanded. The entry goes to the front, so these launchers win over
        # same-named older ones in other user path folders.
        param([bool]$Add)

        $Key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
        try {
            $Current = [string]$Key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $Parts = @($Current -split ';' | Where-Object { $_ -ne '' })

            # Compare the expanded forms, ignoring case and a trailing backslash.
            $Wanted = [Environment]::ExpandEnvironmentVariables($PathEntry).TrimEnd('\')
            $Present = $false
            $Kept = New-Object System.Collections.Generic.List[string]

            foreach ($Part in $Parts) {
                $Expanded = [Environment]::ExpandEnvironmentVariables($Part).TrimEnd('\')
                if ($Expanded -ieq $Wanted) {
                    $Present = $true
                }
                else {
                    $Kept.Add($Part)
                }
            }

            if ($Add -and $Present) {
                return 'present'
            }

            if (-not $Add -and -not $Present) {
                return 'absent'
            }

            if ($Add) {
                $New = (@($PathEntry) + $Kept.ToArray()) -join ';'
            }
            else {
                $New = $Kept.ToArray() -join ';'
            }

            $Key.SetValue('Path', $New, [Microsoft.Win32.RegistryValueKind]::ExpandString)
        }
        finally {
            $Key.Close()
        }

        # Tell running programs (Explorer, new terminal windows) that the
        # environment changed.
        try {
            $Signature = '[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);'
            Add-Type -MemberDefinition $Signature -Name 'NativeMethods' -Namespace 'RemotesInstaller' -ErrorAction Stop
            $Result = [UIntPtr]::Zero
            [void][RemotesInstaller.NativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$Result)
        }
        catch {
            Write-Info '  (could not notify running programs; sign out and in if rms is not found in a new window)'
        }

        if ($Add) { return 'added' }
        return 'removed'
    }

    # -------------------------------------------------------------------------
    # Help, platform
    # -------------------------------------------------------------------------

    if ($ShowHelp) {
        Write-Info 'Remotes installer (Windows)'
        Write-Info ''
        Write-Info 'Options:'
        Write-Info '  -Uninstall   Remove the installed files and the path entry (your records stay)'
        Write-Info '  -NoPath      Do not change the user path'
        Write-Info '  -Help        Show this help'
        Write-Info ''
        Write-Info 'With the one-liner, pass options like this:'
        Write-Info '  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/sikkancs/remotes/main/install.ps1))) -NoPath'
        return
    }

    if (-not (Test-WindowsPlatform)) {
        Write-Failure 'Error: this installer is for Windows. On macOS use install.sh.'
        return
    }

    # -------------------------------------------------------------------------
    # Uninstall
    # -------------------------------------------------------------------------

    if ($DoUninstall) {
        Write-Info "Removing Remotes (your records in $HostsDir are kept)."

        foreach ($Item in $Files) {
            if (Test-Path -LiteralPath $Item.Dest -PathType Leaf) {
                Remove-Item -LiteralPath $Item.Dest -Force
                Write-Info ('  removed    {0}' -f $Item.Dest)
            }
        }

        # Remove the folders when nothing is left in them (hosts\ and recent
        # keep the root folder alive).
        foreach ($Folder in @($BinDir, $SamplesDir)) {
            if ((Test-Path -LiteralPath $Folder) -and @(Get-ChildItem -LiteralPath $Folder -Force).Count -eq 0) {
                Remove-Item -LiteralPath $Folder -Force
            }
        }
        if ((Test-Path -LiteralPath $RootDir) -and @(Get-ChildItem -LiteralPath $RootDir -Force).Count -eq 0) {
            Remove-Item -LiteralPath $RootDir -Force
        }

        if (-not $SkipPath) {
            $State = Update-UserPath -Add $false
            Write-Info ('  user path  {0}' -f $State)
        }

        Write-Info ''
        Write-Info "Left in place: $HostsDir (your records), $RootDir\recent, and any *.bak.* backups."
        Write-Info 'Open a new terminal window so the removed commands disappear.'
        return
    }

    # -------------------------------------------------------------------------
    # Dependency check (nothing is installed here)
    # -------------------------------------------------------------------------

    $MissingNames = New-Object System.Collections.Generic.List[string]
    $MissingHints = New-Object System.Collections.Generic.List[string]

    if ($PSVersionTable.PSVersion.Major -lt 5) {
        $MissingNames.Add('PowerShell 5.1')
        $MissingHints.Add('update Windows PowerShell (Windows Management Framework 5.1)')
    }

    if (-not (Get-Command 'fzf.exe' -ErrorAction SilentlyContinue)) {
        $MissingNames.Add('fzf')
        $MissingHints.Add('winget install --id junegunn.fzf -e   (or: scoop install fzf / choco install fzf)')
    }

    $OpenSshHint = 'Settings > Apps > Optional features > OpenSSH Client, or in an administrator PowerShell: Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0'

    if (-not (Get-Command 'ssh.exe' -ErrorAction SilentlyContinue)) {
        $MissingNames.Add('ssh.exe')
        $MissingHints.Add($OpenSshHint)
    }

    if (-not (Get-Command 'ssh-keygen.exe' -ErrorAction SilentlyContinue)) {
        $MissingNames.Add('ssh-keygen.exe')
        $MissingHints.Add($OpenSshHint)
    }

    if ($MissingNames.Count -gt 0) {
        Write-Failure 'Missing dependencies. Nothing was installed.'
        Write-Info ''
        for ($Index = 0; $Index -lt $MissingNames.Count; $Index++) {
            Write-Info ('  {0,-15} {1}' -f $MissingNames[$Index], $MissingHints[$Index])
        }
        Write-Info ''
        Write-Info 'Install the missing items, open a new terminal window, then run the installer again.'
        return
    }

    # -------------------------------------------------------------------------
    # Download to a staging folder
    # -------------------------------------------------------------------------

    # GitHub needs TLS 1.2, which older Windows PowerShell does not use by default.
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch {
        # Newer systems already negotiate a suitable protocol.
    }

    $Stage = Join-Path ([System.IO.Path]::GetTempPath()) ('remotes-install-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $Stage -Force | Out-Null

    try {
        Write-Info "Installing Remotes from $RawBase"

        $Index = 0
        foreach ($Item in $Files) {
            $Staged = Join-Path $Stage ([string]$Index)
            $Url = '{0}/{1}' -f $RawBase, $Item.Source

            Write-Info ('  downloading {0}' -f $Item.Source)

            $Client = New-Object System.Net.WebClient
            try {
                $Client.DownloadFile($Url, $Staged)
            }
            catch {
                Write-Failure ('Download failed: {0}' -f $Url)
                Write-Failure 'Nothing was installed.'
                return
            }
            finally {
                $Client.Dispose()
            }

            # The file must not be empty and must look like what it should be
            # (this catches HTML error pages).
            $Bytes = [System.IO.File]::ReadAllBytes($Staged)
            if ($Bytes.Length -eq 0) {
                Write-Failure ('Empty file received for {0}. Nothing was installed.' -f $Item.Source)
                return
            }

            $Text = [System.Text.Encoding]::UTF8.GetString($Bytes)

            if ($Item.Kind -eq 'script' -and -not $Text.TrimStart([char]0xFEFF).StartsWith('<#')) {
                Write-Failure ('{0} does not look like the expected script. Nothing was installed.' -f $Item.Source)
                return
            }

            if ($Item.Kind -eq 'cmd') {
                if (-not $Text.TrimStart([char]0xFEFF).StartsWith('@echo off')) {
                    Write-Failure ('{0} does not look like the expected launcher. Nothing was installed.' -f $Item.Source)
                    return
                }

                # Batch files need CRLF line endings, whatever the download had.
                $Normalized = ($Text.TrimStart([char]0xFEFF) -replace "`r?`n", "`r`n")
                [System.IO.File]::WriteAllText($Staged, $Normalized, (New-Object System.Text.ASCIIEncoding))
            }

            if ($Item.Kind -eq 'sample' -and $Text.TrimStart().StartsWith('<')) {
                Write-Failure ('{0} does not look like a sample file. Nothing was installed.' -f $Item.Source)
                return
            }

            $Item.Staged = $Staged
            $Index++
        }

        # ---------------------------------------------------------------------
        # Install the staged files
        # ---------------------------------------------------------------------

        $Stamp = Get-Date -Format 'yyyyMMddHHmmss'

        Write-Info ''
        Write-Info 'Files:'

        foreach ($Item in $Files) {
            $Folder = Split-Path -Parent $Item.Dest
            if (-not (Test-Path -LiteralPath $Folder -PathType Container)) {
                New-Item -ItemType Directory -Path $Folder -Force | Out-Null
            }

            if (Test-Path -LiteralPath $Item.Dest -PathType Leaf) {
                $SameContent = ((Get-FileHash -LiteralPath $Item.Staged).Hash -eq (Get-FileHash -LiteralPath $Item.Dest).Hash)

                if ($SameContent) {
                    Write-Info ('  unchanged  {0}' -f $Item.Dest)
                    continue
                }

                # Different content: keep the old file next to the new one.
                $Backup = '{0}.bak.{1}' -f $Item.Dest, $Stamp
                Copy-Item -LiteralPath $Item.Dest -Destination $Backup -Force
                Copy-Item -LiteralPath $Item.Staged -Destination $Item.Dest -Force
                Write-Info ('  updated    {0}   (old version: {1})' -f $Item.Dest, $Backup)
            }
            else {
                Copy-Item -LiteralPath $Item.Staged -Destination $Item.Dest -Force
                Write-Info ('  installed  {0}' -f $Item.Dest)
            }
        }

        # The folder for the user's own records.
        if (-not (Test-Path -LiteralPath $HostsDir -PathType Container)) {
            New-Item -ItemType Directory -Path $HostsDir -Force | Out-Null
        }
    }
    finally {
        if (Test-Path -LiteralPath $Stage) {
            Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # -------------------------------------------------------------------------
    # User path
    # -------------------------------------------------------------------------

    Write-Info ''
    if ($SkipPath) {
        Write-Info 'User path left unchanged (-NoPath).'
        Write-Info "Start the picker with: powershell -File `"$BinDir\remotes.ps1`""
    }
    else {
        Write-Info 'User path:'
        $State = Update-UserPath -Add $true
        Write-Info ('  {0}  {1}' -f $State, $PathEntry)

        # Make the commands work in this window right away.
        if (($env:Path -split ';') -notcontains $BinDir) {
            $env:Path = $BinDir + ';' + $env:Path
        }
    }

    # -------------------------------------------------------------------------
    # Notes about older setups
    # -------------------------------------------------------------------------

    $StaleNotes = @(Get-StaleLauncherNotes)
    if ($StaleNotes.Count -gt 0) {
        Write-Info ''
        Write-Info 'Note: commands with the same names exist elsewhere (older standalone launchers):'
        foreach ($Note in $StaleNotes) { Write-Info $Note }
        Write-Info 'The Remotes folder is first in your user path, so it wins in new windows; remove or rename'
        Write-Info 'the old ones if a command still starts the old program.'
    }

    $OldFolders = @(
        (Join-Path $HOME '.rdps'),
        (Join-Path $HOME '.webs'),
        (Join-Path (Join-Path $HOME '.ssh') 'config.d')
    ) | Where-Object { Test-Path -LiteralPath $_ }

    if (@($OldFolders).Count -gt 0) {
        Write-Info ''
        Write-Info 'Note: records of the older standalone tools were found. Remotes does not read these folders:'
        foreach ($Old in $OldFolders) { Write-Info ('  {0}' -f $Old) }
        Write-Info 'Copy the files you still need into your records folder, named by type, for example:'
        Write-Info ('  {0}\customer-a\customer-a-ssh.conf   (from .ssh\config.d)' -f $HostsDir)
        Write-Info ('  {0}\customer-a\customer-a-rdp.conf   (from .rdps\config.d)' -f $HostsDir)
        Write-Info ('  {0}\customer-a\customer-a-web.conf   (from .webs\config.d)' -f $HostsDir)
    }

    # -------------------------------------------------------------------------
    # Next steps and optional tools
    # -------------------------------------------------------------------------

    Write-Info ''
    Write-Info 'Done. Next steps:'
    if (-not $SkipPath) {
        Write-Info '  1. Open a new terminal window (rms already works in this one)'
    }
    else {
        Write-Info '  1. Add this folder to your path, or start the picker by its full path'
    }
    Write-Info '  2. Create your first records from a sample, for example:'
    Write-Info ('       New-Item -ItemType Directory "{0}\mycustomer"' -f $HostsDir)
    Write-Info ('       Copy-Item "{0}\ssh.sample" "{1}\mycustomer\mycustomer-ssh.conf"' -f $SamplesDir, $HostsDir)
    Write-Info '  3. Start the picker: rms   (long form: remotes; per type: sshs, rdps, webs)'

    $Optional = New-Object System.Collections.Generic.List[string]
    if (-not (Get-Command 'mstsc.exe' -ErrorAction SilentlyContinue)) {
        $Optional.Add('  - RDP targets use mstsc.exe (Remote Desktop Connection), which was not found.')
    }
    if (-not (Get-Command 'code.cmd' -ErrorAction SilentlyContinue)) {
        $Optional.Add("  - Ctrl+E (edit source file) uses the VS Code 'code.cmd' command, which was not found; or set REMOTES_EDITOR.")
    }
    if ($Optional.Count -gt 0) {
        Write-Info ''
        Write-Info 'Optional (not required):'
        foreach ($Line in $Optional) { Write-Info $Line }
    }
}

Invoke-RemotesInstall -DoUninstall ([bool]$Uninstall) -SkipPath ([bool]$NoPath) -ShowHelp ([bool]$Help)
