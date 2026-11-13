# Audio capture and routing

CueLens captures the selected microphone with AVFoundation and permitted Mac output through a private Core Audio process tap. The tap excludes CueLens itself. Remote participants are labeled **Meeting audio** collectively. The app does not claim to identify individual remote speakers.

The capture engine copies Core Audio buffers before their callback ends, normalizes them to 24 kHz mono PCM, and supplies the same audio to the speech provider and optional recorder. A converter can wait for more input without terminating capture. RMS levels show average volume. A peak at or above 98% of full scale displays a clipping indication for 1.5 seconds. Lower the source input gain or move back from the microphone when this repeats. A clipping indicator cannot repair audio already distorted by the microphone.

## Transcription and optional recording

Apple speech requires Speech Recognition permission and support for the selected locale. It requests on-device recognition. OpenAI Realtime requires its API key and an explicitly enabled audio-processing setting. A transcription failure keeps the audio input and optional recording running. The source shows an error and can be retried. A raw-audio write failure stops that recording and reports the failure while transcription continues.

On the development Mac, concurrent Apple recognition tasks repeatedly cancelled each other. CueLens now schedules one local recognition turn at a time while retaining each source's audio and timestamps separately. The waiting source shows **Queued**. This is a workaround for the observed device behavior, not a claim that every Apple speech implementation has the same limit. Overlapping voices can add transcription delay. Successful recognition clears the speech error without hiding a separate capture or recording failure.

Apple's “failed to recognize any speech” result is treated as an empty turn, so background noise does not turn a healthy source into an error. Service, permission, and timeout failures remain visible. [Apple speech error codes](https://developer.apple.com/documentation/speech/sfspeechrecognitiontask/error)

Ending a session stops live capture and recording, then allows up to eight seconds for already captured Apple speech to finish. The recording has already stopped during this wait. If queued speech cannot finish or the bounded queue overflows, History and text exports flag the affected source as having an incomplete transcript. Immediate pause/emergency stop prioritizes stopping capture. Retained audio, when enabled, remains separate from transcript completeness.

Testing microphone and meeting audio together on the development Mac exposed repeated local speech-task cancellations. CueLens now serializes Apple speech turns across sources and buffers the waiting source, with separate source labels. Each continuous turn is limited to eight seconds so one source can yield to the other. Overlapping speech can increase transcription latency. Waiting and failed states are shown separately. The scheduler is a CueLens workaround for the observed behavior, rather than a claim that every Apple speech implementation has the same limit. [Apple speech recognition tasks](https://developer.apple.com/documentation/speech/sfspeechrecognizer)

An orderly End stops audio capture and recording immediately, then gives queued Apple speech up to eight seconds to finish. Timeouts and skipped turns mark the session transcript incomplete. Emergency stop cancels processing immediately. Diagnostic logs include the source, error domain, and numeric error code without recognized text.

Apple's `kAFAssistantErrorDomain` code `1110` means the recognizer did not recognize speech in a turn. CueLens treats that result as an empty turn and keeps waiting, since room noise can trigger voice activity. Service interruption, authorization, and recognizer-contention errors remain visible failures. [Apple speech error codes](https://developer.apple.com/documentation/speech/sfspeechrecognitiontask/error)

Raw audio is saved only when recording is selected for the session. Each source is written to its own CAF file and retries create a new part. Recording status becomes active after the first successful write. Session exports and deletion are available from History. The app’s sandbox stores its data under `Library/Containers/org.cuelens.mac/Data/Library/Application Support/CueLens/` inside the user’s home directory.

## System microphone effects

During microphone capture, **Microphone Effects…** opens the system microphone-mode controls. Where the current hardware and audio route support it, the user can select **Voice Isolation**. Apple controls availability. The displayed active mode may differ from the preferred mode when the current route cannot support that preference. The app reads the active mode rather than claiming that noise reduction has been enabled. [Apple microphone modes](https://developer.apple.com/videos/play/wwdc2021/10047/?time=298), [Apple system effect controls](https://developer.apple.com/documentation/avfoundation/avcapturedevice/showsystemuserinterface(_:))

## Meeting microphone routing

**CueLens Camera** publishes processed video through a Core Media I/O camera extension. CueLens has no virtual microphone device or outgoing processed-microphone route. Meeting applications must select their own microphone. Voice Isolation applied to CueLens capture does not establish that another meeting app receives that processed audio.

Publishing a separate microphone device would require an audio-driver or other explicitly installed virtual-audio routing dependency plus routing and feedback tests. No such driver is installed by CueLens. Avoid enabling live speaker monitoring while capturing both microphone and meeting audio. Use headphones for tests. Microphone monitoring and in-app test playback remain unimplemented.

## Validation

The audio regression tests exercise tiny and empty converter inputs, changing sample rates, stereo downmix, callback-buffer ownership, and clipping peaks that average meters can miss. They do not establish permission, microphone hardware, Bluetooth reconnect, or real speech-to-text performance.

For real-device verification, choose a microphone, grant the requested permissions, enable optional recording, and speak a known phrase. Confirm source levels, the visible transcript, and a playable recording in History. Separately play a known speech file from another app while **Meeting audio** is enabled. Check the source labels, pause/resume, and an input-device disconnect. Test each configured speech provider separately.

The 720p/30 camera output is a video format target. It does not measure microphone processing or prove a meeting app’s compatibility. [Apple Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps), [Apple camera extensions](https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o)
