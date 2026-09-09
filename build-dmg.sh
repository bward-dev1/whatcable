#!/usr/bin/env bash
set -euo pipefail

APP_NAME="WhatCable"
BUNDLE_ID="uk.whatcable.whatcable"
VERSION="1.5.0-beta.8"
BUILD_NUMBER="137"
MIN_OS="14.0"
CLI_PRODUCT="whatcable-cli"
CLI_BIN_NAME="whatcable"

DIST_DIR="dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
HELPERS_DIR="${CONTENTS_DIR}/Helpers"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
PLUGINS_DIR="${CONTENTS_DIR}/PlugIns"
ENTITLEMENTS="scripts/${APP_NAME}.entitlements"
WIDGET_ENTITLEMENTS="scripts/WhatCableWidget.entitlements"
WIDGET_APPEX="WhatCableWidget.appex"

echo "==> Cleaning previous build"
rm -rf "${DIST_DIR}"
mkdir -p "${MACOS_DIR}" "${HELPERS_DIR}" "${RESOURCES_DIR}" "${PLUGINS_DIR}"

echo "==> Building universal release binaries (arm64 + x86_64)"
swift build -c release --product "${APP_NAME}" \
    --arch arm64 --arch x86_64
swift build -c release --product "${CLI_PRODUCT}" \
    --arch arm64 --arch x86_64

BIN_PATH=$(swift build -c release --product "${APP_NAME}" \
    --arch arm64 --arch x86_64 --show-bin-path)
cp "${BIN_PATH}/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"
cp "${BIN_PATH}/${CLI_PRODUCT}" "${HELPERS_DIR}/${CLI_BIN_NAME}"

echo "==> Building widget extension (xcodebuild)"
if command -v xcodegen &>/dev/null; then
    xcodegen generate --quiet
elif [[ ! -d "WhatCableWidget.xcodeproj" ]]; then
    echo "    ERROR: xcodegen not installed. Install with: brew install xcodegen" >&2
    exit 1
fi

xcodebuild build -project WhatCableWidget.xcodeproj -scheme WhatCableWidget \
    -configuration Release \
    -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="${VERSION}" \
    CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
    -quiet

WIDGET_BUILD_DIR=$(xcodebuild -project WhatCableWidget.xcodeproj -scheme WhatCableWidget \
    -configuration Release -showBuildSettings 2>/dev/null \
    | grep ' BUILD_DIR = ' | awk '{print $NF}')
cp -R "${WIDGET_BUILD_DIR}/Release/${WIDGET_APPEX}" "${PLUGINS_DIR}/${WIDGET_APPEX}"
echo "    Widget embedded at ${PLUGINS_DIR}/${WIDGET_APPEX}"

echo "==> Copying resources"
SPM_BUNDLE_NAME="WhatCable_WhatCableCore.bundle"
SPM_RESOURCES_SRC="Sources/WhatCableCore/Resources"
if [[ -d "${SPM_RESOURCES_SRC}" ]]; then
    bundle_path="${RESOURCES_DIR}/${SPM_BUNDLE_NAME}"
    rm -rf "${bundle_path}"
    mkdir -p "${bundle_path}"
    cp -R "${SPM_RESOURCES_SRC}/." "${bundle_path}/"
fi

APP_BUNDLE_NAME="WhatCable_WhatCable.bundle"
APP_RESOURCES_SRC="Sources/WhatCable/Resources"
if [[ -d "${APP_RESOURCES_SRC}" ]]; then
    bundle_path="${RESOURCES_DIR}/${APP_BUNDLE_NAME}"
    rm -rf "${bundle_path}"
    mkdir -p "${bundle_path}"
    cp -R "${APP_RESOURCES_SRC}/." "${bundle_path}/"
fi

NOTIFICATIONS_BUNDLE_NAME="WhatCable_WhatCableNotifications.bundle"
NOTIFICATIONS_RESOURCES_SRC="Sources/WhatCableNotifications/Resources"
if [[ -d "${NOTIFICATIONS_RESOURCES_SRC}" ]]; then
    bundle_path="${RESOURCES_DIR}/${NOTIFICATIONS_BUNDLE_NAME}"
    rm -rf "${bundle_path}"
    mkdir -p "${bundle_path}"
    cp -R "${NOTIFICATIONS_RESOURCES_SRC}/." "${bundle_path}/"
fi

TUIKIT_BUNDLE_NAME="TUIkit_TUIkit.bundle"
TUIKIT_BUNDLE_SRC="${BIN_PATH}/${TUIKIT_BUNDLE_NAME}"
if [[ -d "${TUIKIT_BUNDLE_SRC}" ]]; then
    cp -R "${TUIKIT_BUNDLE_SRC}" "${RESOURCES_DIR}/${TUIKIT_BUNDLE_NAME}"
fi

echo "==> Copying app icon"
if [[ ! -f "scripts/AppIcon.icns" ]]; then
    echo "    AppIcon.icns missing — regenerating"
    ./scripts/make-icon.sh
fi
cp "scripts/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"

echo "==> Building test kit probes"
PROBES_SRC_DIR="probes/test-kit"
PROBES_DEST_DIR="${RESOURCES_DIR}/probes"
if [[ -d "${PROBES_SRC_DIR}" ]]; then
    mkdir -p "${PROBES_DEST_DIR}"
    for src in "${PROBES_SRC_DIR}"/*.c; do
        name=$(basename "${src}" .c)
        clang -arch arm64 -arch x86_64 \
            -framework IOKit -framework CoreFoundation \
            -mmacosx-version-min="${MIN_OS}" \
            -O2 -o "${PROBES_DEST_DIR}/${name}" "${src}"
    done
fi

echo "==> Writing Info.plist"
cat > "${CONTENTS_DIR}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_OS}</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

printf "APPL????" > "${CONTENTS_DIR}/PkgInfo"

echo "==> Ad-hoc signing"
codesign --force --sign - "${HELPERS_DIR}/${CLI_BIN_NAME}"
if [[ -d "${RESOURCES_DIR}/probes" ]]; then
    for probe in "${RESOURCES_DIR}/probes"/*; do
        codesign --force --sign - "${probe}"
    done
fi
codesign --force --entitlements "${WIDGET_ENTITLEMENTS}" \
    --sign - "${PLUGINS_DIR}/${WIDGET_APPEX}"
codesign --force --entitlements "${ENTITLEMENTS}" \
    --sign - "${APP_DIR}"

echo "==> Creating DMG"
# Create a temporary directory for DMG contents
DMG_TEMP=$(mktemp -d)
trap "rm -rf ${DMG_TEMP}" EXIT

# Copy app to temp directory
cp -R "${APP_DIR}" "${DMG_TEMP}/"

# Create a symlink to Applications folder
ln -s /Applications "${DMG_TEMP}/Applications"

# Create the DMG
DMG_FILE="${DIST_DIR}/WhatCable.dmg"
hdiutil create -volname "WhatCable" -srcfolder "${DMG_TEMP}" -ov -format UDZO "${DMG_FILE}"

echo "Done!"
echo "  DMG: ${DMG_FILE}"
