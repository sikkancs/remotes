#!/bin/zsh

# webs - thin wrapper: opens the Remotes picker limited to web targets.
# Place this file where the old webs.sh lived (for example
# ~/.config/webs/webs.sh) so existing aliases and PATH entries keep working.
# Every argument is passed on, so "webs <query>" pre-fills the search.

exec "${REMOTES_HOME:-$HOME/.config/remotes}/remotes.sh" --type web "$@"
