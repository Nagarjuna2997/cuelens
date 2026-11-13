# CueLens Pro

CueLens Pro is a native Mac app for meeting notes, interview practice, and live assistance. Each assistant has its own résumé, job description, materials, and response types. The floating session displays the live transcript beside streamed answers from OpenAI, Claude, or Gemini.

## Install

On the development Mac, open **CueLens Pro** from your user Applications folder. To build from source, open `cuelens.xcodeproj` in Xcode 27.2 and run the `cuelens` scheme.

```sh
git clone https://github.com/Nagarjuna2997/cuelens.git
cd cuelens
scripts/package.sh
```

The script writes a universal app and ZIP to `build/distribution/0.2.0`. This is a local development build. See [distribution and camera signing](docs/distribution.md) for Developer ID, notarization, and the optional camera extension. The app targets macOS 14.2 or later. Hardware validation so far used an Apple M4 MacBook Air running macOS 27.0.1.

## Quick start

1. In **Assistants → New Assistant**, name the role and use **Upload Résumé**, **Attach Job Description**, and **Add Material**. Review extracted text. Use **Save & Launch** to open the session setup.
2. In **Providers → API connection**, choose OpenAI, Claude, or Gemini. Copy the provider’s API key and click **Paste API Key**. Click **Test Connection**, choose the **Default provider**, and **Save Settings**. Keys are saved in macOS Keychain. Direct account sign-in is deferred.
3. In **Live Session**, select your assistant, enable **Meeting audio from this Mac**, and optionally enable **Microphone** for your own voice. Run **Test Audio Sources** and review cloud and retention choices before starting.
4. Switch to your meeting app. Drag the floating panel by its grip. Use **Minimize** at the far right of the response toolbar, then **Restore** on the compact bar. **Quick Settings** controls opacity, theme, text size, and transcript layout.
5. Use **⌘↩**, **⌃N**, or **What should I say next?** for the latest question. Type a question or use the camera icon to select a coding window or image. Review the image before sending it.
6. End the session from the compact bar or the session menu. Use **History** for transcript corrections, summaries, and exports.

Read the [full user guide](docs/guide.md) for the exact clicks and permission settings. Use CueLens Pro with any required participant consent and follow the meeting or assessment rules.

## Project links

- [Architecture and security](docs/architecture.md)
- [Test results and real-device matrix](docs/validation.md)
- [Eye contact and virtual camera](docs/camera.md)
- [Distribution and signing](docs/distribution.md)
- [Contributing](CONTRIBUTING.md)
- [MIT license](LICENSE)
