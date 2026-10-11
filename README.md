# Remotes

One fast, searchable terminal menu for everything you connect to: **SSH hosts**, **RDP hosts** and the **web GUIs** of routers, switches, firewalls and NAS boxes. Records are kept in plain text files, grouped per customer, and the menu is a single [fzf](https://github.com/junegunn/fzf) list.

Remotes is deliberately light: a shell script, `fzf` and tools that ship with macOS. No daemon, no database, no package manager of its own.

```
Type  Host (Target)                         Info     Tags                           Group
RDP   customer-dc01 (10.10.0.10)            USER     customer dc windows server2022 customer-a
SSH   customer-web01 (10.10.0.21)           deploy   customer web nginx prod        customer-a
WEB   customer-firewall (https://10.1.0.1/) chrome   customer firewall              customer-a
SSH   lab-pi (192.168.50.5)                 pi       raspberry lab                  lab
```

Start it with `rms` (short) or `remotes` (long). Platforms: **macOS** (zsh) and **Windows** (PowerShell 5.1 or 7). Both read the same record files.

## Features

- One list for SSH, RDP and web targets, with the same columns for every type: Type, Host (Target), Info, Tags, Group.
- Search by anything visible: type, alias, address, user or browser, tags, customer or group name.
- Records live in one folder per customer. The same alias can exist once per type (for example `a-fw` as SSH and as web GUI).
- SSH records use normal OpenSSH `ssh_config` syntax. Everything `ssh` understands works (`ProxyJump`, `IdentityFile`, `LocalForward`, 1Password agent, ...).
- RDP records generate a temporary `.rdp` file and open it in the Windows App. Window mode, full screen or a fixed size, administrative session, and raw `.rdp` properties are supported.
- Web records open in the default browser or in a browser and profile of your choice, so each customer can have separate cookies and sessions.
- File defaults: a `Host *` block in an RDP or web file sets defaults for all records of that file, for example one domain user per file.
- The 5 most recently used targets are pinned to the top.
- Preview of the record (`?`), open the source file in your editor (`Ctrl+E`).
- SSH helpers: verbose connection (`Ctrl+V`) and removal of a stale host key from `known_hosts` (`Ctrl+R`).
- SSH records without a `User` ask for the user name before connecting, like PuTTY does (Enter keeps your macOS login name).
- Start with a pre-filled search: `sshs customer-a`. If only one target matches, it connects immediately.
- No `Include` line is required in `~/.ssh/config`: Remotes builds a temporary ssh configuration for every connection.
- Five commands from one program: `rms` and `remotes` (everything), `sshs` (SSH only), `rdps` (RDP only), `webs` (web only).

## Requirements

### macOS

| Requirement | Needed for | How to get it |
|---|---|---|
| macOS with zsh | everything | built in |
| [fzf](https://github.com/junegunn/fzf) | the menu | `brew install fzf` |
| `awk`, `ssh`, `ssh-keygen`, `open`, `find`, `sed`, `grep`, ... | everything | built in |
| `curl` | the installer | built in |
| Windows App | RDP targets (optional) | Mac App Store, "Windows App" |
| VS Code `code` command | `Ctrl+E` (optional) | VS Code, Command Palette: "Shell Command: Install 'code' command in PATH" |

The installer never installs dependencies. If something required is missing, it lists what is missing and how to install it, and it copies no files.

### Windows

| Requirement | Needed for | How to get it |
|---|---|---|
| Windows PowerShell 5.1 or PowerShell 7 | everything | built in (Windows 10 and 11) |
| [fzf](https://github.com/junegunn/fzf) | the menu | `winget install --id junegunn.fzf -e` |
| OpenSSH Client (`ssh.exe`, `ssh-keygen.exe`) | SSH targets | Settings > Apps > Optional features > OpenSSH Client, or in an administrator PowerShell: `Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0` |
| `mstsc.exe` | RDP targets | built in (Remote Desktop Connection) |
| VS Code `code.cmd` | `Ctrl+E` (optional) | VS Code (add to PATH during setup) |

## Installation

Two ways on both systems: the install script (recommended), or a manual download and copy. The macOS instructions come first, the [Windows instructions](#windows) follow after them.

### macOS

#### Install script

```sh
curl -fsSL https://raw.githubusercontent.com/sikkancs/remotes/main/install.sh | bash
```

What it does:

1. Checks the dependencies. If any is missing it prints the list with install hints and stops before copying anything.
2. Downloads every file to a temporary folder and verifies it. Nothing is touched unless all downloads succeeded.
3. Installs the files below. An existing file with different content is kept as `<name>.bak.<timestamp>`.
4. Migrates older layouts (see below).
5. Creates the aliases `rms`, `remotes`, `sshs`, `rdps` and `webs` for your shell.

Everything lives in **one folder**, `~/.config/remotes/`:

```
~/.config/remotes/
  bin/          program: remotes.sh, sshs.sh, rdps.sh, webs.sh, aliases.sh
                (installer managed, replaced on every update)
  hosts/        YOUR records (the installer never changes their content)
  samples/      reference files for new records (installer managed)
  recent        recently used targets (created on first use)
```

Back up or sync `hosts/` only; everything else can be recreated by running the installer again.

Aliases are set up for the shell found in `$SHELL`:

- **zsh**: a marked block in `~/.zshrc` that sources `~/.config/remotes/bin/aliases.sh`
- **bash**: the same block in `~/.bash_profile`
- **fish**: `~/.config/fish/conf.d/remotes.fish`
- other shells: the installer prints the alias lines for you to add

Open a new terminal window afterwards (or `source` the startup file).

Options (pass them after `bash -s --`):

| Option | Meaning |
|---|---|
| `--no-alias` | do not touch any shell startup file |
| `--shell zsh\|bash\|fish` | set up aliases for this shell instead of the detected one |
| `--uninstall` | remove the installed files and the alias setup (your records stay) |
| `-h`, `--help` | show help |

```sh
curl -fsSL https://raw.githubusercontent.com/sikkancs/remotes/main/install.sh | bash -s -- --no-alias
```

**Update**: run the install script again. Changed files are replaced and the old version is kept as a `.bak` copy.

**Coming from an older layout**: the installer moves your records from `~/.remotes/hosts` to `~/.config/remotes/hosts` (only when the new folder is still empty; nothing is ever overwritten), removes the files of earlier installer versions (the wrappers in `~/.config/sshs`, `~/.config/rdps`, `~/.config/webs`, and the program files that used to sit directly in `~/.config/remotes`), and replaces an old alias block in your startup file. Any other file it finds in those places, for example the old standalone app, is left untouched. It also points out alias lines of yours that still use the old paths; they can be deleted.

#### Manual download and copy

```sh
BASE=https://raw.githubusercontent.com/sikkancs/remotes/main

# 1. Folders: program, samples and your records.
mkdir -p ~/.config/remotes/bin ~/.config/remotes/samples ~/.config/remotes/hosts

# 2. Download the program, the three wrappers and the samples.
for f in remotes sshs rdps webs; do curl -fsSL -o ~/.config/remotes/bin/$f.sh "$BASE/macos/$f.sh"; done
for t in ssh rdp web; do curl -fsSL -o ~/.config/remotes/samples/$t.sample "$BASE/samples/$t.sample"; done

# 3. Make the scripts executable.
chmod +x ~/.config/remotes/bin/*.sh
```

Then add the aliases to `~/.zshrc` (bash: `~/.bash_profile`) and open a new terminal:

```sh
alias rms="$HOME/.config/remotes/bin/remotes.sh"
alias remotes="$HOME/.config/remotes/bin/remotes.sh"
alias sshs="$HOME/.config/remotes/bin/sshs.sh"
alias rdps="$HOME/.config/remotes/bin/rdps.sh"
alias webs="$HOME/.config/remotes/bin/webs.sh"
```

Without the command line: open each file on GitHub, press **Raw**, save it, and copy it to the matching location above. You also need `fzf` (see Requirements); the manual route does not check dependencies.

#### Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/sikkancs/remotes/main/install.sh | bash -s -- --uninstall
```

Your records in `~/.config/remotes/hosts` and the recent list are kept. After a manual installation, delete `~/.config/remotes/bin`, `samples` and the alias lines.

### Windows

#### Install script

Run in PowerShell:

```powershell
irm https://raw.githubusercontent.com/sikkancs/remotes/main/install.ps1 | iex
```

What it does:

1. Checks the dependencies. If any is missing it prints the list with install hints and stops before copying anything.
2. Downloads every file to a temporary folder and verifies it. Nothing is touched unless all downloads succeeded.
3. Installs the files below. An existing file with different content is kept as `<name>.bak.<timestamp>`.
4. Adds the `bin` folder to your **user** path (registry, no administrator rights needed).

```
%USERPROFILE%\.config\remotes\
  bin\          remotes.ps1 and the launchers rms.cmd, remotes.cmd, sshs.cmd, rdps.cmd, webs.cmd
  hosts\        YOUR records (the installer never changes their content)
  samples\      reference files for new records
  recent        recently used targets (created on first use)
```

**What is on the path**: only that one folder, `%USERPROFILE%\.config\remotes\bin`. Windows has no shell aliases, so the commands are tiny `.cmd` launchers in this folder. They work in cmd, PowerShell, Windows Terminal and Win+R:

| Command | Does |
|---|---|
| `rms`, `remotes` | start the picker with every target |
| `sshs` | the same picker, SSH targets only |
| `rdps` | the same picker, RDP targets only |
| `webs` | the same picker, web targets only |

Every launcher runs the one script `remotes.ps1` next to it (`sshs.cmd` adds `-Type ssh`, and so on) and passes your arguments on, so `sshs customer-a` pre-fills the search. The entry is placed at the front of the user path, so it wins over same-named older launchers in other user path folders. Open a new terminal window after the first installation; the installing window can use the commands at once.

Options (pass them through a script block):

| Option | Meaning |
|---|---|
| `-NoPath` | do not change the user path |
| `-Uninstall` | remove the installed files and the path entry (your records stay) |
| `-Help` | show help |

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/sikkancs/remotes/main/install.ps1))) -NoPath
```

**Update**: run the install script again. Changed files are replaced and the old version is kept as a `.bak` copy.

**Older Windows tools**: records of the older standalone tools (`~\.ssh\config.d`, `~\.rdps`, `~\.webs`) are not read by Remotes. The installer points them out; copy the files you need into `hosts\<group>\` named by type (`...-ssh.conf`, `...-rdp.conf`, `...-web.conf`). It also lists same-named launchers found elsewhere on your path.

#### Manual download and copy

```powershell
$Base = 'https://raw.githubusercontent.com/sikkancs/remotes/main'
$Root = "$HOME\.config\remotes"

# 1. Folders: program, samples and your records.
New-Item -ItemType Directory -Force "$Root\bin", "$Root\samples", "$Root\hosts" | Out-Null

# 2. Download the script, the five launchers and the samples.
foreach ($File in 'remotes.ps1', 'rms.cmd', 'remotes.cmd', 'sshs.cmd', 'rdps.cmd', 'webs.cmd') {
    Invoke-WebRequest -UseBasicParsing "$Base/windows/$File" -OutFile "$Root\bin\$File"
}
foreach ($Type in 'ssh', 'rdp', 'web') {
    Invoke-WebRequest -UseBasicParsing "$Base/samples/$Type.sample" -OutFile "$Root\samples\$Type.sample"
}

# 3. Batch files need CRLF line endings.
foreach ($Launcher in Get-ChildItem "$Root\bin\*.cmd") {
    $Text = [System.IO.File]::ReadAllText($Launcher.FullName) -replace "`r?`n", "`r`n"
    [System.IO.File]::WriteAllText($Launcher.FullName, $Text, [System.Text.Encoding]::ASCII)
}
```

Then add `%USERPROFILE%\.config\remotes\bin` to your user path (Settings > System > About > Advanced system settings > Environment Variables > user variable `Path` > New) and open a new terminal. You also need `fzf` and the OpenSSH client (see Requirements); the manual route does not check dependencies.

#### Uninstall

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/sikkancs/remotes/main/install.ps1))) -Uninstall
```

Your records in `hosts\` and the recent list are kept. After a manual installation, delete `bin` and `samples` and remove the path entry.

## Quick start

1. Create a folder for a customer and start from a sample:

   ```sh
   cd ~/.config/remotes
   mkdir -p hosts/customer-a
   cp samples/ssh.sample hosts/customer-a/customer-a-ssh.conf
   cp samples/rdp.sample hosts/customer-a/customer-a-rdp.conf
   cp samples/web.sample hosts/customer-a/customer-a-web.conf
   ```

2. Edit the copied files: keep your own records, delete the example ones.
3. Run `rms`.

On Windows the same in PowerShell:

```powershell
cd "$HOME\.config\remotes"
New-Item -ItemType Directory hosts\customer-a | Out-Null
Copy-Item samples\ssh.sample hosts\customer-a\customer-a-ssh.conf
Copy-Item samples\rdp.sample hosts\customer-a\customer-a-rdp.conf
Copy-Item samples\web.sample hosts\customer-a\customer-a-web.conf
```

The files in `samples/` are reference documentation and are never read as data. Keep them there.

## Data layout

On Windows the root is `%USERPROFILE%\.config\remotes`; everything below is the same.

```
~/.config/remotes/hosts/
  customer-a/                     one folder per customer or group
    customer-a-ssh.conf           SSH records
    customer-a-rdp.conf           RDP records
    customer-a-web.conf           web records
    dc-rdp.conf                   any number of files per type is fine
  lab-ssh.conf                    files directly in hosts/ work too
  ssh.conf                        plain names work too (group "general")
```

**The file name decides the type.** A file is read when its name is `ssh.conf`, `rdp.conf` or `web.conf`, or ends with `-ssh.conf`, `-rdp.conf` or `-web.conf`. Any other file name, and any hidden file or folder, is ignored.

**The group** (a searchable column) is the first folder below `hosts/`. For a file directly in `hosts/` it is the name before the type suffix (`lab-ssh.conf` gives `lab`).

Your existing `~/.ssh/config` is still listed (group `ssh-config`), so current hosts keep working. If the same alias is defined twice for one type, the first definition wins: files in `hosts/` in path order, `~/.ssh/config` last.

## Record syntax

All three types use the same block structure:

```
Host alias [alias2 ...]
    Key value
    # Tags space separated words
```

- One block can define several aliases; each alias gets its own row.
- `# Tags` is a comment line inside the block and makes the target searchable. `#Tags` works too.
- RDP and web files accept comments at the end of a line (`Screen Full   # comment`). SSH files do not: `ssh` itself does not support them, so put comments on their own line there.
- Wildcard hosts are not listed. `Host *` has a special meaning, see "Defaults and order" below.

Complete, commented examples for every key are in [`samples/`](samples).

### SSH

Standard `ssh_config`. Remotes reads `Host`, `HostName` (shown in the list), `User` (shown in the Info column) and `# Tags`; everything else is passed to `ssh` untouched.

**Missing user name**: when the configuration gives no user for an alias, `ssh` would silently log in with your macOS user name. Remotes asks instead:

```
Username for customer-web02 [gabor]: 
```

Type a name to log in with `ssh -l <name>`; press Enter (or type your own login name) to keep the default. A `User` from the record itself or from a matching pattern block (`Host lab*`, `Host *`) counts as configured, so no question is asked. The question applies to `Enter` and `Ctrl+V`; set `REMOTES_ASK_USER=0` to switch it off. RDP needs no such setting: when a record has no `User`, the Windows App asks for the credentials itself.

```
Host customer-web01
    HostName 10.10.0.21
    User deploy
    Port 2222
    IdentityFile ~/.ssh/id_ed25519
    # Tags customer web nginx prod
```

### RDP

| Key | Meaning |
|---|---|
| `HostName` | required: IP address or FQDN |
| `User` | optional: `DOMAIN\user` or `user@domain` |
| `Mode` | `User` (default) or `Admin` (administrative session) |
| `Screen` | `Window` (default), `Full`, or a size such as `1600x900` |
| `RdpOption` | raw `.rdp` line `name:type:value` (repeatable); overrides generated lines |

```
Host customer-dc01
    HostName 10.10.0.10
    User CONTOSO\administrator
    Mode Admin
    Screen Full
    RdpOption redirectclipboard:i:1
    # Tags customer dc windows
```

Which `RdpOption` properties take effect depends on the client. The property list is in the [Microsoft documentation](https://learn.microsoft.com/en-us/azure/virtual-desktop/rdp-properties).

**Windows**: RDP sessions open in **full screen by default** (`Screen Full`), because mstsc windows cannot be resized reliably. `Screen Window` and `Screen 1600x900` open a window (with smart sizing and dynamic resolution requested). Full screen uses the monitor mstsc starts on; add `RdpOption use multimon:i:1` to span all monitors. On macOS the default is a window.

### Web

| Key | Meaning |
|---|---|
| `URL` | full address; `https://` is added when the scheme is missing |
| `HostName`, `Port`, `Scheme` | alternative to `URL`; scheme defaults to `https` |
| `Browser` | `default` (system browser), `chrome`, `edge`, `firefox`, `safari`, `brave`, `vivaldi`, `arc`, `opera`, or any application name |
| `Profile` | Chrome, Edge, Brave, Vivaldi: the profile **directory** name (`Default`, `Profile 1`; see `chrome://version`, "Profile Path"). Firefox: the profile name |
| `BrowserArgs` | extra browser arguments, separated by spaces |

```
Host customer-hypervisor
    URL https://10.10.0.5:8006/
    Browser chrome
    Profile "Profile 1"
    # Tags customer hypervisor proxmox
```

`Profile` and `BrowserArgs` are ignored for Safari and the system default browser. Self-signed certificates: the browser warning is not bypassed.

## Defaults and order

### RDP and web files: file defaults

A `Host *` block in an RDP or web file holds the defaults for **all records of the same file, and for no other file**. This is meant for one file per domain, customer or browser profile:

```
# ~/.config/remotes/hosts/customer-a/domain1-rdp.conf
Host *
    User DOMAIN1\myuser
    Screen Full
    RdpOption redirectclipboard:i:1
    # Tags domain1

Host d1-dc01
    HostName 10.1.0.1

Host d1-app01
    HostName 10.1.0.2
    User DOMAIN1\special
```

```
# ~/.config/remotes/hosts/customer-a/domain2-rdp.conf
Host *
    User DOMAIN2\myuser
```

- A record's own value always wins over the default (`d1-app01` above keeps its own user).
- The block can stand anywhere in the file; the usual place is the top.
- `RdpOption` lines add up: the defaults come first, then the record's own lines, so a record can override a single property.
- Tags are combined: every record above is also found by searching `domain1`.
- `Profile` and `BrowserArgs` belong to one browser. A web record that sets a different `Browser` than the file default does not inherit them.
- Several `Host *` blocks in one file are merged; for a repeated key the first one wins.
- The preview (`?`) shows the defaults a record receives.
- Other wildcard patterns (`Host lab-*`) are ignored in these files.

### SSH files: normal ssh_config rules

SSH files keep the normal OpenSSH semantics, so they stay valid for plain `ssh` as well. Remotes connects through a temporary ssh configuration that includes the files in this order: the files in `hosts/` in path order, then `~/.ssh/config` last. For every option **the first value found wins**, and `Host *` is **not** limited to its own file: it applies to every host of every file, and where it stands above a record it overrides that record's own value.

Tested with OpenSSH 9.6, `User myadmin` in a `Host *` block, `lab01` having its own `User labuser`, `other01` (in another file) having `User otheruser`:

| Where the block stands | lab01 | lab02 | other01 |
|---|---|---|---|
| `Host *` at the top of the lab file | myadmin | myadmin | myadmin |
| `Host *` at the end of the lab file | labuser | myadmin | myadmin |
| `Host lab*` at the end of the lab file | labuser | myadmin | otheruser |
| `Host *` only in `~/.ssh/config` (the last file) | labuser | fallback value | otheruser |

What to use:

- **Global defaults**, for example `StrictHostKeyChecking accept-new`: a `Host *` block in `~/.ssh/config`, below its `Include` line if it has one. It has the lowest priority, so every record can still set its own value.
- **Defaults for the hosts of one file**: a name pattern **below** the records, for example `Host lab*`, with the aliases of that file sharing the prefix. Or list the aliases: `Host lab01 lab02 lab03`.

## Usage

```sh
rms                      # everything (same as: remotes)
rms customer-a           # pre-filled search; a single match connects at once
rms --type ssh           # only one type (ssh, rdp or web)

sshs                     # same as: rms --type ssh
rdps customer-a          # RDP targets, search pre-filled
webs                     # web targets
```

### Keys in the menu

| Key | Action |
|---|---|
| Enter | connect: `ssh`, Windows App, or browser, depending on the type |
| `Ctrl+V` | SSH only: verbose connection (`ssh -vvvv`) |
| `Ctrl+R` | SSH only: remove the host key from `known_hosts` (after a server was reinstalled) |
| `Ctrl+E` | open the source file of the highlighted target in the editor |
| `?` | show or hide the preview |
| Esc, `Ctrl+C` | exit |

`Ctrl+R` resolves the real name and port with `ssh -G` (HostName or HostKeyAlias, `[host]:port` for non-default ports) before calling `ssh-keygen -R`. `ssh-keygen` keeps a `known_hosts.old` backup. A custom `UserKnownHostsFile` is not handled.

### Environment variables

All optional. Export them in your shell startup file if you want them permanently.

| Variable | Default | Meaning |
|---|---|---|
| `REMOTES_HOME` | `~/.config/remotes` | root folder (records in `hosts/`, recent list). The installer always uses the default |
| `REMOTES_EDITOR` | `code` | editor command for `Ctrl+E` |
| `REMOTES_BROWSER` | `default` | browser for web records without a `Browser` key |
| `REMOTES_SSH_CONFIG` | `~/.ssh/config` | main ssh config to list; set to an empty value to hide it |
| `REMOTES_ASK_USER` | `1` | ask for the user name of SSH targets that have none; `0` switches it off |

## How it works

- On every start the record files are merged into one temporary file with a marker per source file, parsed with a single `awk` program, and shown in `fzf`. Nothing is cached.
- **SSH**: a temporary ssh config that includes every listed ssh file (and `~/.ssh/config` last) is created for the connection and used with `ssh -F`. That is why `~/.ssh/config` needs no `Include` line for Remotes. If you also want plain `ssh <alias>`, `scp` or VS Code Remote-SSH to see your records, add this to the top of `~/.ssh/config`, before the first `Host` line:

  ```
  Include ~/.config/remotes/hosts/*/*ssh.conf ~/.config/remotes/hosts/*ssh.conf
  ```

- **RDP**: a `.rdp` file is written to `$TMPDIR/remotes-rdp/`, opened in the Windows App, and files older than 12 hours are removed on the next start.
- **Web**: `open`, or `open -na "<browser>" --args ...` when a profile or arguments are set.
- The recent list is stored as `type:alias` lines in `~/.config/remotes/recent`.
- **Windows**: the same flow with `ssh.exe -F` and a temporary config (include paths use forward slashes), an `.rdp` file in `%TEMP%\remotes-rdp\` opened with `mstsc.exe`, and `Start-Process` for web targets (`chrome.exe`, `msedge.exe`, `firefox.exe` and so on, or the system default browser). The preview text is a prepared temporary file that fzf shows. The user name question uses your Windows login name as the default.

## Security notes

Record files contain host names, addresses and user names, but **no passwords or keys**. Treat them as internal data: do not publish your `hosts/` folder in a public repository. Private keys stay in `~/.ssh`.

## Troubleshooting

| Symptom | Check |
|---|---|
| `fzf is not available` | `brew install fzf` |
| `no usable targets found` | files must be named `ssh.conf`/`rdp.conf`/`web.conf` or end in `-ssh.conf`/`-rdp.conf`/`-web.conf`; RDP needs `HostName`, web needs `URL` or `HostName` |
| `your records are still in ~/.remotes/hosts` | run the installer again, or move them: `mv ~/.remotes/hosts ~/.config/remotes/hosts` |
| a record is missing from the list | the same alias was defined earlier for the same type (first definition wins) |
| a file default has no effect | it must be a `Host *` block in an RDP or web file, and the record must be in the same file |
| `Screen` or `Mode` has no effect | check the spelling of the value (`Full`, `1600x900`, `Admin`) |
| aliases not found | open a new terminal window, or `source ~/.zshrc` |
| `rms` runs something else | another program or alias named `rms` comes first; remove it or drop the `rms` line from `~/.config/remotes/bin/aliases.sh` |
| RDP does not open | install "Windows App" from the Mac App Store |
| `Ctrl+E` does nothing | install the `code` command or set `REMOTES_EDITOR` |
| `rms` is not recognized (Windows) | open a new terminal window; check that `%USERPROFILE%\.config\remotes\bin` is in the user path (`$env:Path`) |
| `rms` starts an old program (Windows) | another `rms.cmd`, `sshs.cmd` ... earlier on the path; `Get-Command sshs -All` shows where, then remove or rename it |
| RDP window is not resizable (Windows) | known mstsc limitation; the default is full screen, `Screen Window` is opt-in |
| `fzf.exe` not found (Windows) | `winget install --id junegunn.fzf -e`, then open a new terminal window |
| SSH asks for a user name every time | the alias has no `User`; add one to the record (or a pattern block), or set `REMOTES_ASK_USER=0` |
| SSH works in `rms` but not in the plain terminal | add the `Include` line shown above to `~/.ssh/config` |

## Repository layout

```
install.sh              installer for macOS
install.ps1             installer for Windows
macos/remotes.sh        the picker for macOS (single file, parsers included)
macos/sshs.sh           wrapper: remotes.sh --type ssh
macos/rdps.sh           wrapper: remotes.sh --type rdp
macos/webs.sh           wrapper: remotes.sh --type web
windows/remotes.ps1     the picker for Windows (single file)
windows/*.cmd           launchers: rms, remotes, sshs, rdps, webs
samples/                reference samples for new records (shared)
LICENSE                 MIT
```

The repository folders are only the download source; the installers put the scripts together into `~/.config/remotes/bin/` (macOS) or `%USERPROFILE%\.config\remotes\bin\` (Windows).

## Roadmap

- Migration helper for records kept by the older standalone `sshs`, `rdps` and `webs` tools.

## License

[MIT](LICENSE)
