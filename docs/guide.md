# CueLens user guide

## Create an assistant for each role

1. Open **Assistants → New Assistant** or use **New Assistant** in Studio. All fields are optional. A blank name uses the job title or “Untitled Assistant”. Choose the meeting type and answer style that fit the role.
2. Select **Upload Résumé**. The **Upload** tab accepts PDF, DOCX, TXT, and Markdown. Review the extracted text, then attach it. Scanned PDFs need searchable text. Imports are limited to 12 MB and PDF extraction to 100 pages.
3. Use **Attach Job Description** for the role requirements. Add projects, reference notes, and supporting evidence through **Add Material**. **Type or Paste** accepts text directly. **My Documents** reuses material from existing profiles. Each assistant supports up to 20 materials.
4. Add background, instructions, language, or an assistant-specific model under the additional configuration controls. Personal answers use résumé and experience evidence. Missing facts should produce a qualified answer or a request for more detail.
5. Click **Save Assistant** or **Save & Launch**. The assistant list supports search, duplicate, archive, restore, and delete. Practice records remain associated with the original assistant ID.

## Connect an answer provider

1. Open **Providers** and choose **OpenAI**, **Claude**, or **Gemini** under **Configure**.
2. Use **Get API Key** to open that provider’s dashboard. Copy your key and click **Paste API Key**, or use **⌘V** in the secure field.
3. Choose a model your account can access. Click **Test Connection** to send a short generic prompt and check streaming. This request can consume API credits.
4. Set **Default provider**, choose a backup if needed, and click **Save Settings**. Repeat for another provider when required. Keys are saved in macOS Keychain.
5. Keep **Apple on-device** for local speech recognition. If you select **OpenAI Realtime**, each session has a separate **Use OpenAI Realtime transcription** switch under **Session preferences**. With that switch off, the session uses Apple speech.

Manual **Answer** sends the question, recent transcript, relevant assistant material, and any attached image to the selected provider. **Answer meeting questions automatically** enables requests when meeting questions are detected. Provider access and billing belong to your API account. The app displays token usage when supplied by the provider, with measured response timing. It does not calculate a currency estimate. [OpenAI API keys](https://platform.openai.com/api-keys), [Anthropic API keys](https://platform.claude.com/settings/keys), [Gemini API keys](https://aistudio.google.com/api-keys)

## Camera preview

Click **Start Camera** in Studio. Allow camera access when macOS requests it. The **Me** panel shows your local processed image. Camera settings provide a supported source and format picker, center/thirds framing, crop controls, calibration, and picture effects. Use **Before and After** to compare, **Bypass** for the original camera image, and **Float Video Preview** to move and resize the preview independently. See [the camera guide](camera.md) for outgoing-video setup.

## Start a conversation

1. In **Studio**, choose an assistant. Starting without one creates a general profile.
2. Enable **Microphone** for your voice and **Meeting audio** for sound playing on this Mac. Other applications playing sound may be included. Source labels identify the microphone and meeting route. They do not identify each remote speaker.
3. Open **Session preferences** to choose the microphone and run **Test Audio**. Speak or play a known sample during its eight-second check. Use the **Permissions** menu for Microphone, Screen & System Audio, and Speech Recognition settings if access is denied.
4. Enable **Save an audio recording** if you want retained CAF audio. It starts off for each setup. **Save transcript and answers** controls text retention. Recording also enables saved session text.
5. Enable **Enable screen context** if you want image context. Enable **Answer meeting questions automatically** if desired. Manual Answer remains available with a connected provider.
6. Choose **Open in the compact window** to launch over another application, or use the full Studio. Click **Start Session** when participants have given any required consent and assistance is permitted.

The transcript appears on the left, answers in the center, and video on the right. Resize the dividers to suit your screen. The status bar separates microphone signal, transcription provider, camera state, and answer timing. Audio capture and recording can continue after a transcription error. Read the source error and use **Retry** when ready.

## Capture and answer

- **⌘X** captures the full display under the pointer when screen capture is enabled. CueLens excludes its own windows from that image. This affects CueLens’s screenshot only. The image stays in memory until you send it or remove it.
- The capture menu also offers **Capture a Window** and **Choose an Image…**. Review the preview before sending.
- **⌘C** sends the attached image and question, sends the typed question, or answers the latest transcript question. Image requests default to explaining and solving the visible coding problem.
- The response toolbar provides previous/next answers, pinned responses, response styles, length, retry, and explicit backup-provider selection. Expand **Details** when an answer includes a longer explanation.
- **Cancel** stops the current request. A source or provider error explains what to retry. API credentials and model access must be configured before generating text.

| Shortcut | Action during a live session |
| --- | --- |
| ⌘C | Answer or send |
| ⌘X | Capture the display under the pointer |
| ⌘⌥H | Show or hide the floating panel |
| ⌘⌥X | Pause audio, cancel generation, stop camera, and hide the panel |

The first two shortcuts replace the usual Copy and Cut shortcuts while the session is open. Use **Edit → Copy/Cut** for editing. Session completion releases them. The two ⌘⌥ shortcuts are configurable in **Screen Sharing**.

## Compact window and ending

Use **Minimize** in Studio to move the conversation into a floating panel. Drag its grip and resize the edges. **Minimize** reduces it to the bar, and **Restore** brings back the response panel. **Quick Settings** controls background transparency, answer text size, theme, and docked or separate transcripts. Text remains solid as the panel background changes.

Click **End** in the session toolbar or the stop button on the bar. Audio and camera stop, retained session content is saved, and the compact bar reports the result. A pending save can be retried. Open History when you want to inspect the result.

## Repeatable interview practice

1. Open **Practice**, select the role, and choose **Behavioral**, **Technical**, **Coding discussion**, or **Project deep dive**.
2. Choose whether hints are available and whether to use the microphone. Click **Start Practice** for a baseline question from the selected API.
3. Type your answer and submit it, or speak and click **Review Spoken Answer**. Feedback covers correctness, relevance, structure, and clarity, then gives an example grounded in the supplied facts.
4. Click **Try Again** to answer the same question, **Hint** when enabled, or **Next Question** for an adaptive follow-up.
5. Use **Review Tomorrow** to schedule the latest topic. End the session with saving enabled. **Practice** shows role-specific attempts, due reviews, and feedback. **Practice This Topic** starts a typed review session.

Words, filler phrases, and repetition are estimated from transcript text. Pace and long pauses require usable speech timestamps. Recognition may omit fillers. These measurements are separate from camera posture cues. Saved progress adapts practice requests without training model weights or uploading camera recordings.

## History, export, and deletion

Open **History** to select a session. Search or correct transcript text, expand prior responses, and use **Summarize** to send a bounded transcript excerpt to the chosen provider. Summarization asks for confirmation. Saved audio has playback controls and **Show in Finder**.

The **Actions** menu copies text, exports TXT or Markdown, and deletes a session after confirmation. Exports include available practice feedback and delivery metrics. Deletion removes that session’s text and audio. A damaged record is reported while other readable sessions remain accessible. File locations and handling are described in [architecture](architecture.md).

## Screen sharing

Use **Screen Sharing** to record an actual viewer-side test for the meeting app and sharing mode. Sharing an entire display can expose CueLens. Tab, window, and display sharing need separate checks. Capture and recording indicators remain visible in CueLens. See the [compatibility checklist](validation.md) for tested and unverified combinations.
