#!/bin/sh
set -eu
: "${APELIN_PACKAGE_DIR:?run through apelin_project_build}"
: "${APELIN_PROJECT_ROOT:?}" "${APELIN_BOOTSTRAP:?}" "${APELIN_ARCHITECTURE:?}"
: "${APELIN_BUILD_ID:?}" "${TMPDIR:?}" "${SDKROOT:?}"
: "${APELIN_PREFIX?}"
# The same script also runs on the GitHub macOS runner at the user's request.
sra_clang() {
  if [ "$(uname -s)" = Darwin ]; then
    xcrun --sdk iphoneos clang "$@"
  else
    clang "$@"
  fi
}
stage="$(mktemp -d "${TMPDIR:?}sra-stage.XXXXXX")"
trap 'rm -rf -- "${stage:?}"' EXIT
case "$APELIN_BOOTSTRAP" in
  roothide) arches="arm64 arm64e"; bootstrap_define="APELIN_BOOTSTRAP_ROOTHIDE" ;;
  rootless) arches="arm64 arm64e"; bootstrap_define="APELIN_BOOTSTRAP_ROOTLESS" ;;
  *) echo 'Unsupported bootstrap' >&2; exit 1 ;;
esac
case "${APELIN_CONFIGURATION:-debug}" in
  release) optimization="-Os" ;;
  *) optimization="-O0" ;;
esac
mkdir -p "$stage/slices" "$stage/DEBIAN" "$stage$APELIN_PREFIX/Library/MobileSubstrate/DynamicLibraries" "$stage$APELIN_PREFIX/Library/PreferenceBundles/SRAPreferences.bundle" "$stage$APELIN_PREFIX/Library/PreferenceLoader/Preferences"
for arch in $arches; do
  sra_clang -arch "$arch" -miphoneos-version-min=16.0 -fobjc-arc -fmodules -fblocks -fvisibility=hidden -Wall -Wextra -Wno-unused-parameter -Werror=unguarded-availability-new "$optimization" -g -dynamiclib -I Sources "-D${bootstrap_define}=1" "-DAPELIN_BUILD_ID=\"${APELIN_BUILD_ID}\"" Sources/SRATweak.m Sources/SRACellular.m -L "Vendor/$APELIN_BOOTSTRAP" -lsubstrate -framework Foundation -framework UIKit -framework Intents -framework CoreFoundation -install_name @rpath/SRAAutoRenew.dylib -o "$stage/slices/tweak-$arch.dylib"
  sra_clang -arch "$arch" -miphoneos-version-min=16.0 -fobjc-arc -fmodules -fblocks -fvisibility=hidden -Wall -Wextra -Wno-unused-parameter -Werror=unguarded-availability-new "$optimization" -g -bundle -I Sources -I Vendor -F Vendor Preferences/SRARootListController.m -framework Foundation -framework UIKit -framework CoreFoundation -framework Preferences -o "$stage/slices/preferences-$arch"
done
tweak="$stage$APELIN_PREFIX/Library/MobileSubstrate/DynamicLibraries/SRAAutoRenew.dylib"
prefs="$stage$APELIN_PREFIX/Library/PreferenceBundles/SRAPreferences.bundle"
# Package architecture identifies the bootstrap, not the CPU slices of the hosts.
# A11 devices require arm64 even when the roothide package is iphoneos-arm64e.
lipo -create "$stage/slices/tweak-arm64.dylib" "$stage/slices/tweak-arm64e.dylib" -output "$tweak"
lipo -create "$stage/slices/preferences-arm64" "$stage/slices/preferences-arm64e" -output "$prefs/SRAPreferences"
lipo "$tweak" -verify_arch arm64 arm64e
lipo "$prefs/SRAPreferences" -verify_arch arm64 arm64e
ldid -S "$tweak"
ldid -S "$prefs/SRAPreferences"
cp Preferences/Info.plist "${prefs:?}/Info.plist"
cp Preferences/Root.plist "${prefs:?}/Root.plist"
for icon in icon.png icon@2x.png icon@3x.png; do
  cp "Preferences/$icon" "${prefs:?}/$icon"
done
cp Preferences/Entry.plist "${stage:?}$APELIN_PREFIX/Library/PreferenceLoader/Preferences/SRAAutoRenew.plist"
cat > "$stage$APELIN_PREFIX/Library/MobileSubstrate/DynamicLibraries/SRAAutoRenew.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>Filter</key><dict><key>Executables</key><array><string>SpringBoard</string><string>SideStore</string></array></dict></dict></plist>
PLIST
cat > "$stage/DEBIAN/control" <<CONTROL
Package: com.xx.autosidestore
Name: SideStore Auto Renew
Version: 0.2.3
Architecture: $APELIN_ARCHITECTURE
Description: Schedule SideStore refresh with selectable weekdays and local time.
Maintainer: xx
Author: xx
Section: Tweaks
Depends: firmware (>= 16.0), mobilesubstrate, preferenceloader
CONTROL
# Slices are build intermediates, not installed package content.
rm -rf -- "${stage:?}/slices"
find "$stage" -type d -exec chmod 0755 {} \;
find "$stage" -type f -exec chmod 0644 {} \;
chmod 0755 "$tweak" "$prefs/SRAPreferences"
dpkg-deb -b --root-owner-group "$stage" "$APELIN_PACKAGE_DIR/"
