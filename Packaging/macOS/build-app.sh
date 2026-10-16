#!/bin/bash
# Builds a self-contained vkQuake.app from a meson build linked against the Vulkan loader.
#
# usage: build-app.sh <meson build dir> <output dir>
#   env VERSION        version string shown in Finder (default: from Quake/quakever.h)
#   env BUNDLE_ID      bundle identifier (default: io.github.vkquake)
#   env SIGN_IDENTITY  code signing identity, e.g. "Developer ID Application: Name (TEAMID)" to sign with the hardened
#                      runtime and a secure timestamp, as notarization requires (default: - for an ad-hoc signature)
#
# The app bundles every non-system library it needs from Homebrew, the Vulkan loader, KosmicKrisp and MoltenVK.
# KosmicKrisp is registered with the bundled loader and used by default; MoltenVK is opt-in with:
#   VK_DRIVER_FILES=<path to>/vkQuake.app/Contents/Resources/vulkan/moltenvk/MoltenVK_icd.json
# Requires the Homebrew packages vulkan-loader, mesa (macOS 26 or newer, for KosmicKrisp) and molten-vk.
set -euo pipefail

BUILD_DIR=$(cd "$1" && pwd)
OUT_DIR=$(mkdir -p "$2" && cd "$2" && pwd)
SRC_DIR=$(cd "$(dirname "$0")/../.." && pwd)
BREW=$(brew --prefix)

if [ -z "${VERSION:-}" ]; then
	VERSION=$(sed -n -E 's/^#define[[:space:]]+VKQUAKE_VERSION[[:space:]]+([0-9.]+).*/\1/p' "$SRC_DIR/Quake/quakever.h")
	VERSION=$VERSION.$(sed -n -E 's/^#define[[:space:]]+VKQUAKE_VER_PATCH[[:space:]]+([0-9]+).*/\1/p' "$SRC_DIR/Quake/quakever.h")
fi
BUNDLE_ID=${BUNDLE_ID:-io.github.vkquake}
SIGN_IDENTITY=${SIGN_IDENTITY:--}

APP=$OUT_DIR/vkQuake.app
CONTENTS=$APP/Contents
FRAMEWORKS=$CONTENTS/Frameworks
VULKAN=$CONTENTS/Resources/vulkan
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$FRAMEWORKS" "$VULKAN/icd.d" "$VULKAN/moltenvk"

if ! otool -L "$BUILD_DIR/vkquake" | grep -q libvulkan; then
	echo "error: $BUILD_DIR/vkquake doesn't link the Vulkan loader, configure it with -Duse_vulkan_loader=enabled" >&2
	exit 1
fi

# Copies a library into Frameworks (once) and points its id at the bundled copy
copy_lib () {
	local src=$1 name
	name=$(basename "$src")
	if [ ! -e "$FRAMEWORKS/$name" ]; then
		cp -L "$src" "$FRAMEWORKS/$name"
		chmod u+w "$FRAMEWORKS/$name"
		install_name_tool -id "@executable_path/../Frameworks/$name" "$FRAMEWORKS/$name" 2> /dev/null
		bundle_deps "$FRAMEWORKS/$name"
	fi
}

# Bundles the non-system libraries a Mach-O file links and rewrites its references to the bundled copies
bundle_deps () {
	local file=$1 own_id dep
	own_id=$(otool -D "$file" | sed -n 2p)
	for dep in $(otool -L "$file" | tail -n +2 | awk '{print $1}'); do
		case "$dep" in
		/usr/lib/* | /System/* | @executable_path/* | "$own_id") continue ;;
		@*)
			echo "error: $file links $dep, which can't be resolved" >&2
			exit 1
			;;
		esac
		copy_lib "$dep"
		install_name_tool -change "$dep" "@executable_path/../Frameworks/$(basename "$dep")" "$file" 2> /dev/null
	done
}

cp "$BUILD_DIR/vkquake" "$CONTENTS/MacOS/vkquake"
bundle_deps "$CONTENTS/MacOS/vkquake"

# Vulkan drivers, loaded by the bundled loader through manifests in Contents/Resources/vulkan
copy_lib "$BREW/opt/mesa/lib/libvulkan_kosmickrisp.dylib"
copy_lib "$BREW/opt/molten-vk/lib/libMoltenVK.dylib"
cat > "$VULKAN/icd.d/kosmickrisp_icd.json" << EOF
{
    "file_format_version": "1.0.1",
    "ICD": {
        "library_path": "../../../Frameworks/libvulkan_kosmickrisp.dylib",
        "api_version": "$(sed -n -E 's/.*"api_version": *"([0-9.]+)".*/\1/p' "$BREW"/share/vulkan/icd.d/kosmickrisp_mesa_icd.*.json | head -1)"
    }
}
EOF
cat > "$VULKAN/moltenvk/MoltenVK_icd.json" << EOF
{
    "file_format_version": "1.0.0",
    "ICD": {
        "library_path": "../../../Frameworks/libMoltenVK.dylib",
        "api_version": "$(sed -n -E 's/.*"api_version" *: *"([0-9.]+)".*/\1/p' "$BREW/etc/vulkan/icd.d/MoltenVK_icd.json")",
        "is_portability_driver": true
    }
}
EOF

# The app can't run on an older macOS than the newest minimum of its binaries (Homebrew builds for the host macOS)
MIN_MACOS=$(for f in "$CONTENTS/MacOS/vkquake" "$FRAMEWORKS"/*.dylib; do otool -l "$f" | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "minos" { print $2; exit }'; done | sort -t. -k1,1n -k2,2n | tail -1)

ICONSET=$(mktemp -d)/vkQuake.iconset
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
	sips -z $size $size "$SRC_DIR/Misc/vkQuake_512.png" --out "$ICONSET/icon_${size}x${size}.png" > /dev/null
	if [ $size -lt 512 ]; then
		sips -z $((size * 2)) $((size * 2)) "$SRC_DIR/Misc/vkQuake_512.png" --out "$ICONSET/icon_${size}x${size}@2x.png" > /dev/null
	fi
done
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/vkQuake.icns"
rm -rf "$(dirname "$ICONSET")"

cat > "$CONTENTS/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>vkQuake</string>
	<key>CFBundleExecutable</key>
	<string>vkquake</string>
	<key>CFBundleIconFile</key>
	<string>vkQuake</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>vkQuake</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.action-games</string>
	<key>LSMinimumSystemVersion</key>
	<string>$MIN_MACOS</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
EOF

# install_name_tool invalidates signatures, so sign everything again, libraries first
sign () {
	if [ "$SIGN_IDENTITY" = - ]; then
		codesign --force --sign - "$1"
	else
		codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$1"
	fi
}
for f in "$FRAMEWORKS"/*.dylib; do
	sign "$f"
done
sign "$APP"

echo "Built $APP ($VERSION, macOS $MIN_MACOS or newer, signed by: $SIGN_IDENTITY)"
