#!/bin/bash
# Builds, signs, notarizes and installs "Meta Glasses.app" with its camera extension.
#   scripts/build.sh            build + sign + notarize + install to /Applications
#   scripts/build.sh --no-notarize
# Signing settings come from config.env (copy config.example.env).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
up="$root/upstream"
out="$root/build"
[ -f "$root/config.env" ] || { echo "Copy config.example.env to config.env and fill it in." >&2; exit 1; }
set -a; source "$root/config.env"; set +a
: "${TEAM_ID:?}" "${BUNDLE_ID:?}" "${SIGN_IDENTITY:?}"
APP_PROFILE=${APP_PROFILE:-$root/profiles/app.provisionprofile}
CAMERA_PROFILE=${CAMERA_PROFILE:-$root/profiles/camera.provisionprofile}
case $APP_PROFILE in /*) ;; *) APP_PROFILE=$root/$APP_PROFILE ;; esac
case $CAMERA_PROFILE in /*) ;; *) CAMERA_PROFILE=$root/$CAMERA_PROFILE ;; esac
identity=$SIGN_IDENTITY
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
version=0.1.0
build=$(date +%Y%m%d%H%M)
notarize=1
[ "${1:-}" = "--no-notarize" ] && notarize=0

# CMake: the one on PATH, else a private copy in tools/.
if ! command -v cmake > /dev/null; then
    cmake_dir="$root/tools/cmake-3.31.3-macos-universal"
    if [ ! -d "$cmake_dir" ]; then
        mkdir -p "$root/tools"
        curl -fsSL https://github.com/Kitware/CMake/releases/download/v3.31.3/cmake-3.31.3-macos-universal.tar.gz |
            tar -xz -C "$root/tools"
    fi
    export PATH="$cmake_dir/CMake.app/Contents/bin:$PATH"
fi

# Upstream: the glasses link, the Bluetooth/Wi-Fi helper and the setup window, at the commit
# named in upstream-commit.txt.
if [ ! -d "$up/.git" ]; then
    git clone https://github.com/RandyNorthrup/meta-g-link-direct "$up"
    git -C "$up" checkout -q "$(cut -d' ' -f2 "$root/upstream-commit.txt")"
fi
if ! grep -q "Meta Glasses.app" "$up/src/macos/identity_keychain.mm"; then
    git -C "$up" apply "$root/patches/keychain-trust-meta-glasses.patch"
fi
if ! grep -q "This Mac now owns the glasses" "$up/src/setup/main_macos.mm"; then
    git -C "$up" apply "$root/patches/setup-edit-menu.patch"
fi
[ -f "$up/.deps/obs-deps-2026-07-15-universal/include/libavcodec/avcodec.h" ] || bash "$up/scripts/bootstrap-macos.sh"
cmake -S "$up" -B "$up/out" -DCMAKE_BUILD_TYPE=Release -DMGL_BUILD_LINK=ON -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DBUILD_TESTING=OFF > /dev/null
cmake --build "$up/out" -j8 > /dev/null
deps="$up/.deps/obs-deps-2026-07-15-universal"

rm -rf "$out" && mkdir -p "$out/obj"
app="$out/Meta Glasses.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Frameworks" "$contents/Resources/bin" "$contents/Library/SystemExtensions"

# The app.
flags=(-arch arm64 -mmacosx-version-min=13.3 -O2 -DNDEBUG -I"$up/include" -I"$up/src/plugin" -I"$deps/include")
for source in glasses_link hevc_decoder aac_decoder video_pacer setup_process_posix; do
    clang++ -std=c++20 "${flags[@]}" -c "$up/src/plugin/$source.cpp" -o "$out/obj/$source.o"
done
clang++ -std=c++20 -fobjc-arc "${flags[@]}" -c "$root/app/main.mm" -o "$out/obj/main.o"
clang++ -arch arm64 -mmacosx-version-min=13.3 "$out"/obj/*.o \
    "$up/out/libmgl_link.a" "$up/out/libmgl_protocol.a" \
    "$up/out/_deps/mbedtls-build/library/libmbedcrypto.a" \
    "$up/out/_deps/mbedtls-build/3rdparty/everest/libeverest.a" \
    "$up/out/_deps/mbedtls-build/3rdparty/p256-m/libp256m.a" \
    -L"$deps/lib" -lavcodec -lavutil -lcurl \
    -framework Cocoa -framework CoreMedia -framework CoreMediaIO -framework CoreVideo -framework Accelerate \
    -framework SystemExtensions -framework CoreWLAN -framework Security -framework IOSurface -framework CoreImage -framework ServiceManagement \
    -Wl,-rpath,@executable_path/../Frameworks -o "$contents/MacOS/Meta Glasses"
# Fills in the version, team and bundle ID placeholders.
fill() { sed -e "s/@VERSION@/$version/" -e "s/@BUILD@/$2/" -e "s/@TEAM_ID@/$TEAM_ID/g" -e "s/@BUNDLE_ID@/$BUNDLE_ID/g" "$1"; }
fill "$root/app/Info.plist" "$build" > "$contents/Info.plist"
fill "$root/app/app.entitlements" "$build" > "$out/app.entitlements"
cp "$APP_PROFILE" "$contents/embedded.provisionprofile"

# FFmpeg from OBS's prebuilt dependencies, arm64 only.
for lib in avcodec avutil swresample x264; do
    lipo -thin arm64 "$deps/lib/lib$lib.dylib" -output "$contents/Frameworks/lib$lib.dylib" 2>/dev/null ||
        cp -L "$deps/lib/lib$lib.dylib" "$contents/Frameworks/lib$lib.dylib"
done

# The camera extension.
sysext="$contents/Library/SystemExtensions/$BUNDLE_ID.camera.systemextension"
mkdir -p "$sysext/Contents/MacOS"
swiftc -O -target arm64-apple-macos13.3 "$root/camera/main.swift" \
    -o "$sysext/Contents/MacOS/$BUNDLE_ID.camera"
# The extension keeps its own build number (camera/VERSION). Bump it only when camera/ changes:
# every new number makes macOS replace the running extension, and a camera app only sees the new
# one after it restarts.
camera_build=$(cat "$root/camera/VERSION")
fill "$root/camera/Info.plist" "$camera_build" > "$sysext/Contents/Info.plist"
fill "$root/camera/camera.entitlements" "$camera_build" > "$out/camera.entitlements"
cp "$CAMERA_PROFILE" "$sysext/Contents/embedded.provisionprofile"

# Upstream's helper and setup window, installed by the app into Application Support on launch.
for pair in "helper:Meta G Link Helper" "setup:Meta G Link Setup"; do
    tool=${pair#*:}
    ditto "$up/out/meta-g-link-${pair%%:*}.app" "$contents/Resources/bin/$tool.app"
    /usr/libexec/PlistBuddy -c "Add :MGLBuild string $build" "$contents/Resources/bin/$tool.app/Contents/Info.plist"
done
cp "$up/LICENSE" "$contents/Resources/LICENSE"

# Sign inside out.
sign() { codesign --force --timestamp --options runtime --sign "$identity" "$@"; }
for dylib in "$contents"/Frameworks/*.dylib; do sign "$dylib"; done
sign --entitlements "$root/app/helper.entitlements" "$contents/Resources/bin/Meta G Link Helper.app"
sign "$contents/Resources/bin/Meta G Link Setup.app"
sign --entitlements "$out/camera.entitlements" "$sysext"
sign --entitlements "$out/app.entitlements" "$app"
codesign --verify --deep --strict "$app"

if [ "$notarize" = 1 ]; then
    ditto -c -k --keepParent "$app" "$out/MetaGlasses.zip"
    xcrun notarytool submit "$out/MetaGlasses.zip" --key "${ASC_KEY_PATH/#\~/$HOME}" \
        --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER" --wait
    xcrun stapler staple "$app"
    spctl --assess --type execute --verbose "$app"
fi

osascript -e 'quit app "Meta Glasses"' 2>/dev/null || true
pkill -x "Meta Glasses" 2>/dev/null || true
rm -rf "/Applications/Meta Glasses.app"
ditto "$app" "/Applications/Meta Glasses.app"
echo "installed /Applications/Meta Glasses.app ($version build $build)"
