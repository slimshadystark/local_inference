#!/bin/sh
# Aligns each embedded framework's Info.plist MinimumOSVersion with the iOS version its binary is built for.
#
# Flutter 3.47 writes MinimumOSVersion 13.0 into the Info.plist of every native-asset framework
# (flutter_tools lib/src/isolated/native_assets/ios/native_assets.dart, `targetIOSVersion`), whatever the
# dylib was built for. llamadart's prebuilt iOS dylib is built for iOS 16.4 (LC_BUILD_VERSION minos), and
# App Store Connect rejects the mismatch with ITMS-90208 ("does not support the minimum OS Version
# specified in the Info.plist").
#
# Runs as a build phase after "Thin Binary", which copies the frameworks into the app. A framework whose
# binary needs a newer iOS than its Info.plist says gets the binary's version and is signed again, the way
# Flutter signs it (the build's identity, or ad hoc when there is none). The build fails if a binary needs a
# newer iOS than the app's deployment target, since the app would then crash at launch on older phones.
set -eu

frameworks="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
[ -d "$frameworks" ] || exit 0

# Succeeds when dotted version $1 is greater than $2.
version_gt() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    n = split(a, x, "."); m = split(b, y, "."); k = n > m ? n : m
    for (i = 1; i <= k; i++) { p = x[i] + 0; q = y[i] + 0; if (p > q) exit 0; if (p < q) exit 1 }
    exit 1
  }'
}

for framework in "$frameworks"/*.framework; do
  [ -d "$framework" ] || continue
  plist="$framework/Info.plist"
  [ -f "$plist" ] || continue
  executable=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$plist" 2>/dev/null) || continue
  binary="$framework/$executable"
  [ -f "$binary" ] || continue

  minos=$(xcrun vtool -show-build "$binary" 2>/dev/null | awk '$1 == "minos" { print $2 }' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
  [ -n "$minos" ] || continue

  if version_gt "$minos" "$IPHONEOS_DEPLOYMENT_TARGET"; then
    echo "error: $(basename "$framework") needs iOS $minos, above the app's deployment target $IPHONEOS_DEPLOYMENT_TARGET."
    exit 1
  fi

  declared=$(/usr/libexec/PlistBuddy -c "Print :MinimumOSVersion" "$plist" 2>/dev/null || echo "")
  if [ -n "$declared" ] && ! version_gt "$minos" "$declared"; then
    continue
  fi

  if [ -n "$declared" ]; then
    /usr/libexec/PlistBuddy -c "Set :MinimumOSVersion $minos" "$plist"
  else
    /usr/libexec/PlistBuddy -c "Add :MinimumOSVersion string $minos" "$plist"
  fi
  echo "$(basename "$framework"): MinimumOSVersion ${declared:-missing} -> $minos"

  identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
  [ -n "$identity" ] || identity="-"
  case "${CONFIGURATION:-}" in
    Release*) xcrun codesign --force --sign "$identity" "$framework" ;;
    *) xcrun codesign --force --sign "$identity" --timestamp=none "$framework" ;;
  esac
done
