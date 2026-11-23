#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "==> 1. Generating Xcode project via XcodeGen..."
cd "${REPO_ROOT}"
xcodegen generate

DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
if [ ! -d "${DEVELOPER_DIR}" ]; then
    DEVELOPER_DIR="$(xcode-select -p)"
fi
export DEVELOPER_DIR

echo "==> Using Developer Dir: ${DEVELOPER_DIR}"

DERIVED_DATA_PATH="${REPO_ROOT}/build/DerivedData"
rm -rf "${DERIVED_DATA_PATH}"

echo "==> 2. Building Release configuration for iOS..."
xcodebuild -project Trashcall.xcodeproj \
    -scheme Trashcall \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -derivedDataPath "${DERIVED_DATA_PATH}" \
    clean build \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO

APP_PATH="${DERIVED_DATA_PATH}/Build/Products/Release-iphoneos/Trashcall.app"
if [ ! -d "${APP_PATH}" ]; then
    echo "ERROR: Trashcall.app not found at ${APP_PATH}"
    exit 1
fi

echo "==> 3. Setting up staging payload..."
STAGING_DIR="$(mktemp -d /tmp/trashcall_ipa_staging.XXXXXX)"
trap 'rm -rf "${STAGING_DIR}"' EXIT

mkdir -p "${STAGING_DIR}/Payload"
cp -R "${APP_PATH}" "${STAGING_DIR}/Payload/"

STAGED_APP="${STAGING_DIR}/Payload/Trashcall.app"

# Clean any preview, debug symbols, or stale mobileprovisions
find "${STAGED_APP}" -name "*preview*.dylib" -delete
find "${STAGED_APP}" -name "*.debug.dylib" -delete
find "${STAGED_APP}" -name ".DS_Store" -delete
find "${STAGED_APP}" -name "*.mobileprovision" -delete

# Ensure valid execution permissions across bundles
chmod -R u+rwX,go+rX "${STAGED_APP}"
chmod +x "${STAGED_APP}/Trashcall"
if [ -f "${STAGED_APP}/PlugIns/TrashcallCallDirectory.appex/TrashcallCallDirectory" ]; then
    chmod +x "${STAGED_APP}/PlugIns/TrashcallCallDirectory.appex/TrashcallCallDirectory"
fi
if [ -f "${STAGED_APP}/PlugIns/TrashcallBlockDirectory.appex/TrashcallBlockDirectory" ]; then
    chmod +x "${STAGED_APP}/PlugIns/TrashcallBlockDirectory.appex/TrashcallBlockDirectory"
fi
if [ -f "${STAGED_APP}/Frameworks/TrashcallCore.framework/TrashcallCore" ]; then
    chmod +x "${STAGED_APP}/Frameworks/TrashcallCore.framework/TrashcallCore"
fi

echo "==> 4. Signing app bundle and plugins ad-hoc..."
if [ -d "${STAGED_APP}/Frameworks/TrashcallCore.framework" ]; then
    codesign -s - --force --timestamp=none --generate-entitlement-der "${STAGED_APP}/Frameworks/TrashcallCore.framework"
fi

if [ -d "${STAGED_APP}/PlugIns/TrashcallCallDirectory.appex" ]; then
    codesign -s - --force --timestamp=none --generate-entitlement-der \
        "${STAGED_APP}/PlugIns/TrashcallCallDirectory.appex"
fi

if [ -d "${STAGED_APP}/PlugIns/TrashcallBlockDirectory.appex" ]; then
    codesign -s - --force --timestamp=none --generate-entitlement-der \
        "${STAGED_APP}/PlugIns/TrashcallBlockDirectory.appex"
fi

codesign -s - --force --timestamp=none --generate-entitlement-der \
    --entitlements "${REPO_ROOT}/App/Trashcall.entitlements" \
    "${STAGED_APP}"

codesign -vvv --deep --strict "${STAGED_APP}"

echo "==> 5. Packaging into IPA..."
DESKTOP_DIR="${HOME}/Desktop"
DESKTOP_IPA="${DESKTOP_DIR}/Trashcall.ipa"
ROOT_IPA="${REPO_ROOT}/Trashcall.ipa"

# Explicitly remove prior existing zip to prevent zip from merging stale files into archive
rm -f "${DESKTOP_IPA}" "${ROOT_IPA}"

cd "${STAGING_DIR}"
zip -r -q -y "${DESKTOP_IPA}" Payload

cp -f "${DESKTOP_IPA}" "${ROOT_IPA}"

echo "==> IPA built successfully!"
echo "    Desktop: ${DESKTOP_IPA} ($(ls -lh "${DESKTOP_IPA}" | awk '{print $5}'))"
echo "    Repo:    ${ROOT_IPA} ($(ls -lh "${ROOT_IPA}" | awk '{print $5}'))"
