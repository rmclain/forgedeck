# ForgeDeck release guide

This guide covers building, testing, packaging, signing, and notarizing ForgeDeck, and the update plan.
It states what was done on 2026-11-15 and what could not be done on this Mac.
Version: 0.1 (`Info.plist.in`). Bundle id: `com.forgedeck.app`. Minimum system: macOS 26.0.

## Requirements

| Need | For |
| --- | --- |
| macOS 26 or later, Xcode command line tools with Swift 6.2 or later | Building. Verified here with macOS 27.0.1, Xcode 27.2, Swift 6.4.2 |
| Xcode with Icon Composer (`actool`) | Compiling `Icon/AppIcon.icon` into `Resources/Assets.car` and `AppIcon.icns` |
| `git` | Runtime and tests |
| `node` | The acceptance walkthroughs and the Node companion tests |
| `python3`, `php` | The Python and WordPress companion tests only |
| An Apple Development certificate | Optional. A stable signature, so the Keychain does not ask again after each rebuild |
| A Developer ID Application certificate and a `notarytool` keychain profile | Notarization. Releases from 0.11.1 use the profile `forgedeck-notary` |

`scripts/doctor.sh` prints what this Mac has.

## Build and install

```sh
./build.sh              # release build, sign, install
./build.sh --debug      # debug build
./build.sh --open       # install, quit the running copy, open the new one
./build.sh --link-cli   # also link ~/.local/bin/forgedeck to the app binary
```

`scripts/build.sh` passes its flags through to `./build.sh`.

What `build.sh` does:

1. `swift build -c release` with the scratch path `~/Library/Developer/ForgeDeck/build`, outside the repository.
2. Fails if the binary is older than any Swift source, which catches a build that reported success but did not compile an edited file.
3. Assembles `~/Applications/ForgeDeck.app`: the binary, `Info.plist` with the build number set to the current time (`YYYYMMDDHHMM`), and the icon files. It rebuilds the icon with `tools/make_icon.sh` when the `.icon` changed.
4. Clears extended attributes and signs.

**Install path:** `~/Applications/ForgeDeck.app`. The previous copy is removed first. Your data in `~/Library/Application Support/ForgeDeck` is not touched.

**CLI:** `~/.local/bin/forgedeck` is a symbolic link to `~/Applications/ForgeDeck.app/Contents/MacOS/ForgeDeck`. Because the install path is fixed, the link keeps working across rebuilds.

## Test

```sh
scripts/test.sh          # kit tests, acceptance walkthroughs, build + self-test, grid lint
scripts/test.sh --unit   # kit tests only
scripts/acceptance.sh    # the walkthroughs against the local companion server
tools/selftest.sh        # the in-app self-test (real Keychain items, created and deleted)
scripts/lint.sh          # grid, raw colors, shell strings, StrictHostKeyChecking
tools/snap.sh            # snapshots into /tmp/ForgeDeck-shots
```

Results from today are in TEST_REPORT.md: 353 kit tests pass, `SELFTEST PASS 35 checks`, lint PASS.

The self-test and snapshot scripts set `FORGEDECK_HOME` to a folder in `/tmp`, and the kit tests work in temporary folders. They are written not to touch `~/Library/Application Support/ForgeDeck`.

## Package

```sh
scripts/package.sh
```

The script:

1. Reads the version from `Info.plist.in`.
2. Picks the signing identity: `SIGN_IDENTITY` if set, else the first "Developer ID Application" identity, else the first "Apple Development" identity, else ad hoc.
3. Makes a release build and assembles the app in a temporary folder. It does not touch the installed copy.
4. Signs. For any real identity it adds the hardened runtime (`--options runtime`) and tries a secure timestamp, falling back to signing without one if the timestamp server cannot be reached. For ad hoc it signs without the hardened runtime.
5. Verifies with `codesign --verify --strict`.
6. Zips to `dist/ForgeDeck-<version>.zip` with `ditto -c -k --keepParent`.
7. Notarizes and staples only when the identity is a Developer ID Application identity **and** `NOTARY_PROFILE` is set. Otherwise it prints `notarized: no (...)` and stops. It never claims a notarization it did not do.

Releases up to 0.11 were signed with the Apple Development identity and were **not notarized**. From 0.11.1 they are signed with the Developer ID Application identity and notarized: run `NOTARY_PROFILE=forgedeck-notary scripts/release.sh`. Both identities belong to the same team, so copies signed either way accept the update.

`dist/` is build output. It is not listed in `.gitignore` today.

## Signing notes

| Identity | How it is chosen | Hardened runtime | Keychain behavior | Runs on other Macs |
| --- | --- | --- | --- | --- |
| Ad hoc (`-`) | No certificate found | No | Each build is a new app to the Keychain: expect an access prompt after every rebuild | No |
| Apple Development | Found automatically by `build.sh` and `package.sh` | `package.sh` only | Stable across rebuilds | No. Gatekeeper blocks a downloaded copy |
| Developer ID Application | Preferred by `package.sh`; `build.sh` needs `SIGN_IDENTITY` | `package.sh` only | Stable | Yes, once notarized |

- `build.sh` does not pass `--options runtime`. Use `scripts/package.sh` for anything you hand to someone else.
- To make `build.sh` use a specific identity: `SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh`.
- There is no entitlements file. The app is not sandboxed and needs no hardened-runtime exceptions: it loads no plugins, uses no JIT, and requests no protected resources. See SECURITY_MODEL.md, "Sandbox and entitlements".
- The CLI is the app binary, so it carries the same signature. The Keychain treats both as the same app.
- If you change the signing identity, existing Keychain items were created by the old one. macOS asks before the new build may read them.

## Notarization

Not done: this Mac has no Developer ID certificate. These are the exact steps for a Mac that has one.

One-time setup. Create an app-specific password at appleid.apple.com, then store a profile in the keychain:

```sh
xcrun notarytool store-credentials forgedeck-notary \
  --apple-id "you@example.com" \
  --team-id "TEAMID1234" \
  --password "abcd-efgh-ijkl-mnop"
```

Each release:

```sh
NOTARY_PROFILE=forgedeck-notary scripts/package.sh
```

With a Developer ID identity and that variable, the script runs these commands after zipping:

```sh
xcrun notarytool submit dist/ForgeDeck-0.1.zip --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple <staged>/ForgeDeck.app
ditto -c -k --keepParent <staged>/ForgeDeck.app dist/ForgeDeck-0.1.zip    # repackage with the ticket
spctl --assess --type execute --verbose <staged>/ForgeDeck.app
```

and prints `notarized: yes, stapled, repackaged`.

To do the same by hand on an app you already signed with a Developer ID identity, the hardened runtime, and a secure timestamp:

```sh
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: Your Name (TEAMID1234)" ForgeDeck.app
codesign --verify --strict --verbose=2 ForgeDeck.app
ditto -c -k --keepParent ForgeDeck.app ForgeDeck-0.1.zip
xcrun notarytool submit ForgeDeck-0.1.zip --keychain-profile forgedeck-notary --wait
xcrun stapler staple ForgeDeck.app
xcrun stapler validate ForgeDeck.app
spctl --assess --type execute --verbose ForgeDeck.app
ditto -c -k --keepParent ForgeDeck.app ForgeDeck-0.1.zip
```

If the submission is rejected, read the log:

```sh
xcrun notarytool log <submission-id> --keychain-profile forgedeck-notary
```

Notes:

- Notarization needs a secure timestamp. If `package.sh` fell back to signing without one, the submission will be rejected; run it again with a network connection.
- None of the notarization commands above were run for ForgeDeck. They are the standard `notarytool` flow and the lines in `scripts/package.sh`.

## Release checklist

1. Set `CFBundleShortVersionString` in `Info.plist.in` and `CLI.version` in `Sources/ForgeDeckKit/CLI/CLI.swift` to the same value. They are two separate constants today.
2. If the portfolio schema changed, raise `Portfolio.currentSchemaVersion`, add a step to `PortfolioMigrator`, and add a migration test.
3. `scripts/test.sh` passes.
4. `scripts/lint.sh` prints PASS.
5. `tools/snap.sh`, then look at the light and dark images.
6. Run the companion suites if `Companions/` changed.
7. `scripts/package.sh` (with `NOTARY_PROFILE` when a Developer ID is available).
8. Unzip the result on a clean account or another Mac and open it.
9. Update ROADMAP.md and TEST_REPORT.md with the new results.

## Update plan

- **Installed copies** update themselves from GitHub releases. See "Publishing a release" below. The install asks first (Install and Relaunch), and the data folder and Keychain items are kept.
- **On this Mac, from source:** pull and run `./build.sh --open`. A portfolio written by an older version is migrated on load; one written by a newer version is refused and left untouched.
- Notarization would remove the first-launch "Open Anyway" step; it needs a Developer ID (see Notarization).

## Rollback

Install an older build with `./build.sh` from an older commit, or unzip an older package over the app. If the newer version raised the schema version, the older build refuses the newer `portfolio.json`. Keep a copy of the data folder before upgrading across a schema change, or export the configuration first (Settings > Privacy & Data > Export) and import it into the older version.


## Sharing a build with a friend (0.2, 2026-11-15)

`scripts/package.sh` now builds one universal binary (Apple silicon and Intel), signs it with
the hardened runtime, and zips a folder holding `ForgeDeck.app` and `Read Me First.txt`
(`scripts/README-friend.txt`) to `dist/ForgeDeck-<version>.zip`. The 0.2 zip is 12.3 MB.

Checked on this Mac after unzipping: both architectures present, signature valid, `version`
prints 0.2, and the self-test passes. Gatekeeper rejects it (`spctl`), as expected without a
Developer ID and notarization: the friend allows it once in System Settings > Privacy &
Security > Open Anyway, as the read-me explains. The signature shows the Apple Development
certificate's name. The binary holds no home-folder paths.

## Publishing a release (and how updates work)

1. Raise the version in `Info.plist.in` (`CFBundleShortVersionString`) and `CLI.version` in `Sources/ForgeDeckKit/CLI/CLI.swift`. They must match.
2. Commit, run `scripts/publish-public.sh "<message>"` (the public repo gets one commit with the current tree; local history stays private, and the build prompt and personal screenshots are left out), then run `scripts/release.sh`. It runs `scripts/package.sh` and publishes `v<version>` with `ForgeDeck-<version>.zip` to the repository named by `FDUpdateRepository` in `Info.plist.in`, with notes from the commits since the previous release. `--notes file` uses your own notes; `--draft` makes a draft.
3. Installed copies find it within a day (Settings › About › Check Now, or ForgeDeck › Check for Updates…, to check at once).

The updater asks `api.github.com/repos/<repo>/releases/latest` without credentials, ignores drafts and pre-releases, and takes the first asset named `ForgeDeck*.zip` from github.com. It downloads over https, follows redirects only to GitHub's download hosts, unzips with `ditto`, and runs `codesign --verify --deep --strict`. It installs only when the new app's TeamIdentifier equals the running app's, so a release must be signed with the same team. The old app goes to the Trash, the new one takes its place, and the app relaunches. A copy without a team signature does not update itself.

The website in `site/` is served by GitHub Pages from the `gh-pages` branch. After committing a change to `site/`, run `scripts/publish-site.sh`.
