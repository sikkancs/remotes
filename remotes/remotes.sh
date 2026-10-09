#!/bin/zsh

# Remotes - one interactive picker for SSH, RDP and web GUI targets (macOS)
#
# Requires: fzf, awk, open (built in), ssh, VS Code optional for Ctrl+E,
#           Windows App for RDP connections
#
# Single file: the list parser and the preview parser are embedded, so no
# separate .awk files are needed.
#
# Data layout (what you edit, sync and back up):
#
# ~/.remotes/
#   hosts/
#     customer-a/                   one folder per customer or group
#       customer-a-ssh.conf         ssh_config syntax (Host, HostName, User, ...)
#       customer-a-rdp.conf         Host, HostName, User, Mode, Screen, RdpOption
#       customer-a-web.conf         Host, URL, Browser, Profile, BrowserArgs
#       dc-rdp.conf                 any number of files per type is fine
#     lab-ssh.conf                  files directly in hosts/ are fine too
#     ssh.conf                      plain names work as well (group "general")
#
# File names decide the type: the name must be ssh.conf, rdp.conf, web.conf or
# end with -ssh.conf, -rdp.conf, -web.conf. Everything else is ignored, as are
# hidden files and folders.
#
# The group (a searchable column) is the first folder below hosts/. For files
# directly in hosts/ it is the part of the name before the type suffix
# (lab-ssh.conf -> lab).
#
# State (can be deleted at any time):
#
# ~/.config/remotes/
#   remotes.sh
#   recent                  recently used targets (created automatically)
#
# The main ~/.ssh/config is still listed (group "ssh-config") so existing
# hosts keep working. Connections go through a temporary ssh config that
# includes every listed ssh file, so ~/.ssh/config needs no Include line for
# Remotes itself.
#
# This script is written to run under both zsh and bash.

# ---------------------------------------------------------------------------
# Settings (every path can be overridden with an environment variable)
# ---------------------------------------------------------------------------

# Root of the data tree.
REMOTES_DIR="${REMOTES_DIR:-$HOME/.remotes}"

# Folder holding the per group configuration folders.
HOSTS_DIR="$REMOTES_DIR/hosts"

# Existing main ssh config; set REMOTES_SSH_CONFIG="" to hide it.
SSH_MAIN_CONFIG="${REMOTES_SSH_CONFIG-$HOME/.ssh/config}"

# Program and state directory.
APP_DIR="${REMOTES_APP_DIR:-$HOME/.config/remotes}"

# File storing the most recently used targets as "type:alias" lines.
RECENT_FILE="$APP_DIR/recent"

# How many recent targets are pinned to the top, and how many are remembered.
MAX_RECENT=5
RECENT_KEEP=20

# Editor command used by Ctrl+E (may contain arguments).
EDITOR_CMD="${REMOTES_EDITOR:-code}"

# Browser used for web targets without their own Browser key.
DEFAULT_BROWSER="${REMOTES_BROWSER:-default}"

# Folder for generated .rdp files (removed after 12 hours).
RDP_TMP_DIR="${TMPDIR:-/tmp}/remotes-rdp"

# Limit the list to one type: ssh, rdp or web (empty = everything).
TYPE_FILTER=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Print an error message to stderr and stop.
fail() {
    printf 'Remotes error: %s\n' "$1" >&2
    exit 1
}

# Print a warning to stderr and continue.
warn() {
    printf 'Remotes warning: %s\n' "$1" >&2
}

# Print the help text.
usage() {
    cat <<'EOF'
Remotes - SSH, RDP and web GUI picker for macOS

Usage:
  remotes                    Launch the menu with every target
  remotes <query>            Pre-fill the search; a single match connects at once
  remotes -t|--type <type>   Limit the list to ssh, rdp or web
  remotes -h|--help          Show this help message

Data (one folder per customer or group):
  ~/.remotes/hosts/<group>/<anything>-ssh.conf
  ~/.remotes/hosts/<group>/<anything>-rdp.conf
  ~/.remotes/hosts/<group>/<anything>-web.conf
  Plain ssh.conf, rdp.conf and web.conf names work too, and files may also
  sit directly in ~/.remotes/hosts/.

Keys:
  ssh.conf   normal ssh_config syntax; "# Tags a b c" adds search tags
  rdp.conf   HostName (required), User, Mode (User|Admin),
             Screen (Window|Full|WIDTHxHEIGHT), RdpOption <raw .rdp line> (repeatable)
  web.conf   URL, or HostName + Port + Scheme; Browser, Profile, BrowserArgs

Menu keys:
  Enter        Connect (ssh, Windows App, or browser, depending on the type)
  Ctrl+V       SSH only: verbose connection (ssh -vvvv)
  Ctrl+R       SSH only: remove the host key from known_hosts (ssh-keygen -R)
  Ctrl+E       Open the source file in the editor ($REMOTES_EDITOR, default: code)
  ?            Toggle preview
  Esc/Ctrl-C   Exit

Environment variables:
  REMOTES_DIR, REMOTES_SSH_CONFIG, REMOTES_APP_DIR, REMOTES_EDITOR, REMOTES_BROWSER
EOF
}

# Move a "type:alias" key to the top of the recent file and trim the file.
update_recent() {
    {
        printf '%s\n' "$1"
        cat "$RECENT_FILE" 2>/dev/null || true
    } | awk 'NF && !seen[$0]++' | head -n "$RECENT_KEEP" > "${RECENT_FILE}.tmp" &&
        mv "${RECENT_FILE}.tmp" "$RECENT_FILE"
}

# Create the effective ssh configuration used for connecting. It includes every
# listed ssh.conf (and the main ~/.ssh/config last), so connections work
# without any Include line in ~/.ssh/config. ssh reads it again for jump hosts,
# so the file lives until the script exits.
prepare_ssh_config() {
    [ -n "${SSH_CFG:-}" ] && return 0

    SSH_CFG=$(mktemp "${TMPDIR:-/tmp}/remotes-ssh.XXXXXX") || fail "cannot create temporary ssh config."

    # The merged config carries one marker line per source file, in order.
    awk -F '\t' '$1 == "#@" && $2 == "ssh" { printf "Include \"%s\"\n", $4 }' "$TMP_CONFIG" > "$SSH_CFG"
}

# Remove the stored host key of an ssh alias from known_hosts.
# ssh stores the key under the resolved HostName (or HostKeyAlias when set),
# and as [name]:port when the port is not 22, so the alias itself is useless
# for ssh-keygen -R. "ssh -G" prints the fully resolved configuration.
forget_host_key() {
    local alias_name="$1"
    local resolved hostname port keyalias base target

    command -v ssh-keygen >/dev/null 2>&1 || fail "ssh-keygen is not available."

    prepare_ssh_config
    resolved=$(ssh -F "$SSH_CFG" -G "$alias_name" 2>/dev/null) || fail "ssh -G failed for $alias_name."

    # Pick the first occurrence of each option (ssh -G prints lowercase keys).
    hostname=$(printf '%s\n' "$resolved" | awk '$1 == "hostname"     { print $2; exit }')
    port=$(printf '%s\n' "$resolved"     | awk '$1 == "port"         { print $2; exit }')
    keyalias=$(printf '%s\n' "$resolved" | awk '$1 == "hostkeyalias" { print $2; exit }')

    # "none" means the option is not set.
    [ "$keyalias" = "none" ] && keyalias=""

    # HostKeyAlias wins over HostName, exactly as in ssh itself.
    base="${keyalias:-${hostname:-$alias_name}}"

    # Non-default ports are stored in the bracketed form.
    if [ -n "$port" ] && [ "$port" != "22" ]; then
        target="[$base]:$port"
    else
        target="$base"
    fi

    printf 'Removing known_hosts entries for: %s (alias: %s)\n' "$target" "$alias_name"

    # ssh-keygen keeps a backup copy as known_hosts.old.
    ssh-keygen -R "$target"
}

# Write the .rdp file for the selected RDP target and print its path.
# Arguments: target, user, mode, screen, raw options (unit separator joined).
build_rdp_file() {
    local target="$1" rdp_user="$2" mode="$3" screen="$4" options="$5"
    local base file width height

    mkdir -p "$RDP_TMP_DIR"
    chmod 700 "$RDP_TMP_DIR" 2>/dev/null || true

    # Housekeeping: purge .rdp files older than 12 hours.
    find "$RDP_TMP_DIR" -type f -name '*.rdp' -mmin +720 -delete 2>/dev/null || true

    # macOS mktemp needs the X run at the end of the template. Create a
    # suffixless file, then rename it to .rdp for the Windows App association.
    base=$(mktemp "$RDP_TMP_DIR/rdp.XXXXXX") || fail "cannot create temporary RDP file."
    file="${base}.rdp"
    mv "$base" "$file" || fail "cannot prepare temporary RDP file."

    # Generated defaults come first; raw RdpOption lines come last so they can
    # override anything. The awk filter keeps one line per property name.
    {
        printf 'full address:s:%s\n' "$target"

        # Optional user name (DOMAIN\user is passed through unchanged).
        if [ -n "$rdp_user" ]; then
            printf 'username:s:%s\n' "$rdp_user"
        fi

        # Administrative (console) session switch.
        if [ "$mode" = "ADMIN" ]; then
            printf 'administrative session:i:1\n'
        else
            printf 'administrative session:i:0\n'
        fi

        # Window behaviour: Full, WIDTHxHEIGHT, or a normal window (default).
        case "$(printf '%s' "$screen" | tr '[:upper:]' '[:lower:]')" in
            full)
                printf 'screen mode id:i:2\n'
                ;;
            *)
                printf 'screen mode id:i:1\n'
                if printf '%s' "$screen" | grep -Eq '^[0-9]{3,5}x[0-9]{3,5}$'; then
                    width="${screen%x*}"
                    height="${screen#*x}"
                    printf 'desktopwidth:i:%s\n' "$width"
                    printf 'desktopheight:i:%s\n' "$height"
                fi
                ;;
        esac

        # Raw options, one per line (stored joined by the ASCII unit separator).
        if [ -n "$options" ]; then
            printf '%s' "$options" | tr '\037' '\n'
            printf '\n'
        fi
    } | awk '
        {
            line = $0
            idx = index(line, ":")
            if (line == "") next

            # A valid .rdp line looks like name:type:value where type is s, i or b.
            if (line !~ /^[^:]+:[sib]:/) {
                print "Remotes warning: ignoring invalid RdpOption: " line > "/dev/stderr"
                next
            }

            key = tolower(substr(line, 1, idx - 1))
            if (!(key in pos)) pos[key] = ++n
            val[pos[key]] = line
        }
        END {
            for (i = 1; i <= n; i++) printf "%s\r\n", val[i]
        }
    ' > "$file"

    printf '%s\n' "$file"
}

# Open a web address. Arguments: url, browser, profile, raw browser arguments.
open_web() {
    local url="$1" browser_name="$2" profile_name="$3" extra_args="$4"
    local browser_lower app_name family word

    # A host specific Browser wins over the REMOTES_BROWSER default.
    [ -n "$browser_name" ] || browser_name="$DEFAULT_BROWSER"
    browser_lower=$(printf '%s' "$browser_name" | tr '[:upper:]' '[:lower:]')

    # app_name is the macOS application name; empty means "system default".
    # family decides which profile argument style is used.
    app_name=""
    family="chromium"

    case "$browser_lower" in
        ''|default|system) app_name="" ;;
        chrome|google-chrome) app_name="Google Chrome" ;;
        edge|msedge) app_name="Microsoft Edge" ;;
        brave) app_name="Brave Browser" ;;
        vivaldi) app_name="Vivaldi" ;;
        arc) app_name="Arc" ;;
        opera) app_name="Opera" ;;
        firefox) app_name="Firefox"; family="firefox" ;;
        safari) app_name="Safari"; family="safari" ;;
        *)
            # Anything else is treated as an application name.
            app_name="$browser_name"
            case "$browser_lower" in
                *firefox*) family="firefox" ;;
                *safari*)  family="safari" ;;
            esac
            ;;
    esac

    # System default browser: no profile or extra arguments are possible.
    if [ -z "$app_name" ]; then
        if [ -n "$profile_name" ] || [ -n "$extra_args" ]; then
            warn "Profile and BrowserArgs are ignored for the default browser."
        fi
        open "$url" || fail "the default browser could not open $url"
        return 0
    fi

    # Safari has no command line profile support.
    if [ "$family" = "safari" ]; then
        if [ -n "$profile_name" ] || [ -n "$extra_args" ]; then
            warn "Profile and BrowserArgs are ignored for Safari."
        fi
        open -a "$app_name" "$url" || fail "$app_name could not open $url"
        return 0
    fi

    # Named browser without profile or arguments: plain open -a.
    if [ -z "$profile_name" ] && [ -z "$extra_args" ]; then
        open -a "$app_name" "$url" || fail "$app_name could not open $url"
        return 0
    fi

    # Browser with profile and/or extra arguments. A new application instance
    # is requested (-n) so that the arguments are delivered; Chromium based
    # browsers hand them over to the already running instance. The argument
    # list is built in the positional parameters, which keeps spaces inside
    # values intact.
    set -- -na "$app_name" --args

    if [ -n "$profile_name" ]; then
        if [ "$family" = "firefox" ]; then
            set -- "$@" -P "$profile_name"
        else
            set -- "$@" "--profile-directory=$profile_name"
        fi
    fi

    # Raw BrowserArgs are split on spaces, one argument per word.
    if [ -n "$extra_args" ]; then
        while IFS= read -r word; do
            [ -n "$word" ] && set -- "$@" "$word"
        done <<EOF
$(printf '%s\n' "$extra_args" | tr -s ' ' '\n')
EOF
    fi

    # The address always goes last.
    set -- "$@" "$url"

    open "$@" || fail "$app_name could not open $url"
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
        -t|--type)
            [ $# -ge 2 ] || fail "--type needs a value: ssh, rdp or web."
            TYPE_FILTER="$2"
            shift 2
            ;;
        --type=*)
            TYPE_FILTER="${1#--type=}"
            shift
            ;;
        --)
            shift
            break
            ;;
        *)
            break
            ;;
    esac
done

# Validate the type filter.
case "$TYPE_FILTER" in
    ''|ssh|rdp|web) ;;
    *) fail "unknown type '$TYPE_FILTER' (use ssh, rdp or web)." ;;
esac

# Any remaining arguments become the initial search query.
QUERY="$*"

# ---------------------------------------------------------------------------
# Preparation
# ---------------------------------------------------------------------------

# Required external tools (ssh-keygen is checked only when Ctrl+R is used).
for dependency in fzf awk open ssh mktemp find sort tr sed cut head grep; do
    command -v "$dependency" >/dev/null 2>&1 || fail "$dependency is not available."
done

# At least the data folder or the main ssh config must exist.
if [ ! -d "$HOSTS_DIR" ] && { [ -z "$SSH_MAIN_CONFIG" ] || [ ! -f "$SSH_MAIN_CONFIG" ]; }; then
    fail "no data found. Create $HOSTS_DIR/<group>/ssh.conf, rdp.conf or web.conf"
fi

# Make sure the state directory and the recent file exist.
mkdir -p "$APP_DIR"
touch "$RECENT_FILE"

# Temporary merged configuration. SSH_CFG (effective ssh config) is created
# only when an ssh action needs it.
TMP_CONFIG=$(mktemp "${TMPDIR:-/tmp}/remotes-config.XXXXXX") || fail "cannot create temporary config."
SSH_CFG=""

# Always remove the temporary files on exit.
trap 'rm -f "$TMP_CONFIG" "$SSH_CFG"' EXIT

# True when the given type should be listed.
want_type() {
    [ -z "$TYPE_FILTER" ] || [ "$TYPE_FILTER" = "$1" ]
}

# Append one source file, preceded by a marker line:
#   #@<TAB>type<TAB>group<TAB>full path
emit_source() {
    printf '\n#@\t%s\t%s\t%s\n' "$1" "$2" "$3"
    cat "$3"
    printf '\n'
}

# Build the merged configuration.
{
    if [ -d "$HOSTS_DIR" ]; then
        # Work from inside hosts/ so hidden folders can be skipped by relative
        # path (the data root itself usually lives in a hidden ~/.remotes).
        # -L follows symlinked files and folders.
        ( cd "$HOSTS_DIR" && find -L . -type f -name '*.conf' ! -path '*/.*' -print | sort ) |
        while IFS= read -r rel; do
            rel="${rel#./}"
            file="$HOSTS_DIR/$rel"
            base=$(basename "$rel")

            # The file name decides the type.
            case "$base" in
                ssh.conf|*-ssh.conf) kind="ssh" ;;
                rdp.conf|*-rdp.conf) kind="rdp" ;;
                web.conf|*-web.conf) kind="web" ;;
                *) continue ;;
            esac

            want_type "$kind" || continue

            # The group is the first folder below hosts/; for files directly in
            # hosts/ it is the name part before the type suffix.
            case "$rel" in
                */*)
                    group="${rel%%/*}"
                    ;;
                *)
                    group="${base%.conf}"
                    group="${group%-$kind}"
                    [ "$group" = "$kind" ] && group="general"
                    ;;
            esac

            emit_source "$kind" "$group" "$file"
        done
    fi

    # The main ssh config goes last, so group files win on duplicate aliases
    # (the same order the effective ssh config uses).
    if want_type ssh && [ -n "$SSH_MAIN_CONFIG" ] && [ -f "$SSH_MAIN_CONFIG" ]; then
        emit_source ssh ssh-config "$SSH_MAIN_CONFIG"
    fi
} > "$TMP_CONFIG"

# ---------------------------------------------------------------------------
# Build the host list
# ---------------------------------------------------------------------------
#
# Tab separated, one row per target:
#   1 key (type:alias) | 2 type | 3 "alias (target)" | 4 info | 5 tags | 6 group
#   7 source path | 8 alias | 9 lowercase type | 10 target
#   11 to 14 type specific values:
#     rdp: user, mode, screen, raw options (unit separator joined)
#     web: browser, profile, browser args, unused
#     ssh: unused
#
# The Info column shows ssh: user, rdp: USER/ADMIN, web: browser, so every type
# fills the same visible columns. Fields 11 to 14 use "-" when empty, because
# the shell would otherwise collapse consecutive tab characters when the
# selected row is split again.
#
# The awk program reads the recent file first, so recent targets are emitted at
# the top in recency order, followed by a separator and all remaining targets.
# The awk code contains no single quote characters (\047 is used instead)
# because the program itself is wrapped in single quotes.

HOST_LIST=$(
    awk -v RECENT_FILE="$RECENT_FILE" \
        -v MAX_RECENT="$MAX_RECENT" \
        -v DEFAULT_BROWSER="$DEFAULT_BROWSER" '

    BEGIN {
        n = 0                                           # number of rows stored
        nrecent = 0                                     # number of recent keys
        type = ""                                       # type of the current source
        group = ""                                      # group of the current source
        path = ""                                       # path of the current source
        US = "\037"                                     # separator for repeated values
        max_display = length("Host (Target)")          # column width trackers
        max_info = length("Info")
        max_tags = length("Tags")
        max_group = length("Group")
        reset_block()
    }

    # Strip leading and trailing whitespace.
    function trim(value) {
        sub(/^[[:space:]]+/, "", value)
        sub(/[[:space:]]+$/, "", value)
        return value
    }

    # Value part of a "Key value" line. A quoted value keeps everything between
    # the quotes; an unquoted value ends at an inline comment (whitespace + #).
    function value_of(line,    v, first, rest, endq) {
        v = line
        sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+/, "", v)
        v = trim(v)
        first = substr(v, 1, 1)
        if (first == "\"" || first == "\047") {
            rest = substr(v, 2)
            endq = index(rest, first)
            if (endq > 0) return substr(rest, 1, endq - 1)
        }
        sub(/[[:space:]]+#.*$/, "", v)
        return trim(v)
    }

    # Build the final web address from URL or HostName/Scheme/Port.
    function resolve_url(url, hostname, port, scheme,    out) {
        if (url != "") {
            # Add https:// when the scheme is missing.
            if (url !~ /^[A-Za-z][A-Za-z0-9+.-]*:\/\//) url = "https://" url
            return url
        }
        if (hostname == "") return ""
        if (scheme == "") scheme = "https"
        out = scheme "://" hostname
        if (port != "") out = out ":" port
        return out "/"
    }

    # Forget everything collected for the current Host block.
    function reset_block() {
        in_host = 0
        nalias = 0
        b_hostname = ""
        b_user = ""
        b_port = ""
        b_scheme = ""
        b_url = ""
        b_browser = ""
        b_profile = ""
        b_args = ""
        b_mode = ""
        b_screen = ""
        b_rdpopts = ""
        b_tags = ""
    }

    # Value or "-" placeholder for the hidden fields.
    function hidden(value) {
        return (value != "") ? value : "-"
    }

    # Store every alias of the finished Host block (first definition wins per
    # type) and reset the block state. Blocks that cannot be used are skipped.
    function save_block(    ok, a, name, key, target, info, x1, x2, x3, x4, display) {
        if (!in_host) return

        ok = 0
        target = ""
        info = ""
        x1 = ""; x2 = ""; x3 = ""; x4 = ""

        if (type == "ssh") {
            # ssh needs no address of its own; the alias is enough.
            ok = 1
            target = b_hostname
            info = b_user
        }
        else if (type == "rdp") {
            # RDP needs a HostName.
            if (b_hostname != "") {
                ok = 1
                target = b_hostname
                info = (tolower(b_mode) == "admin") ? "ADMIN" : "USER"
                x1 = b_user
                x2 = info
                x3 = b_screen
                x4 = b_rdpopts
            }
        }
        else if (type == "web") {
            # Web needs a URL or a HostName.
            target = resolve_url(b_url, b_hostname, b_port, b_scheme)
            if (target != "") {
                ok = 1
                info = (b_browser != "") ? b_browser : DEFAULT_BROWSER
                x1 = b_browser
                x2 = b_profile
                x3 = b_args
            }
        }

        if (ok) {
            for (a = 1; a <= nalias; a++) {
                name = alias[a]
                key = type ":" name

                # Skip targets already defined earlier.
                if (key in seen) continue
                seen[key] = 1

                display = name
                if (target != "" && target != name) display = name " (" target ")"

                n++
                row_index[key] = n
                r_key[n] = key
                r_type[n] = toupper(type)
                r_display[n] = display
                r_info[n] = info
                r_tags[n] = b_tags
                r_group[n] = group
                r_path[n] = path
                r_alias[n] = name
                r_ltype[n] = type
                r_target[n] = (target != "") ? target : "-"
                r_x1[n] = hidden(x1)
                r_x2[n] = hidden(x2)
                r_x3[n] = hidden(x3)
                r_x4[n] = hidden(x4)

                if (length(display) > max_display) max_display = length(display)
                if (length(info) > max_info) max_info = length(info)
                if (length(b_tags) > max_tags) max_tags = length(b_tags)
                if (length(group) > max_group) max_group = length(group)
            }
        }

        reset_block()
    }

    # Print one stored row.
    function print_row(i) {
        printf "%s\t%-*s\t%-*s\t%-*s\t%-*s\t%-*s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
            r_key[i], 4, r_type[i], max_display, r_display[i], \
            max_info, r_info[i], max_tags, r_tags[i], max_group, r_group[i], \
            r_path[i], r_alias[i], r_ltype[i], r_target[i], \
            r_x1[i], r_x2[i], r_x3[i], r_x4[i]
    }

    # Normalize Windows line endings in every input line.
    { sub(/\r$/, "") }

    # First input file: the recent list (most recent first).
    FILENAME == RECENT_FILE {
        name = trim($0)
        if (name != "" && !(name in recent_seen)) {
            nrecent++
            recent[nrecent] = name
            recent_seen[name] = 1
        }
        next
    }

    # Source marker written by remotes.sh: #@<TAB>type<TAB>group<TAB>path
    index($0, "#@\t") == 1 {
        save_block()
        split($0, parts, "\t")
        type = parts[2]
        group = parts[3]
        path = parts[4]
        next
    }

    # Host block start. One line may define several aliases.
    tolower($1) == "host" && NF >= 2 {
        save_block()
        in_host = 1

        for (i = 2; i <= NF; i++) {
            # Stop at an inline comment.
            if ($i ~ /^#/) break
            # Hide wildcard, single character and negated patterns.
            if ($i ~ /[*?!]/) continue
            nalias++
            alias[nalias] = $i
        }
        next
    }

    # Match blocks end the current Host block and are not listed.
    tolower($1) == "match" {
        save_block()
        next
    }

    # Tags comment inside a Host block.
    in_host && tolower($0) ~ /^[[:space:]]*#[[:space:]]*tags[[:space:]]+/ {
        match(tolower($0), /^[[:space:]]*#[[:space:]]*tags[[:space:]]+/)
        b_tags = trim(substr($0, RLENGTH + 1))
        next
    }

    # Other comments are ignored.
    /^[[:space:]]*#/ { next }

    # Settings inside a Host block (first occurrence of a key wins).
    in_host && tolower($1) == "hostname"    && b_hostname == "" { b_hostname = value_of($0); next }
    in_host && tolower($1) == "user"        && b_user == ""     { b_user = value_of($0); next }
    in_host && tolower($1) == "port"        && b_port == ""     { b_port = value_of($0); next }
    in_host && tolower($1) == "scheme"      && b_scheme == ""   { b_scheme = tolower(value_of($0)); next }
    in_host && tolower($1) == "url"         && b_url == ""      { b_url = value_of($0); next }
    in_host && tolower($1) == "browser"     && b_browser == ""  { b_browser = value_of($0); next }
    in_host && tolower($1) == "profile"     && b_profile == ""  { b_profile = value_of($0); next }
    in_host && tolower($1) == "browserargs" && b_args == ""     { b_args = value_of($0); next }
    in_host && tolower($1) == "mode"        && b_mode == ""     { b_mode = value_of($0); next }
    in_host && tolower($1) == "screen"      && b_screen == ""   { b_screen = value_of($0); next }

    # RdpOption may repeat; every occurrence is kept.
    in_host && tolower($1) == "rdpoption" {
        b_rdpopts = (b_rdpopts == "") ? value_of($0) : b_rdpopts US value_of($0)
        next
    }

    END {
        save_block()

        # Header row (consumed by fzf --header-lines=1).
        printf "__header__\t%-*s\t%-*s\t%-*s\t%-*s\t%-*s\t\t\t\t\t\t\t\t\n", \
            4, "Type", max_display, "Host (Target)", max_info, "Info", \
            max_tags, "Tags", max_group, "Group"

        # Recent targets first, in recency order, only if they still exist.
        printed_recent = 0
        for (i = 1; i <= nrecent && printed_recent < MAX_RECENT; i++) {
            idx = row_index[recent[i]]
            if (idx > 0 && !(idx in printed)) {
                print_row(idx)
                printed[idx] = 1
                printed_recent++
            }
        }

        # Separator row, only when both groups are non-empty.
        if (printed_recent > 0 && printed_recent < n) {
            printf "__separator__\t%s\t\t\t\t\t\t\t\t\t\t\t\t\n", "────────────── All Targets ──────────────"
        }

        # Everything else in file order.
        for (i = 1; i <= n; i++) {
            if (!(i in printed)) print_row(i)
        }
    }
    ' "$RECENT_FILE" "$TMP_CONFIG" | tr -d '\r'
)

# The header is always present, so at least two lines are needed for a target.
if [ "$(printf '%s\n' "$HOST_LIST" | awk 'END { print NR }')" -le 1 ]; then
    fail "no usable targets found. Check $HOSTS_DIR (rdp needs HostName, web needs URL or HostName)."
fi

# ---------------------------------------------------------------------------
# fzf menu
# ---------------------------------------------------------------------------

# Preview program: prints the block of the highlighted target. It is kept in
# a variable (and exported) so no separate .awk file is needed. It must not
# contain single quote characters (\047 is used instead).
PREVIEW_PROGRAM='
BEGIN {
    n = 0               # number of settings collected
    width = 6           # widest key, for column alignment
    found = 0           # set once the requested target is located
    tags = ""
}

# Strip leading and trailing whitespace.
function trim(value) {
    sub(/^[[:space:]]+/, "", value)
    sub(/[[:space:]]+$/, "", value)
    return value
}

# Value part of a "Key value" line (same rules as the list parser).
function value_of(line,    v, first, rest, endq) {
    v = line
    sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+/, "", v)
    v = trim(v)
    first = substr(v, 1, 1)
    if (first == "\"" || first == "\047") {
        rest = substr(v, 2)
        endq = index(rest, first)
        if (endq > 0) return substr(rest, 1, endq - 1)
    }
    sub(/[[:space:]]+#.*$/, "", v)
    return trim(v)
}

# Convert CRLF to LF.
{ sub(/\r$/, "") }

# Source marker: #@<TAB>type<TAB>group<TAB>path
index($0, "#@\t") == 1 {
    if (found) exit
    split($0, parts, "\t")
    type = parts[2]
    group = parts[3]
    path = parts[4]
    next
}

# A new Host or Match line ends the matched block.
tolower($1) == "host" || tolower($1) == "match" {
    if (found) exit

    # Host lines may define several aliases; any of them can match.
    if (tolower($1) == "host" && type == TYPE) {
        for (i = 2; i <= NF; i++) {
            if ($i == HOST) {
                found = 1
                found_type = type
                found_group = group
                found_path = path
            }
        }
    }
    next
}

# Everything before the matching block is ignored.
!found { next }

# Tags comment inside the block.
tolower($0) ~ /^[[:space:]]*#[[:space:]]*tags[[:space:]]+/ {
    match(tolower($0), /^[[:space:]]*#[[:space:]]*tags[[:space:]]+/)
    tags = trim(substr($0, RLENGTH + 1))
    next
}

# Skip other comments and empty lines.
/^[[:space:]]*#/ || /^[[:space:]]*$/ { next }

# Inside the matched block: store key and value.
{
    keys[n] = $1
    values[n++] = value_of($0)
    if (length($1) > width) width = length($1)
}

END {
    if (!found) exit

    printf "%-" width "s  %s\n", "Type", toupper(found_type)
    printf "%-" width "s  %s\n", "Group", found_group
    printf "%-" width "s  %s\n", "Source", found_path
    if (tags != "")
        printf "%-" width "s  %s\n", "Tags", tags
    printf "\n"

    for (i = 0; i < n; ++i)
        printf "%-" width "s  %s\n", keys[i], values[i]
}
'

# Exported so the preview command (a separate process) can read them.
export REMOTES_TMP_CONFIG="$TMP_CONFIG"
export REMOTES_PREVIEW_PROGRAM="$PREVIEW_PROGRAM"

FZF_ARGS=(
    --ansi
    --height=70%
    --reverse
    --exact
    --tiebreak=begin,length
    --delimiter=$'\t'
    # Visible columns: type, alias+target, info, tags, group.
    --with-nth=2,3,4,5,6
    --header-lines=1
    # Keys handled after fzf exits: Ctrl+V (verbose), Ctrl+R (forget host key).
    --expect=ctrl-v,ctrl-r
    --prompt="[Recent $MAX_RECENT at top] Search: "
    --info=right
    --border=rounded
    --border-label=' Remotes | Enter=Connect | Ctrl-V=Verbose (SSH) | Ctrl-R=Forget key (SSH) | Ctrl-E=Edit | ?=Details '
    --ellipsis='...'
)

# Preview window (toggled with ?): field 8 is the alias, field 9 the type.
FZF_ARGS+=(
    --preview='awk -v HOST={8} -v TYPE={9} "$REMOTES_PREVIEW_PROGRAM" "$REMOTES_TMP_CONFIG"'
    --preview-window='down:45%:wrap:hidden'
    --bind='?:toggle-preview'
)

# Ctrl+E opens the exact source file of the highlighted target (field 7).
# Skipped when the editor command is not installed.
if command -v "${EDITOR_CMD%% *}" >/dev/null 2>&1; then
    FZF_ARGS+=("--bind=ctrl-e:execute-silent($EDITOR_CMD {7})")
fi

# A query argument pre-fills the search; a single match is selected at once.
if [ -n "$QUERY" ]; then
    FZF_ARGS+=(--query="$QUERY" --select-1)
fi

# Run the menu. Cancelling (Esc, Ctrl-C, no match) is not an error.
FZF_OUTPUT=$(printf '%s\n' "$HOST_LIST" | fzf "${FZF_ARGS[@]}") || exit 0

# With --expect, line 1 is the pressed key (empty for Enter) and line 2 is the row.
PRESSED_KEY=$(printf '%s\n' "$FZF_OUTPUT" | sed -n '1p')
SELECTED=$(printf '%s\n' "$FZF_OUTPUT" | sed -n '2p')

# An auto-selected single match may arrive without the key line.
if [ -z "$SELECTED" ] && printf '%s' "$PRESSED_KEY" | grep -q "$(printf '\t')"; then
    SELECTED="$PRESSED_KEY"
    PRESSED_KEY=""
fi

# Split the selected row. Variable names avoid shell specials (HOST, USER,
# BROWSER, DISPLAY).
IFS=$'\t' read -r ROW_KEY ROW_TYPE ROW_DISPLAY ROW_INFO ROW_TAGS ROW_GROUP ROW_PATH \
    ALIAS_NAME ROW_LTYPE TARGET X1 X2 X3 X4 <<< "$SELECTED"

# Ignore the header and the separator row.
case "$ROW_KEY" in
    ''|__header__|__separator__) exit 0 ;;
esac

# Convert the "-" placeholders back to empty values.
[ "$TARGET" = "-" ] && TARGET=""
[ "$X1" = "-" ] && X1=""
[ "$X2" = "-" ] && X2=""
[ "$X3" = "-" ] && X3=""
[ "$X4" = "-" ] && X4=""

# ---------------------------------------------------------------------------
# Act on the selection
# ---------------------------------------------------------------------------

# Ctrl+V and Ctrl+R only make sense for ssh targets.
if [ "$ROW_LTYPE" != "ssh" ]; then
    case "$PRESSED_KEY" in
        ctrl-v|ctrl-r) fail "Ctrl+V and Ctrl+R work for SSH targets only." ;;
    esac
fi

case "$ROW_LTYPE" in
    ssh)
        case "$PRESSED_KEY" in
            ctrl-r)
                # Forget the stored host key; does not touch the recent list.
                forget_host_key "$ALIAS_NAME"
                exit $?
                ;;
            ctrl-v)
                # Verbose connection for troubleshooting.
                update_recent "$ROW_KEY"
                prepare_ssh_config
                ssh -F "$SSH_CFG" -vvvv "$ALIAS_NAME"
                exit $?
                ;;
            *)
                # Normal connection.
                update_recent "$ROW_KEY"
                prepare_ssh_config
                ssh -F "$SSH_CFG" "$ALIAS_NAME"
                exit $?
                ;;
        esac
        ;;

    rdp)
        # X1 user, X2 mode, X3 screen, X4 raw options.
        [ -n "$TARGET" ] || fail "HostName is missing for $ALIAS_NAME."
        update_recent "$ROW_KEY"
        RDP_FILE=$(build_rdp_file "$TARGET" "$X1" "$X2" "$X3" "$X4") || exit 1
        open -a "Windows App" "$RDP_FILE" || fail "Windows App could not open the RDP file."
        exit 0
        ;;

    web)
        # X1 browser, X2 profile, X3 browser args.
        [ -n "$TARGET" ] || fail "address is missing for $ALIAS_NAME."
        update_recent "$ROW_KEY"
        open_web "$TARGET" "$X1" "$X2" "$X3"
        exit 0
        ;;

    *)
        fail "unknown target type '$ROW_LTYPE'."
        ;;
esac
