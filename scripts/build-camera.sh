#!/bin/zsh
set -euo pipefail

cd "${0:A:h:h}"
mode=${1:-check}
case "$mode" in
  check)
    team=""
    host="org.cuelens.mac"
    signing=(CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO)
    ;;
  signed)
    team=${CUELENS_DEVELOPMENT_TEAM:?Set CUELENS_DEVELOPMENT_TEAM to your Apple team ID}
    host=${CUELENS_BUNDLE_ID:-org.cuelens.mac}
    if [[ ! "$team" =~ '^[A-Z0-9]{10}$' || ! "$host" =~ '^[A-Za-z0-9]+([.-][A-Za-z0-9]+)+$' ]]; then
      print -u2 "Check the Apple team ID and bundle identifier."
      exit 1
    fi
    signing=(DEVELOPMENT_TEAM="$team" -allowProvisioningUpdates)
    if [[ -n "${CUELENS_CODE_SIGN_IDENTITY:-}" ]]; then
      signing+=(CODE_SIGN_IDENTITY="$CUELENS_CODE_SIGN_IDENTITY")
    fi
    ;;
  *)
    print -u2 "Usage: scripts/build-camera.sh check|signed"
    exit 2
    ;;
esac

# Build a generated sibling project so the ordinary app stays installable
# without a provisioning profile or camera extension.
mkdir -p build
generated="$PWD/build/CameraProject"
mkdir -p "$generated"
for source in cuelens cuelensTests cuelensUITests Config CameraExtension; do
  ln -sfn "$PWD/$source" "$generated/$source"
done
export CUELENS_HOST_ID_FOR_BUILD="$host"
python3 scripts/camera-project.py "$generated/cuelens.xcodeproj"
xcodebuild -project "$generated/cuelens.xcodeproj" -scheme cuelens -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$PWD/build/CameraDerivedData" \
  "${signing[@]}" build

app="$PWD/build/CameraDerivedData/Build/Products/Release/cuelens.app"
extension="$app/Contents/Library/SystemExtensions/$host.camera.systemextension"
[[ -x "$extension/Contents/MacOS/$host.camera" ]]
if [[ "$mode" == signed ]]; then
  codesign --verify --deep --strict "$app"
  print "Signed camera build: $app"
  print "Copy it to /Applications, then open CueLens → Camera → Enable Camera Extension."
else
  print "Camera extension compiled and embedded: $extension"
  print "Use a signed build to activate it in macOS."
fi
