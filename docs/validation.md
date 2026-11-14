# Validation

This page separates automated checks from observed device behavior. The development machine is a 10-core Apple M4 MacBook Air with 16 GB memory, macOS 27.0.1 (26A434), and Xcode 27.2 (27B52). Observations below are from November 13, 2026.

## Automated evidence

The 0.3.0 (build 7) release candidate passed **84 unit tests**, with zero failures, skips, or runtime warnings, in `build/AttachedSessionTests.xcresult`. Coverage includes storage, scoped material retrieval, provider request/stream parsing, transcript behavior, recording lifecycle, cancellation, practice recovery, image metadata removal, camera settings, bounded frame delivery, and framing/effect safeguards. Coverage also verifies speech-task scheduling, practice/conversation preference isolation, scoped error recovery, final audio-event delivery, and graceful-quit saving and recovery. New coverage verifies camera startup defaults, opt-in persistence, and no fallback for a missing explicit camera. These tests include a real generated CAF file opened by AVAudioFile and AVAudioPlayer. Synthetic camera tests do not establish face tracking quality in real video.

The signed universal app was packaged for local testing with Apple Development signing; signature verification passed. The optional 720p30 virtual-camera extension also compiled and embedded successfully for arm64 and x86_64 (`build/final-camera-check.log`). Activation is blocked by Xcode's “No Accounts” and missing Mac App Development provisioning profiles for `org.cuelens.mac` in the attempted signed extension build. A compilation or development-signature check is not notarization or receiver-side compatibility.

To run the unit target from the repository:

```sh
xcodebuild -project cuelens.xcodeproj -scheme cuelens \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:cuelensTests test
```

## Observed on this Mac

| Area | Observed result | Limit or remaining check |
| --- | --- | --- |
| Camera preview | Physical camera produced frames; one sample showed 30 fps, about 6 ms processing, and zero dropped frames | No face was present in the first sample. A later active preview reported Face tracked locally at 28 fps, 3 ms, and zero dropped frames. Tracking quality, posture calibration, and long-run thermals remain unverified |
| Audio transcription | A known 4.55-second phrase played through `afplay` was transcribed under both Meeting audio and Me with both inputs enabled in build 6. The bar menu showed both sources transcribing. An earlier meeting-only test also recorded successfully | This speaker-playback check includes acoustic microphone pickup. Independent human speech, Bluetooth changes, overlapping conversations, and long sessions remain unverified |
| Saved audio | The retained test session exposed `meeting-1.caf`; Play entered playback and Pause stopped it after the audio-path fix | Long recordings, seeking, and output-device changes remain unverified |
| Live window lifecycle | Build 7 Start hid Studio and opened one live window with the bar attached above transcript and answers. Minimize left the compact bar; Restore returned the attached window without Studio. End saved to History and left only the bar. Earlier idle-bar Play started directly without opening Studio | Multi-display placement and physical global keyboard behavior still need separate checks. Normal Quit/save has unit coverage; a clean UI quit-and-relaunch cycle remains to verify |
| Full-display screenshot | After the user enabled Screen & System Audio Recording, ⌘X in build 7 displayed a captured-image preview. The agent removed the test image without sending it | Capture was checked locally; receiver-side sharing visibility is a separate test |
| Keyboard shortcuts | In-app ⌘C sent a typed test question; ⌘X now produced a full-display preview after permission was enabled | Real global keyboard behavior from other apps and Copy/Cut restoration should be checked independently |
| Provider answers | Existing Keychain OpenAI connection streamed successfully. A synthetic backoff/jitter question on `gpt-5.4-mini` produced first text in 1.54 s, completed in 2.39 s, with 68 output tokens. A subsequent binary-search follow-up correctly used the prior typed context | These are individual observations, not latency guarantees. Claude/Gemini accounts, summaries, and Realtime remain separate checks |
| Coding image | A generated PNG was imported, previewed, and sent to OpenAI. The response contained valid Swift two-sum code, `[0, 1]`, and O(n) time/space explanations. First text 2.86 s; complete 7.92 s; 341 output tokens | The imported-image answer and local full-display acquisition were checked separately |
| Answer formatting | A live response displayed a native Approach heading and two formatted bullets; fenced Swift code and Copy controls were visible in the image test | Broader Markdown support is intentionally limited to the documented native blocks |
| Practice | A baseline question, typed synthetic answer, provider feedback, 55-word delivery estimate, saved attempt, and next-day review date were observed in the selected profile | This validates the typed flow; spoken practice and multi-profile switching still need device checks |
| Session camera startup | The opt-in was enabled in Studio, Start launched the session, and the camera preview was on without an additional Start Camera action. GazeAt virtual input also delivered video during the separate local trial | External camera apps control their own effects. Native eye correction remains unavailable; model-quality checks are described in [gaze status](gaze.md) |
| Virtual camera | Universal host and embedded 1280 × 720/30 extension compiled successfully | Provision the extension, activate, and view from a separate meeting client |
| Screen sharing | No receiver-side invisibility result is established | Test each tab/window/display mode from a second device in the actual meeting app |
| Distribution | Local development packaging is available | Public Developer ID signing, notarization, clean-machine install, Intel execution, and macOS 14.2 execution remain unverified |

Build 5 exposed a Swift overlapping-access crash when marking incomplete transcription. Build 6 fixes that mutation and the same pattern in response pinning, with regression tests. The subsequent live audio run remained active through transcription, Minimize, Restore, and camera use.

Earlier builds had desktop checks and a UI automation timeout. Those do not count as acceptance of the redesigned 0.3.0 interface. Additional results should identify the exact build, device, action, and observed outcome.

## Remaining acceptance checks

1. Start/stop the physical camera, compare before/after, calibrate a real seated subject, exercise framing and background controls, disable individual posture cues, and verify all effects bypass together. Check camera unplug/reconnect.
2. Play a known phrase with each source separately, then both. Confirm transcript labels, recording state, pause/resume, saved playback, and no capture after End. Confirm audio and speech failures remain independently visible.
3. Use a generic question and an authorized API key for each provider. Confirm first text, complete response, cancellation, a failed request, an image, and saved-session summarization. Test automatic answers only after explicit opt-in.
4. Grant screen permission, capture a non-sensitive display/window, preview/remove/send, and exercise ⌘X/⌘C. End the session and confirm Copy/Cut work normally again.
5. Create an empty assistant and one with material. Practice, save an answer, switch assistants, restart, and verify progress and review dates stay with the correct assistant.
6. Test compact/minimize/restore, drag and resize across displays, background transparency, and ending without reopening the main app. Inspect light/dark appearance and larger text.
7. Activate the signed camera extension, select it in the target meeting app, and verify video on another client. Test each screen-share mode separately and record actual visibility.

## Performance measurements

Use the same two-minute audio sample and provider/model for repeated runs. Record the app's first-text and total-response timings, CPU/memory in Activity Monitor, and camera FPS/processing/drops. Compare cold and warm starts and each performance preset; record virtual-camera output separately after activation. A brief 30 fps camera sample is not an end-to-end latency benchmark. No live-call latency guarantee is made.

Eye-contact redirection, a virtual microphone, direct provider-account session login, and public notarization are not completed features. The active camera tools provide local framing, posture cues, and effects; answers use configured cloud APIs.

Build 7 was packaged for arm64 and x86_64, signed with Apple Development, verified with strict deep code-signature validation, and installed on this Mac. The release archive SHA-256 is `beca399841f0fdff82558b65cbc678a082345be51320068f08cb5184fae8b8d4`.
