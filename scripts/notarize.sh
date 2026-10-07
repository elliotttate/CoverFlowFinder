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
#   4. Generate Sparkle EdDSA signing keys (one-time):
#      ./build/sparkle-tools/bin/generate_keys
#      The private key is stored in your Keychain automatically.
#
# USAGE:
#   ./scripts/notarize.sh              # Build, sign, notarize, create DMG
#   ./scripts/notarize.sh --release    # Same as above + appcast + GitHub release (run on an up-to-date main)
#   ./scripts/notarize.sh --skip-build # Skip build, just notarize existing app
#   ./scripts/notarize.sh --dmg-only   # Create DMG from existing notarized app
#   ./scripts/notarize.sh --check      # Check notarization history

set -euo pipefail

# Configuration
APP_NAME="FlowFinder"
SCHEME="FlowFinder"
TEAM_ID="RH4U5VJHM6"
KEYCHAIN_PROFILE="FlowFinder-Notarization"
SIGNING_IDENTITY="Developer ID Application: Brian Tate (RH4U5VJHM6)"
RELEASE_BRANCH="main"

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PBXPROJ="$PROJECT_DIR/$APP_NAME.xcodeproj/project.pbxproj"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_PATH="$EXPORT_PATH/$APP_NAME.app"
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
DOCS_DIR="$PROJECT_DIR/docs"
APPCAST="$DOCS_DIR/appcast.xml"

# Sparkle tools. These get access to the EdDSA private key in the Keychain, so the download is pinned to a
# version and verified against its SHA-256 before use. To update: change both values (the digest is listed
# for each asset on the GitHub release, or run: curl -fL <url> | shasum -a 256).
SPARKLE_VERSION="2.9.0"
SPARKLE_SHA256="01e0f0ebf6614061ea816d414de50f937d64ffa6822ad572243031ca3676fe19"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
SPARKLE_TOOLS_DIR="$BUILD_DIR/sparkle-tools"
SPARKLE_STAMP="$SPARKLE_TOOLS_DIR/.flowfinder-sparkle-sha256"
SPARKLE_SIGN="$SPARKLE_TOOLS_DIR/bin/sign_update"
SPARKLE_APPCAST="$SPARKLE_TOOLS_DIR/bin/generate_appcast"

# How far a --release run got in publishing, so a failure can say how to recover (see print_recovery)
RELEASE_STAGE=""

# Private scratch space for this run (removed on exit)
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/flowfinder-release.XXXXXX")"
cleanup() {
    local status=$?
    rm -rf "$WORK_DIR"
    if [ "$status" -ne 0 ] && [ -n "$RELEASE_STAGE" ]; then
        print_recovery
    fi
}
trap cleanup EXIT

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

# Value of a build setting from the project file; fails if Debug and Release disagree.
get_build_setting() {
    local name="$1" values count
    values=$(grep -E "^[[:space:]]*$name = " "$PBXPROJ" | sed 's/.*= //; s/;.*//; s/"//g' | tr -d ' ' | sort -u || true)
    count=$(printf '%s' "$values" | grep -c . || true)
    if [ "$count" -ne 1 ]; then
        print_error "Expected exactly one value for $name in project.pbxproj, found: ${values:-none}" >&2
        exit 1
    fi
    printf '%s\n' "$values"
}

# MARKETING_VERSION (CFBundleShortVersionString), e.g. 1.38.0
get_version() {
    get_build_setting MARKETING_VERSION
}

# CURRENT_PROJECT_VERSION (CFBundleVersion), e.g. 138. Sparkle compares this number.
get_build_number() {
    get_build_setting CURRENT_PROJECT_VERSION
}

# Highest sparkle:version already published in the appcast (0 if none).
latest_appcast_build_number() {
    local latest=""
    if [ -f "$APPCAST" ]; then
        latest=$(grep -o '<sparkle:version>[0-9]*</sparkle:version>' "$APPCAST" | sed 's/[^0-9]//g' | sort -n | tail -1 || true)
    fi
    echo "${latest:-0}"
}

check_versions() {
    print_step "Checking version numbers..."
    local version build latest
    version=$(get_version)
    build=$(get_build_number)
    latest=$(latest_appcast_build_number)

    if ! [[ "$build" =~ ^[0-9]+$ ]]; then
        print_error "CURRENT_PROJECT_VERSION must be a plain integer (got '$build')"
        exit 1
    fi
    if [ "$build" -le "$latest" ]; then
        print_error "CURRENT_PROJECT_VERSION ($build) must be greater than the newest sparkle:version in docs/appcast.xml ($latest)."
        echo "Sparkle compares CFBundleVersion: bump CURRENT_PROJECT_VERSION (and MARKETING_VERSION) in both build configurations."
        exit 1
    fi
    if [ -f "$APPCAST" ] && grep -q "<sparkle:shortVersionString>$version</sparkle:shortVersionString>" "$APPCAST"; then
        print_error "Version $version is already in docs/appcast.xml. Bump MARKETING_VERSION."
        exit 1
    fi
    print_success "Version $version (build $build) > latest published build $latest"
}

# A release must be built from the commit GitHub Pages and the release tag will point at.
check_release_branch() {
    print_step "Checking git state..."
    cd "$PROJECT_DIR"
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD)
    if [ "$branch" != "$RELEASE_BRANCH" ]; then
        print_error "Releases are published from '$RELEASE_BRANCH' (GitHub Pages serves the appcast from it); you're on '$branch'."
        exit 1
    fi
    git fetch --quiet origin "$RELEASE_BRANCH"
    if [ "$(git rev-parse HEAD)" != "$(git rev-parse "origin/$RELEASE_BRANCH")" ]; then
        print_error "Local $RELEASE_BRANCH differs from origin/$RELEASE_BRANCH. Push (or pull) first so the release tag matches what you build."
        exit 1
    fi
    if ! git diff --quiet || ! git diff --cached --quiet; then
        print_error "Uncommitted changes. Commit them (e.g. the version bump) and push before releasing."
        exit 1
    fi
    print_success "On $RELEASE_BRANCH, in sync with origin"
}

check_github_cli() {
    if ! command -v gh &>/dev/null; then
        print_error "GitHub CLI (gh) not installed. Install with: brew install gh"
        exit 1
    fi
    if ! gh auth status &>/dev/null; then
        print_error "Not authenticated with GitHub. Run: gh auth login"
        exit 1
    fi
}

# Before the long build: the version must not be released or tagged yet.
check_release_not_published() {
    print_step "Checking that v$(get_version) isn't published yet..."
    local tag output status
    tag="v$(get_version)"
    check_github_cli
    cd "$PROJECT_DIR"

    if output=$(gh release view "$tag" 2>&1); then
        print_error "GitHub release $tag already exists. Bump the version (step 1 in RELEASING.md)."
        echo "If it's left over from a failed run, see \"Recovering from a failed release\" in RELEASING.md."
        exit 1
    elif ! grep -qi "not found" <<<"$output"; then
        print_error "Couldn't check for an existing release $tag: $output"
        exit 1
    fi

    status=0
    git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1 || status=$?
    if [ "$status" -eq 0 ]; then
        print_error "Tag $tag already exists on origin (without a release). Delete it (git push origin :refs/tags/$tag) or bump the version."
        exit 1
    elif [ "$status" -ne 2 ]; then
        print_error "Couldn't list the tags on origin (git ls-remote exit $status)"
        exit 1
    fi
    print_success "No release or tag $tag yet"
}

# Optional release notes for the update dialog: release-notes/X.Y.Z.html, embedded in the appcast item. They must
# be an HTML fragment (no DOCTYPE, <html> or <body>), which Sparkle shows inside its own page.
release_notes_file() {
    echo "$PROJECT_DIR/release-notes/$(get_version).html"
}

check_release_notes() {
    print_step "Checking release notes..."
    local notes
    notes=$(release_notes_file)
    if [ ! -f "$notes" ]; then
        print_warning "No release-notes/$(get_version).html: the update dialog will show no notes"
        return
    fi
    if grep -qiE '<!doctype|<html([[:space:]>]|$)|<body([[:space:]>]|$)' "$notes"; then
        print_error "release-notes/$(get_version).html must be an HTML fragment (no DOCTYPE, <html> or <body>): it's embedded in the appcast."
        exit 1
    fi
    print_success "Release notes: release-notes/$(get_version).html"
}

# After a failed --release: what has been published so far, and how to finish or retry.
print_recovery() {
    local version tag
    version=$(get_version)
    tag="v$version"
    echo ""
    print_warning "The release of $tag stopped partway."
    case "$RELEASE_STAGE" in
        appcast)
            echo "  docs/appcast.xml was regenerated locally but not committed, and the GitHub release may be incomplete."
            echo "  To retry from scratch:"
            echo "    git checkout -- docs/appcast.xml"
            echo "    gh release delete $tag --cleanup-tag --yes   # only if 'gh release view $tag' shows a partial release"
            echo "    ./scripts/notarize.sh --release"
            ;;
        released)
            echo "  The GitHub release $tag is published, but the appcast isn't pushed, so Sparkle users don't see it yet."
            echo "  Finish by publishing the appcast (don't rerun the script):"
            echo "    git commit -m \"Update appcast.xml for $tag\" -- docs/appcast.xml   # skip if already committed"
            echo "    git push origin $RELEASE_BRANCH"
            ;;
    esac
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
    local identities
    identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
    if ! grep -q "Developer ID Application" <<<"$identities"; then
        print_error "Developer ID Application certificate not found!"
        echo "Please install your Developer ID certificate from the Apple Developer portal."
        exit 1
    fi
    print_success "Developer ID certificate found"
}

ensure_sparkle_tools() {
    if [ -x "$SPARKLE_SIGN" ] && [ -x "$SPARKLE_APPCAST" ] && [ -f "$SPARKLE_STAMP" ] \
        && [ "$(cat "$SPARKLE_STAMP")" = "$SPARKLE_SHA256" ]; then
        print_success "Sparkle tools v${SPARKLE_VERSION} found"
        return
    fi

    print_step "Downloading Sparkle tools v${SPARKLE_VERSION}..."
    local download_dir="$WORK_DIR/sparkle-download"
    local archive="$download_dir/Sparkle-${SPARKLE_VERSION}.tar.xz"
    mkdir -p "$download_dir/extracted"

    curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 -o "$archive" "$SPARKLE_URL"

    local actual
    actual=$(shasum -a 256 "$archive" | awk '{print $1}')
    if [ "$actual" != "$SPARKLE_SHA256" ]; then
        print_error "Sparkle download checksum mismatch!"
        echo "  expected: $SPARKLE_SHA256"
        echo "  actual:   $actual"
        exit 1
    fi

    tar -xf "$archive" -C "$download_dir/extracted"
    rm -rf "$SPARKLE_TOOLS_DIR"
    mkdir -p "$BUILD_DIR"
    mv "$download_dir/extracted" "$SPARKLE_TOOLS_DIR"
    echo "$SPARKLE_SHA256" > "$SPARKLE_STAMP"
    print_success "Sparkle tools downloaded and verified"
}

clean_build() {
    print_step "Cleaning previous build..."
    # Preserve sparkle-tools across builds (moved into this run's private scratch dir meanwhile)
    local backup="$WORK_DIR/sparkle-tools-backup"
    if [ -d "$SPARKLE_TOOLS_DIR" ]; then
        mv "$SPARKLE_TOOLS_DIR" "$backup"
    fi
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    if [ -d "$backup" ]; then
        mv "$backup" "$SPARKLE_TOOLS_DIR"
    fi
    print_success "Build directory cleaned"
}

build_archive() {
    print_step "Building archive (this may take a minute)..."
    local log="$BUILD_DIR/archive.log"

    if ! xcodebuild -project "$PROJECT_DIR/$APP_NAME.xcodeproj" \
        -scheme "$SCHEME" \
        -configuration Release \
        -archivePath "$ARCHIVE_PATH" \
        archive \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        > "$log" 2>&1; then
        tail -30 "$log"
        print_error "Archive failed! Full log: $log"
        exit 1
    fi
    tail -5 "$log"

    if [ ! -d "$ARCHIVE_PATH" ]; then
        print_error "Archive failed!"
        exit 1
    fi
    print_success "Archive created"
}

export_app() {
    print_step "Exporting app with Developer ID signing..."
    local log="$BUILD_DIR/export.log"

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

    if ! xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_PATH" \
        -exportOptionsPlist "$EXPORT_OPTIONS" \
        > "$log" 2>&1; then
        tail -30 "$log"
        print_error "Export failed! Full log: $log"
        exit 1
    fi
    tail -3 "$log"

    if [ ! -d "$APP_PATH" ]; then
        print_error "Export failed!"
        exit 1
    fi
    print_success "App exported"
}

# The exported app must carry the versions Sparkle will see in the appcast.
verify_bundle_versions() {
    print_step "Verifying bundle versions..."
    local plist="$APP_PATH/Contents/Info.plist" short build
    short=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist")
    build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist")
    if [ "$short" != "$(get_version)" ] || [ "$build" != "$(get_build_number)" ]; then
        print_error "Built app is $short ($build), expected $(get_version) ($(get_build_number))"
        exit 1
    fi
    print_success "CFBundleShortVersionString $short, CFBundleVersion $build"
}

verify_signature() {
    print_step "Verifying code signature..."
    local details entitlements
    details=$(codesign -dvv "$APP_PATH" 2>&1 || true)

    # Check signature
    if grep -q "Developer ID Application" <<<"$details"; then
        print_success "Signed with Developer ID"
    else
        print_error "Not properly signed!"
        exit 1
    fi

    # Check timestamp
    if grep -q "Timestamp=" <<<"$details"; then
        print_success "Secure timestamp present"
    else
        print_warning "No secure timestamp (may fail notarization)"
    fi

    # Check for debug entitlement
    entitlements=$(codesign -d --entitlements :- "$APP_PATH" 2>/dev/null || true)
    if grep -q "get-task-allow" <<<"$entitlements"; then
        print_error "Debug entitlement present (will fail notarization)!"
        exit 1
    else
        print_success "No debug entitlements"
    fi
}

# Submits a file and waits; fails unless Apple reports "Accepted".
notarize_file() {
    local file="$1"
    local log
    log="$WORK_DIR/notarize-$(basename "$file").log"
    if ! xcrun notarytool submit "$file" --keychain-profile "$KEYCHAIN_PROFILE" --wait 2>&1 | tee "$log"; then
        print_error "Notarization submission failed"
        exit 1
    fi
    if ! grep -q "status: Accepted" "$log"; then
        print_error "Notarization was not accepted (see: xcrun notarytool log <submission-id> --keychain-profile \"$KEYCHAIN_PROFILE\")"
        exit 1
    fi
}

submit_notarization() {
    print_step "Submitting for notarization (this may take 2-5 minutes)..."

    # Create a temporary zip for notarization
    local notarize_zip="$WORK_DIR/notarize.zip"
    ditto -c -k --keepParent "$APP_PATH" "$notarize_zip"
    notarize_file "$notarize_zip"
    rm -f "$notarize_zip"
    print_success "Notarization accepted"
}

staple_app() {
    print_step "Stapling notarization ticket..."
    xcrun stapler staple "$APP_PATH"
    print_success "Ticket stapled"
}

verify_notarization() {
    print_step "Verifying notarization..."

    local result
    result=$(spctl -a -t open --context context:primary-signature -v "$APP_PATH" 2>&1 || true)
    if grep -q "accepted" <<<"$result"; then
        print_success "App is notarized and ready for distribution"
        echo "  $result"
    else
        print_warning "Verification returned unexpected result:"
        echo "  $result"
    fi
}

create_dmg() {
    local version dmg_name dmg_path staging tmp_dmg
    version=$(get_version)
    dmg_name="$APP_NAME-$version.dmg"
    dmg_path="$PROJECT_DIR/$dmg_name"
    staging="$WORK_DIR/dmg_contents"
    tmp_dmg="$WORK_DIR/$APP_NAME-temp.dmg"

    print_step "Creating DMG installer..."

    # Clean up
    rm -f "$dmg_path"
    rm -rf "$staging"
    mkdir -p "$staging"

    # Copy app and create Applications symlink
    cp -R "$APP_PATH" "$staging/"
    ln -s /Applications "$staging/Applications"

    # Create DMG
    hdiutil create -volname "$APP_NAME" -srcfolder "$staging" -ov -format UDRW "$tmp_dmg" >/dev/null
    hdiutil convert "$tmp_dmg" -format UDZO -o "$dmg_path" >/dev/null

    # Sign DMG
    codesign --force --sign "$SIGNING_IDENTITY" "$dmg_path"

    # Clean up
    rm -f "$tmp_dmg"
    rm -rf "$staging"

    print_success "DMG created: $dmg_name"
    echo "$dmg_path"
}

notarize_dmg() {
    local dmg_path
    dmg_path="$PROJECT_DIR/$APP_NAME-$(get_version).dmg"

    if [ ! -f "$dmg_path" ]; then
        print_error "DMG not found at $dmg_path"
        exit 1
    fi

    print_step "Notarizing DMG..."
    notarize_file "$dmg_path"

    print_step "Stapling DMG..."
    xcrun stapler staple "$dmg_path"

    print_success "DMG notarized and stapled"
}

verify_dmg() {
    local dmg_path result
    dmg_path="$PROJECT_DIR/$APP_NAME-$(get_version).dmg"

    print_step "Verifying DMG..."
    result=$(spctl -a -t open --context context:primary-signature -v "$dmg_path" 2>&1 || true)
    if grep -q "accepted" <<<"$result"; then
        print_success "DMG verified: $result"
    else
        print_warning "DMG verification: $result"
    fi
}

sparkle_sign_dmg() {
    local dmg_path signature
    dmg_path="$PROJECT_DIR/$APP_NAME-$(get_version).dmg"

    print_step "Signing DMG with Sparkle EdDSA key..."

    # sign_update reads the private key from the Keychain automatically
    signature=$("$SPARKLE_SIGN" "$dmg_path" || true)

    if [ -z "$signature" ]; then
        print_error "Sparkle signing failed! Make sure EdDSA key is in Keychain."
        print_warning "Run: $SPARKLE_TOOLS_DIR/bin/generate_keys  (if not done)"
        exit 1
    fi

    print_success "DMG signed with Sparkle EdDSA"
    echo "  $signature"
}

update_appcast() {
    local version dmg_path releases_dir
    version=$(get_version)
    dmg_path="$PROJECT_DIR/$APP_NAME-$version.dmg"

    print_step "Generating appcast.xml..."

    mkdir -p "$DOCS_DIR"

    # Create a releases directory with the current DMG
    releases_dir="$BUILD_DIR/releases"
    rm -rf "$releases_dir"
    mkdir -p "$releases_dir"
    cp "$dmg_path" "$releases_dir/"

    # Release notes: an HTML file next to the DMG with the same base name is picked up by generate_appcast, and
    # embedded in the item (otherwise it would link to the file, which is never published).
    if [ -f "$(release_notes_file)" ]; then
        cp "$(release_notes_file)" "$releases_dir/$APP_NAME-$version.html"
    fi

    # If an existing appcast exists, copy it so generate_appcast can append
    if [ -f "$APPCAST" ]; then
        cp "$APPCAST" "$releases_dir/"
    fi

    # generate_appcast reads the EdDSA key from Keychain
    "$SPARKLE_APPCAST" \
        --embed-release-notes \
        --download-url-prefix "https://github.com/elliotttate/CoverFlowFinder/releases/download/v$version/" \
        "$releases_dir"

    # Copy generated appcast to docs/
    cp "$releases_dir/appcast.xml" "$APPCAST"

    if ! grep -q "<sparkle:version>$(get_build_number)</sparkle:version>" "$APPCAST"; then
        print_error "docs/appcast.xml has no entry for build $(get_build_number)"
        exit 1
    fi
    print_success "Appcast updated at docs/appcast.xml"
}

commit_appcast() {
    local version branch
    version=$(get_version)

    print_step "Committing appcast.xml..."

    cd "$PROJECT_DIR"
    branch=$(git rev-parse --abbrev-ref HEAD)
    if [ "$branch" != "$RELEASE_BRANCH" ]; then
        print_error "Not pushing the appcast from '$branch' (GitHub Pages serves $RELEASE_BRANCH)."
        echo "Commit and push it from $RELEASE_BRANCH: git commit -m \"Update appcast.xml for v$version\" -- docs/appcast.xml && git push origin $RELEASE_BRANCH"
        exit 1
    fi

    git add -- docs/appcast.xml
    if git diff --cached --quiet -- docs/appcast.xml; then
        print_warning "docs/appcast.xml unchanged; nothing to commit"
        return
    fi
    # Commit only the appcast, even if other changes happen to be staged.
    git commit -m "Update appcast.xml for v$version" -- docs/appcast.xml
    git push origin "$RELEASE_BRANCH"

    print_success "Appcast committed and pushed"
}

create_github_release() {
    local version dmg_path tag commit_msg
    version=$(get_version)
    dmg_path="$PROJECT_DIR/$APP_NAME-$version.dmg"
    tag="v$version"

    if [ ! -f "$dmg_path" ]; then
        print_error "DMG not found at $dmg_path"
        exit 1
    fi

    print_step "Creating GitHub release $tag..."
    check_github_cli

    # Get the last commit message for release notes
    commit_msg=$(git log -1 --pretty=%s)

    # Create release (tagging the commit that was built)
    gh release create "$tag" "$dmg_path" \
        --target "$(git rev-parse HEAD)" \
        --title "$APP_NAME $version" \
        --notes "## What's New

$commit_msg"

    print_success "Release created: $tag"
}

show_history() {
    print_step "Recent notarization submissions..."
    local history
    history=$(xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" 2>/dev/null || true)
    printf '%s\n' "$history" | head -20
}

show_help() {
    echo ""
    echo "FlowFinder Build & Notarization Script"
    echo ""
    echo "Usage: $0 [option]"
    echo ""
    echo "Options:"
    echo "  (none)        Build, sign, notarize app, create DMG"
    echo "  --release     Same as above + Sparkle-sign, update appcast, create GitHub release"
    echo "                (must run on an up-to-date main with CURRENT_PROJECT_VERSION bumped)"
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
    echo "  2. Generate Sparkle EdDSA signing keys (one-time):"
    echo "     ./build/sparkle-tools/bin/generate_keys"
    echo ""
    echo "  3. For GitHub releases, install and authenticate gh:"
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
    local version
    version=$(get_version)
    echo -e "Version: ${CYAN}$version${NC} (build $(get_build_number))"

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
            check_release_branch
            check_versions
            check_release_not_published
            check_release_notes
            check_credentials
            check_certificate
            ensure_sparkle_tools
            clean_build
            build_archive
            export_app
            verify_bundle_versions
            verify_signature
            submit_notarization
            staple_app
            verify_notarization
            create_dmg
            notarize_dmg
            verify_dmg
            sparkle_sign_dmg
            # The release goes up before the appcast announces it, so Sparkle never offers a download that isn't
            # there yet. A failure after this point prints how to recover (print_recovery).
            RELEASE_STAGE=appcast
            update_appcast
            create_github_release
            RELEASE_STAGE=released
            commit_appcast
            RELEASE_STAGE=""
            ;;
        "")
            check_credentials
            check_certificate
            clean_build
            build_archive
            export_app
            verify_bundle_versions
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
    echo -e "${GREEN}  Done! DMG ready: $APP_NAME-$version.dmg${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════${NC}"
    echo ""
}

main "$@"
