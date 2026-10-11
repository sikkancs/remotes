#!/usr/bin/env bash

# Remotes installer (macOS)
#
# Everything lives in ONE folder, ~/.config/remotes:
#   bin/remotes.sh      the picker itself
#   bin/sshs.sh         wrapper: SSH targets only
#   bin/rdps.sh         wrapper: RDP targets only
#   bin/webs.sh         wrapper: web targets only
#   bin/aliases.sh      aliases: rms, remotes, sshs, rdps, webs
#   samples/*.sample    reference files for new records
#   hosts/              YOUR records (the installer never changes their content)
#   recent              recently used targets (created by the picker)
#
# Behaviour:
#   - Dependencies are never installed automatically. If something is missing,
#     the installer lists what and how to install it, and copies NO files.
#   - Files are downloaded to a temporary folder first and verified; nothing
#     is touched unless every download succeeded.
#   - An existing file with different content is kept as <name>.bak.<timestamp>.
#   - Older layouts are migrated: records in ~/.remotes/hosts are moved to
#     ~/.config/remotes/hosts, and files of earlier versions of this installer
#     are removed. A foreign file (for example an old standalone app) is
#     never touched.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/sikkancs/remotes/main/install.sh | bash
#   bash install.sh [--uninstall] [--no-alias] [--shell zsh|bash|fish] [--help]

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

# Where the files are downloaded from (always the main branch).
RAW_BASE="https://raw.githubusercontent.com/sikkancs/remotes/main"

# The one folder of the whole application.
ROOT_DIR="$HOME/.config/remotes"
BIN_DIR="$ROOT_DIR/bin"
HOSTS_DIR="$ROOT_DIR/hosts"
SAMPLES_DIR="$ROOT_DIR/samples"
ALIAS_FILE="$BIN_DIR/aliases.sh"

# Data folder of the previous layout.
OLD_DATA_DIR="$HOME/.remotes"

# Markers that delimit the block added to the shell startup file.
RC_BEGIN="# >>> remotes >>>"
RC_END="# <<< remotes <<<"

# Texts that identify files created by earlier versions of this installer.
WRAPPER_MARKER="thin wrapper: opens the Remotes picker"
PROGRAM_MARKER="Remotes - one interactive picker"
ALIAS_MARKER="Managed by the Remotes installer"

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
                     (your records in ~/.config/remotes/hosts are kept)
  --no-alias         Do not touch any shell startup file
  --shell NAME       Set up aliases for zsh, bash or fish
                     (default: detected from $SHELL)
  -h, --help         Show this help
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

    # curl downloads the files.
    command -v curl >/dev/null 2>&1 || add_missing "curl" "$(hint_for curl)"

    # Tools used by remotes.sh and by this installer (all part of macOS).
    for cmd in zsh awk ssh ssh-keygen open find sort mktemp sed tr cut head grep cmp cp mv rm chmod mkdir rmdir date; do
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
# Download to the staging folder
# ---------------------------------------------------------------------------

# Download every registered file into the staging folder as 0, 1, 2, ...
# Any failure stops the installer before anything is copied.
stage_files() {
    local i src target first

    STAGE=$(mktemp -d "${TMPDIR:-/tmp}/remotes-install.XXXXXX") || die "cannot create a temporary folder."

    for i in "${!SRC_LIST[@]}"; do
        src="${SRC_LIST[$i]}"
        target="$STAGE/$i"

        info "  downloading $src"
        curl -fsSL --retry 2 --connect-timeout 15 -o "$target" "$RAW_BASE/$src" ||
            die "download failed: $RAW_BASE/$src (nothing was installed)"

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
}

# ---------------------------------------------------------------------------
# Older layouts
# ---------------------------------------------------------------------------

# Remove a file when it carries the given marker text (so only files of earlier
# installer versions go; anything else is kept). Arguments: file, marker, note.
remove_if_marked() {
    local file="$1" marker="$2" note="$3"

    [ -f "$file" ] || return 0

    if grep -qF "$marker" "$file"; then
        rm -f "$file"
        info "  removed    $file   ($note)"
    else
        info "  kept       $file   (not a Remotes file, probably the old standalone app)"
    fi
}

# Files of the previous flat layout, directly in ~/.config/remotes, and the
# wrappers of the oldest layout in ~/.config/sshs, ~/.config/rdps, ~/.config/webs.
remove_legacy_files() {
    local name dir

    remove_if_marked "$ROOT_DIR/remotes.sh" "$PROGRAM_MARKER" "now in bin/"
    remove_if_marked "$ROOT_DIR/aliases.sh" "$ALIAS_MARKER" "now in bin/"

    for name in sshs rdps webs; do
        remove_if_marked "$ROOT_DIR/$name.sh" "$WRAPPER_MARKER" "now in bin/"

        dir="$HOME/.config/$name"
        remove_if_marked "$dir/$name.sh" "$WRAPPER_MARKER" "old wrapper, now in $BIN_DIR"
        # Remove the folder too when nothing else is in it.
        rmdir "$dir" 2>/dev/null || true
    done
}

# Move the records of the previous layout (~/.remotes/hosts) to the new place.
# Nothing is overwritten: if the new folder already has content, only a note is
# printed. The old reference samples are installer files and are removed.
migrate_old_data() {
    local t

    [ -d "$OLD_DATA_DIR" ] || return 0

    if [ -d "$OLD_DATA_DIR/hosts" ]; then
        # An empty new folder (from an earlier run) may be replaced by the move.
        rmdir "$HOSTS_DIR" 2>/dev/null || true

        if [ ! -e "$HOSTS_DIR" ]; then
            mkdir -p "$ROOT_DIR" || die "cannot create $ROOT_DIR"
            mv "$OLD_DATA_DIR/hosts" "$HOSTS_DIR" || die "cannot move $OLD_DATA_DIR/hosts"
            info "  moved      $OLD_DATA_DIR/hosts  ->  $HOSTS_DIR"
        else
            info "  note       $OLD_DATA_DIR/hosts was NOT moved because $HOSTS_DIR already has content."
            info "             Merge them by hand, for example: cp -Rn $OLD_DATA_DIR/hosts/. $HOSTS_DIR/"
        fi
    fi

    # Old reference samples (replaced by the ones in the new samples folder).
    for t in ssh rdp web; do
        rm -f "$OLD_DATA_DIR/samples/$t.sample"
    done
    rmdir "$OLD_DATA_DIR/samples" 2>/dev/null || true

    # The old folder goes away only when nothing else is in it.
    if rmdir "$OLD_DATA_DIR" 2>/dev/null; then
        info "  removed    $OLD_DATA_DIR   (empty)"
    else
        info "  kept       $OLD_DATA_DIR   (still contains other files)"
    fi
}

# Tell the user about alias lines that still point to old locations. They are
# harmless or dead (the Remotes block defines the aliases again later), but
# worth cleaning up.
warn_stale_aliases() {
    local rc hits

    for rc in "${ZDOTDIR:-$HOME}/.zshrc" "$HOME/.bash_profile" "$HOME/.bashrc"; do
        [ -f "$rc" ] || continue

        hits=$(grep -nE 'config/(sshs|rdps|webs)/|config/remotes/(remotes|sshs|rdps|webs)\.sh' "$rc")
        if [ -n "$hits" ]; then
            info ""
            info "Note: $rc still has lines that point to old locations:"
            info "$hits"
            info "They can be deleted; the new aliases are defined by the Remotes block."
        fi
    done
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

# Remove the alias block from a startup file (if present).
# The optional second argument "quiet" suppresses the message.
remove_rc_block() {
    local rc="$1" quiet="${2:-}" tmp

    [ -f "$rc" ] || return 0
    grep -qF "$RC_BEGIN" "$rc" || return 0

    tmp=$(mktemp "${TMPDIR:-/tmp}/remotes-rc.XXXXXX") || return 1

    awk -v b="$RC_BEGIN" -v e="$RC_END" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip   { print }
    ' "$rc" > "$tmp" && cat "$tmp" > "$rc"

    rm -f "$tmp"
    [ "$quiet" = "quiet" ] || info "  alias block removed from $rc"
}

# Add the block that sources the alias file. A block from an earlier version
# (it pointed to the old alias file location) is replaced.
add_rc_block() {
    local rc="$1"

    touch "$rc" || die "cannot write $rc"

    if grep -qF "$RC_BEGIN" "$rc"; then
        if grep -qF '.config/remotes/bin/aliases.sh' "$rc"; then
            info "  alias block already present in $rc"
            return 0
        fi
        # Block of an earlier version: replace it.
        remove_rc_block "$rc" quiet
    fi

    {
        printf '\n%s\n' "$RC_BEGIN"
        printf '%s\n' '[ -f "$HOME/.config/remotes/bin/aliases.sh" ] && . "$HOME/.config/remotes/bin/aliases.sh"'
        printf '%s\n' "$RC_END"
    } >> "$rc"

    info "  alias block added to $rc"
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
alias rms="$HOME/.config/remotes/bin/remotes.sh"
alias remotes="$HOME/.config/remotes/bin/remotes.sh"
alias sshs="$HOME/.config/remotes/bin/sshs.sh"
alias rdps="$HOME/.config/remotes/bin/rdps.sh"
alias webs="$HOME/.config/remotes/bin/webs.sh"
EOF
            rc=$(rc_file_for "$shell_name")
            add_rc_block "$rc"
            ALIAS_HINT="Open a new terminal window (or run: source $rc)"
            ;;
        fish)
            mkdir -p "$(dirname "$FISH_CONF")" || die "cannot create $(dirname "$FISH_CONF")"
            cat > "$FISH_CONF" <<'EOF'
# Managed by the Remotes installer; re-running the installer rewrites this file.
alias rms "$HOME/.config/remotes/bin/remotes.sh"
alias remotes "$HOME/.config/remotes/bin/remotes.sh"
alias sshs "$HOME/.config/remotes/bin/sshs.sh"
alias rdps "$HOME/.config/remotes/bin/rdps.sh"
alias webs "$HOME/.config/remotes/bin/webs.sh"
EOF
            info "  aliases written to $FISH_CONF"
            ALIAS_HINT="Open a new terminal window"
            ;;
        *)
            warn "unknown shell '$shell_name'; no aliases were created."
            info "Add these lines to your shell startup file manually:"
            info '  alias rms="$HOME/.config/remotes/bin/remotes.sh"'
            info '  alias remotes="$HOME/.config/remotes/bin/remotes.sh"'
            info '  alias sshs="$HOME/.config/remotes/bin/sshs.sh"'
            info '  alias rdps="$HOME/.config/remotes/bin/rdps.sh"'
            info '  alias webs="$HOME/.config/remotes/bin/webs.sh"'
            ALIAS_HINT="Add the aliases above, then open a new terminal window"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

do_uninstall() {
    local file

    info "Removing Remotes (your records in $HOSTS_DIR are kept)."

    # Program files, wrappers, aliases and samples (all installer managed).
    for file in \
        "$BIN_DIR/remotes.sh" \
        "$BIN_DIR/sshs.sh" \
        "$BIN_DIR/rdps.sh" \
        "$BIN_DIR/webs.sh" \
        "$ALIAS_FILE" \
        "$SAMPLES_DIR/ssh.sample" \
        "$SAMPLES_DIR/rdp.sample" \
        "$SAMPLES_DIR/web.sample" \
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

    # Files of older layouts.
    remove_legacy_files

    # Remove the folders when nothing is left in them (hosts/ and recent keep
    # the root folder alive).
    rmdir "$BIN_DIR" "$SAMPLES_DIR" 2>/dev/null || true
    rmdir "$ROOT_DIR" 2>/dev/null || true

    info ""
    info "Left in place: $HOSTS_DIR (your records), $ROOT_DIR/recent, and any *.bak.* backups."
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

# Dependencies first: if anything is missing, stop before copying anything.
check_dependencies
if [ "${#MISSING_NAMES[@]}" -gt 0 ]; then
    report_missing_and_exit
fi

# The files to install.
add_file "macos/remotes.sh"   "$BIN_DIR/remotes.sh"     "755"
add_file "macos/sshs.sh"      "$BIN_DIR/sshs.sh"        "755"
add_file "macos/rdps.sh"      "$BIN_DIR/rdps.sh"        "755"
add_file "macos/webs.sh"      "$BIN_DIR/webs.sh"        "755"
add_file "samples/ssh.sample" "$SAMPLES_DIR/ssh.sample" "644"
add_file "samples/rdp.sample" "$SAMPLES_DIR/rdp.sample" "644"
add_file "samples/web.sample" "$SAMPLES_DIR/web.sample" "644"

info "Installing Remotes from $RAW_BASE"

# Download everything to the staging folder first.
stage_files

# Copy to the final locations.
info ""
info "Files:"
install_files

# Clean up and migrate older layouts, then make sure the records folder exists.
info ""
info "Older layouts:"
remove_legacy_files
migrate_old_data
mkdir -p "$HOSTS_DIR" || die "cannot create $HOSTS_DIR"

# Aliases.
ALIAS_HINT=""
info ""
if [ "$OPT_NO_ALIAS" -eq 1 ]; then
    info "Aliases skipped (--no-alias)."
else
    info "Aliases:"
    setup_aliases
fi

# Dead alias lines from older setups.
warn_stale_aliases

# Next steps.
info ""
info "Done. Next steps:"
if [ -n "$ALIAS_HINT" ]; then
    info "  1. $ALIAS_HINT"
else
    info "  1. Run the picker with: $BIN_DIR/remotes.sh"
fi
info "  2. Create your first records from a sample, for example:"
info "       mkdir -p $HOSTS_DIR/mycustomer"
info "       cp $SAMPLES_DIR/ssh.sample $HOSTS_DIR/mycustomer/mycustomer-ssh.conf"
info "  3. Start the picker: rms   (long form: remotes; per type: sshs, rdps, webs)"

# Optional tools that were not found.
OPTIONAL_NOTES=$(print_optional_notes)
if [ -n "$OPTIONAL_NOTES" ]; then
    info ""
    info "Optional (not required):"
    info "$OPTIONAL_NOTES"
fi
