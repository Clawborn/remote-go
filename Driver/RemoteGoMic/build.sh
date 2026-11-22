#!/bin/zsh
set -euo pipefail

source_dir=${0:A:h}
output_dir=${1:-"$source_dir/build"}
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$source_dir/Info.plist")
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}
sdk=$(xcrun --sdk macosx --show-sdk-path)
clang=$(xcrun --sdk macosx --find clang)

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
driver="$staging/root/Library/Audio/Plug-Ins/HAL/RemoteGoMic.driver"
contents="$driver/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources" "$output_dir"

"$clang" -Os -bundle -arch arm64 -mmacosx-version-min=15.0 -isysroot "$sdk" \
    -include "$source_dir/RemoteGoMicConfig.h" "$source_dir/Driver.c" \
    -framework CoreAudio -framework CoreFoundation -framework Accelerate \
    -o "$contents/MacOS/RemoteGoMic"
/bin/cp -X "$source_dir/Info.plist" "$contents/"
/bin/cp -X "$source_dir/RemoteGoMic.icns" "$source_dir/LICENSE.txt" "$contents/Resources/"
/usr/bin/codesign --force --sign - --timestamp=none "$driver"
/usr/bin/codesign --verify --strict "$driver"
/usr/bin/ditto "$driver" "$output_dir/RemoteGoMic.driver"

/usr/bin/pkgbuild --root "$staging/root" --install-location / --ownership recommended \
    --identifier me.tianrun.remotego.mic.pkg --version "$version" \
    "$output_dir/Remote-Go-Mic-$version.pkg"
