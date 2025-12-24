# Auto-Update Implementation Report for CoverFlowFinder

## Executive Summary

The best approach for adding auto-update functionality to CoverFlowFinder is **Sparkle 2** - the de-facto standard framework used by thousands of macOS apps including VLC, OBS Studio, Wireshark, and SourceTree. It integrates seamlessly with SwiftUI, supports GitHub-hosted releases, and provides a polished user experience.

---

## Table of Contents

1. [Recommended Solution: Sparkle 2](#recommended-solution-sparkle-2)
2. [Prerequisites](#prerequisites)
3. [Implementation Steps](#implementation-steps)
4. [GitHub Integration Options](#github-integration-options)
5. [Security Requirements](#security-requirements)
6. [Code Examples](#code-examples)
7. [Automation with GitHub Actions](#automation-with-github-actions)
8. [Effort Estimate](#effort-estimate)
9. [Alternatives Considered](#alternatives-considered)

---

## Recommended Solution: Sparkle 2

**Why Sparkle?**

| Feature | Benefit |
|---------|---------|
| Industry standard | Used by 1000s of apps, battle-tested |
| SwiftUI support | Native programmatic API for SwiftUI apps |
| Delta updates | Only downloads changed files (faster, smaller) |
| Silent updates | Users can opt for automatic background updates |
| EdDSA signatures | Cryptographic verification of updates |
| GitHub compatible | Works with GitHub Releases + Pages |
| Swift Package Manager | Easy integration via SPM |

**Links:**
- [Sparkle Official Site](https://sparkle-project.org/)
- [Sparkle GitHub Repository](https://github.com/sparkle-project/Sparkle)
- [Swift Package Index](https://swiftpackageindex.com/sparkle-project/Sparkle)

---

## Prerequisites

### 1. Apple Developer Program Membership ($99/year)

**Required for:**
- Developer ID certificate (code signing for distribution outside App Store)
- Notarization (required since macOS 10.14.5)
- Hardened Runtime entitlements

**Current status:** Your app is NOT currently code signed or notarized. This is the biggest prerequisite.

### 2. Code Signing Setup

You'll need:
- **Developer ID Application** certificate
- **Developer ID Installer** certificate (if using .pkg)
- Xcode configured with your team

### 3. Notarization

Required for:
- Gatekeeper acceptance on modern macOS
- Users won't see "unidentified developer" warnings
- Sparkle framework embedded in your app

---

## Implementation Steps

### Step 1: Add Sparkle via Swift Package Manager

In Xcode:
1. File → Add Package Dependencies
2. Enter: `https://github.com/sparkle-project/Sparkle`
3. Select version 2.x (latest stable)

### Step 2: Generate EdDSA Keys

Run once (keys stored in Keychain):
```bash
# Download Sparkle tools from GitHub releases or find in SPM artifacts
./bin/generate_keys
```

This outputs:
- **Private key** → Stored in your Keychain (NEVER share)
- **Public key** → Add to Info.plist as `SUPublicEDKey`

### Step 3: Update Info.plist

Add these keys:
```xml
<key>SUFeedURL</key>
<string>https://yourusername.github.io/CoverFlowFinder/appcast.xml</string>

<key>SUPublicEDKey</key>
<string>YOUR_BASE64_PUBLIC_KEY_HERE</string>

<key>SUEnableAutomaticChecks</key>
<true/>
```

### Step 4: Integrate with SwiftUI

See [Code Examples](#code-examples) below.

### Step 5: Generate Appcast

After building your signed/notarized app:
```bash
./bin/generate_appcast /path/to/your/releases/folder
```

This creates `appcast.xml` with update metadata.

### Step 6: Host Appcast

Options:
- **GitHub Pages** (recommended - free, automatic)
- Your own HTTPS server
- CDN like Cloudflare

---

## GitHub Integration Options

### Option A: GitHub Pages + Manual Releases (Simplest)

**Workflow:**
1. Build & notarize app locally
2. Create DMG
3. Run `generate_appcast` to update appcast.xml
4. Push appcast.xml to GitHub Pages branch
5. Create GitHub Release with DMG attached

**Pros:** Simple, full control
**Cons:** Manual process

### Option B: GitHub Actions Automation (Recommended)

**Workflow:**
1. Tag a release (e.g., `git tag v1.15.0`)
2. GitHub Action automatically:
   - Builds Universal Binary
   - Signs with Developer ID
   - Notarizes with Apple
   - Generates appcast.xml
   - Creates GitHub Release
   - Deploys appcast to GitHub Pages

**Pros:** Fully automated, consistent
**Cons:** Requires storing secrets in GitHub, initial setup complexity

### Option C: SparkleHub (Third-Party Service)

[SparkleHub on GitHub Marketplace](https://github.com/marketplace/sparklehub-appcast) automatically generates appcasts from your GitHub Releases.

**Pros:** Zero maintenance
**Cons:** Third-party dependency, may have limitations

---

## Security Requirements

### EdDSA Signatures (Required)

Every update must be signed with your private EdDSA key:
```bash
# Sign an update archive
./bin/sign_update /path/to/CoverFlowFinder.dmg
```

### Code Signing Order for Sparkle 2

**Critical:** Don't use `--deep` flag. Sign in this order:

```bash
# 1. Sign XPC services
codesign --force --options runtime --sign "Developer ID Application: Your Name" \
  --preserve-metadata=entitlements \
  "Sparkle.framework/Versions/B/XPCServices/Installer.xpc"

codesign --force --options runtime --sign "Developer ID Application: Your Name" \
  --preserve-metadata=entitlements \
  "Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"

# 2. Sign Autoupdate
codesign --force --options runtime --sign "Developer ID Application: Your Name" \
  "Sparkle.framework/Versions/B/Autoupdate"

# 3. Sign Updater.app
codesign --force --options runtime --sign "Developer ID Application: Your Name" \
  "Sparkle.framework/Versions/B/Updater.app"

# 4. Sign Sparkle.framework
codesign --force --options runtime --sign "Developer ID Application: Your Name" \
  "Sparkle.framework"

# 5. Sign your app last
codesign --force --options runtime --sign "Developer ID Application: Your Name" \
  "CoverFlowFinder.app"
```

### Notarization

```bash
# Submit for notarization
xcrun notarytool submit CoverFlowFinder.dmg \
  --apple-id "your@email.com" \
  --team-id "YOUR_TEAM_ID" \
  --password "app-specific-password" \
  --wait

# Staple the ticket
xcrun stapler staple CoverFlowFinder.dmg
```

---

## Code Examples

### SwiftUI Integration

**CheckForUpdatesViewModel.swift** (new file):
```swift
import Foundation
import Sparkle

final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}
```

**CheckForUpdatesView.swift** (new file):
```swift
import SwiftUI
import Sparkle

struct CheckForUpdatesView: View {
    @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates...", action: updater.checkForUpdates)
            .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
    }
}
```

**CoverFlowFinderApp.swift** (modify existing):
```swift
import SwiftUI
import Sparkle

@main
struct CoverFlowFinderApp: App {
    // Add this property
    private let updaterController: SPUStandardUpdaterController

    init() {
        // Initialize Sparkle
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            // Add to your existing CommandGroup
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }

            // ... your existing commands
        }

        Settings {
            SettingsView()
        }
    }
}
```

---

## Automation with GitHub Actions

### Required GitHub Secrets

| Secret Name | Description |
|-------------|-------------|
| `DEVELOPER_ID_APPLICATION_CERT` | Base64-encoded .p12 certificate |
| `DEVELOPER_ID_APPLICATION_PASSWORD` | Password for .p12 |
| `APPLE_ID` | Your Apple ID email |
| `APPLE_ID_PASSWORD` | App-specific password |
| `APPLE_TEAM_ID` | Your team ID |
| `SPARKLE_PRIVATE_KEY` | EdDSA private key from generate_keys |

### Sample Workflow (`.github/workflows/release.yml`)

```yaml
name: Build and Release

on:
  push:
    tags:
      - 'v*'

jobs:
  build:
    runs-on: macos-14

    steps:
      - uses: actions/checkout@v4

      - name: Install certificates
        env:
          CERT_BASE64: ${{ secrets.DEVELOPER_ID_APPLICATION_CERT }}
          CERT_PASSWORD: ${{ secrets.DEVELOPER_ID_APPLICATION_PASSWORD }}
        run: |
          # Create keychain and import certificate
          security create-keychain -p "" build.keychain
          security default-keychain -s build.keychain
          security unlock-keychain -p "" build.keychain
          echo "$CERT_BASE64" | base64 --decode > certificate.p12
          security import certificate.p12 -k build.keychain -P "$CERT_PASSWORD" -T /usr/bin/codesign
          security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" build.keychain

      - name: Build Universal Binary
        run: |
          xcodebuild -project CoverFlowFinder.xcodeproj \
            -scheme CoverFlowFinder \
            -configuration Release \
            -derivedDataPath ./build \
            ARCHS="arm64 x86_64" \
            ONLY_ACTIVE_ARCH=NO \
            CODE_SIGN_IDENTITY="Developer ID Application" \
            clean build

      - name: Create DMG
        run: |
          mkdir -p dmg-contents
          cp -R ./build/Build/Products/Release/CoverFlowFinder.app dmg-contents/
          ln -s /Applications dmg-contents/Applications
          hdiutil create -volname "CoverFlowFinder" \
            -srcfolder dmg-contents \
            -ov -format UDZO \
            CoverFlowFinder.dmg

      - name: Notarize
        env:
          APPLE_ID: ${{ secrets.APPLE_ID }}
          APPLE_ID_PASSWORD: ${{ secrets.APPLE_ID_PASSWORD }}
          APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
        run: |
          xcrun notarytool submit CoverFlowFinder.dmg \
            --apple-id "$APPLE_ID" \
            --team-id "$APPLE_TEAM_ID" \
            --password "$APPLE_ID_PASSWORD" \
            --wait
          xcrun stapler staple CoverFlowFinder.dmg

      - name: Sign with Sparkle
        env:
          SPARKLE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}
        run: |
          # Get Sparkle tools
          SPARKLE_VERSION="2.6.0"
          curl -L -o sparkle.tar.xz \
            "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
          tar -xf sparkle.tar.xz

          # Sign the DMG
          echo "$SPARKLE_KEY" | ./bin/sign_update CoverFlowFinder.dmg

      - name: Generate Appcast
        env:
          SPARKLE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}
        run: |
          mkdir -p releases
          cp CoverFlowFinder.dmg releases/
          echo "$SPARKLE_KEY" | ./bin/generate_appcast --ed-key-file - releases/

      - name: Create GitHub Release
        uses: softprops/action-gh-release@v1
        with:
          files: CoverFlowFinder.dmg
          generate_release_notes: true

      - name: Deploy Appcast to GitHub Pages
        uses: peaceiris/actions-gh-pages@v3
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          publish_dir: ./releases
          keep_files: true
```

---

## Effort Estimate

| Task | Effort | Notes |
|------|--------|-------|
| Apple Developer enrollment | 1 day | Waiting for approval |
| Certificate setup | 1-2 hours | Generate, download, configure Xcode |
| Sparkle integration (code) | 2-3 hours | Add SPM, write SwiftUI wrapper |
| EdDSA key generation | 15 min | One-time setup |
| Info.plist configuration | 15 min | Add required keys |
| Manual release workflow | 1-2 hours | Document the process |
| GitHub Actions automation | 4-6 hours | Complex but worth it |
| Testing | 2-3 hours | Test update flow end-to-end |

**Total: 1-2 days** (excluding Apple Developer Program approval time)

---

## Alternatives Considered

### 1. Custom Update Mechanism

Building your own HTTP check + download + replace system.

**Verdict:** Not recommended. Sparkle handles edge cases (permissions, atomic installs, rollback, delta updates) that would take weeks to implement properly.

### 2. Mac App Store

Distribute via App Store instead of direct download.

**Verdict:** Not suitable for CoverFlowFinder because:
- App sandbox required (breaks file system access)
- No full disk access possible
- Review delays
- 15-30% revenue cut (if monetized)

### 3. Homebrew Cask

Distribute via `brew install --cask coverflowfinder`.

**Verdict:** Complementary, not replacement. Users must manually run `brew upgrade`. No in-app notification. Good to add alongside Sparkle for power users.

---

## Recommendations

### Immediate (v1.15.0)

1. **Join Apple Developer Program** - Required for everything else
2. **Add Sparkle via SPM** - Get the framework in place
3. **Implement basic Check for Updates** - Manual menu item

### Short-term (v1.16.0)

4. **Set up code signing + notarization** - Professional distribution
5. **Host appcast on GitHub Pages** - Free, reliable
6. **Manual release process** - Document and test

### Long-term (v2.0.0)

7. **GitHub Actions automation** - Fully automated releases
8. **Delta updates** - Smaller, faster downloads
9. **Homebrew Cask** - Additional distribution channel

---

## References

- [Sparkle Documentation](https://sparkle-project.org/documentation/)
- [Sparkle Programmatic Setup](https://sparkle-project.org/documentation/programmatic-setup/)
- [SwiftUI Integration Guide](https://dev.to/prashant/how-to-add-auto-update-feature-in-macos-app-step-by-step-guide-to-setup-sparkle-framework-part-1-2klh)
- [GitHub Actions for Sparkle Discussion](https://github.com/sparkle-project/Sparkle/discussions/2308)
- [Code Signing & Notarization Deep Dive](https://steipete.me/posts/2025/code-signing-and-notarization-sparkle-and-tears)
- [Apple Notarization Documentation](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution)
