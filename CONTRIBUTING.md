# Contributing

Open the Xcode project, use the `cuelens` scheme, and keep features usable without an account with this project. Use official provider and macOS APIs. Keep changes small enough to build, verify, and review independently.

```sh
xcodebuild -project cuelens.xcodeproj -scheme cuelens -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData -only-testing:cuelensTests CODE_SIGN_IDENTITY=- test
```

For capture, provider, and privacy changes, record the device, app version, relevant settings, test evidence, and any unverified behavior. Use synthetic meeting content and test credentials for fixtures. Never include API keys, personal documents, recordings, transcripts, provisioning profiles, or account details in commits or issue reports.

When changing the app icon, regenerate all sizes with `swift scripts/generate-icon.swift`. For the camera extension, run `scripts/build-camera.sh check` as well.
