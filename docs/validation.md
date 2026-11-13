# Validation and roadmap

## Automated checks

Test hardware was a 10-core Apple M4 MacBook Air with 16 GB of memory, macOS 27.0.1 (26A434), and Xcode 27.2 (27B52).

- The macOS unit suite passed for assistant and session storage, DOCX extraction and scoped retrieval, provider request shapes and SSE, transcript timestamps and corrections, export and audio deletion, cloud consent, request cancellation, voice activity, resource pressure, and pixel-level camera correction and calibration fallback.
- The universal app and optional extension compile for arm64 and x86_64. Only arm64 was run.
- The Xcode UI test runner timed out enabling automation mode on this Mac. Separate desktop checks verified launching, creating an assistant, starting a session with capture off, saving it, opening History, and opening the compact floating bar. The Mac locked during CueLens Pro’s final visual checks.
- During an earlier signed build’s system-audio test, macOS showed the system-audio permission path. The test did not establish playback-to-transcript performance. No production API keys or personal assistant material were used for automated checks.

## Real-device checklist

| Area | Development Mac | Next verification |
| --- | --- | --- |
| Native app | Development-signed app launched locally | Install a notarized build on another Mac |
| Assistant and History | Created a sample assistant, saved a session, and reopened its History entry | Recheck every revised material tab and import on both appearances |
| Overlay | Compact panel and its route to session setup observed | Drag and resize across displays. Verify Minimize and Restore, opacity, and global shortcuts with a meeting app active |
| Audio | Separate sources compiled and system-audio permission requested | Play known speech. Verify system audio, microphone, source labels, Bluetooth reconnect, pause and wake |
| Cloud | Request formats, streaming events, and cancellation tested with fixtures | With a provider’s own key, test generic connection, streamed answer, image, summary, and optional Realtime transcription |
| Chrome / Google Meet | Viewer-side screen sharing unverified | Compare tab, window, and display on a second device |
| Zoom and Teams | Unverified | Test capture, share modes, and virtual camera after approval |
| Camera | Correction and fallback tested on synthetic frames | Verify live camera permission, frame rate, calibration quality, and physical camera disconnection |
| Virtual camera | Universal extension compiled and embedded | Provision, approve, and verify the feed in meeting apps |
| Other macOS versions / Intel | Deployment target and universal compilation checked | Run on macOS 14.2 and the oldest intended Intel Mac |

## Measure performance

Use a quiet two-minute meeting with a repeatable set of questions. In **Session Setup**, select the audio routes you want to compare and keep the provider and model constant.

1. Run once with a warm provider connection, then again after launching the app.
2. For each answer, record **First text**, **Total**, and **Speech** from the live response area. First text includes the transcription turn delay when an automatic answer starts from a finalized meeting question.
3. Record process CPU and memory from **Overview** or Activity Monitor. If the camera is enabled, record the displayed preview frame rate.
4. Repeat for Low, Balanced, and Performance. Run a separate check with the virtual camera on after it is approved.
5. Use a second client to observe any share exclusion. Record the macOS build, meeting app version, mode, and actual visibility in **Screen Sharing**.

The installed build displayed about 23 MB of physical memory at initial Overview launch on this Mac. This is an idle sample. Live end-to-end latency, frame rate, and performance during a real call are unmeasured.

## Remaining work

- Verify live meeting audio, all live providers, and window capture with real fixtures and authorized API accounts.
- Test Intel and older supported macOS builds on physical Macs.
- Sign and notarize a public release and activate the optional camera extension.
- Validate better gaze redirection with licensed model weights and real video.
- Direct provider account sign-in is deferred. Upcoming-calendar integration and PDF export are outside the current build.
