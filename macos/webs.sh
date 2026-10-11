#!/bin/zsh

# webs - thin wrapper: opens the Remotes picker limited to web targets.
# It lives next to remotes.sh (~/.config/remotes/bin/) and calls it from there.
# Every argument is passed on, so "webs <query>" pre-fills the search.

# Folder of this wrapper; remotes.sh sits next to it.
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

exec "$SELF_DIR/remotes.sh" --type web "$@"
