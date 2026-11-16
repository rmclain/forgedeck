#!/bin/zsh
# Publishes the current commit to the public GitHub repository as one new commit on top of the public history.
# Local history stays private: only the tree is sent, without the files listed in EXCLUDE.
#   scripts/publish-public.sh "Message for the public commit"
set -euo pipefail
here=${0:A:h:h}
cd "$here"
message=${1:?give a commit message}
EXCLUDE=(ForgeDeck_Agentic_Build_Prompt.md docs/screenshots/usage-panel-dark.png docs/screenshots/usage-panel-light.png docs/screenshots/recipe-result-ios-simulator.png)
[[ -z "$(git status --porcelain)" ]] || { echo "commit your changes first"; exit 1; }
index=$(mktemp); rm -f "$index"
GIT_INDEX_FILE=$index git read-tree HEAD
for excluded in $EXCLUDE; do GIT_INDEX_FILE=$index git rm --cached -q --ignore-unmatch "$excluded"; done
tree=$(GIT_INDEX_FILE=$index git write-tree); rm -f "$index"
git fetch -q origin main
parent=$(git rev-parse origin/main)
[[ "$(git rev-parse "$parent^{tree}")" != "$tree" ]] || { echo "nothing new to publish"; exit 0; }
id="1417707+rmclain@users.noreply.github.com"
commit=$(GIT_AUTHOR_NAME=rmclain GIT_AUTHOR_EMAIL=$id GIT_COMMITTER_NAME=rmclain GIT_COMMITTER_EMAIL=$id git commit-tree "$tree" -p "$parent" -m "$message")
git branch -f public "$commit"
git push origin public:main
echo "published $commit"
