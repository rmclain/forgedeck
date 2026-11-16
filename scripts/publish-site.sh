#!/bin/zsh
# Publishes site/ to the gh-pages branch of the repository in FDUpdateRepository. GitHub Pages serves that branch.
#   scripts/publish-site.sh
# Uses only committed files: commit site/ first.
set -euo pipefail
here=${0:A:h:h}
repo=$(sed -n 's/.*<key>FDUpdateRepository<\/key><string>\(.*\)<\/string>.*/\1/p' "$here/Info.plist.in")
cd "$here"
split=$(git subtree split --prefix=site HEAD)
git push "https://github.com/$repo.git" "$split:refs/heads/gh-pages" --force
echo "published site/ ($split) to $repo gh-pages"
