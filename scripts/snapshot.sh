#!/bin/zsh
# Every page in light and dark, at the default size and at the compact size, into /tmp/ForgeDeck-shots*.
set -u
cd ${0:A:h:h}
tools/snap.sh
SHOTS=/tmp/ForgeDeck-shots-compact APP_SNAPSHOT_SIZE=1050x700 tools/snap.sh
SHOTS=/tmp/ForgeDeck-shots-empty APP_SEED=empty APP_SNAPSHOT_PAGES=overview,projects,secrets,activity,git,deployments,leads tools/snap.sh
echo "snapshots: /tmp/ForgeDeck-shots /tmp/ForgeDeck-shots-compact /tmp/ForgeDeck-shots-empty"
