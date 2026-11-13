# Architecture and privacy

The main app uses SwiftUI for the sidebar, setup, assistants, provider settings, and history. AppKit supplies floating panels and Carbon registers the session shortcuts. The app runs on macOS 14.2 or later because system audio uses Core Audio process taps. ScreenCaptureKit provides the user-selected one-frame window capture.

- `cuelens/App` contains app state, the session and editor views, and window control.
- `cuelens/Domain` contains assistant and session data, storage, document extraction, local retrieval, and export.
- `cuelens/Media` contains audio capture, speech, window images, and the local camera pipeline.
- `cuelens/Providers` contains the Keychain interface, fixed vendor endpoints, text and image streaming adapters, and OpenAI Realtime transcription.
- `cuelens/Session` coordinates user-approved capture and provider requests. Request identity prevents superseded responses from updating the UI. A local document index retrieves excerpts from the selected assistant only.
- `CameraExtension` is the optional Core Media I/O extension. It relays frames from its same-team, signed host. The host starts publishing only on request and uses the original camera image when correction is unavailable.

## Data and permissions

- Profiles, extracted text, preferences, and screen-share observations are stored in `workspace.json`. Saved session data is under `Sessions/`. Optional CAF files are under `Audio/<session-id>/`. The sandboxed build resolves these under `~/Library/Containers/org.cuelens.mac/Data/Library/Application Support/CueLens/`. A signing build with another bundle ID uses that ID’s container.
- The app keeps imported text rather than the source PDF or DOCX. Reused material is copied into the selected assistant. To remove all copies, remove it from each profile that uses it. Deleting a session removes its transcript and associated audio.
- Audio starts after an explicit session or audio check action. The audio check meters input and uses no transcription provider. Live sources can be paused, toggled, or restarted. A tap can include other apps that play audio on the Mac. “Meeting audio” identifies a source and does not identify individual speakers.
- Apple on-device recognition sets the request to require on-device processing. Availability depends on locale and the speech resources macOS has for that locale. OpenAI Realtime sends audio to OpenAI only with the session’s cloud switch enabled.
- Answer requests send a bounded recent transcript and relevant profile excerpts to the configured provider. A window image is sent only after preview and the send action. A capture stays in memory while it can be retried. Summaries ask for separate confirmation.
- Cloud data handling and billing depend on the provider account. OpenAI response requests set `store: false`. The app does not provide telemetry. Provider keys are stored in non-synchronizing Keychain items and excluded from workspace and session exports.
- Plain-text exports can contain confidential information. Store or share them using the same care as your résumé and meeting notes.

## Dependencies and licenses

CueLens Pro and its icon source are MIT licensed. Runtime code uses macOS system frameworks only. The app does not redistribute model weights. Speech and face landmarks use Apple system services. The three optional answer services are operated by OpenAI, Anthropic, and Google. Their service terms and models are separate from this repository’s license.

API references [Apple Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps), [OpenAI streaming](https://developers.openai.com/api/docs/guides/streaming-responses), [OpenAI Realtime transcription](https://developers.openai.com/api/docs/guides/realtime-transcription), [Anthropic streaming](https://platform.claude.com/docs/en/build-with-claude/streaming), [Gemini content streaming](https://aistudio.google.com/api-reference/generate-content)
