# Bundled SevenZipKit

7-Zip engine 26.04 and the Objective-C++ Mac bridge from https://github.com/yrambler2001/7zip-macos, vendored from local revision `3aea5b8750f9193d648c19e4cca3ca498ffd9dae` on 2026-10-11. Only engine sources, the bridge, language resources, and license/patch documentation are included; the file-manager app and Finder extensions are excluded.

Sources retain their upstream licenses: LGPL 2.1 or later, the listed BSD/public-domain components, and the unRAR restriction for RAR decompression. See LICENSE, NOTICE, DOC/License.txt and DOC/unRarLicense.txt. This dependency does not provide RAR compression. CoverFlowFinder's own code retains its existing license.

Regenerate the checked-in project with `xcodegen -s Vendor/SevenZip/Mac/project.yml`. Normal CoverFlowFinder Xcode builds build and embed SevenZipKit automatically. No XcodeGen or external archive executable is needed to build the checked-in project or use the app.

CoverFlowFinder changes to the bridge are documented in PATCHES.md. The original Mac compatibility changes are documented in Mac/docs/upstream-patches.md. Preserve these notices and make this dependency's corresponding source available with binary distributions.
