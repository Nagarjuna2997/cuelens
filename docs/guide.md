# CueLens Pro user guide

## Set up an assistant for each role

1. Open **Assistants → New Assistant**. Enter a name such as “iOS Developer Interview”. Select **Interview**, **Mock interview**, **Work meeting**, **Sales**, **Technical discussion**, or **Custom**.
2. Select **Upload Résumé**. In the **Upload** tab, choose a PDF, DOCX, TXT, or Markdown file and click **Attach to Assistant**. Click **Review Text** to check the extraction. Scanned PDFs may require a searchable copy.
3. Select **Attach Job Description**. Upload a file or open **Type or Paste** to paste the text. CueLens Pro uses it to understand the role. Your résumé and experience notes supply personal facts.
4. Select **Add Material** for project notes, portfolio details, or other references. **My Documents** reuses text attached to your saved assistants. **Type or Paste** accepts a note with an optional title. The file size limit is 12 MB, with up to 20 materials per assistant.
5. Open **Additional background and job details** for details missing from the résumé, such as your exact role in a project. Use **Configuration** to set language, tone, instructions, or an assistant-specific model.
6. In **Response types**, choose a default such as STAR. Click **Add Response Type** to add a named instruction such as “Compare the tradeoffs and give one practical example.”
7. Click **Save Assistant** or **Save & Launch**. The assistant list has search, launch, edit, duplicate, archive, and delete. Archiving keeps the profile in the workspace and removes it from the live assistant picker.

## Connect OpenAI, Claude, or Gemini

1. Open **Providers**. At the top, under **API connection**, choose the provider in **Configure**.
2. Click **Get API Key** or use the provider dashboard where you manage API access. Use an API key associated with your own provider account.
3. Copy the key. In CueLens Pro, click **Paste API Key** or press **⌘V** in the secure key field. Keep the suggested model ID unless your account needs another supported model.
4. Click **Test Connection**. A successful test confirms that the selected model streamed text to the app. It sends a generic prompt and can use API credits.
5. Under **Answers**, select the **Default provider** and optionally a **Backup provider**. Click **Save Settings**. Repeat the connection steps for any backup. Switch providers explicitly from the live session menu.
6. Keep **Apple on-device** for local speech recognition when your locale supports it. Select **OpenAI Realtime** to send enabled audio sources to OpenAI after session approval.

API links are available in the app. [OpenAI API keys](https://platform.openai.com/api-keys), [Anthropic API keys](https://platform.claude.com/settings/keys), [Gemini API keys](https://aistudio.google.com/api-keys)

## Start and use a live session

1. Open your meeting in Chrome, Zoom, Teams, or another app.
2. In **Live Session**, choose your assistant. Enable **Meeting audio from this Mac** for audio playing through your Mac and **Microphone** if you want your own spoken responses. Choose headphones to reduce sound picked up by the microphone from your speakers.
3. Run **Test Audio Sources**. Speak or play sample audio for about eight seconds. If a source shows no signal or a permission error, use **Permissions** to open macOS settings. Camera access is requested from the Camera page when you start a preview.
4. Review the cloud processing toggle, local transcript saving, and optional raw audio recording. Enable cloud processing for answers and cloud speech. Start with participant consent and any required permission under your meeting or assessment rules.
5. The floating session opens over your meeting when **Use floating window over the meeting** is on. Drag the dotted grip, resize from the edges, and move it aside to see more of your meeting. Set **Quick Settings → Opacity** to your preference.
6. Live transcript appears on the left. The center shows the answer and streams new text as it arrives. Use **What should I say next?**, **⌘↩**, or **⌃N** to answer the latest meeting question. A transcript row can also be sent on its own. The toolbar provides transcript and response-type toggles, pinned responses, shortcut help, and previous and next responses.
7. To ask something else, type it in the full-width message field and click **Ask CueLens**. To analyze a coding problem, click the camera icon and choose **Capture a Window** or **Choose an Image**. Select only the intended material, review the preview, then click **Solve Image**.
8. **Minimize** is the far-right button in the floating response toolbar. It leaves the compact bar available. Click **Restore** to reopen the response window. **⌘⌥H** shows or hides the panel. **⌘⌥X** pauses capture, cancels answer generation, stops the camera, and hides the panel. The two ⌘⌥ shortcuts can be changed in **Screen Sharing**.
9. In **Quick Settings**, use **Docked** to keep the transcript next to the answer or **Floating** to move it separately. Choose where to put response types, change answer font size, or switch theme.
10. Use the stop button on the compact bar or **Session Options → End Session** to finish. Saved sessions appear in **History**. Open a transcript row’s pencil to correct it. Use **Summarize** with a configured provider or **Actions** to copy, export, or delete the session.

## Practice, sharing, and camera

- **Practice** starts a mock interviewer with the configured provider. Type your answer or speak into the selected microphone and click **Review Spoken Answer**. Click **Next Question** to continue.
- **Screen Sharing** can show a neutral test card. Share a window or display, check the actual viewer’s feed, and record what they saw. A display share can include both floating panels. Hide them before sharing whenever visibility is uncertain.
- **Camera → Start Preview** opens your physical camera. Enable **Eye Contact (Experimental)**, calibrate looking into the camera, then calibrate the spot where you read. The effect has a bounded correction range and an original-feed fallback. To send video to a meeting app, use a signed build with the approved extension. See [camera setup](camera.md).
