#!/bin/zsh
# Makes a release build and a zip in dist/.
#   scripts/package.sh
# Signing: uses SIGN_IDENTITY, else the first "Developer ID Application" identity, else the
# first "Apple Development" identity, else ad hoc. The hardened runtime is on for every
# identity except ad hoc.
# Notarization: runs only with a Developer ID identity AND a notarytool keychain profile
# named in NOTARY_PROFILE (xcrun notarytool store-credentials <name>). Otherwise it is
# skipped and the script says so. It never claims a notarization it did not do.
set -euo pipefail
here=${0:A:h:h}
name=ForgeDeck
scratch="$HOME/Library/Developer/$name/universal"
version=$(sed -n 's/.*<key>CFBundleShortVersionString<\/key><string>\(.*\)<\/string>.*/\1/p' "$here/Info.plist.in")
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

identity="${SIGN_IDENTITY:-}"
find_identity() { security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o "\"$1: [^\"]*\"" | tr -d '"' || true; }
[[ -n "$identity" ]] || identity=$(find_identity "Developer ID Application")
[[ -n "$identity" ]] || identity=$(find_identity "Apple Development")
[[ -n "$identity" ]] || identity=-

# One binary for Apple silicon and Intel Macs.
swift build -c release --arch arm64 --arch x86_64 --package-path "$here" --scratch-path "$scratch" 2>&1 | grep -E "error|Build complete" || true
bin="$scratch/out/Products/Release/$name"
[[ -x "$bin" ]] || bin="$scratch/apple/Products/Release/$name"
[[ -x "$bin" ]] || { echo "build failed"; exit 1; }

app="$stage/$name.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/$name"
sed -e "s/__BUILD__/$(date +%Y%m%d%H%M)/" "$here/Info.plist.in" > "$app/Contents/Info.plist"
[[ -f "$here/Resources/Assets.car" ]] || "$here/tools/make_icon.sh"
cp -X "$here/Resources/Assets.car" "$here/Resources/AppIcon.icns" "$app/Contents/Resources/"
xattr -cr "$app"
if [[ "$identity" == "-" ]]; then
  codesign --force --sign - "$app"
else
  codesign --force --options runtime --timestamp --sign "$identity" "$app" 2>/dev/null \
    || codesign --force --options runtime --sign "$identity" "$app"
fi
codesign --verify --strict "$app"

mkdir -p "$here/dist"
zip="$here/dist/$name-$version.zip"
rm -f "$zip"
# The app and a short read-me, in one folder.
folder="$stage/$name $version"
mkdir -p "$folder"
ditto "$app" "$folder/$name.app"
cp "$here/scripts/README-friend.txt" "$folder/Read Me First.txt"
ditto -c -k --keepParent "$folder" "$zip"
echo "signed:    $identity"
echo "packaged:  $zip"

if [[ "$identity" == Developer\ ID\ Application* && -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$app"
  rm -f "$zip"
  rm -rf "$folder/$name.app" && ditto "$app" "$folder/$name.app"
  ditto -c -k --keepParent "$folder" "$zip"
  spctl --assess --type execute --verbose "$app"
  echo "notarized: yes, stapled, repackaged"
else
  echo "notarized: no (needs a Developer ID Application identity and NOTARY_PROFILE). This build runs on this Mac; other Macs will block it."
fi
