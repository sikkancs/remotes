#!/bin/zsh

# sshs - thin wrapper: opens the Remotes picker limited to ssh targets.
# It lives next to remotes.sh (~/.config/remotes/bin/) and calls it from there.
# Every argument is passed on, so "sshs <query>" pre-fills the search.

# Folder of this wrapper; remotes.sh sits next to it.
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

exec "$SELF_DIR/remotes.sh" --type ssh "$@"
