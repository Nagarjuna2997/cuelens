# CueLens

CueLens is a native macOS app for meeting notes, interview practice, and live answers. It pairs selected assistant materials with a transcript and streams answers from your choice of OpenAI, Claude, or Gemini.

## Build and run

Open `cuelens.xcodeproj` in Xcode 27.2 and run the `cuelens` scheme, or build for local testing:

```sh
xcodebuild -project cuelens.xcodeproj -scheme cuelens -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY=- build
open build/DerivedData/Build/Products/Debug/cuelens.app
```

CueLens targets macOS 14.2 and later. This development milestone builds and runs on Apple Silicon. A device matrix and distribution instructions will be added with release validation.

## Start a session

1. Create an assistant and add your role, experience, and optional PDF, DOCX, TXT, or Markdown material. Review the extracted text before saving.
2. In **Providers**, select Apple on-device speech or OpenAI Realtime. Choose one of the three answer providers, enter your API key, test the connection, and save.
3. In **Live Session**, select the assistant and audio sources, run **Test Audio Sources**, then review retention and cloud processing. Start only after obtaining any required consent.
4. Ask a question, press **⌘↩** to answer the latest meeting question, or select a single window or an image with **Capture**. Review a capture before sending it. Use capture assistance only when the meeting or assessment permits it.
5. Drag the floating panel by its grip. The default **⌘⌥H** shows or hides it. **⌘⌥X** stops audio, cancels the current request, and hides the panel.

Apple on-device speech keeps audio on the Mac for supported locales. OpenAI Realtime sends enabled audio sources to OpenAI after session approval. Cloud answer requests can include selected document excerpts, recent transcript, and a reviewed image. API keys are stored in Keychain. The app saves transcript and raw audio locally according to session options.

The floating panel can appear in screen sharing. Use the **Screen Sharing** page to verify the viewer’s feed and record the result for the capture mode you tested.

[MIT license](LICENSE)
