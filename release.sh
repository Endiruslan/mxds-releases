#!/bin/bash
# Release script: build, sign, upload to GitHub, update appcast
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ORIG_ARGS=("$@")
source "$ROOT_DIR/scripts/build-app.sh" release 2>&1
set -- "${ORIG_ARGS[@]}"

# Read version from build-app.sh variables
VERSION="$MXDS_VERSION"
BUILD="$MXDS_BUILD"
RELEASES_REPO="Endiruslan/mxds-releases"
ZIP_NAME="mxds-${VERSION}.zip"
ZIP_PATH="$ROOT_DIR/.build/release-app/$ZIP_NAME"
APP_PATH="$ROOT_DIR/.build/release-app/mxds.app"
SPARKLE_BIN="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin"

echo ""
echo "=== Creating release v${VERSION} (build ${BUILD}) ==="

# Create zip with ditto (preserves macOS attributes)
echo "Creating $ZIP_NAME..."
cd "$ROOT_DIR/.build/release-app"
ditto -c -k --keepParent mxds.app "$ZIP_NAME"

# Sign with EdDSA
echo "Signing archive..."
SIGN_OUTPUT=$("$SPARKLE_BIN/sign_update" "$ZIP_PATH")
echo "$SIGN_OUTPUT"

# Extract signature and length for appcast
ED_SIGNATURE=$(echo "$SIGN_OUTPUT" | grep -o 'sparkle:edSignature="[^"]*"' | sed 's/sparkle:edSignature="//;s/"//')
ZIP_LENGTH=$(stat -f%z "$ZIP_PATH")

# Generate appcast.xml
APPCAST_PATH="$ROOT_DIR/.build/release-app/appcast.xml"
RELEASE_DATE=$(date -R)
cat > "$APPCAST_PATH" <<APPCAST_EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>mxds</title>
    <link>https://raw.githubusercontent.com/${RELEASES_REPO}/main/appcast.xml</link>
    <language>en</language>
    <item>
      <title>mxds v${VERSION}</title>
      <pubDate>${RELEASE_DATE}</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure
        url="https://github.com/${RELEASES_REPO}/releases/download/v${VERSION}/${ZIP_NAME}"
        length="${ZIP_LENGTH}"
        type="application/octet-stream"
        sparkle:edSignature="${ED_SIGNATURE}"
      />
    </item>
  </channel>
</rss>
APPCAST_EOF

echo ""
echo "=== Release artifacts ready ==="
echo "  App:     $APP_PATH"
echo "  Archive: $ZIP_PATH"
echo "  Appcast: $APPCAST_PATH"
echo ""
echo "To publish:"
echo "  1. gh release create v${VERSION} ${ZIP_PATH} --repo ${RELEASES_REPO} --title 'mxds v${VERSION}' --notes 'Changelog here'"
echo "  2. Copy appcast.xml to mxds-releases repo and push"
echo ""
echo "Or run with --publish flag to do it automatically."

if [[ "${2:-}" == "--publish" ]]; then
    CHANGELOG="${3:-Release v${VERSION}}"
    echo "Publishing to GitHub..."
    gh release create "v${VERSION}" "$ZIP_PATH" \
        --repo "$RELEASES_REPO" \
        --title "mxds v${VERSION}" \
        --notes "$CHANGELOG"

    echo "Updating appcast.xml in releases repo..."
    RELEASES_DIR=$(mktemp -d)
    gh repo clone "$RELEASES_REPO" "$RELEASES_DIR" -- --depth 1 2>/dev/null
    cp "$APPCAST_PATH" "$RELEASES_DIR/appcast.xml"
    cd "$RELEASES_DIR"
    git add appcast.xml
    git -c user.name="Endiruslan" -c user.email="endiruslan@gmail.com" \
        commit -m "Update appcast for v${VERSION}"
    git push
    rm -rf "$RELEASES_DIR"

    echo ""
    echo "=== Published v${VERSION} ==="
    echo "https://github.com/${RELEASES_REPO}/releases/tag/v${VERSION}"
fi
