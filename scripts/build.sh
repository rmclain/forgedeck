#!/bin/zsh
# One command: build, sign, and install ~/Applications/ForgeDeck.app. Flags pass through (--open, --debug, --link-cli).
exec ${0:A:h:h}/build.sh "$@"
