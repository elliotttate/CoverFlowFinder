#!/bin/bash

# FlowFinder Build & Notarization Script
# This script builds, signs, notarizes, and packages the app for distribution.
#
# SETUP (one-time):
#   1. Store your credentials in the keychain:
#      xcrun notarytool store-credentials "FlowFinder-Notarization" \
#          --apple-id "your-apple-id@example.com" \
#          --team-id "RH4U5VJHM6" \
#          --password "app-specific-password"
#
#   2. To create an app-specific password:
#      - Go to https://appleid.apple.com
#      - Sign in and go to Sign-In and Security > App-Specific Passwords
#      - Generate a new password for "FlowFinder Notarization"
#
#   3. Ensure you have the GitHub CLI installed: brew install gh
#      Then authenticate: gh auth login
#
# USAGE:
#   ./scripts/notarize.sh              # Build, sign, notarize, create DMG
#   ./scripts/notarize.sh --release    # Same as above + create GitHub release
#   ./scripts/notarize.sh --skip-build # Skip build, just notarize existing app
#   ./scripts/notarize.sh --dmg-only   # Create DMG from existing notarized app
#   ./scripts/notarize.sh --check      # Check notarization history

set -e

# Configuration
APP_NAME="FlowFinder"
SCHEME="FlowFinder"
BUNDLE_ID="com.flowfinder.app"
TEAM_ID="RH4U5VJHM6"
KEYCHAIN_PROFILE="FlowFinder-Notarization"
SIGNING_IDENTITY="Developer ID Application: Brian Tate (RH4U5VJHM6)"

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_PATH="$EXPORT_PATH/$APP_NAME.app"
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_step() {
    echo -e "\n${BLUE}==>${NC} ${CYAN}$1${NC}"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

get_version() {
    grep -m1 'MARKETING_VERSION' "$PROJECT_DIR/$APP_NAME.xcodeproj/project.pbxproj" | sed 's/.*= //' | sed 's/;.*//' | tr -d ' '
}

check_credentials() {
    print_step "Checking notarization credentials..."
    if ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" &>/dev/null; then
        print_error "Keychain profile '$KEYCHAIN_PROFILE' not found!"
        echo ""
        echo "Please set up your credentials first:"
        echo ""
        echo "  xcrun notarytool store-credentials \"$KEYCHAIN_PROFILE\" \\"
        echo "      --apple-id \"your-apple-id@example.com\" \\"
        echo "      --team-id \"$TEAM_ID\" \\"
        echo "      --password \"your-app-specific-password\""
        echo ""
        echo "Get an app-specific password at: https://appleid.apple.com"
        exit 1
    fi
    print_success "Credentials found"
}

check_certificate() {
    print_step "Checking Developer ID certificate..."
    if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
        print_error "Developer ID Application certificate not found!"
        echo "Please install your Developer ID certificate from the Apple Developer portal."
        exit 1
    fi
    print_success "Developer ID certificate found"
}

clean_build() {
    print_step "Cleaning previous build..."
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    print_success "Build directory cleaned"
}

build_archive() {
    print_step "Building archive (this may take a minute)..."

    xcodebuild -project "$PROJECT_DIR/$APP_NAME.xcodeproj" \
        -scheme "$SCHEME" \
        -configuration Release \
        -archivePath "$ARCHIVE_PATH" \
        archive \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        2>&1 | tail -5

    if [ ! -d "$ARCHIVE_PATH" ]; then
        print_error "Archive failed!"
        exit 1
    fi
    print_success "Archive created"
}

export_app() {
    print_step "Exporting app with Developer ID signing..."

    # Create export options plist
    cat > "$EXPORT_OPTIONS" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF

    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_PATH" \
        -exportOptionsPlist "$EXPORT_OPTIONS" \
        2>&1 | tail -3

    if [ ! -d "$APP_PATH" ]; then
        print_error "Export failed!"
        exit 1
    fi
    print_success "App exported"
}

verify_signature() {
    print_step "Verifying code signature..."

    # Check signature
    if codesign -dv "$APP_PATH" 2>&1 | grep -q "Developer ID Application"; then
        print_success "Signed with Developer ID"
    else
        print_error "Not properly signed!"
        exit 1
    fi

    # Check timestamp
    if codesign -dv "$APP_PATH" 2>&1 | grep -q "Timestamp="; then
        print_success "Secure timestamp present"
    else
        print_warning "No secure timestamp (may fail notarization)"
    fi

    # Check for debug entitlement
    if codesign -d --entitlements :- "$APP_PATH" 2>/dev/null | grep -q "get-task-allow"; then
        print_error "Debug entitlement present (will fail notarization)!"
        exit 1
    else
        print_success "No debug entitlements"
    fi
}

submit_notarization() {
    print_step "Submitting for notarization (this may take 2-5 minutes)..."

    # Create a temporary zip for notarization
    local NOTARIZE_ZIP="$BUILD_DIR/notarize-temp.zip"
    ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

    xcrun notarytool submit "$NOTARIZE_ZIP" \
        --keychain-profile "$KEYCHAIN_PROFILE" \
        --wait

    rm -f "$NOTARIZE_ZIP"
    print_success "Notarization accepted"
}

staple_app() {
    print_step "Stapling notarization ticket..."
    xcrun stapler staple "$APP_PATH"
    print_success "Ticket stapled"
}

verify_notarization() {
    print_step "Verifying notarization..."

    local RESULT=$(spctl -a -t open --context context:primary-signature -v "$APP_PATH" 2>&1)
    if echo "$RESULT" | grep -q "accepted"; then
        print_success "App is notarized and ready for distribution"
        echo "  $RESULT"
    else
        print_warning "Verification returned unexpected result:"
        echo "  $RESULT"
    fi
}

create_dmg() {
    VERSION=$(get_version)
    DMG_NAME="$APP_NAME-$VERSION.dmg"
    DMG_PATH="$PROJECT_DIR/$DMG_NAME"
    TMP_DMG="/tmp/$APP_NAME-temp.dmg"

    print_step "Creating DMG installer..."

    # Clean up
    rm -f "$DMG_PATH" "$TMP_DMG"
    rm -rf /tmp/dmg_contents
    mkdir -p /tmp/dmg_contents

    # Copy app and create Applications symlink
    cp -R "$APP_PATH" /tmp/dmg_contents/
    ln -sf /Applications /tmp/dmg_contents/Applications

    # Create DMG
    hdiutil create -volname "$APP_NAME" -srcfolder /tmp/dmg_contents -ov -format UDRW "$TMP_DMG" >/dev/null
    hdiutil convert "$TMP_DMG" -format UDZO -o "$DMG_PATH" >/dev/null

    # Sign DMG
    codesign --force --sign "$SIGNING_IDENTITY" "$DMG_PATH"

    # Clean up
    rm -f "$TMP_DMG"
    rm -rf /tmp/dmg_contents

    print_success "DMG created: $DMG_NAME"
    echo "$DMG_PATH"
}

notarize_dmg() {
    VERSION=$(get_version)
    DMG_PATH="$PROJECT_DIR/$APP_NAME-$VERSION.dmg"

    if [ ! -f "$DMG_PATH" ]; then
        print_error "DMG not found at $DMG_PATH"
        exit 1
    fi

    print_step "Notarizing DMG..."
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$KEYCHAIN_PROFILE" \
        --wait

    print_step "Stapling DMG..."
    xcrun stapler staple "$DMG_PATH"

    print_success "DMG notarized and stapled"
}

verify_dmg() {
    VERSION=$(get_version)
    DMG_PATH="$PROJECT_DIR/$APP_NAME-$VERSION.dmg"

    print_step "Verifying DMG..."
    local RESULT=$(spctl -a -t open --context context:primary-signature -v "$DMG_PATH" 2>&1)
    if echo "$RESULT" | grep -q "accepted"; then
        print_success "DMG verified: $RESULT"
    else
        print_warning "DMG verification: $RESULT"
    fi
}

create_github_release() {
    VERSION=$(get_version)
    DMG_PATH="$PROJECT_DIR/$APP_NAME-$VERSION.dmg"
    TAG="v$VERSION"

    if [ ! -f "$DMG_PATH" ]; then
        print_error "DMG not found at $DMG_PATH"
        exit 1
    fi

    print_step "Creating GitHub release $TAG..."

    # Check if gh is installed
    if ! command -v gh &>/dev/null; then
        print_error "GitHub CLI (gh) not installed. Install with: brew install gh"
        exit 1
    fi

    # Check if authenticated
    if ! gh auth status &>/dev/null; then
        print_error "Not authenticated with GitHub. Run: gh auth login"
        exit 1
    fi

    # Get the last commit message for release notes
    COMMIT_MSG=$(git log -1 --pretty=%B | head -1)

    # Create release
    gh release create "$TAG" "$DMG_PATH" \
        --title "$APP_NAME $VERSION" \
        --notes "## What's New

$COMMIT_MSG"

    print_success "Release created: $TAG"
}

show_history() {
    print_step "Recent notarization submissions..."
    xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" 2>/dev/null | head -20
}

show_help() {
    echo ""
    echo "FlowFinder Build & Notarization Script"
    echo ""
    echo "Usage: $0 [option]"
    echo ""
    echo "Options:"
    echo "  (none)        Build, sign, notarize app, create DMG"
    echo "  --release     Same as above + create GitHub release"
    echo "  --skip-build  Skip build, notarize existing app"
    echo "  --dmg-only    Create DMG from existing notarized app"
    echo "  --check       Show notarization history"
    echo "  --help        Show this help message"
    echo ""
    echo "Setup:"
    echo "  1. Store notarization credentials:"
    echo "     xcrun notarytool store-credentials \"$KEYCHAIN_PROFILE\" \\"
    echo "         --apple-id \"your@email.com\" --team-id \"$TEAM_ID\""
    echo ""
    echo "  2. For GitHub releases, install and authenticate gh:"
    echo "     brew install gh && gh auth login"
    echo ""
}

# Main script
main() {
    echo ""
    echo "╔════════════════════════════════════════════════╗"
    echo "║      FlowFinder Build & Notarization           ║"
    echo "╚════════════════════════════════════════════════╝"

    cd "$PROJECT_DIR"
    VERSION=$(get_version)
    echo -e "Version: ${CYAN}$VERSION${NC}"

    case "${1:-}" in
        --help|-h)
            show_help
            exit 0
            ;;
        --check)
            check_credentials
            show_history
            exit 0
            ;;
        --skip-build)
            if [ ! -d "$APP_PATH" ]; then
                print_error "No app found at $APP_PATH"
                echo "Run without --skip-build first."
                exit 1
            fi
            check_credentials
            verify_signature
            submit_notarization
            staple_app
            verify_notarization
            create_dmg
            notarize_dmg
            verify_dmg
            ;;
        --dmg-only)
            if [ ! -d "$APP_PATH" ]; then
                print_error "No app found at $APP_PATH"
                exit 1
            fi
            create_dmg
            notarize_dmg
            verify_dmg
            ;;
        --release)
            check_credentials
            check_certificate
            clean_build
            build_archive
            export_app
            verify_signature
            submit_notarization
            staple_app
            verify_notarization
            create_dmg
            notarize_dmg
            verify_dmg
            create_github_release
            ;;
        "")
            check_credentials
            check_certificate
            clean_build
            build_archive
            export_app
            verify_signature
            submit_notarization
            staple_app
            verify_notarization
            create_dmg
            notarize_dmg
            verify_dmg
            ;;
        *)
            print_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac

    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Done! DMG ready: $APP_NAME-$VERSION.dmg${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════${NC}"
    echo ""
}

main "$@"
