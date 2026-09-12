#!/bin/zsh
set -euo pipefail
script_dir=${0:A:h}
project_dir=${script_dir:h}
cd "$project_dir"

swift build -c release

bundle="$project_dir/.build/MImoMeter.app"
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"

cp Resources/Info.plist "$bundle/Contents/Info.plist"
cp ".build/release/MImoMeter" "$bundle/Contents/MacOS/MImoMeter"

# Icon: generate icns from SVG-rendered PNGs if present, else create a simple one.
icon_src="$project_dir/Resources/AppIcon.png"
icns_path="$bundle/Contents/Resources/AppIcon.icns"
if [[ -f "$icon_src" ]]; then
  iconset="$project_dir/.build/AppIcon.iconset"
  rm -rf "$iconset"
  mkdir -p "$iconset"
  for size in 16 32 64 128 256 512; do
    sips -z "$size" "$size" "$icon_src" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size*2)) $((size*2)) "$icon_src" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o "$icns_path"
  rm -rf "$iconset"
fi

# Ad-hoc sign so SMAppService / Gatekeeper accept the bundle.
codesign --force --deep --sign - "$bundle"

# Install to ~/Applications for a stable path required by login items.
install_dir="$HOME/Applications"
mkdir -p "$install_dir"
install_path="$install_dir/MImoMeter.app"
rm -rf "$install_path"
cp -R "$bundle" "$install_path"
codesign --force --deep --sign - "$install_path"

echo "BUILT: $bundle"
echo "INSTALLED: $install_path"
open -R "$install_path"
