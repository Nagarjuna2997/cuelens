# Validation

This page separates automated checks from observed device behavior. The development machine is a 10-core Apple M4 MacBook Air with 16 GB memory, macOS 27.0.1 (26A434), and Xcode 27.2 (27B52). Observations below are from November 13, 2026.

## Automated evidence

The release candidate passed **57 unit tests**, with zero failures, skips, or runtime warnings, in `build/ReleaseCandidateTests.xcresult`. Coverage includes storage, scoped material retrieval, provider request/stream parsing, transcript behavior, recording lifecycle, cancellation, practice recovery, image metadata removal, camera settings, bounded frame delivery, and framing/effect safeguards. These tests include a real generated CAF file opened by AVAudioFile and AVAudioPlayer. Synthetic camera tests do not establish face tracking quality in real video.

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
| Camera preview | Physical camera produced frames; one sample showed 30 fps, about 6 ms processing, and zero dropped frames | No face was present in that sample. Human tracking, posture calibration, long-run thermals, and framing quality remain unverified |
| Meeting-audio transcription | A known 4.55-second audio phrase played through `afplay` was transcribed correctly, including “lavender telescope”; the source showed recording active | Verify microphone independently, simultaneous sources, Bluetooth changes, and long sessions |
| Saved audio | The retained test session exposed `meeting-1.caf`; Play entered playback and Pause stopped it after the audio-path fix | Long recordings, seeking, and output-device changes remain unverified |
| Ending a session | End saved the session to History and left only the compact bar visible | Recheck after capture errors, pending saves, and device disconnects |
| Full-display screenshot | Capture reached a macOS Screen Recording approval requirement | User approved enabling access, but macOS still required physical Touch ID/password authentication. Access remains off; system-audio-only access is already on |
| Keyboard shortcuts | In-app ⌘C sent a typed test question; ⌘X reached the screen-permission error | Real global keyboard behavior from other apps and Copy/Cut restoration should be checked independently |
| Provider answers | Existing Keychain OpenAI connection streamed successfully. A synthetic backoff/jitter question on `gpt-5.4-mini` produced first text in 1.54 s, completed in 2.39 s, with 68 output tokens | This is one observed request, not a latency guarantee. Claude/Gemini account checks, image answers, summaries, and Realtime remain separate checks |
| Virtual camera | Universal host and embedded 1280 × 720/30 extension compiled successfully | Provision the extension, activate, and view from a separate meeting client |
| Screen sharing | No receiver-side invisibility result is established | Test each tab/window/display mode from a second device in the actual meeting app |
| Distribution | Local development packaging is available | Public Developer ID signing, notarization, clean-machine install, Intel execution, and macOS 14.2 execution remain unverified |

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
