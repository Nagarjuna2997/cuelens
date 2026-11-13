# Build, sign, and distribute

CueLens 0.3.0 retains the existing icon, Xcode project, and `org.cuelens.mac` application identifier. The project is tracked in Xcode's XCProject format (`cuelens.xcodeproj/project.xcproj`) and was built with Xcode 27.2. The deployment target is macOS 14.2. There are no third-party package downloads.

```sh
scripts/package.sh
```

The script builds the `cuelens` scheme for arm64 and x86_64, verifies the signature, and creates `build/distribution/0.3.0/CueLens.app` and `CueLens-0.3.0-macOS.zip` with a SHA-256 digest. It uses ad hoc signing by default. This is a local development package, not a notarized public release. Retaining the bundle identifier preserves the expected sandbox location; changing it creates a separate app container and may require new permissions.

To use an available development identity:

```sh
CUELENS_CODE_SIGN_IDENTITY='Apple Development' \
  CUELENS_DEVELOPMENT_TEAM='YOURTEAMID' scripts/package.sh
```

Keep keys, certificates, provisioning profiles, and signing credentials out of Git. App provider keys are entered in **Providers** and saved in Keychain.

## Public distribution

Use a Developer ID Application identity and the correct team. The project enables hardened runtime. Submit the signed archive through an existing `notarytool` Keychain profile, then staple and verify the accepted app. [Apple notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

```sh
CUELENS_CODE_SIGN_IDENTITY='Developer ID Application: Your Team (TEAMID)' \
  CUELENS_DEVELOPMENT_TEAM='TEAMID' scripts/package.sh

xcrun notarytool submit build/distribution/0.3.0/CueLens-0.3.0-macOS.zip \
  --keychain-profile cuelens-notary --wait
xcrun stapler staple build/distribution/0.3.0/CueLens.app
xcrun stapler validate build/distribution/0.3.0/CueLens.app
spctl --assess --type execute --verbose build/distribution/0.3.0/CueLens.app
ditto -c -k --norsrc --noextattr --keepParent \
  build/distribution/0.3.0/CueLens.app \
  build/distribution/0.3.0/CueLens-0.3.0-macOS.zip
```

Test that final archive on a clean Mac before publishing. Public signing and notarization are not established by a successful local build; see [validation](validation.md) for the current evidence.

## Optional camera extension

The ordinary app works without a camera extension. The separate script generates a sibling project under `build/CameraProject` and embeds the Core Media I/O extension:

```sh
scripts/build-camera.sh check
CUELENS_DEVELOPMENT_TEAM='YOURTEAMID' scripts/build-camera.sh signed
```

`check` compiles without signing and cannot activate the extension. `signed` requires an authorized Apple Developer account, suitable provisioning, the System Extension capability, and the shared App Group for both targets. The default host identifier is `org.cuelens.mac`; `CUELENS_BUNDLE_ID` is an explicit override for a team-owned identifier. The output is `build/CameraDerivedData/Build/Products/Release/cuelens.app`.

Copy the signed app to **/Applications** before choosing **Camera → Enable Camera Extension…**. Approve the request as an administrator in the macOS extension settings when prompted. Reopen the meeting app, start the camera in CueLens, enable virtual-camera output, and select **CueLens Camera** in the meeting app. Compilation alone does not establish that activation or receiver-side video works. [Apple camera extension guide](https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o)

The extension advertises 1280 × 720 at 30 fps and carries processed video only. It does not replace the meeting microphone. A public extension build also needs valid signing, profiles, and notarization.
