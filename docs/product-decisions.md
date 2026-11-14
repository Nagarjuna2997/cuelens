# CueLens product decisions

These decisions capture the user's current requirements for this repository.

- Keep the **CueLens** name, existing app icon, native macOS project, and repository.
- The main app is the studio and setup workspace. Starting a session hides it and opens separate floating controls. Never surface the main app automatically after Start, Minimize, Restore, or End.
- Attach the live control bar to the top of the transcript-and-answer window so dragging moves them together. Minimize leaves only the compact bar; Restore expands it at the same location. End stops CueLens capture, saves enabled history, and leaves the bar.
- The idle bar's Play action starts the selected assistant directly. Opening setup is a separate, explicit action.
- Keep one camera-start action and one detach-preview action per panel. Disable preview-only controls before a frame exists. Live Quick Settings handle panel adjustments; Open Setup is the deliberate route back to the main app.
- Remember conversation audio sources consistently from the bar and transcript. Practice defaults meeting audio off and keeps its source choices separate from conversation preferences.
- Use **⌘X** for capture and **⌘C** for answering during a session. Release their global bindings when the session ends. Keep visible buttons available.
- Assistant fields and résumé/material uploads are optional. Store separate context and practice progress for each role.
- Answers use OpenAI, Claude, or Gemini. Keep API credentials in Keychain and out of the public repository. Do not extract consumer-app login cookies or pretend those logins provide supported API access.
- Make answer formatting readable: a concise opening, native headings and lists, expandable details, and copyable code. Keep personal claims grounded in uploaded experience.
- Starting the selected camera with a session is an explicit persisted option. Never substitute the physical camera when a selected external source is unavailable. External apps control their own processing and capture lifecycle.
- Keep camera processing local. Automatic framing and posture coaching are separate from eye-contact correction. Keep native gaze correction off by default and explicitly experimental until model rights and live quality are validated. Missing models disable activation; never claim an applied warp guarantees centered eyes.
- Record audio only when enabled. Screen context is optional and captured images are reviewed before sending. Turning screen context off removes the pending image.
- Never claim universal invisibility during screen sharing. The operating system and receiving meeting app determine what is visible.
- Keep measured results separate from implemented features and unverified compatibility. Record remaining authentication, provisioning, and device-validation limits in [validation](validation.md).

The latest implementation supersedes earlier requests for a different app name or a main-window-first live-session flow.
