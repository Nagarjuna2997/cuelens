#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

typeset -a signing
signing=(CODE_SIGN_IDENTITY=-)
if [[ -n "${CUELENS_CODE_SIGN_IDENTITY:-}" ]]; then
  signing=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$CUELENS_CODE_SIGN_IDENTITY")
  if [[ -n "${CUELENS_DEVELOPMENT_TEAM:-}" ]]; then
    signing+=(DEVELOPMENT_TEAM="$CUELENS_DEVELOPMENT_TEAM")
  fi
  if [[ "$CUELENS_CODE_SIGN_IDENTITY" == 'Developer ID Application'* ]]; then
    signing+=(OTHER_CODE_SIGN_FLAGS=--timestamp)
  fi
fi

xcodebuild -quiet -project cuelens.xcodeproj -scheme cuelens -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/ReleaseData "${signing[@]}" build
product="build/ReleaseData/Build/Products/Release/cuelens.app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$product/Contents/Info.plist")
distribution="$PWD/build/distribution/$version"
mkdir -p "$distribution"
app="$distribution/CueLens.app"
ditto --norsrc --noextattr "$product" "$app"
xattr -cr "$app"
codesign --verify --deep --strict "$app"
lipo -archs "$app/Contents/MacOS/cuelens"
archive="$distribution/CueLens-$version-macOS.zip"
ditto -c -k --norsrc --noextattr --keepParent "$app" "$archive"
shasum -a 256 "$archive"
print "$app"
print "$archive"
