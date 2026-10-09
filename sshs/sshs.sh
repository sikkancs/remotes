#!/bin/zsh

# sshs - thin wrapper: opens the Remotes picker limited to ssh targets.
# Place this file where the old sshs.sh lived (for example
# ~/.config/sshs/sshs.sh) so existing aliases and PATH entries keep working.
# Every argument is passed on, so "sshs <query>" pre-fills the search.

exec "${REMOTES_HOME:-$HOME/.config/remotes}/remotes.sh" --type ssh "$@"
