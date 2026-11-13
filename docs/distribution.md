# Build, sign, and distribute

Build with Xcode 27.2. The native Xcode project is tracked in XCProject format. The ordinary build needs no package downloads.

```sh
scripts/package.sh
```

The script builds for `arm64` and `x86_64`, copies the app to the distribution directory, verifies the signature, creates a ZIP, and prints its SHA-256 digest. It uses ad hoc signing by default. For local development with an Apple Development identity, set `CUELENS_CODE_SIGN_IDENTITY` and `CUELENS_DEVELOPMENT_TEAM` in your shell. Never commit credentials or signing files.

## Public distribution

Use a Developer ID Application certificate from your Apple Developer team. Build with hardened runtime, submit the signed archive using an existing `notarytool` Keychain profile, wait for acceptance, and staple the ticket to the app.

```sh
CUELENS_CODE_SIGN_IDENTITY='Developer ID Application: Your Team (TEAMID)' \
  CUELENS_DEVELOPMENT_TEAM='TEAMID' scripts/package.sh

xcrun notarytool submit build/distribution/0.2.0/CueLens-Pro-0.2.0-macOS.zip \
  --keychain-profile cuelens-notary --wait
xcrun stapler staple 'build/distribution/0.2.0/CueLens Pro.app'
xcrun stapler validate 'build/distribution/0.2.0/CueLens Pro.app'
spctl --assess --type execute --verbose 'build/distribution/0.2.0/CueLens Pro.app'
```

After stapling, make a fresh ZIP from the stapled app without rebuilding it. Verify the archive on a clean Mac before publishing. The local development package has an Apple Development signature. Public notarization is pending a Developer ID identity and notary credentials. [Apple notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## Optional camera build

```sh
scripts/build-camera.sh check
CUELENS_DEVELOPMENT_TEAM='YOURTEAMID' \
  CUELENS_BUNDLE_ID='com.example.cuelens' scripts/build-camera.sh signed
```

The check compiles and embeds the extension. The signed build requires a developer account in **Xcode → Settings → Accounts**. Use a bundle ID your team owns. Both targets use the same team and a shared App Group. The host needs the System Extension capability. A public distribution requires correct profiles for both targets, Developer ID signatures, and notarization.

Copy the signed app to **/Applications** before requesting activation. In **Camera → Enable Camera Extension**, request activation, then approve it as an administrator under **System Settings → General → Login Items & Extensions → Camera Extensions**. The app reports activation failures and reboot requests. Reopen your meeting app after approval. [Apple camera extension guide](https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o), [Apple system extension activation](https://developer.apple.com/documentation/systemextensions/installing-system-extensions-and-drivers)
