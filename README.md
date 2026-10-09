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

Platform: **macOS** (zsh). A Windows version is planned and is not part of this repository yet.

## Features

- One list for SSH, RDP and web targets, with the same columns for every type: Type, Host (Target), Info, Tags, Group.
- Search by anything visible: type, alias, address, user or browser, tags, customer or group name.
- Records live in one folder per customer. The same alias can exist once per type (for example `a-fw` as SSH and as web GUI).
- SSH records use normal OpenSSH `ssh_config` syntax. Everything `ssh` understands works (`ProxyJump`, `IdentityFile`, `LocalForward`, 1Password agent, ...).
- RDP records generate a temporary `.rdp` file and open it in the Windows App. Window mode, full screen or a fixed size, administrative session, and raw `.rdp` properties are supported.
- Web records open in the default browser or in a browser and profile of your choice, so each customer can have separate cookies and sessions.
- The 5 most recently used targets are pinned to the top.
- Preview of the record (`?`), open the source file in your editor (`Ctrl+E`).
- SSH helpers: verbose connection (`Ctrl+V`) and removal of a stale host key from `known_hosts` (`Ctrl+R`).
- Start with a pre-filled search: `sshs customer-a`. If only one target matches, it connects immediately.
- No `Include` line is required in `~/.ssh/config`: Remotes builds a temporary ssh configuration for every connection.
- Four commands from one program: `remotes` (everything), `sshs` (SSH only), `rdps` (RDP only), `webs` (web only).

## Requirements

| Requirement | Needed for | How to get it |
|---|---|---|
| macOS with zsh | everything | built in |
| [fzf](https://github.com/junegunn/fzf) | the menu | `brew install fzf` |
| `awk`, `ssh`, `ssh-keygen`, `open`, `find`, `sed`, `grep`, ... | everything | built in |
| `curl` | the one-line installer | built in |
| Windows App | RDP targets (optional) | Mac App Store, "Windows App" |
| VS Code `code` command | `Ctrl+E` (optional) | VS Code, Command Palette: "Shell Command: Install 'code' command in PATH" |

The installer never installs dependencies. If something required is missing, it lists what is missing and how to install it, and it copies no files.

## Installation

### One line

```sh
curl -fsSL https://raw.githubusercontent.com/sikkancs/remotes/main/install.sh | bash
```

### From a clone

```sh
git clone https://github.com/sikkancs/remotes.git
cd remotes
bash install.sh
```

### What the installer does

1. Checks the dependencies. If any is missing it prints the list with install hints and stops before copying anything.
2. Downloads every file to a temporary folder and verifies it. Nothing is touched unless all downloads succeeded.
3. Installs the files below. An existing file with different content is kept as `<name>.bak.<timestamp>`, so an older standalone `sshs.sh`, `rdps.sh` or `webs.sh` is never lost.
4. Creates the aliases `remotes`, `sshs`, `rdps` and `webs` for your shell.

| File | Location |
|---|---|
| picker | `~/.config/remotes/remotes.sh` |
| aliases | `~/.config/remotes/aliases.sh` |
| `sshs` wrapper | `~/.config/sshs/sshs.sh` |
| `rdps` wrapper | `~/.config/rdps/rdps.sh` |
| `webs` wrapper | `~/.config/webs/webs.sh` |
| reference samples | `~/.remotes/samples/*.sample` |
| your data folder | `~/.remotes/hosts/` |

Aliases are set up for the shell found in `$SHELL`:

- **zsh**: a marked block in `~/.zshrc` that sources `aliases.sh`
- **bash**: the same block in `~/.bash_profile`
- **fish**: `~/.config/fish/conf.d/remotes.fish`
- other shells: the installer prints the four alias lines for you to add

Open a new terminal window afterwards (or `source` the startup file).

### Options

| Option | Meaning |
|---|---|
| `--no-alias` | do not touch any shell startup file |
| `--shell zsh\|bash\|fish` | set up aliases for this shell instead of the detected one |
| `--uninstall` | remove the installed files and the alias setup (your data stays) |
| `-h`, `--help` | show help |

With the one-liner, pass options after `bash -s --`:

```sh
curl -fsSL https://raw.githubusercontent.com/sikkancs/remotes/main/install.sh | bash -s -- --no-alias
```

Environment variables: `REMOTES_REF` (branch or tag to download, default `main`), `REMOTES_DIR` (data folder, default `~/.remotes`), `REMOTES_SOURCE_DIR` (use a local checkout instead of downloading).

### Manual installation

```sh
mkdir -p ~/.config/remotes ~/.config/sshs ~/.config/rdps ~/.config/webs
cp remotes/remotes.sh ~/.config/remotes/
cp sshs/sshs.sh ~/.config/sshs/
cp rdps/rdps.sh ~/.config/rdps/
cp webs/webs.sh ~/.config/webs/
chmod +x ~/.config/remotes/remotes.sh ~/.config/*/*.sh
```

Then add your own aliases, for example `alias remotes="$HOME/.config/remotes/remotes.sh"`.

### Uninstall

```sh
bash install.sh --uninstall
```

Your records in `~/.remotes` are kept.

## Quick start

1. Create a folder for a customer and start from a sample:

   ```sh
   mkdir -p ~/.remotes/hosts/customer-a
   cp ~/.remotes/samples/ssh.sample ~/.remotes/hosts/customer-a/customer-a-ssh.conf
   cp ~/.remotes/samples/rdp.sample ~/.remotes/hosts/customer-a/customer-a-rdp.conf
   cp ~/.remotes/samples/web.sample ~/.remotes/hosts/customer-a/customer-a-web.conf
   ```

2. Edit the copied files: keep your own records, delete the example ones.
3. Run `remotes`.

The files in `~/.remotes/samples/` are reference documentation and are never read as data. Keep them there.

## Data layout

```
~/.remotes/
  samples/                          reference files, not read as data
    ssh.sample
    rdp.sample
    web.sample
  hosts/
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
- Wildcard hosts (`Host *`) are not listed.
- RDP and web files accept comments at the end of a line (`Screen Full   # comment`). SSH files do not: `ssh` itself does not support them, so put comments on their own line there.

Complete, commented examples for every key are in [`samples/`](samples).

### SSH

Standard `ssh_config`. Remotes reads `Host`, `HostName` (shown in the list), `User` (shown in the Info column) and `# Tags`; everything else is passed to `ssh` untouched.

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

## Usage

```sh
remotes                  # everything
remotes customer-a       # pre-filled search; a single match connects at once
remotes --type ssh       # only one type (ssh, rdp or web)

sshs                     # same as: remotes --type ssh
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

| Variable | Default | Meaning |
|---|---|---|
| `REMOTES_DIR` | `~/.remotes` | data folder |
| `REMOTES_SSH_CONFIG` | `~/.ssh/config` | main ssh config to list; set to an empty value to hide it |
| `REMOTES_APP_DIR` | `~/.config/remotes` | state folder (recent list) |
| `REMOTES_EDITOR` | `code` | editor command for `Ctrl+E` |
| `REMOTES_BROWSER` | `default` | browser for web records without a `Browser` key |
| `REMOTES_HOME` | `~/.config/remotes` | where the wrappers look for `remotes.sh` |

## How it works

- On every start the record files are merged into one temporary file with a marker per source file, parsed with a single `awk` program, and shown in `fzf`. Nothing is cached.
- **SSH**: a temporary ssh config that includes every listed ssh file (and `~/.ssh/config` last) is created for the connection and used with `ssh -F`. That is why `~/.ssh/config` needs no `Include` line for Remotes. If you also want plain `ssh <alias>`, `scp` or VS Code Remote-SSH to see your records, add this to the top of `~/.ssh/config`:

  ```
  Include ~/.remotes/hosts/*/*ssh.conf ~/.remotes/hosts/*ssh.conf
  ```

- **RDP**: a `.rdp` file is written to `$TMPDIR/remotes-rdp/`, opened in the Windows App, and files older than 12 hours are removed on the next start.
- **Web**: `open`, or `open -na "<browser>" --args ...` when a profile or arguments are set.
- The recent list is stored as `type:alias` lines in `~/.config/remotes/recent`.

## Security notes

Record files contain host names, addresses and user names, but **no passwords or keys**. Treat them as internal data: do not publish your `~/.remotes/hosts` folder in a public repository. Private keys stay in `~/.ssh`.

## Troubleshooting

| Symptom | Check |
|---|---|
| `fzf is not available` | `brew install fzf` |
| `no usable targets found` | files must be named `ssh.conf`/`rdp.conf`/`web.conf` or end in `-ssh.conf`/`-rdp.conf`/`-web.conf`; RDP needs `HostName`, web needs `URL` or `HostName` |
| a record is missing from the list | the same alias was defined earlier for the same type (first definition wins); wildcard aliases are hidden |
| `Screen` or `Mode` has no effect | a comment at the end of the line is fine in RDP and web files; check the spelling of the value (`Full`, `1600x900`, `Admin`) |
| aliases not found | open a new terminal window, or `source ~/.zshrc` |
| RDP does not open | install "Windows App" from the Mac App Store |
| `Ctrl+E` does nothing | install the `code` command or set `REMOTES_EDITOR` |
| SSH works in `remotes` but not in the plain terminal | add the `Include` line shown above to `~/.ssh/config` |

## Repository layout

```
install.sh              installer
remotes/remotes.sh      the picker (single file, parsers included)
sshs/sshs.sh            wrapper: remotes --type ssh
rdps/rdps.sh            wrapper: remotes --type rdp
webs/webs.sh            wrapper: remotes --type web
samples/                reference samples for new records
```

## Roadmap

- Windows version (PowerShell, same data layout).
