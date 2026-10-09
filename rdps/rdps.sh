#!/bin/zsh

# rdps - thin wrapper: opens the Remotes picker limited to rdp targets.
# Place this file where the old rdps.sh lived (for example
# ~/.config/rdps/rdps.sh) so existing aliases and PATH entries keep working.
# Every argument is passed on, so "rdps <query>" pre-fills the search.

exec "${REMOTES_HOME:-$HOME/.config/remotes}/remotes.sh" --type rdp "$@"
