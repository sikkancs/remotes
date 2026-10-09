#!/usr/bin/env bash

# Remotes installer (macOS)
#
# Installs:
#   ~/.config/remotes/remotes.sh      the picker itself
#   ~/.config/sshs/sshs.sh            wrapper: SSH targets only
#   ~/.config/rdps/rdps.sh            wrapper: RDP targets only
#   ~/.config/webs/webs.sh            wrapper: web targets only
#   ~/.config/remotes/aliases.sh      aliases: remotes, sshs, rdps, webs
#   ~/.remotes/samples/*.sample       reference files for new records
#   ~/.remotes/hosts/                 empty data folder (created if missing)
#
# Behaviour:
#   - Dependencies are never installed automatically. If something is missing,
#     the installer lists what and how to install it, and copies NO files.
#   - Files are downloaded to a temporary folder first and verified; nothing
#     is touched unless every download succeeded.
#   - An existing file with different content is kept as <name>.bak.<timestamp>.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/sikkancs/remotes/main/install.sh | bash
#   ./install.sh [--uninstall] [--no-alias] [--shell zsh|bash|fish] [--help]
#
# When started from a clone of the repository, the files next to this script
# are used instead of downloading them.

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

# Where the files are downloaded from (branch or tag can be overridden).
REPO_SLUG="sikkancs/remotes"
REF="${REMOTES_REF:-main}"
RAW_BASE="${REMOTES_RAW_BASE:-https://raw.githubusercontent.com/${REPO_SLUG}/${REF}}"

# Program directory of the picker and its alias file.
INSTALL_APP_DIR="$HOME/.config/remotes"
ALIAS_FILE="$INSTALL_APP_DIR/aliases.sh"

# Data directory (hosts and samples). Honours REMOTES_DIR like remotes.sh does.
DATA_DIR="${REMOTES_DIR:-$HOME/.remotes}"

# Markers that delimit the block added to the shell startup file.
RC_BEGIN="# >>> remotes >>>"
RC_END="# <<< remotes <<<"

# Fish gets its own file instead of a block.
FISH_CONF="$HOME/.config/fish/conf.d/remotes.fish"

# Command line options.
OPT_UNINSTALL=0
OPT_NO_ALIAS=0
OPT_SHELL=""

# Files to install: source path in the repository, destination, file mode.
SRC_LIST=()
DEST_LIST=()
MODE_LIST=()

# Missing dependencies collected by check_dependencies.
MISSING_NAMES=()
MISSING_HINTS=()

# Staging folder, created later.
STAGE=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Print a normal message.
info() {
    printf '%s\n' "$1"
}

# Print a warning to stderr.
warn() {
    printf 'Warning: %s\n' "$1" >&2
}

# Print an error to stderr and stop.
die() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

# Remove the staging folder on exit.
cleanup() {
    if [ -n "$STAGE" ] && [ -d "$STAGE" ]; then
        rm -rf "$STAGE"
    fi
}
trap cleanup EXIT

# Print the help text.
usage() {
    cat <<'EOF'
Remotes installer (macOS)

Usage:
  install.sh [options]

Options:
  --uninstall        Remove the installed files and the alias setup
                     (your data in ~/.remotes is kept)
  --no-alias         Do not touch any shell startup file
  --shell NAME       Set up aliases for zsh, bash or fish
                     (default: detected from $SHELL)
  -h, --help         Show this help

Environment variables:
  REMOTES_REF        Branch or tag to download (default: main)
  REMOTES_DIR        Data directory (default: ~/.remotes)
  REMOTES_SOURCE_DIR Use a local checkout instead of downloading
EOF
}

# Register one file for installation.
add_file() {
    SRC_LIST+=("$1")
    DEST_LIST+=("$2")
    MODE_LIST+=("$3")
}

# Register one missing dependency with an installation hint.
add_missing() {
    MISSING_NAMES+=("$1")
    MISSING_HINTS+=("$2")
}

# Installation hint for a missing command.
hint_for() {
    case "$1" in
        fzf)
            if command -v brew >/dev/null 2>&1; then
                printf 'brew install fzf'
            else
                printf 'install Homebrew (https://brew.sh), then run: brew install fzf   (other options: https://github.com/junegunn/fzf#installation)'
            fi
            ;;
        curl)
            printf 'ships with macOS, check your PATH (or: brew install curl)'
            ;;
        *)
            printf 'ships with macOS; your system or PATH looks incomplete'
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------

# Collect every missing required command. Nothing is installed here.
check_dependencies() {
    local cmd

    # fzf is the only tool macOS does not ship; check it first.
    command -v fzf >/dev/null 2>&1 || add_missing "fzf" "$(hint_for fzf)"

    # curl is needed only when the files are downloaded.
    if [ -z "$SOURCE_DIR" ]; then
        command -v curl >/dev/null 2>&1 || add_missing "curl" "$(hint_for curl)"
    fi

    # Tools used by remotes.sh and by this installer (all part of macOS).
    for cmd in zsh awk ssh ssh-keygen open find sort mktemp sed tr cut head grep cmp cp mv rm chmod mkdir date; do
        command -v "$cmd" >/dev/null 2>&1 || add_missing "$cmd" "$(hint_for "$cmd")"
    done
}

# Print the missing dependencies and stop without installing anything.
report_missing_and_exit() {
    local i
    printf 'Missing dependencies. Nothing was installed.\n\n' >&2

    for i in "${!MISSING_NAMES[@]}"; do
        printf '  %-10s %s\n' "${MISSING_NAMES[$i]}" "${MISSING_HINTS[$i]}" >&2
    done

    printf '\nInstall the missing items, then run the installer again.\n' >&2
    exit 1
}

# Optional tools: only informational, never blocking. Prints nothing when
# everything is present.
print_optional_notes() {
    if ! command -v code >/dev/null 2>&1; then
        printf '%s\n' "  - Ctrl+E (edit source file) uses the VS Code 'code' command, which was not found."
        printf '%s\n' "    Install the command from VS Code (Command Palette: Shell Command), or set REMOTES_EDITOR."
    fi

    if [ ! -d "/Applications/Windows App.app" ] && [ ! -d "$HOME/Applications/Windows App.app" ]; then
        printf '%s\n' "  - RDP targets open in the Windows App, which was not found."
        printf '%s\n' "    Install 'Windows App' from the Mac App Store. SSH and web targets work without it."
    fi
}

# ---------------------------------------------------------------------------
# Download / copy to the staging folder
# ---------------------------------------------------------------------------

# Fetch every registered file into the staging folder as 0, 1, 2, ...
# Any failure stops the installer before anything is copied.
stage_files() {
    local i src target first

    STAGE=$(mktemp -d "${TMPDIR:-/tmp}/remotes-install.XXXXXX") || die "cannot create a temporary folder."

    for i in "${!SRC_LIST[@]}"; do
        src="${SRC_LIST[$i]}"
        target="$STAGE/$i"

        if [ -n "$SOURCE_DIR" ]; then
            # Local checkout.
            [ -f "$SOURCE_DIR/$src" ] || die "file not found in the local checkout: $SOURCE_DIR/$src"
            cp "$SOURCE_DIR/$src" "$target" || die "cannot read $SOURCE_DIR/$src"
        else
            # Download from GitHub.
            info "  downloading $src"
            curl -fsSL --retry 2 --connect-timeout 15 -o "$target" "$RAW_BASE/$src" ||
                die "download failed: $RAW_BASE/$src (nothing was installed)"
        fi

        # The file must not be empty.
        [ -s "$target" ] || die "empty file received for $src (nothing was installed)"

        # Scripts must start with a shebang; this catches HTML error pages.
        if [ "${MODE_LIST[$i]}" = "755" ]; then
            first=$(head -c 2 "$target")
            [ "$first" = "#!" ] || die "$src does not look like a script (nothing was installed)"
        fi
    done
}

# ---------------------------------------------------------------------------
# Install the staged files
# ---------------------------------------------------------------------------

# Copy every staged file to its destination; keep a backup of changed files.
install_files() {
    local stamp i staged dest mode
    stamp=$(date +%Y%m%d%H%M%S)

    for i in "${!SRC_LIST[@]}"; do
        staged="$STAGE/$i"
        dest="${DEST_LIST[$i]}"
        mode="${MODE_LIST[$i]}"

        mkdir -p "$(dirname "$dest")" || die "cannot create $(dirname "$dest")"

        if [ -f "$dest" ]; then
            if cmp -s "$staged" "$dest"; then
                # Same content: only make sure the mode is right.
                chmod "$mode" "$dest"
                info "  unchanged  $dest"
                continue
            fi

            # Different content: keep the old file next to the new one.
            cp -p "$dest" "$dest.bak.$stamp" || die "cannot back up $dest"
            cp "$staged" "$dest" || die "cannot write $dest"
            chmod "$mode" "$dest"
            info "  updated    $dest   (old version: $dest.bak.$stamp)"
        else
            cp "$staged" "$dest" || die "cannot write $dest"
            chmod "$mode" "$dest"
            info "  installed  $dest"
        fi
    done

    # Empty data folder for the user's records.
    mkdir -p "$DATA_DIR/hosts" || die "cannot create $DATA_DIR/hosts"
}

# ---------------------------------------------------------------------------
# Alias setup
# ---------------------------------------------------------------------------

# Startup file of a shell (zsh and bash only).
rc_file_for() {
    case "$1" in
        zsh)  printf '%s' "${ZDOTDIR:-$HOME}/.zshrc" ;;
        # macOS Terminal starts login shells, which read .bash_profile.
        bash) printf '%s' "$HOME/.bash_profile" ;;
    esac
}

# Add the block that sources the alias file (once).
add_rc_block() {
    local rc="$1"

    touch "$rc" || die "cannot write $rc"

    if grep -qF "$RC_BEGIN" "$rc"; then
        info "  alias block already present in $rc"
        return 0
    fi

    {
        printf '\n%s\n' "$RC_BEGIN"
        printf '%s\n' '[ -f "$HOME/.config/remotes/aliases.sh" ] && . "$HOME/.config/remotes/aliases.sh"'
        printf '%s\n' "$RC_END"
    } >> "$rc"

    info "  alias block added to $rc"
}

# Remove the alias block from a startup file (if present).
remove_rc_block() {
    local rc="$1" tmp

    [ -f "$rc" ] || return 0
    grep -qF "$RC_BEGIN" "$rc" || return 0

    tmp=$(mktemp "${TMPDIR:-/tmp}/remotes-rc.XXXXXX") || return 1

    awk -v b="$RC_BEGIN" -v e="$RC_END" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip   { print }
    ' "$rc" > "$tmp" && cat "$tmp" > "$rc"

    rm -f "$tmp"
    info "  alias block removed from $rc"
}

# Create the aliases for the detected or requested shell.
setup_aliases() {
    local shell_name rc

    shell_name="${OPT_SHELL:-$(basename "${SHELL:-}")}"

    case "$shell_name" in
        zsh|bash)
            # One alias file, sourced from the startup file.
            cat > "$ALIAS_FILE" <<'EOF'
# Managed by the Remotes installer; re-running the installer rewrites this file.
alias remotes="$HOME/.config/remotes/remotes.sh"
alias sshs="$HOME/.config/sshs/sshs.sh"
alias rdps="$HOME/.config/rdps/rdps.sh"
alias webs="$HOME/.config/webs/webs.sh"
EOF
            rc=$(rc_file_for "$shell_name")
            add_rc_block "$rc"
            ALIAS_HINT="Open a new terminal window (or run: source $rc)"
            ;;
        fish)
            mkdir -p "$(dirname "$FISH_CONF")" || die "cannot create $(dirname "$FISH_CONF")"
            cat > "$FISH_CONF" <<'EOF'
# Managed by the Remotes installer; re-running the installer rewrites this file.
alias remotes "$HOME/.config/remotes/remotes.sh"
alias sshs "$HOME/.config/sshs/sshs.sh"
alias rdps "$HOME/.config/rdps/rdps.sh"
alias webs "$HOME/.config/webs/webs.sh"
EOF
            info "  aliases written to $FISH_CONF"
            ALIAS_HINT="Open a new terminal window"
            ;;
        *)
            warn "unknown shell '$shell_name'; no aliases were created."
            info "Add these lines to your shell startup file manually:"
            info '  alias remotes="$HOME/.config/remotes/remotes.sh"'
            info '  alias sshs="$HOME/.config/sshs/sshs.sh"'
            info '  alias rdps="$HOME/.config/rdps/rdps.sh"'
            info '  alias webs="$HOME/.config/webs/webs.sh"'
            ALIAS_HINT="Add the aliases above, then open a new terminal window"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

do_uninstall() {
    local file

    info "Removing Remotes (your data in $DATA_DIR is kept)."

    # Program files and wrappers.
    for file in \
        "$INSTALL_APP_DIR/remotes.sh" \
        "$ALIAS_FILE" \
        "$HOME/.config/sshs/sshs.sh" \
        "$HOME/.config/rdps/rdps.sh" \
        "$HOME/.config/webs/webs.sh" \
        "$FISH_CONF"
    do
        if [ -f "$file" ]; then
            rm -f "$file"
            info "  removed    $file"
        fi
    done

    # Alias blocks in every startup file this installer may have touched.
    remove_rc_block "${ZDOTDIR:-$HOME}/.zshrc"
    remove_rc_block "$HOME/.bash_profile"
    remove_rc_block "$HOME/.bashrc"

    # Remove folders that are now empty (the recent file keeps remotes/ alive).
    rmdir "$HOME/.config/sshs" "$HOME/.config/rdps" "$HOME/.config/webs" 2>/dev/null || true

    info ""
    info "Left in place: $DATA_DIR (your hosts), $INSTALL_APP_DIR/recent, and any *.bak.* backups."
    info "Open a new terminal window so the removed aliases disappear."
}

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --uninstall)
            OPT_UNINSTALL=1
            shift
            ;;
        --no-alias)
            OPT_NO_ALIAS=1
            shift
            ;;
        --shell)
            [ $# -ge 2 ] || die "--shell needs a value: zsh, bash or fish."
            OPT_SHELL="$2"
            shift 2
            ;;
        --shell=*)
            OPT_SHELL="${1#--shell=}"
            shift
            ;;
        *)
            die "unknown option: $1 (see --help)"
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Remotes needs macOS (open, Windows App). A Windows version is separate.
if [ "$(uname -s)" != "Darwin" ]; then
    die "Remotes currently supports macOS only."
fi

# Uninstall does not need any dependency or download.
if [ "$OPT_UNINSTALL" -eq 1 ]; then
    do_uninstall
    exit 0
fi

# Use a local checkout when this script sits next to the repository files,
# or when REMOTES_SOURCE_DIR is set. Otherwise download from GitHub.
SOURCE_DIR="${REMOTES_SOURCE_DIR:-}"
if [ -z "$SOURCE_DIR" ] && [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    candidate="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$candidate/remotes/remotes.sh" ]; then
        SOURCE_DIR="$candidate"
    fi
fi

# Dependencies first: if anything is missing, stop before copying anything.
check_dependencies
if [ "${#MISSING_NAMES[@]}" -gt 0 ]; then
    report_missing_and_exit
fi

# The files to install.
add_file "remotes/remotes.sh" "$INSTALL_APP_DIR/remotes.sh" "755"
add_file "sshs/sshs.sh"       "$HOME/.config/sshs/sshs.sh"  "755"
add_file "rdps/rdps.sh"       "$HOME/.config/rdps/rdps.sh"  "755"
add_file "webs/webs.sh"       "$HOME/.config/webs/webs.sh"  "755"
add_file "samples/ssh.sample" "$DATA_DIR/samples/ssh.sample" "644"
add_file "samples/rdp.sample" "$DATA_DIR/samples/rdp.sample" "644"
add_file "samples/web.sample" "$DATA_DIR/samples/web.sample" "644"

if [ -n "$SOURCE_DIR" ]; then
    info "Installing Remotes from $SOURCE_DIR"
else
    info "Installing Remotes from $RAW_BASE"
fi

# Download or copy everything to the staging folder first.
stage_files

# Copy to the final locations.
info ""
info "Files:"
install_files

# Aliases.
ALIAS_HINT=""
info ""
if [ "$OPT_NO_ALIAS" -eq 1 ]; then
    info "Aliases skipped (--no-alias)."
else
    info "Aliases:"
    setup_aliases
fi

# Next steps.
info ""
info "Done. Next steps:"
if [ -n "$ALIAS_HINT" ]; then
    info "  1. $ALIAS_HINT"
else
    info "  1. Run the picker with: $INSTALL_APP_DIR/remotes.sh"
fi
info "  2. Create your first records from a sample, for example:"
info "       mkdir -p $DATA_DIR/hosts/mycustomer"
info "       cp $DATA_DIR/samples/ssh.sample $DATA_DIR/hosts/mycustomer/mycustomer-ssh.conf"
info "  3. Start the picker: remotes   (or sshs, rdps, webs)"

# Optional tools that were not found.
OPTIONAL_NOTES=$(print_optional_notes)
if [ -n "$OPTIONAL_NOTES" ]; then
    info ""
    info "Optional (not required):"
    info "$OPTIONAL_NOTES"
fi
