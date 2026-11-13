# CueLens

CueLens is a native macOS camera studio, conversation assistant, and interview practice app. The Studio combines a live transcript, streamed answers, and a large camera preview. Each role keeps its own résumé, documents, and practice history.

The 0.3.0 rebuild adds local automatic framing, desk calibration, posture cues, background effects, a movable video preview, and an adaptive practice loop. The existing app icon is retained. Eye-contact correction is marked unavailable while a suitably licensed model and its output quality remain unvalidated.

## Build and run

Open `cuelens.xcodeproj` in Xcode 27.2, select the `cuelens` scheme, and run on your Mac. The deployment target is macOS 14.2. Packaging uses the existing project and bundle identifier `org.cuelens.mac`.

```sh
git clone https://github.com/Nagarjuna2997/cuelens.git
cd cuelens
scripts/package.sh
```

The script produces `build/distribution/0.3.0/CueLens.app` and `CueLens-0.3.0-macOS.zip`. It builds Apple Silicon and Intel slices and uses ad hoc signing unless an identity is supplied. See [distribution and signing](docs/distribution.md) for the development-signing and public-release workflows.

## Start using CueLens

1. Open **Studio** and click **Start Camera** to preview yourself. Use **Camera** for camera selection, format, framing, calibration, and effects.
2. Create an assistant for your role. Add a résumé, job description, and project notes as needed. All profile fields are optional.
3. Open **Providers**, choose OpenAI, Claude, or Gemini, use **Paste API Key**, then **Test Connection** and **Save Settings**. Keys are stored in macOS Keychain.
4. Select your microphone and meeting audio in Studio. Enable audio recording, screen capture, and automatic answers only when wanted. Click **Start Session**.
5. Use **⌘X** to preview the display under the pointer and **⌘C** to send the attached image, typed question, or latest transcript question. These shortcuts replace Copy and Cut during the live session. The Edit menu remains available.
6. Click **End** to stop the session and return to the floating bar. Open **History** to review saved text, play retained audio, generate a summary, export, or delete a session.

Start **Practice** for behavioral, technical, coding-discussion, or project questions. Review an answer, retry the same question, request a hint, and schedule a topic for later review. Camera and posture observations stay local. Manual answers use the selected API with the context described in setup.

## Current validation

The 0.3.0 release candidate passed 57 unit tests on an M4 MacBook Air. Camera preview, system-audio transcription, retained audio playback, End-to-bar behavior, and an OpenAI streamed answer were checked on this Mac. Measurements and remaining checks are recorded in [validation](docs/validation.md). Virtual-camera output requires the separately signed and activated extension. Meeting-app compatibility, full-screen sharing behavior, and live API performance must be established for each tested configuration.

## Documentation

- [User guide and shortcuts](docs/guide.md)
- [Camera studio, framing, and virtual output](docs/camera.md)
- [Audio capture and routing](docs/audio.md)
- [Architecture and data handling](docs/architecture.md)
- [Dependencies, models, and licenses](docs/dependencies.md)
- [Build, signing, and distribution](docs/distribution.md)
- [Tests and compatibility checklist](docs/validation.md)
- [Contributing](CONTRIBUTING.md)
- [MIT license](LICENSE)
