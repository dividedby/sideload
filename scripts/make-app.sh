#!/usr/bin/env bash
# Assembles .build/app/SideloadMenu.app (docs/design.md section 4): an arm64 release build of the SideloadMenu
# SPM executable, an Info.plist, the canary project as a resource, and an ad-hoc signature.
#
# It builds and signs only. It never installs the app, never launches it, and never signs with an identity
# (no certificate, no Apple ID, no portal): the owner copies the app to ~/Applications and opens it.
set -euo pipefail

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "make-app.sh: Apple Silicon (arm64) only; got $(uname -m)" >&2
  exit 1
fi

cd "$(dirname "$0")/.."
root="$PWD"

# A release build: `#if DEBUG` code (the SIDELOAD_TEST_FORCE_SLOT hook in SlotCommand) is compiled out of the app.
swift build -c release --arch arm64 --product SideloadMenu
bin="$(swift build -c release --arch arm64 --show-bin-path)"
if [[ ! -x "$bin/SideloadMenu" ]]; then
  echo "make-app.sh: $bin/SideloadMenu was not built" >&2
  exit 1
fi

version="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' package.json | head -n 1)"
version="${version:-0.1.0}"

app="$root/.build/app/SideloadMenu.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp "$bin/SideloadMenu" "$app/Contents/MacOS/SideloadMenu"
# SPM cannot run a post-build strip (design section 3).
strip -x "$app/Contents/MacOS/SideloadMenu"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.dividedby.sideload.menu</string>
  <key>CFBundleName</key><string>SideloadMenu</string>
  <key>CFBundleDisplayName</key><string>sideload</string>
  <key>CFBundleExecutable</key><string>SideloadMenu</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${version}</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>LSUIElement</key><true/>
  <key>LSRequiresNativeExecution</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>Copyright 2026 dividedby</string>
</dict>
</plist>
PLIST
plutil -lint "$app/Contents/Info.plist" >/dev/null

# The canary payload (the project and its sources, nothing else from canary/). The canary build writes its derived
# data to $SIDELOAD_HOME/builds/canary, never into the bundle, so the signature stays intact.
mkdir -p "$app/Contents/Resources/canary"
rsync -a --exclude xcuserdata --exclude .DS_Store canary/Canary.xcodeproj canary/Canary "$app/Contents/Resources/canary/"

# Ad-hoc only (`-s -`): the code hash is the identity, so a rebuild is a "new" app to the keychain (design section 4).
codesign --force --deep --sign - --options runtime --timestamp=none "$app"
codesign --verify --strict --deep --verbose=2 "$app"

echo "$app"
