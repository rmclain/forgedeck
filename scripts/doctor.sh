#!/bin/zsh
# What this Mac has for building and running ForgeDeck.
echo "macOS   $(sw_vers -productVersion)"
echo "Swift   $(swift --version 2>&1 | head -1)"
echo "Xcode   $(xcodebuild -version 2>/dev/null | head -1)"
for tool in git gh docker node php python3 op; do
  printf "%-7s %s\n" $tool "$(command -v $tool || echo 'not installed')"
done
echo "Signing $(security find-identity -v -p codesigning 2>/dev/null | grep -c '"') identities"
app=~/Applications/ForgeDeck.app
[[ -d $app ]] && { echo "App     $app"; codesign -dv $app 2>&1 | grep -E "Authority|TeamIdentifier|Signature" | head -3; $app/Contents/MacOS/ForgeDeck doctor; } || echo "App     not built yet: run ./build.sh"
