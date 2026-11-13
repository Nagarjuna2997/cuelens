# Dependencies and licenses

CueLens source and its existing icon source are covered by the repository's [MIT license](../LICENSE). Version 0.3.0 keeps that icon. The runtime uses Apple system frameworks and direct HTTPS provider APIs; it has no third-party Swift package dependency and bundles no model weights. Apple frameworks and hosted AI services have their own terms and are not relicensed by this repository.

## System frameworks

| Dependency | Use | Reference |
| --- | --- | --- |
| SwiftUI, AppKit, Foundation, Observation | Native UI, panels, state, files, networking | [SwiftUI](https://developer.apple.com/documentation/swiftui), [AppKit](https://developer.apple.com/documentation/appkit) |
| AVFoundation, Core Audio, Core Media, Core Video | Camera, microphone, PCM processing, audio files, and meeting-audio taps | [AVFoundation](https://developer.apple.com/documentation/avfoundation), [Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps) |
| Vision | Local face/body observations and person masks | [Vision](https://developer.apple.com/documentation/vision) |
| Core Image, ImageIO, Core Graphics | Local crop, compositing, image effects, and image encoding | [Core Image](https://developer.apple.com/documentation/coreimage) |
| Speech | Apple on-device speech recognition when the selected locale is supported | [Speech](https://developer.apple.com/documentation/speech) |
| ScreenCaptureKit | Requested display/window still images | [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) |
| Core Media I/O, System Extensions | Optional virtual-camera extension and activation | [Camera extensions](https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o) |
| Security | Non-synchronizing Keychain storage for provider credentials | [Keychain services](https://developer.apple.com/documentation/security/keychain-services) |
| PDFKit, Compression, Uniform Type Identifiers | Local document extraction and supported import types | [PDFKit](https://developer.apple.com/documentation/pdfkit), [Compression](https://developer.apple.com/documentation/compression) |
| Carbon | Session-scoped global keyboard shortcuts | [Carbon](https://developer.apple.com/documentation/carbon) |

Apple supplies system framework implementations and any system-managed Vision/Speech resources. CueLens does not download or redistribute an open-source speech, language, or gaze model. System-provided recognition availability can vary by OS, hardware, and locale. The native interface uses system typography and SF Symbols under Apple's applicable terms.

## Hosted providers

| Service | CueLens usage | Reference |
| --- | --- | --- |
| OpenAI API | Streaming answers/images; optional Realtime transcription | [Streaming responses](https://developers.openai.com/api/docs/guides/streaming-responses), [Realtime transcription](https://developers.openai.com/api/docs/guides/realtime-transcription) |
| Anthropic API | Streaming Claude answers/images | [Streaming](https://platform.claude.com/docs/en/build-with-claude/streaming) |
| Gemini API | Streaming Gemini answers/images | [Content generation](https://ai.google.dev/api/generate-content) |

The model IDs shown in **Providers** come from the source configuration and can be edited. Availability, billing, and limits depend on the provider account; a ChatGPT, Claude, or Gemini consumer subscription does not supply an API credential to CueLens. No browser cookies or other applications' sessions are extracted. Manual **Answer** sends context to the selected API, and automatic answering and cloud transcription have separate session controls. See [the setup guide](guide.md).

## Build tools and future model integrations

Development uses Xcode and Apple's command-line tools. Packaging scripts use zsh, `ditto`, `codesign`, and `lipo`; the optional extension-project generator uses Python 3. Public distribution additionally uses an authorized Developer ID identity and `notarytool`/`stapler`. These tools are not shipped inside the app.

Eye-contact correction remains unavailable. Any future gaze model must have a documented distribution/commercial license, artifact provenance, supported hardware, measured video quality, performance limits, and a safe bypass before inclusion. Historical gaze-warp source files are ordinary repository code, not a licensed or verified model dependency.
