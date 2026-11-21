#!/bin/zsh
set -euo pipefail

root=${0:A:h}
source_dir="$root/Sources"
app_path=${1:-"$root/dist/Remote Go.app"}
if [[ -z ${DEVELOPER_DIR:-} && -x /Library/Developer/CommandLineTools/usr/bin/swiftc ]]; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
sdk_path=$(xcrun --sdk macosx --show-sdk-path)
compiler=$(xcrun --sdk macosx --find swiftc)
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT
staged_app="$build_dir/Remote Go.app"

mkdir -p "$staged_app/Contents/MacOS"
ditto --norsrc "$source_dir/Resources" "$staged_app/Contents/Resources"
cp "$source_dir/Info.plist" "$staged_app/Contents/Info.plist"
"$compiler" -O -swift-version 5 -sdk "$sdk_path" -target arm64-apple-macosx15.0 \
    "$source_dir/"*.swift -o "$staged_app/Contents/MacOS/RemoteDesk"
codesign --force --sign - "$staged_app"
codesign --verify --strict "$staged_app"

mkdir -p "${app_path:h}"
ditto --norsrc "$staged_app" "$app_path"
codesign --verify --strict "$app_path"
print -r -- "$app_path"
