#!/bin/zsh
# Runs the in-app self-test against a fresh temporary data folder. Exit code 0 when every check passed.
set -u
rm -rf ~/Library/Saved\ Application\ State/com.forgedeck.app.savedState
home=/tmp/ForgeDeck-selftest-home
rm -rf $home
# APP_SELFTEST_KEYCHAIN=1 adds the real Keychain and real `forgedeck exec` pass. Items are deleted afterwards.
FORGEDECK_HOME=$home APP_SELFTEST_KEYCHAIN=${APP_SELFTEST_KEYCHAIN:-1} ~/Applications/ForgeDeck.app/Contents/MacOS/ForgeDeck --selftest
