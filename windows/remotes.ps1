<#
.SYNOPSIS
    Remotes - one interactive picker for SSH, RDP and web GUI targets (Windows).

.DESCRIPTION
    Written for Windows PowerShell 5.1 (also runs on PowerShell 7).

    Everything lives in ONE folder, %USERPROFILE%\.config\remotes (override: REMOTES_HOME):

      bin\       program, replaced by the installer on update
      hosts\     YOUR records (the installer never changes their content)
        customer-a\                   one folder per customer or group
          customer-a-ssh.conf         ssh_config syntax (Host, HostName, User, ...)
          customer-a-rdp.conf         Host, HostName, User, Mode, Screen, RdpOption
          customer-a-web.conf         Host, URL, Browser, Profile, BrowserArgs
          dc-rdp.conf                 any number of files per type is fine
        lab-ssh.conf                  files directly in hosts\ work too
        ssh.conf                      plain names work too (group "general")
      samples\   reference files for new records
      recent     recently used targets (created automatically)

    File names decide the type: the name must be ssh.conf, rdp.conf, web.conf or
    end with -ssh.conf, -rdp.conf, -web.conf. Everything else is ignored, as are
    hidden files and folders. The group (a searchable column) is the first folder
    below hosts\; for files directly in hosts\ it is the name before the suffix.

    File defaults (rdp and web files only): a "Host *" block holds defaults for
    all records of the SAME file. A record value always wins over the default,
    RdpOption lines add up (default first, then the record), tags are combined.
    In ssh files "Host *" keeps its normal ssh_config meaning.

    The main %USERPROFILE%\.ssh\config is still listed (group "ssh-config").
    SSH connections go through a temporary ssh config that includes every listed
    ssh file, so the main config needs no Include line for Remotes itself.

    Dependencies:
      - fzf.exe
      - OpenSSH client (ssh.exe, ssh-keygen.exe) for SSH targets
      - mstsc.exe (built into Windows) for RDP targets
      - Optional: code.cmd (VS Code) for Ctrl+E
#>

[CmdletBinding()]
param(
    [Alias('h')]
    [switch]$Help,

    # Limit the list to one type: ssh, rdp or web.
    [Alias('t')]
    [string]$Type = '',

    # Remaining arguments become the initial search query. "--type ssh" and
    # "--help" (the macOS spelling) are understood here as well.
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Query
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Settings (every value can be overridden with an environment variable)
# -----------------------------------------------------------------------------

# Root folder of everything (program, records, samples, state).
$RemotesHome = if ($env:REMOTES_HOME) {
    [Environment]::ExpandEnvironmentVariables($env:REMOTES_HOME)
} else {
    Join-Path (Join-Path $HOME '.config') 'remotes'
}

# Folder holding the per group record folders and files.
$HostsDirectory = Join-Path $RemotesHome 'hosts'

# File storing the most recently used targets as "type:alias" lines.
$RecentFile = Join-Path $RemotesHome 'recent'

# How many recent targets are pinned to the top, and how many are remembered.
$MaximumRecent = 5
$RecentKeep = 20

# Existing main ssh config; set REMOTES_SSH_CONFIG to an empty value to hide it.
$SshMainConfig = if (Test-Path 'Env:REMOTES_SSH_CONFIG') {
    [string]$env:REMOTES_SSH_CONFIG
} else {
    Join-Path (Join-Path $HOME '.ssh') 'config'
}

# Editor command used by Ctrl+E (may contain arguments).
$EditorCommand = if ($env:REMOTES_EDITOR) { $env:REMOTES_EDITOR } else { 'code.cmd' }

# Browser used for web targets without their own Browser key ('default' = system default).
$DefaultBrowser = if ($env:REMOTES_BROWSER) { $env:REMOTES_BROWSER.Trim() } else { 'default' }

# Ask for a user name when an ssh target has none (REMOTES_ASK_USER=0 switches it off).
$AskUser = ($env:REMOTES_ASK_USER -ne '0')

# Folder for generated .rdp files (files older than 12 hours are removed).
$RdpTempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) 'remotes-rdp'

# UTF-8 without BOM for every text file this script writes.
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Temporary files created during a run; removed in the finally block.
$script:PreviewDirectory = $null
$script:SshConfigFile = $null

# -----------------------------------------------------------------------------
# Argument handling
# -----------------------------------------------------------------------------

# Words typed after the command: options in the macOS spelling are picked out,
# everything else becomes the search query.
$TypeFilter = $Type
$QueryWords = New-Object System.Collections.Generic.List[string]
$Words = @($Query | Where-Object { $null -ne $_ })

for ($WordIndex = 0; $WordIndex -lt $Words.Count; $WordIndex++) {
    $Word = [string]$Words[$WordIndex]

    if ($Word -eq '--help') {
        $Help = $true
        continue
    }

    if ($Word -eq '--type') {
        if ($WordIndex + 1 -ge $Words.Count) {
            throw '--type needs a value: ssh, rdp or web.'
        }
        $TypeFilter = [string]$Words[$WordIndex + 1]
        $WordIndex++
        continue
    }

    if ($Word.StartsWith('--type=')) {
        $TypeFilter = $Word.Substring(7)
        continue
    }

    $QueryWords.Add($Word)
}

$TypeFilter = $TypeFilter.Trim().ToLowerInvariant()
$QueryText = ($QueryWords.ToArray() -join ' ').Trim()

function Show-Usage {
    @'
Remotes - SSH, RDP and web GUI picker for Windows

Usage:
  rms                         Launch the menu with every target
  rms <query>                 Pre-fill the search; a single match connects at once
  rms --type ssh|rdp|web      Limit the list to one type (also: -Type ssh)
  rms -h | --help             Show this help

  sshs, rdps and webs are the same program limited to one type.

Records (one folder per customer or group):
  %USERPROFILE%\.config\remotes\hosts\<group>\<anything>-ssh.conf
  %USERPROFILE%\.config\remotes\hosts\<group>\<anything>-rdp.conf
  %USERPROFILE%\.config\remotes\hosts\<group>\<anything>-web.conf
  Plain ssh.conf, rdp.conf and web.conf names work too, and files may also
  sit directly in the hosts folder.

Keys:
  ssh.conf   normal ssh_config syntax; "# Tags a b c" adds search tags
  rdp.conf   HostName (required), User, Mode (User|Admin),
             Screen (Full|Window|WIDTHxHEIGHT), RdpOption <raw .rdp line> (repeatable)
  web.conf   URL, or HostName + Port + Scheme; Browser, Profile, BrowserArgs

RDP on Windows opens full screen by default (mstsc windows cannot be resized
reliably). Use "Screen Window" or "Screen 1600x900" for a window.

File defaults (rdp.conf and web.conf only): a "Host *" block sets defaults for
all records of the same file; a record value wins over the default.

SSH without a User: the user name is asked for before connecting (Enter keeps
your Windows login name). Set REMOTES_ASK_USER=0 to switch this off.

Menu keys:
  Enter        Connect (ssh, mstsc, or browser, depending on the type)
  Ctrl+V       SSH only: verbose connection (ssh -vvvv)
  Ctrl+R       SSH only: remove the host key from known_hosts (ssh-keygen -R)
  Ctrl+E       Open the source file in the editor (REMOTES_EDITOR, default: code.cmd)
  ?            Toggle preview
  Esc/Ctrl+C   Exit

Environment variables:
  REMOTES_HOME (default %USERPROFILE%\.config\remotes), REMOTES_SSH_CONFIG,
  REMOTES_EDITOR, REMOTES_BROWSER, REMOTES_ASK_USER
'@
}

# -----------------------------------------------------------------------------
# Small helpers
# -----------------------------------------------------------------------------

function Assert-Command {
    # Stop with a helpful message when a required command is missing.
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Hint
    )

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $Name`r`n$Hint"
    }
}

function Join-Words {
    # Join two word lists with a space; empty parts are skipped.
    param([string]$First, [string]$Second)

    if ($First -eq '') { return $Second }
    if ($Second -eq '') { return $First }
    return ($First + ' ' + $Second)
}

function ConvertTo-FzfField {
    # Make a value safe for a tab separated fzf line.
    param([AllowEmptyString()][AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return ''
    }

    return ($Value.Replace("`t", ' ').Replace("`r", ' ').Replace("`n", ' '))
}

# -----------------------------------------------------------------------------
# Finding the record files
# -----------------------------------------------------------------------------

function Get-RecordType {
    # The file name decides the type: ssh.conf, rdp.conf, web.conf or *-ssh.conf, ...
    param([string]$FileName)

    $Lower = $FileName.ToLowerInvariant()

    foreach ($Kind in @('ssh', 'rdp', 'web')) {
        if ($Lower -eq ($Kind + '.conf') -or $Lower.EndsWith('-' + $Kind + '.conf')) {
            return $Kind
        }
    }

    return ''
}

function Get-SourceFiles {
    # All files to read, in reading order: records below hosts\ in path order,
    # the main ssh config last.
    $Result = New-Object System.Collections.Generic.List[object]

    if (Test-Path -LiteralPath $HostsDirectory -PathType Container) {
        $Root = (Resolve-Path -LiteralPath $HostsDirectory).Path.TrimEnd('\', '/')
        $Found = New-Object System.Collections.Generic.List[object]

        foreach ($File in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.conf' -ErrorAction SilentlyContinue)) {
            # Path relative to hosts\, split into its parts.
            $Relative = $File.FullName.Substring($Root.Length).TrimStart('\', '/')
            $Parts = @($Relative -split '[\\/]')

            # Hidden files and folders (names starting with a dot) are ignored.
            $Hidden = $false
            foreach ($Part in $Parts) {
                if ($Part.StartsWith('.')) { $Hidden = $true }
            }
            if ($Hidden) { continue }

            $Kind = Get-RecordType -FileName $File.Name
            if ($Kind -eq '') { continue }
            if ($TypeFilter -ne '' -and $TypeFilter -ne $Kind) { continue }

            # Group: first folder below hosts\; for files directly in hosts\ the
            # name before the type suffix ("general" for a plain ssh.conf).
            if ($Parts.Count -gt 1) {
                $Group = $Parts[0]
            }
            else {
                $Group = $File.Name.Substring(0, $File.Name.Length - 5)
                if ($Group.ToLowerInvariant().EndsWith('-' + $Kind)) {
                    $Group = $Group.Substring(0, $Group.Length - $Kind.Length - 1)
                }
                elseif ($Group.ToLowerInvariant() -eq $Kind) {
                    $Group = 'general'
                }
            }

            $Found.Add([pscustomobject]@{
                Path     = $File.FullName
                Type     = $Kind
                Group    = $Group
                Relative = $Relative
            })
        }

        foreach ($Item in @($Found.ToArray() | Sort-Object Relative)) {
            $Result.Add($Item)
        }
    }

    # The main ssh config goes last, so group files win on duplicate aliases
    # (the same order the effective ssh config uses).
    if (($TypeFilter -eq '' -or $TypeFilter -eq 'ssh') -and $SshMainConfig -ne '' -and
        (Test-Path -LiteralPath $SshMainConfig -PathType Leaf)) {
        $Result.Add([pscustomobject]@{
            Path     = (Resolve-Path -LiteralPath $SshMainConfig).Path
            Type     = 'ssh'
            Group    = 'ssh-config'
            Relative = ''
        })
    }

    return @($Result.ToArray())
}

# -----------------------------------------------------------------------------
# Parsing one record file
# -----------------------------------------------------------------------------

function ConvertTo-LineValue {
    # Value part of a "Key value" line. A quoted value keeps everything between
    # the quotes; an unquoted value ends at an inline comment (whitespace + #).
    param([string]$Line)

    $Value = ''
    if ($Line -match '^\s*\S+\s+(.*)$') {
        $Value = $Matches[1].Trim()
    }

    if ($Value.Length -ge 1 -and ($Value[0] -eq '"' -or $Value[0] -eq "'")) {
        $Quote = [string]$Value[0]
        $Rest = $Value.Substring(1)
        $EndQuote = $Rest.IndexOf($Quote)

        if ($EndQuote -ge 0) {
            return $Rest.Substring(0, $EndQuote)
        }
    }

    return (($Value -replace '\s+#.*$', '').Trim())
}

function New-Block {
    # One Host block under construction.
    return @{
        Aliases    = New-Object System.Collections.Generic.List[string]
        IsDefaults = $false
        Settings   = @{}
        RdpOptions = New-Object System.Collections.Generic.List[string]
        Tags       = ''
        Raw        = New-Object System.Collections.Generic.List[object]
    }
}

function Add-FinishedBlock {
    # A "Host *" block of an rdp or web file is kept as the defaults of its file;
    # every other block waits until the whole file has been read.
    param([hashtable]$State, [hashtable]$Block)

    if ($Block.IsDefaults) {
        $Defaults = $State.Defaults

        # First value of every key wins; repeatable values add up.
        foreach ($Key in @($Block.Settings.Keys)) {
            if (-not $Defaults.Settings.ContainsKey($Key)) {
                $Defaults.Settings[$Key] = $Block.Settings[$Key]
            }
        }

        foreach ($Option in $Block.RdpOptions) {
            $Defaults.RdpOptions.Add($Option)
        }

        $Defaults.Tags = Join-Words $Defaults.Tags $Block.Tags

        foreach ($Pair in $Block.Raw) {
            $Defaults.Raw.Add($Pair)
        }
    }
    elseif ($Block.Aliases.Count -gt 0) {
        $State.Blocks.Add($Block)
    }
}

function Get-OwnValue {
    # Value a block sets itself ('' when it does not set the key).
    param([hashtable]$Block, [string]$Key)

    if ($Block.Settings.ContainsKey($Key)) {
        return [string]$Block.Settings[$Key]
    }

    return ''
}

function Resolve-WebUrl {
    # Build the final address from URL or HostName + Scheme + Port.
    param([string]$Url, [string]$HostName, [string]$Port, [string]$Scheme)

    if ($Url -ne '') {
        # Add https:// when the scheme is missing.
        if ($Url -notmatch '^[A-Za-z][A-Za-z0-9+.\-]*://') {
            return ('https://' + $Url)
        }
        return $Url
    }

    if ($HostName -eq '') {
        return ''
    }

    if ($Scheme -eq '') {
        $Scheme = 'https'
    }

    $Address = '{0}://{1}' -f $Scheme.ToLowerInvariant(), $HostName
    if ($Port -ne '') {
        $Address = '{0}:{1}' -f $Address, $Port
    }

    return ($Address + '/')
}

function New-EntriesFromBlock {
    # Merge one block with the file defaults and create one entry per alias.
    # Blocks that cannot be used (rdp without HostName, web without address) give none.
    param([hashtable]$Block, [hashtable]$Defaults, [object]$File)

    # Record value wins, otherwise the default of the file.
    $Merged = @{}
    foreach ($Key in @('hostname', 'user', 'port', 'scheme', 'url', 'browser', 'profile', 'browserargs', 'mode', 'screen')) {
        $Own = Get-OwnValue -Block $Block -Key $Key
        if ($Own -ne '') {
            $Merged[$Key] = $Own
        }
        else {
            $Merged[$Key] = Get-OwnValue -Block $Defaults -Key $Key
        }
    }

    # Profile and BrowserArgs belong to one browser: when the record picks a
    # different browser than the default, only its own values count.
    $OwnBrowser = Get-OwnValue -Block $Block -Key 'browser'
    $DefaultBrowserKey = Get-OwnValue -Block $Defaults -Key 'browser'
    if ($OwnBrowser -ne '' -and $OwnBrowser -ne $DefaultBrowserKey) {
        $Merged['profile'] = Get-OwnValue -Block $Block -Key 'profile'
        $Merged['browserargs'] = Get-OwnValue -Block $Block -Key 'browserargs'
    }

    # Raw RdpOption lines: defaults first, then the record (so it can override).
    $RdpOptions = New-Object System.Collections.Generic.List[string]
    foreach ($Option in $Defaults.RdpOptions) { $RdpOptions.Add($Option) }
    foreach ($Option in $Block.RdpOptions) { $RdpOptions.Add($Option) }

    $Tags = Join-Words $Defaults.Tags $Block.Tags

    $Target = ''
    $Info = ''
    $Usable = $false

    switch ($File.Type) {
        'ssh' {
            # ssh needs no address of its own; the alias is enough.
            $Usable = $true
            $Target = $Merged['hostname']
            $Info = $Merged['user']
        }
        'rdp' {
            # RDP needs a HostName.
            if ($Merged['hostname'] -ne '') {
                $Usable = $true
                $Target = $Merged['hostname']
                $Info = if ($Merged['mode'] -ieq 'admin') { 'ADMIN' } else { 'USER' }
            }
        }
        'web' {
            # Web needs a URL or a HostName.
            $Target = Resolve-WebUrl -Url $Merged['url'] -HostName $Merged['hostname'] -Port $Merged['port'] -Scheme $Merged['scheme']
            if ($Target -ne '') {
                $Usable = $true
                $Info = if ($Merged['browser'] -ne '') { $Merged['browser'] } else { $DefaultBrowser }
            }
        }
    }

    $Entries = New-Object System.Collections.Generic.List[object]

    if (-not $Usable) {
        return @()
    }

    foreach ($Alias in $Block.Aliases) {
        $Display = $Alias
        if ($Target -ne '' -and $Target -ne $Alias) {
            $Display = '{0} ({1})' -f $Alias, $Target
        }

        $Entries.Add([pscustomobject]@{
            Key         = ('{0}:{1}' -f $File.Type, $Alias)
            LType       = $File.Type
            TypeLabel   = $File.Type.ToUpperInvariant()
            Alias       = $Alias
            Display     = $Display
            Info        = $Info
            Tags        = $Tags
            Group       = $File.Group
            Path        = $File.Path
            Target      = $Target
            User        = $Merged['user']
            Mode        = $Merged['mode']
            Screen      = $Merged['screen']
            RdpOptions  = [string[]]$RdpOptions.ToArray()
            Browser     = $Merged['browser']
            BrowserProfile = $Merged['profile']
            BrowserArgs = $Merged['browserargs']
            RecordRaw   = $Block.Raw.ToArray()
            DefaultsRaw = $Defaults.Raw.ToArray()
            PreviewPath = ''
        })
    }

    return @($Entries.ToArray())
}

function Read-SourceFile {
    # Parse one record file into entries (file defaults already applied).
    param([Parameter(Mandatory = $true)][object]$File)

    $State = @{
        Defaults = New-Block
        Blocks   = New-Object System.Collections.Generic.List[object]
    }

    $Current = $null

    foreach ($RawLine in [System.IO.File]::ReadAllLines($File.Path)) {
        $Line = [string]$RawLine
        $Trimmed = $Line.Trim()
        $Tokens = @($Trimmed -split '\s+')
        $Keyword = $Tokens[0].ToLowerInvariant()

        # A Host line starts a new block (and finishes the previous one).
        if ($Keyword -eq 'host' -and $Tokens.Count -ge 2) {
            if ($null -ne $Current) {
                Add-FinishedBlock -State $State -Block $Current
            }

            $Current = New-Block

            for ($TokenIndex = 1; $TokenIndex -lt $Tokens.Count; $TokenIndex++) {
                $Token = $Tokens[$TokenIndex]

                # Stop at an inline comment.
                if ($Token.StartsWith('#')) { break }

                # "Host *" in an rdp or web file holds the defaults of that file.
                if ($Token -eq '*' -and $File.Type -ne 'ssh') {
                    $Current.IsDefaults = $true
                    continue
                }

                # Hide wildcard, single character and negated patterns.
                if ($Token -match '[*?!]') { continue }

                $Current.Aliases.Add($Token)
            }

            continue
        }

        # A Match line ends the current block and is not listed.
        if ($Keyword -eq 'match') {
            if ($null -ne $Current) {
                Add-FinishedBlock -State $State -Block $Current
            }
            $Current = $null
            continue
        }

        # Lines outside any block are ignored.
        if ($null -eq $Current) {
            continue
        }

        # "# Tags a b c" comment inside the block.
        if ($Trimmed -match '^#\s*tags\s+(.+)$') {
            $Current.Tags = $Matches[1].Trim()
            continue
        }

        # Other comments and empty lines.
        if ($Trimmed -eq '' -or $Trimmed.StartsWith('#')) {
            continue
        }

        # "Key value" setting; the first occurrence of a key wins.
        $Value = ConvertTo-LineValue -Line $Line
        $Current.Raw.Add([pscustomobject]@{ Key = $Tokens[0]; Value = $Value })

        if ($Keyword -eq 'rdpoption') {
            # RdpOption may repeat; every occurrence is kept.
            $Current.RdpOptions.Add($Value)
        }
        elseif (-not $Current.Settings.ContainsKey($Keyword)) {
            $Current.Settings[$Keyword] = $Value
        }
    }

    # Finish the last block of the file.
    if ($null -ne $Current) {
        Add-FinishedBlock -State $State -Block $Current
    }

    # Now that the whole file is known, apply the defaults to every block.
    $Result = New-Object System.Collections.Generic.List[object]
    foreach ($Block in $State.Blocks) {
        foreach ($Entry in @(New-EntriesFromBlock -Block $Block -Defaults $State.Defaults -File $File)) {
            $Result.Add($Entry)
        }
    }

    return @($Result.ToArray())
}

function Get-AllEntries {
    # Read every file; the first definition of a type:alias wins.
    param([object[]]$Files)

    $Result = New-Object System.Collections.Generic.List[object]
    $Seen = @{}

    foreach ($File in $Files) {
        foreach ($Entry in @(Read-SourceFile -File $File)) {
            if (-not $Seen.ContainsKey($Entry.Key)) {
                $Seen[$Entry.Key] = $true
                $Result.Add($Entry)
            }
        }
    }

    return @($Result.ToArray())
}

# -----------------------------------------------------------------------------
# Recent list
# -----------------------------------------------------------------------------

function Get-RecentKeys {
    # Recent "type:alias" keys, most recent first, without duplicates.
    if (-not (Test-Path -LiteralPath $RecentFile -PathType Leaf)) {
        return @()
    }

    $Result = New-Object System.Collections.Generic.List[string]
    $Seen = @{}

    foreach ($Line in [System.IO.File]::ReadAllLines($RecentFile)) {
        $Name = $Line.Trim()

        if ($Name -eq '' -or $Seen.ContainsKey($Name)) {
            continue
        }

        $Seen[$Name] = $true
        $Result.Add($Name)
    }

    return @($Result.ToArray())
}

function Set-RecentKey {
    # Move one key to the top of the recent file and trim the file.
    param([Parameter(Mandatory = $true)][string]$Key)

    $Updated = New-Object System.Collections.Generic.List[string]
    $Updated.Add($Key)

    foreach ($Existing in @(Get-RecentKeys)) {
        if ($Existing -ne $Key -and $Updated.Count -lt $RecentKeep) {
            $Updated.Add($Existing)
        }
    }

    [System.IO.File]::WriteAllLines($RecentFile, [string[]]$Updated.ToArray(), $Utf8NoBom)
}

# -----------------------------------------------------------------------------
# Preview files
# -----------------------------------------------------------------------------

function Write-PreviewFile {
    # Write the preview text of one entry into a temp file (fzf shows it with "type").
    param(
        [Parameter(Mandatory = $true)][object]$Entry,
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][int]$Index
    )

    $PreviewPath = Join-Path $Directory ('{0:D5}.txt' -f $Index)

    # Widest key, for column alignment.
    $Width = 6
    foreach ($Pair in (@($Entry.RecordRaw) + @($Entry.DefaultsRaw))) {
        if ($Pair.Key.Length -gt $Width) { $Width = $Pair.Key.Length }
    }

    $Content = New-Object System.Collections.Generic.List[string]
    $Content.Add(('{0}  {1}' -f 'Type'.PadRight($Width), $Entry.TypeLabel))
    $Content.Add(('{0}  {1}' -f 'Group'.PadRight($Width), $Entry.Group))
    $Content.Add(('{0}  {1}' -f 'Source'.PadRight($Width), $Entry.Path))

    if ($Entry.Tags -ne '') {
        $Content.Add(('{0}  {1}' -f 'Tags'.PadRight($Width), $Entry.Tags))
    }

    $Content.Add('')

    foreach ($Pair in @($Entry.RecordRaw)) {
        $Content.Add(('{0}  {1}' -f $Pair.Key.PadRight($Width), $Pair.Value))
    }

    # File defaults apply to this record unless it sets the same key itself.
    if (@($Entry.DefaultsRaw).Count -gt 0) {
        $Content.Add('')
        $Content.Add('Defaults from this file (Host *):')

        foreach ($Pair in @($Entry.DefaultsRaw)) {
            $Content.Add(('{0}  {1}' -f $Pair.Key.PadRight($Width), $Pair.Value))
        }
    }

    [System.IO.File]::WriteAllLines($PreviewPath, [string[]]$Content.ToArray(), $Utf8NoBom)
    return $PreviewPath
}

# -----------------------------------------------------------------------------
# SSH
# -----------------------------------------------------------------------------

function New-SshConfigFile {
    # Create the effective ssh configuration used for connecting. It includes
    # every listed ssh file (the main config last), so connections work without
    # any Include line in the main ssh config. ssh reads it again for jump
    # hosts, so the file lives until the script exits.
    param([object[]]$Files)

    if ($null -ne $script:SshConfigFile) {
        return $script:SshConfigFile
    }

    $Lines = New-Object System.Collections.Generic.List[string]

    foreach ($File in $Files) {
        if ($File.Type -eq 'ssh') {
            # Forward slashes: ssh treats a backslash as an escape character.
            $Lines.Add(('Include "{0}"' -f $File.Path.Replace('\', '/')))
        }
    }

    $Path = Join-Path ([System.IO.Path]::GetTempPath()) ('remotes-ssh-' + [Guid]::NewGuid().ToString('N') + '.conf')
    [System.IO.File]::WriteAllLines($Path, [string[]]$Lines.ToArray(), $Utf8NoBom)

    $script:SshConfigFile = $Path
    return $Path
}

function Get-SshResolved {
    # Resolved ssh options of an alias ("ssh -G"): the first value of each key.
    param([string]$ConfigFile, [string]$Alias)

    # Native tools write to stderr; do not turn that into terminating errors here.
    $ErrorActionPreference = 'Continue'

    $Resolved = @{}

    foreach ($ResolvedLine in @(& ssh.exe -F $ConfigFile -G $Alias 2>$null)) {
        $Text = [string]$ResolvedLine

        if ($Text -match '^(\S+)\s+(.*)$') {
            $Name = $Matches[1].ToLowerInvariant()
            if (-not $Resolved.ContainsKey($Name)) {
                $Resolved[$Name] = $Matches[2].Trim()
            }
        }
    }

    return $Resolved
}

function Invoke-Ssh {
    # Connect to an ssh alias. When the configuration gives no user name (ssh
    # would silently use the local Windows user), ask for one, like PuTTY does.
    param(
        [Parameter(Mandatory = $true)][string]$Alias,
        [object[]]$Files,
        [string[]]$ExtraArguments = @()
    )

    Assert-Command -Name 'ssh.exe' -Hint 'Install the Windows OpenSSH Client optional feature.'

    $ConfigFile = New-SshConfigFile -Files $Files
    $SshArguments = New-Object System.Collections.Generic.List[string]
    $SshArguments.Add('-F')
    $SshArguments.Add($ConfigFile)

    foreach ($Extra in $ExtraArguments) {
        $SshArguments.Add($Extra)
    }

    if ($AskUser) {
        $LocalUser = [string]$env:USERNAME
        $Resolved = Get-SshResolved -ConfigFile $ConfigFile -Alias $Alias

        # The user ssh would really use (a User line of the record, or of any
        # matching pattern block such as "Host lab*" or "Host *").
        $ConfiguredUser = ''
        if ($Resolved.ContainsKey('user')) {
            $ConfiguredUser = [string]$Resolved['user']
        }

        # Without a configured user, ssh falls back to the local login name.
        if ($ConfiguredUser -eq '' -or $ConfiguredUser -ieq $LocalUser) {
            $Answer = ([string](Read-Host -Prompt ('Username for {0} [{1}]' -f $Alias, $LocalUser))).Trim()

            # Enter (or the local name) keeps ssh's default; anything else is
            # passed as the login name.
            if ($Answer -ne '' -and $Answer -ine $LocalUser) {
                $SshArguments.Add('-l')
                $SshArguments.Add($Answer)
            }
        }
    }

    $SshArguments.Add($Alias)

    & ssh.exe $SshArguments.ToArray()
    return [int]$LASTEXITCODE
}

function Invoke-ForgetHostKey {
    # Remove the stored host key of an ssh alias from known_hosts.
    # ssh stores the key under the resolved HostName (or HostKeyAlias when set),
    # and as [name]:port when the port is not 22, so the alias itself is useless
    # for ssh-keygen -R. "ssh -G" prints the fully resolved configuration.
    param([Parameter(Mandatory = $true)][string]$Alias, [object[]]$Files)

    $ErrorActionPreference = 'Continue'

    Assert-Command -Name 'ssh.exe' -Hint 'Install the Windows OpenSSH Client optional feature.'
    Assert-Command -Name 'ssh-keygen.exe' -Hint 'Install the Windows OpenSSH Client optional feature.'

    $ConfigFile = New-SshConfigFile -Files $Files
    $Resolved = Get-SshResolved -ConfigFile $ConfigFile -Alias $Alias

    $ResolvedHost = ''
    if ($Resolved.ContainsKey('hostname')) { $ResolvedHost = [string]$Resolved['hostname'] }

    $Port = ''
    if ($Resolved.ContainsKey('port')) { $Port = [string]$Resolved['port'] }

    $KeyAlias = ''
    if ($Resolved.ContainsKey('hostkeyalias') -and [string]$Resolved['hostkeyalias'] -ne 'none') {
        $KeyAlias = [string]$Resolved['hostkeyalias']
    }

    # HostKeyAlias wins over HostName, exactly as in ssh itself.
    $Base = $Alias
    if ($ResolvedHost -ne '') { $Base = $ResolvedHost }
    if ($KeyAlias -ne '') { $Base = $KeyAlias }

    # Non-default ports are stored in the bracketed form.
    $Target = $Base
    if ($Port -ne '' -and $Port -ne '22') {
        $Target = '[{0}]:{1}' -f $Base, $Port
    }

    Write-Host ('Removing known_hosts entries for: {0} (alias: {1})' -f $Target, $Alias)

    # ssh-keygen keeps a backup copy as known_hosts.old. Out-Host keeps its text
    # out of the function return value.
    & ssh-keygen.exe -R $Target | Out-Host

    return [int]$LASTEXITCODE
}

# -----------------------------------------------------------------------------
# RDP
# -----------------------------------------------------------------------------

function Remove-StaleRdpFiles {
    # Delete generated .rdp files older than 12 hours. mstsc reads the file once
    # at startup, so keeping it around briefly is harmless.
    if (-not (Test-Path -LiteralPath $RdpTempDirectory -PathType Container)) {
        return
    }

    $Cutoff = (Get-Date).AddHours(-12)

    Get-ChildItem -LiteralPath $RdpTempDirectory -Filter '*.rdp' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $Cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function New-RdpFile {
    # Build the .rdp file for one target and return its path.
    param([Parameter(Mandatory = $true)][object]$Entry)

    if (-not (Test-Path -LiteralPath $RdpTempDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $RdpTempDirectory -Force | Out-Null
    }

    # File name is derived from the alias, with unsafe characters replaced.
    $SafeName = [regex]::Replace([string]$Entry.Alias, '[^A-Za-z0-9._-]', '_')
    $Path = Join-Path $RdpTempDirectory ($SafeName + '.rdp')

    # Ordered map: lower-cased property name -> complete .rdp line.
    # One entry per property guarantees there are no duplicate keys in the file.
    $Props = [ordered]@{}

    $SetProp = {
        param([string]$PropLine)
        $PropName = $PropLine.Substring(0, $PropLine.IndexOf(':')).Trim().ToLowerInvariant()
        $Props[$PropName] = $PropLine
    }

    & $SetProp ('full address:s:{0}' -f $Entry.Target)

    # Optional user name (DOMAIN\user is passed through unchanged). Without one,
    # mstsc asks for the credentials itself.
    if ($Entry.User -ne '') {
        & $SetProp ('username:s:{0}' -f $Entry.User.Trim())
    }

    # Administrative (console) session switch.
    if ($Entry.Mode -ieq 'admin') {
        & $SetProp 'administrative session:i:1'
    }
    else {
        & $SetProp 'administrative session:i:0'
    }

    # Pin multimon explicitly; its documented default is 1 and it overrides
    # screen mode id, which makes the window behaviour unpredictable.
    & $SetProp 'use multimon:i:0'

    # Window behaviour. FULL SCREEN IS THE DEFAULT on Windows: mstsc windows are
    # not reliably resizable. "Screen Window" or "Screen WIDTHxHEIGHT" select a window.
    $Screen = ([string]$Entry.Screen).Trim()

    if ($Screen -eq '' -or $Screen -ieq 'full') {
        & $SetProp 'screen mode id:i:2'
    }
    elseif ($Screen -ieq 'window') {
        & $SetProp 'screen mode id:i:1'
        & $SetProp 'smart sizing:i:1'
        & $SetProp 'dynamic resolution:i:1'
    }
    elseif ($Screen -match '^(\d{3,5})x(\d{3,5})$') {
        & $SetProp 'screen mode id:i:1'
        & $SetProp 'smart sizing:i:1'
        & $SetProp 'dynamic resolution:i:1'
        & $SetProp ('desktopwidth:i:{0}' -f $Matches[1])
        & $SetProp ('desktopheight:i:{0}' -f $Matches[2])
    }
    else {
        Write-Warning ("Unknown Screen value '{0}' for {1}; using full screen." -f $Screen, $Entry.Alias)
        & $SetProp 'screen mode id:i:2'
    }

    # Raw RdpOption lines come last so they can override anything generated above.
    foreach ($Raw in @($Entry.RdpOptions)) {
        $Option = ([string]$Raw).Trim()

        if ($Option -eq '') {
            continue
        }

        # A valid .rdp line looks like: name:type:value where type is s, i or b.
        if ($Option -notmatch '^[^:]+:[sib]:') {
            Write-Warning "Ignoring invalid RdpOption: $Option"
            continue
        }

        & $SetProp $Option
    }

    # UTF-16 LE with BOM is the encoding mstsc itself writes, so it is always
    # read correctly, including non-ASCII characters in user names.
    $RdpEncoding = New-Object System.Text.UnicodeEncoding($false, $true)
    [System.IO.File]::WriteAllLines($Path, [string[]]@($Props.Values), $RdpEncoding)

    return $Path
}

function Start-RdpSession {
    # Generate the .rdp file and hand it to mstsc, which reads it at startup.
    param([Parameter(Mandatory = $true)][object]$Entry)

    Assert-Command -Name 'mstsc.exe' -Hint 'The Remote Desktop client (mstsc.exe) is part of Windows.'

    Remove-StaleRdpFiles
    $RdpFile = New-RdpFile -Entry $Entry

    Start-Process -FilePath 'mstsc.exe' -ArgumentList ('"{0}"' -f $RdpFile)
}

# -----------------------------------------------------------------------------
# Web
# -----------------------------------------------------------------------------

function Open-WebTarget {
    # Open the address in the system default or the configured browser.
    param([Parameter(Mandatory = $true)][object]$Entry)

    $Url = [string]$Entry.Target
    $BrowserProfile = ([string]$Entry.BrowserProfile).Trim()
    $ExtraArguments = ([string]$Entry.BrowserArgs).Trim()

    # A host specific Browser wins over the REMOTES_BROWSER default.
    $BrowserName = ([string]$Entry.Browser).Trim()
    if ($BrowserName -eq '') {
        $BrowserName = $DefaultBrowser
    }

    # Executable is empty for the system default browser.
    # Family decides which profile argument style is used.
    $Executable = ''
    $Family = 'chromium'

    switch ($BrowserName.ToLowerInvariant()) {
        ''        { $Executable = '' }
        'default' { $Executable = '' }
        'system'  { $Executable = '' }
        'chrome'  { $Executable = 'chrome.exe' }
        'edge'    { $Executable = 'msedge.exe' }
        'msedge'  { $Executable = 'msedge.exe' }
        'brave'   { $Executable = 'brave.exe' }
        'vivaldi' { $Executable = 'vivaldi.exe' }
        'opera'   { $Executable = 'opera.exe' }
        'firefox' { $Executable = 'firefox.exe'; $Family = 'firefox' }
        default {
            # Any other value is treated as an executable name or full path.
            $Executable = $BrowserName
            if ($BrowserName.ToLowerInvariant().Contains('firefox')) {
                $Family = 'firefox'
            }
        }
    }

    # System default browser: no profile or extra arguments are possible.
    if ($Executable -eq '') {
        if ($BrowserProfile -ne '' -or $ExtraArguments -ne '') {
            Write-Warning 'Profile and BrowserArgs are ignored for the default browser.'
        }

        Start-Process -FilePath $Url
        return
    }

    # Build the argument list. Values with spaces are quoted by hand because
    # Start-Process joins the array elements with plain spaces.
    $Arguments = New-Object System.Collections.Generic.List[string]

    if ($BrowserProfile -ne '') {
        if ($Family -eq 'firefox') {
            $Arguments.Add('-P')
            $Arguments.Add(('"{0}"' -f $BrowserProfile))
        }
        else {
            $Arguments.Add(('--profile-directory="{0}"' -f $BrowserProfile))
        }
    }

    # Raw extra arguments are passed as typed.
    if ($ExtraArguments -ne '') {
        $Arguments.Add($ExtraArguments)
    }

    # The address always goes last.
    $Arguments.Add(('"{0}"' -f $Url))

    try {
        Start-Process -FilePath $Executable -ArgumentList $Arguments.ToArray()
    }
    catch {
        throw ("Could not start browser '{0}'.`r`nCheck the Browser key of '{1}' or use a full path.`r`n{2}" -f $BrowserName, $Entry.Alias, $_.Exception.Message)
    }
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

if ($Help) {
    Show-Usage
    exit 0
}

try {
    if ($TypeFilter -ne '' -and @('ssh', 'rdp', 'web') -notcontains $TypeFilter) {
        throw "Unknown type '$TypeFilter' (use ssh, rdp or web)."
    }

    Assert-Command -Name 'fzf.exe' -Hint 'Install fzf with: winget install --id junegunn.fzf -e'

    # Records from the previous layout are not read any more.
    $OldHostsDirectory = Join-Path (Join-Path $HOME '.remotes') 'hosts'
    if (-not (Test-Path -LiteralPath $HostsDirectory) -and (Test-Path -LiteralPath $OldHostsDirectory)) {
        Write-Warning ("Your records are still in {0}. Move them to {1}." -f $OldHostsDirectory, $HostsDirectory)
    }

    # Make sure the state folder and the recent file exist.
    if (-not (Test-Path -LiteralPath $RemotesHome -PathType Container)) {
        New-Item -ItemType Directory -Path $RemotesHome -Force | Out-Null
    }

    # Read the records.
    $SourceFiles = @(Get-SourceFiles)

    if ($SourceFiles.Count -eq 0) {
        throw ("No data found. Create {0}\<group>\<name>-ssh.conf, -rdp.conf or -web.conf" -f $HostsDirectory)
    }

    $Entries = @(Get-AllEntries -Files $SourceFiles)

    if ($Entries.Count -eq 0) {
        throw "No usable targets found. Check $HostsDirectory (rdp needs HostName, web needs URL or HostName)."
    }

    # Temporary folder for the preview files, removed in the finally block.
    $script:PreviewDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('remotes-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:PreviewDirectory -Force | Out-Null

    $EntriesByKey = @{}
    $PreviewIndex = 0

    foreach ($Entry in $Entries) {
        $Entry.PreviewPath = Write-PreviewFile -Entry $Entry -Directory $script:PreviewDirectory -Index $PreviewIndex
        $EntriesByKey[$Entry.Key] = $Entry
        $PreviewIndex++
    }

    # Column widths.
    $DisplayWidth = 'Host (Target)'.Length
    $InfoWidth = 'Info'.Length
    $TagsWidth = 'Tags'.Length
    $GroupWidth = 'Group'.Length

    foreach ($Entry in $Entries) {
        if ($Entry.Display.Length -gt $DisplayWidth) { $DisplayWidth = $Entry.Display.Length }
        if ($Entry.Info.Length -gt $InfoWidth) { $InfoWidth = $Entry.Info.Length }
        if ($Entry.Tags.Length -gt $TagsWidth) { $TagsWidth = $Entry.Tags.Length }
        if ($Entry.Group.Length -gt $GroupWidth) { $GroupWidth = $Entry.Group.Length }
    }

    # Recent targets first, in recency order, only if they still exist.
    $RecentEntries = New-Object System.Collections.Generic.List[object]
    $RecentSet = @{}

    foreach ($RecentKey in @(Get-RecentKeys)) {
        if ($RecentEntries.Count -ge $MaximumRecent) { break }

        if ($EntriesByKey.ContainsKey($RecentKey) -and -not $RecentSet.ContainsKey($RecentKey)) {
            $RecentEntries.Add($EntriesByKey[$RecentKey])
            $RecentSet[$RecentKey] = $true
        }
    }

    $NormalEntries = New-Object System.Collections.Generic.List[object]
    foreach ($Entry in $Entries) {
        if (-not $RecentSet.ContainsKey($Entry.Key)) {
            $NormalEntries.Add($Entry)
        }
    }

    # One tab separated fzf row:
    #   1 key | 2 type | 3 display | 4 info | 5 tags | 6 group | 7 source path | 8 alias | 9 preview path
    $DisplayLines = New-Object System.Collections.Generic.List[string]

    # Header row (consumed by fzf --header-lines=1).
    $DisplayLines.Add((@(
        '__header__',
        'Type'.PadRight(4),
        'Host (Target)'.PadRight($DisplayWidth + 2),
        'Info'.PadRight($InfoWidth + 2),
        'Tags'.PadRight($TagsWidth + 2),
        'Group'.PadRight($GroupWidth),
        '', '', ''
    ) -join "`t"))

    $ToLine = {
        param([object]$Row)
        return (@(
            (ConvertTo-FzfField $Row.Key),
            (ConvertTo-FzfField $Row.TypeLabel).PadRight(4),
            (ConvertTo-FzfField $Row.Display).PadRight($DisplayWidth + 2),
            (ConvertTo-FzfField $Row.Info).PadRight($InfoWidth + 2),
            (ConvertTo-FzfField $Row.Tags).PadRight($TagsWidth + 2),
            (ConvertTo-FzfField $Row.Group).PadRight($GroupWidth),
            (ConvertTo-FzfField $Row.Path),
            (ConvertTo-FzfField $Row.Alias),
            (ConvertTo-FzfField $Row.PreviewPath)
        ) -join "`t")
    }

    foreach ($Entry in $RecentEntries) {
        $DisplayLines.Add((& $ToLine $Entry))
    }

    # Separator row, only when both groups are non-empty.
    if ($RecentEntries.Count -gt 0 -and $NormalEntries.Count -gt 0) {
        $DisplayLines.Add((@('__separator__', '---------------- All Targets ----------------', '', '', '', '', '', '', '') -join "`t"))
    }

    foreach ($Entry in $NormalEntries) {
        $DisplayLines.Add((& $ToLine $Entry))
    }

    $EditorAvailable = [bool](Get-Command (($EditorCommand -split '\s+')[0]) -ErrorAction SilentlyContinue)

    $FzfArguments = New-Object System.Collections.Generic.List[string]
    foreach ($Argument in @(
        '--height=70%',
        '--reverse',
        '--exact',
        '--tiebreak=begin,length',
        "--delimiter=`t",
        # Visible columns: type, alias+target, info, tags, group.
        '--with-nth=2,3,4,5,6',
        '--header-lines=1',
        # Keys handled after fzf exits: Ctrl+V (verbose), Ctrl+R (forget host key).
        '--expect=ctrl-v,ctrl-r',
        # The preview text is a prepared file (field 9).
        '--preview=cmd.exe /d /c type "{9}"',
        '--preview-window=down:45%:wrap:hidden',
        '--bind=?:toggle-preview',
        ('--prompt=[Recent {0} at top] Search: ' -f $MaximumRecent),
        '--info=right',
        '--border=rounded',
        '--border-label= Remotes | Enter=Connect | Ctrl-V=Verbose (SSH) | Ctrl-R=Forget key (SSH) | Ctrl-E=Edit | ?=Details ',
        '--ellipsis=...'
    )) {
        $FzfArguments.Add($Argument)
    }

    # A query argument pre-fills the search; a single match is selected at once.
    if ($QueryText -ne '') {
        $FzfArguments.Add('--query=' + $QueryText)
        $FzfArguments.Add('--select-1')
    }

    # Ctrl+E opens the exact source file of the highlighted target (field 7).
    if ($EditorAvailable) {
        $FzfArguments.Add(('--bind=ctrl-e:execute-silent({0} "{{7}}")' -f $EditorCommand))
    }

    $PreviousConsoleEncoding = [Console]::OutputEncoding
    $PreviousPipelineEncoding = $OutputEncoding

    try {
        [Console]::OutputEncoding = $Utf8NoBom
        $OutputEncoding = $Utf8NoBom
        $FzfOutput = @($DisplayLines.ToArray() | & fzf.exe $FzfArguments.ToArray())
        $FzfExitCode = $LASTEXITCODE
    }
    finally {
        [Console]::OutputEncoding = $PreviousConsoleEncoding
        $OutputEncoding = $PreviousPipelineEncoding
    }

    # Cancelled (Esc / Ctrl+C) or no match: nothing to do.
    if ($FzfExitCode -ne 0 -or $FzfOutput.Count -eq 0) {
        exit 0
    }

    # With --expect, line 1 is the pressed key (empty for Enter) and line 2 is the row.
    $PressedKey = ''
    $SelectedRow = ''

    if ($FzfOutput.Count -ge 2) {
        $PressedKey = [string]$FzfOutput[0]
        $SelectedRow = [string]$FzfOutput[1]
    }
    elseif (([string]$FzfOutput[0]).Contains("`t")) {
        # An auto-selected single match may arrive without the key line.
        $SelectedRow = [string]$FzfOutput[0]
    }

    if ([string]::IsNullOrWhiteSpace($SelectedRow)) {
        exit 0
    }

    # The key is the first tab separated field.
    $SelectedKey = ($SelectedRow -split "`t", 2)[0]

    # Ignore the header and the separator row.
    if ($SelectedKey -eq '__header__' -or $SelectedKey -eq '__separator__' -or -not $EntriesByKey.ContainsKey($SelectedKey)) {
        exit 0
    }

    $Selected = $EntriesByKey[$SelectedKey]

    # Ctrl+V and Ctrl+R only make sense for ssh targets.
    if ($Selected.LType -ne 'ssh' -and ($PressedKey -eq 'ctrl-v' -or $PressedKey -eq 'ctrl-r')) {
        throw 'Ctrl+V and Ctrl+R work for SSH targets only.'
    }

    switch ($Selected.LType) {
        'ssh' {
            if ($PressedKey -eq 'ctrl-r') {
                # Forget the stored host key; does not touch the recent list.
                exit (Invoke-ForgetHostKey -Alias $Selected.Alias -Files $SourceFiles)
            }

            Set-RecentKey -Key $Selected.Key

            if ($PressedKey -eq 'ctrl-v') {
                # Verbose connection for troubleshooting.
                exit (Invoke-Ssh -Alias $Selected.Alias -Files $SourceFiles -ExtraArguments @('-vvvv'))
            }

            exit (Invoke-Ssh -Alias $Selected.Alias -Files $SourceFiles)
        }
        'rdp' {
            Set-RecentKey -Key $Selected.Key
            Start-RdpSession -Entry $Selected
            exit 0
        }
        'web' {
            Set-RecentKey -Key $Selected.Key
            Open-WebTarget -Entry $Selected
            exit 0
        }
    }

    throw "Unknown target type '$($Selected.LType)'."
}
catch {
    # Show a readable error instead of a raw PowerShell exception dump.
    Write-Host '----- Remotes ERROR -----' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red

    if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) {
        Write-Host ''
        Write-Host $_.ScriptStackTrace
    }

    exit 1
}
finally {
    # Always remove the temporary preview folder and the temporary ssh config.
    if (-not [string]::IsNullOrWhiteSpace($script:PreviewDirectory)) {
        if (Test-Path -LiteralPath $script:PreviewDirectory) {
            Remove-Item -LiteralPath $script:PreviewDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($script:SshConfigFile)) {
        if (Test-Path -LiteralPath $script:SshConfigFile) {
            Remove-Item -LiteralPath $script:SshConfigFile -Force -ErrorAction SilentlyContinue
        }
    }
}
