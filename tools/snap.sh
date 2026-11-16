#!/bin/zsh
# Snapshots of every page, tab, sheet, and Settings tab in light and dark, on a fresh
# temporary data folder filled with the demo fixtures.
# Usage: tools/snap.sh                                   all pages, demo data
#        APP_SNAPSHOT_PAGES=overview,settings tools/snap.sh
#        APP_SEED=empty tools/snap.sh                    the first-run state
#        APP_SNAPSHOT_SIZE=1050x700 tools/snap.sh        another window size
#        SHOTS=/tmp/other tools/snap.sh                  another output folder
set -u
app=~/Applications/ForgeDeck.app/Contents/MacOS/ForgeDeck
home=/tmp/ForgeDeck-snap-home
shots=${SHOTS:-/tmp/ForgeDeck-shots}
rm -rf ~/Library/Saved\ Application\ State/com.forgedeck.app.savedState
rm -rf $home $shots
FORGEDECK_HOME=$home APP_SEED=${APP_SEED:-demo} APP_SNAPSHOT=$shots $app
