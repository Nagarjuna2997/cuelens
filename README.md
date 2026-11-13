# CueLens

CueLens is a native macOS app for meeting notes and live assistance. The first milestone includes native setup, local assistant profiles, and provider configuration.

## Build

Open `cuelens.xcodeproj` in Xcode 27.2 and run the `cuelens` scheme, or build for local testing with:

```sh
xcodebuild -project cuelens.xcodeproj -scheme cuelens -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY=- build
open build/DerivedData/Build/Products/Debug/cuelens.app
```

The app targets macOS 14.2 or later. This milestone has a session setup screen. Live capture, answers, history, and camera tools arrive in subsequent milestones.

## Configure

Create an assistant from Overview or Assistants. Set up an on-device speech locale, OpenAI Realtime, or your own OpenAI, Anthropic, or Gemini API key and model in Providers. API credentials use Keychain. Assistant profiles and preferences are stored in the app’s Application Support directory.

[MIT license](LICENSE)
