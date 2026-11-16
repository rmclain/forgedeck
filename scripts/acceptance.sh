#!/bin/zsh
# The end-to-end walkthroughs: a real local companion server, real HTTP, real Git repositories.
# Nothing outside this Mac is contacted. Needs node.
set -u
cd ${0:A:h:h}
command -v node >/dev/null || { echo "node is needed for the acceptance walkthroughs"; exit 1; }
FORGEDECK_ACCEPTANCE=1 swift test --scratch-path ~/Library/Developer/ForgeDeck/test-build --filter AcceptanceWalkthroughs 2>&1 \
  | grep -E "✘|✔ Test |error:|Test run with"
exit ${pipestatus[1]}
