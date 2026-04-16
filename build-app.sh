#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Version — bump these for each release
MXDS_VERSION="0.0.5"
MXDS_BUILD="5"

CONFIGURATION="${1:-release}"
APP_NAME="mxds.app"
APP_ROOT="$ROOT_DIR/.build/${CONFIGURATION}-app/$APP_NAME"
CONTENTS_DIR="$APP_ROOT/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE_PATH="$MACOS_DIR/mxds"

echo "Building mxds ($CONFIGURATION)..."
if [[ -x "$ROOT_DIR/scripts/build-bigquery-helper.sh" ]]; then
  "$ROOT_DIR/scripts/build-bigquery-helper.sh"
fi
swift build -c "$CONFIGURATION" --product mxds
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
SOURCE_EXECUTABLE="$BIN_DIR/mxds"

if [[ ! -f "$SOURCE_EXECUTABLE" ]]; then
  echo "mxds executable not found at $SOURCE_EXECUTABLE" >&2
  exit 1
fi

rm -rf "$APP_ROOT"
mkdir -p "$MACOS_DIR" "$FRAMEWORKS_DIR" "$RESOURCES_DIR"

cp "$SOURCE_EXECUTABLE" "$EXECUTABLE_PATH"
chmod u+w "$EXECUTABLE_PATH"

if ! otool -l "$EXECUTABLE_PATH" | rg -q "path @executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXECUTABLE_PATH"
fi

# Copy all top-level resource files into Contents/Resources/ so that
# Bundle.main.url(forResource:withExtension:) can find them.
# Also preserve the nested Resources/ directory for subdirectories
# (Ghostty, TreeSitter, Go, etc.) that code references by relative path.
for f in "$ROOT_DIR/Resources"/*.png; do
  cp "$f" "$RESOURCES_DIR/"
done
cp -R "$ROOT_DIR/Resources/Ghostty" "$RESOURCES_DIR/Ghostty"
cp -R "$ROOT_DIR/Resources/TreeSitter" "$RESOURCES_DIR/TreeSitter"
if [[ -d "$ROOT_DIR/Resources/LSP" ]]; then
  cp -R "$ROOT_DIR/Resources/LSP" "$RESOURCES_DIR/LSP"
fi
if [[ -d "$ROOT_DIR/Resources/Go" ]]; then
  cp -R "$ROOT_DIR/Resources/Go" "$RESOURCES_DIR/Go"
fi

# Generate .icns from icon.png so Finder, Cmd+Tab, and Dock show the icon.
echo "Generating app icon..."
ICONSET_DIR=$(mktemp -d)/icon.iconset
mkdir -p "$ICONSET_DIR"
ICON_SRC="$ROOT_DIR/Resources/icon.png"
for size in 16 32 64 128 256 512; do
  sips -z $size $size "$ICON_SRC" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null 2>&1
  double=$((size * 2))
  sips -z $double $double "$ICON_SRC" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null 2>&1
done
iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
rm -rf "$(dirname "$ICONSET_DIR")"

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>mxds</string>
    <key>CFBundleIdentifier</key>
    <string>dev.mxds.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>mxds</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${MXDS_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${MXDS_BUILD}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>SUFeedURL</key>
    <string>https://raw.githubusercontent.com/Endiruslan/mxds-releases/main/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>jEojoHUBWBR535gwij7CCLvqJu/GNaWcKCVuRfT+glA=</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <integer>21600</integer>
</dict>
</plist>
EOF

bundle_dependencies_for() {
  local item="$1"
  local item_kind="$2"
  local deps=()

  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    deps+=("$dep")
  done < <(otool -L "$item" | awk 'NR > 1 { print $1 }')

  local dep
  for dep in "${deps[@]}"; do
    case "$dep" in
      /System/*|/usr/lib/*|@*)
        continue
        ;;
    esac

    local dep_name
    dep_name="$(basename "$dep")"
    local bundled_dep="$FRAMEWORKS_DIR/$dep_name"

    if [[ ! -f "$bundled_dep" ]]; then
      cp -L "$dep" "$bundled_dep"
      chmod u+w "$bundled_dep"
      install_name_tool -id "@rpath/$dep_name" "$bundled_dep"
      bundle_dependencies_for "$bundled_dep" dylib
    fi

    local rewritten_dep
    if [[ "$item_kind" == "executable" ]]; then
      rewritten_dep="@rpath/$dep_name"
    else
      rewritten_dep="@loader_path/$dep_name"
    fi

    install_name_tool -change "$dep" "$rewritten_dep" "$item"
  done
}

echo "Bundling Homebrew dynamic libraries..."
bundle_dependencies_for "$EXECUTABLE_PATH" executable

while IFS= read -r dep; do
  [[ -z "$dep" ]] && continue
  case "$dep" in
    /System/*|/usr/lib/*|@*)
      continue
      ;;
  esac
  install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$EXECUTABLE_PATH"
done < <(otool -L "$EXECUTABLE_PATH" | awk 'NR > 1 { print $1 }')

for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    case "$dep" in
      /System/*|/usr/lib/*|@*)
        continue
        ;;
    esac
    install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$dylib"
  done < <(otool -L "$dylib" | awk 'NR > 1 { print $1 }')
done

if otool -L "$EXECUTABLE_PATH" | rg -q "/opt/homebrew|/Cellar"; then
  echo "Packaged executable still references Homebrew libraries." >&2
  exit 1
fi

for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
  if otool -L "$dylib" | rg -q "/opt/homebrew|/Cellar"; then
    echo "Bundled dylib still references Homebrew libraries: $dylib" >&2
    exit 1
  fi
done

# Bundle Sparkle.framework for auto-updates
SPARKLE_FW=$(find "$ROOT_DIR/.build/artifacts" -path "*/Sparkle.framework" -type d | head -1)
if [[ -n "$SPARKLE_FW" && -d "$SPARKLE_FW" ]]; then
  echo "Bundling Sparkle.framework..."
  cp -R "$SPARKLE_FW" "$FRAMEWORKS_DIR/"
else
  echo "Warning: Sparkle.framework not found, auto-update will not work" >&2
fi

echo "Ad-hoc signing app bundle..."
codesign --force --deep --sign - "$APP_ROOT"

echo "Built app bundle: $APP_ROOT"
