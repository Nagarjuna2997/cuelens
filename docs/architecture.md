# Architecture and privacy

CueLens is a native macOS app. SwiftUI provides Studio, assistants, providers, practice, history, and settings. AppKit supplies the movable session panel, compact bar, and camera preview; Carbon registers shortcuts only for the live session. The minimum macOS version is 14.2 because meeting audio uses Core Audio process taps.

| Area | Responsibility |
| --- | --- |
| `cuelens/App` | App state, navigation, editors, camera controls, practice, and session windows |
| `cuelens/Domain` | Codable models, atomic local storage, document extraction, profile-scoped retrieval, practice progress, and export |
| `cuelens/Media` | Microphone/system audio, Apple speech, screen images, local camera tracking, framing, and effects |
| `cuelens/Providers` | Keychain credentials, fixed vendor endpoints, streaming text/images, and opt-in OpenAI Realtime transcription |
| `cuelens/Session` | Capture lifecycle, context assembly, manual/automatic answer requests, cancellation, and saving |
| `CameraExtension` | Optional Core Media I/O video source receiving processed frames from the authorized host |

## Camera pipeline

AVFoundation captures a selected camera and supported format. A dedicated processing queue runs Vision tracking, smoothed crop/framing, and Core Image effects. The result feeds the local preview and, when explicitly enabled and available, the virtual-camera publisher. Resource pressure can reduce processing quality. Tracking loss widens the frame instead of making a sudden crop toward an uncertain position.

Framing follows a subject by cropping; it does not rotate their head or eyes. Posture cues use detected geometry and a seated calibration, not medical or emotional judgments. Eye-contact correction is unavailable in the active pipeline until a licensed, tested model is integrated. Historical gaze-warp files are not evidence of a working production correction feature. See [camera behavior](camera.md).

## Audio and answers

Microphone and meeting audio use separate capture and speech pipelines. Each reports its source state independently; recording can continue when recognition fails. PCM is normalized for the selected recognizer. Apple Speech requires on-device recognition; locale resources must be available. OpenAI Realtime sends audio only when selected and explicitly enabled for that session. A Core Audio tap can include other applications playing on the Mac; a source label is not speaker diarization.

Manual **Answer** sends the typed question or recent transcript, relevant excerpts from the selected assistant, and an attached image when present. Automatic answers are an explicit session option. Provider requests are asynchronous and carry request identity so cancelled or superseded results cannot overwrite a newer answer. The local document index never retrieves material from another assistant. Practice progress is saved per assistant and uses text-derived feedback; it does not fine-tune a provider model.

The built-in answer providers are OpenAI, Anthropic, and Google, through fixed HTTPS endpoints. Their clients use ephemeral sessions, disable cookies, and reject redirects. OpenAI answer requests set `store: false`; this is not a promise that every provider retains no data. There is no CueLens relay server. Account billing and retention remain subject to the chosen provider's terms.

## Data and permissions

- Camera capture begins with **Start Camera** or an explicit session choice and stops with the corresponding stop/end action. Microphone, speech, system audio, camera, and screen capture have separate macOS permissions. Enabling one does not grant the others.
- Profiles, extracted material, settings, practice progress, and share-test observations live in `workspace.json`. Saved sessions are under `Sessions/`; optional CAF recordings are under `Audio/<session-id>/`. The sandbox resolves these under `~/Library/Containers/org.cuelens.mac/Data/Library/Application Support/CueLens/`. A different bundle identifier uses a different container.
- Import keeps extracted text rather than the original PDF/DOCX. Reusing material copies it into that assistant. Removing every copy requires removing it from each assistant that uses it.
- Recording and screen context require session opt-in. Audio checking meters local input without sending it for transcription. Local camera frames are not sent to an answer provider or saved as video by the active pipeline.
- Screen capture is a requested still image, previewed before **Answer** sends it. It remains in memory for removal or retry. Excluding CueLens from its own screenshot does not make its windows invisible to conferencing software.
- Session transcript/answer saving is configurable. Ending stops capture and returns to the compact bar. Deleting a saved session removes its transcript and associated audio. There is no automatic retention deadline.
- Provider keys use non-synchronizing Keychain items and are excluded from workspace files, exports, and Git. No app telemetry is implemented. Summarization requires a separate confirmation and sends the bounded saved transcript to the selected provider.
- Exports can contain personal material. The application does not encrypt exported TXT/Markdown files; choose their destination and sharing intentionally.

See [dependencies and licenses](dependencies.md), [audio](audio.md), and [validation](validation.md) for implementation limits and test evidence.
