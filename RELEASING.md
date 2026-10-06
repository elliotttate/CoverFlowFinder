# FlowFinder Release Guide

This guide explains how to build, sign, notarize, and release FlowFinder.

## Prerequisites

### 1. Apple Developer Account
- Active Apple Developer Program membership ($99/year)
- Developer ID Application certificate installed in Keychain

### 2. Notarization Credentials (One-Time Setup)

Store your Apple ID credentials in the macOS Keychain:

```bash
xcrun notarytool store-credentials "FlowFinder-Notarization" \
    --apple-id "your-apple-id@example.com" \
    --team-id "RH4U5VJHM6"
```

You'll be prompted for an app-specific password. To create one:
1. Go to https://appleid.apple.com
2. Sign in to your Apple ID
3. Go to **Sign-In and Security** → **App-Specific Passwords**
4. Click **Generate an app-specific password**
5. Name it "FlowFinder Notarization"
6. Copy the generated password and paste it when prompted

### 3. GitHub CLI (for releases)

```bash
brew install gh
gh auth login
```


### 4. Sparkle EdDSA Key (One-Time Setup)

Updates are delivered with [Sparkle](https://sparkle-project.org). Every update archive must be signed with the
EdDSA private key whose public half is `SUPublicEDKey` in `FlowFinder/Info.plist`. The private key lives in your
login Keychain; create it once with `./build/sparkle-tools/bin/generate_keys` (the release script downloads the
tools, see step 9 below). Never generate a new key for an existing app: users' copies would reject every update.

## How Sparkle Sees a Release

The app checks `https://elliotttate.github.io/CoverFlowFinder/appcast.xml`, which GitHub Pages serves from
`docs/appcast.xml` on `main`. An update is offered only when **all** of these hold:

- the appcast has an `<item>` whose `sparkle:version` is **greater than the installed app's `CFBundleVersion`**
  (`CURRENT_PROJECT_VERSION`). `MARKETING_VERSION` (`CFBundleShortVersionString`) is only for display;
- the item's `enclosure` URL downloads (the GitHub release asset exists);
- the enclosure's `sparkle:edSignature` and `length` match the downloaded file;
- the user's macOS is at least the item's `sparkle:minimumSystemVersion`.

A release that skips the build-number bump, the EdDSA signature or the appcast update reaches no Sparkle user.

## Quick Release

First bump the version and push it (step 1 of the manual process below). Then, on an up-to-date `main`:

```bash
./scripts/notarize.sh --release
```

This single command will:
1. Check you're on `main`, in sync with `origin/main`, with no uncommitted changes
2. Check that `CURRENT_PROJECT_VERSION` is greater than the newest `sparkle:version` in `docs/appcast.xml`
3. Build a Release archive and export it with Developer ID signing
4. Verify the exported app's versions, code signature and timestamp
5. Notarize and staple the app
6. Create a signed DMG, then notarize and staple it
7. Sign the DMG with the Sparkle EdDSA key and regenerate `docs/appcast.xml` (`generate_appcast`)
8. Create the GitHub release `vX.Y.Z` with the DMG attached
9. Commit **only** `docs/appcast.xml` and push it to `main`

The Sparkle command-line tools are downloaded once into `build/sparkle-tools`, pinned to the version in
`SPARKLE_VERSION` and checked against `SPARKLE_SHA256` before they're used (they can read your EdDSA private key).

To include release notes in the update dialog, put them in `release-notes/X.Y.Z.html` before running the script.

## Script Options

| Command | Description |
|---------|-------------|
| `./scripts/notarize.sh` | Build, sign, notarize, create DMG |
| `./scripts/notarize.sh --release` | Same as above + Sparkle signature, appcast, GitHub release |
| `./scripts/notarize.sh --skip-build` | Skip build, notarize existing app |
| `./scripts/notarize.sh --dmg-only` | Create DMG from existing notarized app |
| `./scripts/notarize.sh --check` | Show notarization history |
| `./scripts/notarize.sh --help` | Show help message |

## Manual Release Process

If you need to do things step-by-step. The examples release 1.39.0 (build 139) after 1.38.0 (build 138).

### 1. Bump Both Version Numbers

Edit `FlowFinder.xcodeproj/project.pbxproj`. Both settings appear twice (Debug and Release); change both copies:

```
CURRENT_PROJECT_VERSION = 139;   // CFBundleVersion: what Sparkle compares. Must go up every release.
MARKETING_VERSION = 1.39.0;      // CFBundleShortVersionString: what users see.
```

Or use sed:
```bash
sed -i '' -e 's/CURRENT_PROJECT_VERSION = 138;/CURRENT_PROJECT_VERSION = 139;/g' \
          -e 's/MARKETING_VERSION = 1.38.0;/MARKETING_VERSION = 1.39.0;/g' \
          FlowFinder.xcodeproj/project.pbxproj
```

The new `CURRENT_PROJECT_VERSION` must be greater than every `<sparkle:version>` already in `docs/appcast.xml`:
```bash
grep -o '<sparkle:version>[0-9]*' docs/appcast.xml | sort -t'>' -k2 -n | tail -1
```

### 2. Commit and Push

```bash
git add FlowFinder.xcodeproj/project.pbxproj
git commit -m "Version 1.39.0 - Your changes here"
git push origin main
```

### 3. Build Release Archive

```bash
xcodebuild -project FlowFinder.xcodeproj -scheme FlowFinder -configuration Release \
    -archivePath ./build/FlowFinder.xcarchive archive
```

### 4. Export with Developer ID Signing

Create `build/ExportOptions.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>RH4U5VJHM6</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
```

Export:
```bash
xcodebuild -exportArchive \
    -archivePath ./build/FlowFinder.xcarchive \
    -exportPath ./build/export \
    -exportOptionsPlist build/ExportOptions.plist
```

### 5. Verify Versions and Signature

```bash
# Versions Sparkle will see (expect 1.39.0 and 139)
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" -c "Print :CFBundleVersion" \
    ./build/export/FlowFinder.app/Contents/Info.plist

# Check signing identity and secure timestamp
codesign -dvv ./build/export/FlowFinder.app 2>&1 | grep -E "Authority=Developer ID Application|Timestamp="

# Check entitlements (should NOT have get-task-allow)
codesign -d --entitlements :- ./build/export/FlowFinder.app
```

### 6. Notarize and Staple the App

```bash
ditto -c -k --keepParent ./build/export/FlowFinder.app ./build/notarize.zip

# Must end with "status: Accepted"
xcrun notarytool submit ./build/notarize.zip \
    --keychain-profile "FlowFinder-Notarization" \
    --wait

xcrun stapler staple ./build/export/FlowFinder.app
```

### 7. Create, Notarize and Staple the DMG

```bash
STAGING=$(mktemp -d)
cp -R ./build/export/FlowFinder.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "FlowFinder" -srcfolder "$STAGING" \
    -ov -format UDZO FlowFinder-1.39.0.dmg
rm -rf "$STAGING"

codesign --force --sign "Developer ID Application: Brian Tate (RH4U5VJHM6)" \
    FlowFinder-1.39.0.dmg

xcrun notarytool submit FlowFinder-1.39.0.dmg \
    --keychain-profile "FlowFinder-Notarization" \
    --wait

xcrun stapler staple FlowFinder-1.39.0.dmg
```

### 8. Verify Final DMG

```bash
spctl -a -t open --context context:primary-signature -v FlowFinder-1.39.0.dmg
# Should show: accepted, source=Notarized Developer ID
```

Don't modify the DMG after this point: the Sparkle signature in the next step covers its exact bytes.

### 9. Sign the DMG for Sparkle (EdDSA)

Get the Sparkle tools (pinned version, checksum verified — the same values as in `scripts/notarize.sh`):
```bash
SPARKLE_VERSION=2.9.0
SPARKLE_SHA256=01e0f0ebf6614061ea816d414de50f937d64ffa6822ad572243031ca3676fe19
curl --fail -L -o /tmp/Sparkle.tar.xz \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
echo "$SPARKLE_SHA256  /tmp/Sparkle.tar.xz" | shasum -a 256 -c -   # must print OK
mkdir -p build/sparkle-tools && tar -xf /tmp/Sparkle.tar.xz -C build/sparkle-tools
```

Sign (reads the private key from the Keychain):
```bash
./build/sparkle-tools/bin/sign_update FlowFinder-1.39.0.dmg
# sparkle:edSignature="…" length="7012345"
```

### 10. Update `docs/appcast.xml`

Either let Sparkle generate it (this is what the script does; it signs and measures the DMG itself):
```bash
mkdir -p build/releases && cp FlowFinder-1.39.0.dmg docs/appcast.xml build/releases/
# optional release notes: build/releases/FlowFinder-1.39.0.html
./build/sparkle-tools/bin/generate_appcast \
    --download-url-prefix "https://github.com/elliotttate/CoverFlowFinder/releases/download/v1.39.0/" \
    build/releases
cp build/releases/appcast.xml docs/appcast.xml
```

Or add the item by hand at the top of `<channel>`, using the output of `sign_update`:
```xml
<item>
    <title>1.39.0</title>
    <pubDate>Tue, 06 Oct 2026 12:00:00 -0400</pubDate>
    <sparkle:version>139</sparkle:version>                        <!-- CFBundleVersion -->
    <sparkle:shortVersionString>1.39.0</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>  <!-- MACOSX_DEPLOYMENT_TARGET -->
    <description><![CDATA[
        <h2>What's New</h2>
        <ul><li>Your release notes here</li></ul>
    ]]></description>
    <enclosure url="https://github.com/elliotttate/CoverFlowFinder/releases/download/v1.39.0/FlowFinder-1.39.0.dmg"
               length="7012345"
               type="application/octet-stream"
               sparkle:edSignature="…"/>
</item>
```

Check that `sparkle:version` is the new build number, `length` and `sparkle:edSignature` are exactly what
`sign_update` printed, and the URL matches the tag and file name of the GitHub release below.

### 11. Create the GitHub Release

The appcast points at this asset, so publish it before the appcast:
```bash
gh release create v1.39.0 FlowFinder-1.39.0.dmg \
    --target main \
    --title "FlowFinder 1.39.0" \
    --notes "## What's New

- Your release notes here"
```

### 12. Publish the Appcast

Commit only the appcast and push it to `main` (GitHub Pages serves it from there):
```bash
git commit -m "Update appcast.xml for v1.39.0" -- docs/appcast.xml
git push origin main
```

### 13. Verify the Update

```bash
# After Pages has deployed (usually a minute or two):
curl -fsSL https://elliotttate.github.io/CoverFlowFinder/appcast.xml | grep -A3 "<title>1.39.0"
curl -fsIL https://github.com/elliotttate/CoverFlowFinder/releases/download/v1.39.0/FlowFinder-1.39.0.dmg | grep -i content-length
```

Then launch the previous version and choose **FlowFinder → Check for Updates…**: it should offer 1.39.0.

## Troubleshooting

### "No Keychain password item found for profile"

Your keychain may have locked. Unlock it:
```bash
security unlock-keychain ~/Library/Keychains/login.keychain-db
```

Or re-store the credentials:
```bash
xcrun notarytool store-credentials "FlowFinder-Notarization" \
    --apple-id "your@email.com" --team-id "RH4U5VJHM6"
```

### "The signature does not include a secure timestamp"

This happens when building with `xcodebuild` directly without proper export options. Use `-exportArchive` with `developer-id` method instead of just `build`.

### "The executable requests the com.apple.security.get-task-allow entitlement"

This debug entitlement is automatically removed when using Release configuration and exporting with `developer-id` method. Make sure you're:
1. Building with `-configuration Release`
2. Using `-exportArchive` with `method: developer-id`

### "A timestamp was expected but was not found"

The Apple timestamp server may be temporarily unavailable. Wait a minute and try again.

### Check Notarization Status

```bash
# View history
xcrun notarytool history --keychain-profile "FlowFinder-Notarization"

# Get details for a specific submission
xcrun notarytool log <submission-id> --keychain-profile "FlowFinder-Notarization"
```


### "CURRENT_PROJECT_VERSION (…) must be greater than the newest sparkle:version"

The script refuses to build a release Sparkle would ignore. Bump `CURRENT_PROJECT_VERSION` (both
configurations) as in step 1, commit, push, and run it again.

### "Sparkle download checksum mismatch!"

The downloaded Sparkle archive doesn't match `SPARKLE_SHA256`. Don't bypass this: the tools get access to your
EdDSA private key. If you deliberately changed `SPARKLE_VERSION`, update `SPARKLE_SHA256` to the digest shown for
`Sparkle-<version>.tar.xz` on the Sparkle GitHub release.

## File Locations

| File | Description |
|------|-------------|
| `scripts/notarize.sh` | Automated build & release script |
| `build/FlowFinder.xcarchive` | Xcode archive |
| `build/export/FlowFinder.app` | Exported, signed app |
| `build/sparkle-tools` | Sparkle command-line tools (`sign_update`, `generate_appcast`, `generate_keys`) |
| `FlowFinder-X.X.X.dmg` | Final DMG installer (not committed; attached to the GitHub release) |
| `docs/appcast.xml` | Sparkle update feed, served by GitHub Pages |

## Configuration

Edit these values in `scripts/notarize.sh` if needed:

```bash
TEAM_ID="RH4U5VJHM6"
KEYCHAIN_PROFILE="FlowFinder-Notarization"
SIGNING_IDENTITY="Developer ID Application: Brian Tate (RH4U5VJHM6)"
RELEASE_BRANCH="main"
SPARKLE_VERSION="2.9.0"
SPARKLE_SHA256="01e0f0ebf6614061ea816d414de50f937d64ffa6822ad572243031ca3676fe19"
```
