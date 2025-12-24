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

## Quick Release

For a full release (build, sign, notarize, create DMG, publish to GitHub):

```bash
./scripts/notarize.sh --release
```

This single command will:
1. Build a Release archive
2. Export with Developer ID signing
3. Verify code signature and timestamp
4. Submit to Apple for notarization
5. Staple the notarization ticket
6. Create a signed DMG installer
7. Notarize and staple the DMG
8. Create a GitHub release with the DMG attached

## Script Options

| Command | Description |
|---------|-------------|
| `./scripts/notarize.sh` | Build, sign, notarize, create DMG |
| `./scripts/notarize.sh --release` | Same as above + create GitHub release |
| `./scripts/notarize.sh --skip-build` | Skip build, notarize existing app |
| `./scripts/notarize.sh --dmg-only` | Create DMG from existing notarized app |
| `./scripts/notarize.sh --check` | Show notarization history |
| `./scripts/notarize.sh --help` | Show help message |

## Manual Release Process

If you need to do things step-by-step:

### 1. Update Version Number

Edit `FlowFinder.xcodeproj/project.pbxproj` and update `MARKETING_VERSION`:
```
MARKETING_VERSION = 1.28.0;
```

Or use sed:
```bash
sed -i '' 's/MARKETING_VERSION = 1.27.0/MARKETING_VERSION = 1.28.0/g' FlowFinder.xcodeproj/project.pbxproj
```

### 2. Commit Changes

```bash
git add -A
git commit -m "Version 1.28.0 - Your changes here"
git push origin main
```

### 3. Build Release Archive

```bash
xcodebuild -scheme FlowFinder -configuration Release \
    -archivePath ./build/FlowFinder.xcarchive archive
```

### 4. Export with Developer ID Signing

Create `ExportOptions.plist`:
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
    -exportOptionsPlist ExportOptions.plist
```

### 5. Verify Signature

```bash
# Check signing identity
codesign -dv ./build/export/FlowFinder.app

# Check for secure timestamp
codesign -dv ./build/export/FlowFinder.app 2>&1 | grep Timestamp

# Check entitlements (should NOT have get-task-allow)
codesign -d --entitlements :- ./build/export/FlowFinder.app
```

### 6. Notarize the App

```bash
# Create zip for notarization
ditto -c -k --keepParent ./build/export/FlowFinder.app ./build/notarize.zip

# Submit for notarization
xcrun notarytool submit ./build/notarize.zip \
    --keychain-profile "FlowFinder-Notarization" \
    --wait

# Staple the ticket
xcrun stapler staple ./build/export/FlowFinder.app
```

### 7. Create DMG

```bash
# Create temp folder with app and Applications alias
mkdir -p /tmp/dmg_contents
cp -R ./build/export/FlowFinder.app /tmp/dmg_contents/
ln -sf /Applications /tmp/dmg_contents/Applications

# Create DMG
hdiutil create -volname "FlowFinder" -srcfolder /tmp/dmg_contents \
    -ov -format UDZO FlowFinder-1.28.0.dmg

# Sign DMG
codesign --force --sign "Developer ID Application: Brian Tate (RH4U5VJHM6)" \
    FlowFinder-1.28.0.dmg

# Notarize DMG
xcrun notarytool submit FlowFinder-1.28.0.dmg \
    --keychain-profile "FlowFinder-Notarization" \
    --wait

# Staple DMG
xcrun stapler staple FlowFinder-1.28.0.dmg
```

### 8. Verify Final DMG

```bash
spctl -a -t open --context context:primary-signature -v FlowFinder-1.28.0.dmg
# Should show: accepted, source=Notarized Developer ID
```

### 9. Create GitHub Release

```bash
gh release create v1.28.0 FlowFinder-1.28.0.dmg \
    --title "FlowFinder 1.28.0" \
    --notes "## What's New

- Your release notes here"
```

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

## File Locations

| File | Description |
|------|-------------|
| `scripts/notarize.sh` | Automated build & release script |
| `build/FlowFinder.xcarchive` | Xcode archive |
| `build/export/FlowFinder.app` | Exported, signed app |
| `FlowFinder-X.X.X.dmg` | Final DMG installer |

## Configuration

Edit these values in `scripts/notarize.sh` if needed:

```bash
TEAM_ID="RH4U5VJHM6"
KEYCHAIN_PROFILE="FlowFinder-Notarization"
SIGNING_IDENTITY="Developer ID Application: Brian Tate (RH4U5VJHM6)"
```
