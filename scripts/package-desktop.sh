#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
platform=${1:?Expected linux-x64 or macos-arm64}
binary=${2:?Expected the Cargo release executable}
name=hermes-desktop-lite-$platform
stage=$(mktemp -d)
trap 'rm -r -- "$stage"' EXIT
mkdir -p dist

copy_notices() {
    cp LICENSE THIRD_PARTY_NOTICES.md "$1/"
    for asset in tabler codicon phosphor fonts; do
        mkdir -p "$1/assets/$asset"
    done
    cp assets/tabler/LICENSE "$1/assets/tabler/"
    cp assets/codicon/{LICENSE,NOTICE} "$1/assets/codicon/"
    cp assets/phosphor/LICENSE "$1/assets/phosphor/"
    cp assets/fonts/OFL-BodoniModa.txt "$1/assets/fonts/"
}

case "$platform" in
    linux-x64)
        file "$binary" | grep -q 'ELF 64-bit.*x86-64'
        if ldd "$binary" | grep -q 'not found'; then
            ldd "$binary"
            exit 1
        fi
        mkdir "$stage/$name"
        install -m 755 "$binary" "$stage/$name/hermes-desktop-lite"
        copy_notices "$stage/$name"
        archive=$name.tar.gz
        tar -czf "dist/$archive" -C "$stage" "$name"
        ;;
    macos-arm64)
        test "$(lipo -archs "$binary")" = arm64
        app="Hermes Desktop Lite.app"
        contents="$stage/$app/Contents"
        mkdir -p "$contents/MacOS" "$contents/Resources"
        install -m 755 "$binary" "$contents/MacOS/hermes-desktop-lite"
        version=$(sed -nE 's/^version = "([^"]+)"$/\1/p' Cargo.toml)
        cat > "$contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>hermes-desktop-lite</string>
  <key>CFBundleIdentifier</key><string>io.github.hejuntt1014.hermes-desktop-lite</string>
  <key>CFBundleName</key><string>Hermes Desktop Lite</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
        copy_notices "$contents/Resources"
        plutil -lint "$contents/Info.plist"
        codesign --force --sign - "$stage/$app"
        codesign --verify --strict "$stage/$app"
        archive=$name.zip
        ditto -c -k --keepParent "$stage/$app" "dist/$archive"
        ;;
    *)
        echo "Unsupported package platform: $platform" >&2
        exit 2
        ;;
esac

(cd dist && shasum -a 256 "$archive" > "$archive.sha256")
