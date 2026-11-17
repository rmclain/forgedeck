#!/bin/zsh
# Packages the app and publishes it as a GitHub release, which the in-app updater reads.
#   scripts/release.sh                 package, then publish v<version> with notes from git log
#   scripts/release.sh --notes file    use these release notes
#   scripts/release.sh --draft         make a draft release (the updater ignores drafts)
# The version comes from Info.plist.in. Raise CFBundleShortVersionString and CLI.version first.
# The repository is FDUpdateRepository in Info.plist.in. Needs gh, signed in.
set -euo pipefail
here=${0:A:h:h}
notes_file="" draft=()
while (( $# )); do
  case $1 in
    --notes) notes_file=$2; shift 2 ;;
    --draft) draft=(--draft); shift ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
done
plist="$here/Info.plist.in"
version=$(sed -n 's/.*<key>CFBundleShortVersionString<\/key><string>\(.*\)<\/string>.*/\1/p' "$plist")
repo=$(sed -n 's/.*<key>FDUpdateRepository<\/key><string>\(.*\)<\/string>.*/\1/p' "$plist")
cli=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' "$here/Sources/ForgeDeckKit/CLI/CLI.swift")
[[ "$cli" == "$version" ]] || { echo "CLI.version ($cli) and Info.plist.in ($version) differ"; exit 1; }
[[ -n "$repo" ]] || { echo "FDUpdateRepository is not set in Info.plist.in"; exit 1; }
tag="v$version"
if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then echo "$tag is already released on $repo"; exit 1; fi

"$here/scripts/package.sh"
zip="$here/dist/ForgeDeck-$version.zip"
[[ -f "$zip" ]] || { echo "no $zip"; exit 1; }

if [[ -z "$notes_file" ]]; then
  notes_file=$(mktemp)
  previous=$(gh release view --repo "$repo" --json tagName -q .tagName 2>/dev/null || true)
  {
    echo "## What's new"
    echo
    if [[ -n "$previous" ]] && git -C "$here" rev-parse -q --verify "$previous" >/dev/null; then
      git -C "$here" log --format='- %s' "$previous..HEAD"
    else
      git -C "$here" log -1 --format='- %s'
    fi
    echo
    echo "## Install"
    echo
    echo "Unzip, drag ForgeDeck.app to Applications, and open it. Copies that are already installed update themselves."
  } > "$notes_file"
fi
gh release create "$tag" "$zip" --repo "$repo" --title "ForgeDeck $version" --notes-file "$notes_file" "${draft[@]}"
echo "released $tag on $repo"
