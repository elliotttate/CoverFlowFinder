#!/bin/bash

# FlowFinder Notarization Script
# This script builds, signs, notarizes, and packages the app for distribution.
#
# SETUP (one-time):
#   Store your credentials in the keychain to avoid putting passwords in scripts:
#   xcrun notarytool store-credentials "FlowFinder-Notarization" \
#       --apple-id "your-apple-id@example.com" \
#       --team-id "RH4U5VJHM6" \
#       --password "app-specific-password"
#
#   To create an app-specific password:
#   1. Go to https://appleid.apple.com
#   2. Sign in and go to "App-Specific Passwords"
#   3. Generate a new password for "FlowFinder Notarization"
#
# USAGE:
#   ./scripts/notarize.sh
#   ./scripts/notarize.sh --skip-build    # Skip build, just notarize existing app
#   ./scripts/notarize.sh --check-status  # Check notarization history

set -e

# Configuration
APP_NAME="FlowFinder"
SCHEME="FlowFinder"
BUNDLE_ID="com.flowfinder.app"
TEAM_ID="RH4U5VJHM6"
KEYCHAIN_PROFILE="FlowFinder-Notarization"

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_PATH="$EXPORT_PATH/$APP_NAME.app"
ZIP_PATH="$BUILD_DIR/$APP_NAME-notarization.zip"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_step() {
    echo -e "\n${BLUE}==>${NC} $1"
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

get_version() {
    # Extract version from project
    VERSION=$(grep -m1 'MARKETING_VERSION' "$PROJECT_DIR/FlowFinder.xcodeproj/project.pbxproj" | sed 's/.*= //' | sed 's/;.*//' | tr -d ' ')
    echo "$VERSION"
}

clean_build() {
    print_step "Cleaning previous build..."
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    print_success "Build directory cleaned"
}

build_archive() {
    print_step "Building archive..."

    xcodebuild -project "$PROJECT_DIR/$APP_NAME.xcodeproj" \
        -scheme "$SCHEME" \
        -configuration Release \
        -archivePath "$ARCHIVE_PATH" \
        archive \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGN_IDENTITY="Developer ID Application" \
        CODE_SIGN_STYLE=Manual \
        | xcpretty || xcodebuild -project "$PROJECT_DIR/$APP_NAME.xcodeproj" \
            -scheme "$SCHEME" \
            -configuration Release \
            -archivePath "$ARCHIVE_PATH" \
            archive \
            DEVELOPMENT_TEAM="$TEAM_ID" \
            CODE_SIGN_IDENTITY="Developer ID Application" \
            CODE_SIGN_STYLE=Manual

    print_success "Archive created at $ARCHIVE_PATH"
}

export_app() {
    print_step "Exporting app..."

    # Create export options plist
    EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
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
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
EOF

    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_PATH" \
        -exportOptionsPlist "$EXPORT_OPTIONS"

    print_success "App exported to $APP_PATH"
}

verify_signature() {
    print_step "Verifying code signature..."

    codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1

    if codesign -dv --verbose=4 "$APP_PATH" 2>&1 | grep -q "Developer ID Application"; then
        print_success "App is signed with Developer ID"
    else
        print_error "App is not properly signed with Developer ID!"
        exit 1
    fi

    # Check for hardened runtime
    if codesign -dv --verbose=4 "$APP_PATH" 2>&1 | grep -q "runtime"; then
        print_success "Hardened runtime is enabled"
    else
        print_warning "Hardened runtime may not be enabled (required for notarization)"
    fi
}

create_zip() {
    print_step "Creating ZIP for notarization..."

    rm -f "$ZIP_PATH"
    ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

    print_success "ZIP created at $ZIP_PATH"
}

submit_notarization() {
    print_step "Submitting for notarization (this may take a few minutes)..."

    xcrun notarytool submit "$ZIP_PATH" \
        --keychain-profile "$KEYCHAIN_PROFILE" \
        --wait

    print_success "Notarization complete"
}

staple_app() {
    print_step "Stapling notarization ticket..."

    xcrun stapler staple "$APP_PATH"

    print_success "Ticket stapled to app"
}

verify_notarization() {
    print_step "Verifying notarization..."

    if spctl -a -vv "$APP_PATH" 2>&1 | grep -q "accepted"; then
        print_success "App is properly notarized and ready for distribution"
    else
        print_warning "Notarization verification returned unexpected result"
        spctl -a -vv "$APP_PATH"
    fi
}

create_distribution_zip() {
    VERSION=$(get_version)
    DIST_ZIP="$PROJECT_DIR/$APP_NAME-$VERSION.zip"

    print_step "Creating distribution ZIP..."

    rm -f "$DIST_ZIP"
    ditto -c -k --keepParent "$APP_PATH" "$DIST_ZIP"

    print_success "Distribution ZIP created: $DIST_ZIP"
    echo ""
    echo -e "${GREEN}Ready for distribution!${NC}"
    echo "Upload this file to GitHub releases: $DIST_ZIP"
}

show_history() {
    print_step "Notarization history..."
    xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE"
}

# Main script
main() {
    echo ""
    echo "╔═══════════════════════════════════════════╗"
    echo "║     FlowFinder Notarization Script        ║"
    echo "╚═══════════════════════════════════════════╝"

    cd "$PROJECT_DIR"

    case "${1:-}" in
        --check-status)
            check_credentials
            show_history
            exit 0
            ;;
        --skip-build)
            if [ ! -d "$APP_PATH" ]; then
                print_error "No app found at $APP_PATH. Run without --skip-build first."
                exit 1
            fi
            check_credentials
            verify_signature
            create_zip
            submit_notarization
            staple_app
            verify_notarization
            create_distribution_zip
            ;;
        "")
            check_credentials
            check_certificate
            clean_build
            build_archive
            export_app
            verify_signature
            create_zip
            submit_notarization
            staple_app
            verify_notarization
            create_distribution_zip
            ;;
        *)
            echo "Usage: $0 [--skip-build|--check-status]"
            exit 1
            ;;
    esac
}

main "$@"
