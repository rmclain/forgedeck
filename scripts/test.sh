#!/bin/zsh
# Runs every automated check: unit tests, the acceptance walkthroughs against a local
# companion server, the in-app self-test, and the grid lint.
# Usage: scripts/test.sh            everything
#        scripts/test.sh --unit     unit tests only (no node, no app launch)
set -u
here=${0:A:h:h}
cd "$here"
fail=0
echo "== unit tests"
swift test --scratch-path ~/Library/Developer/ForgeDeck/test-build 2>&1 | grep -E "✘|error:|Test run with" || fail=1
[[ " $* " == *" --unit "* ]] && exit $fail
echo "== acceptance walkthroughs"
scripts/acceptance.sh || fail=1
echo "== app self-test"
./build.sh >/dev/null 2>&1 || { echo "build failed"; exit 1; }
tools/selftest.sh | tail -1 | grep -q "SELFTEST PASS" && echo "SELFTEST PASS" || { echo "SELFTEST FAIL"; fail=1; }
echo "== lint"
scripts/lint.sh | tail -1 | grep -q "PASS lint" && echo "PASS lint" || { echo "FAIL lint"; fail=1; }
exit $fail
