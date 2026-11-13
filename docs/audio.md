# Audio capture and routing

CueLens captures the selected microphone with AVFoundation and permitted Mac output through a private Core Audio process tap. The tap excludes CueLens itself. Remote participants are labeled **Meeting audio** collectively. The app does not claim to identify individual remote speakers.

The capture engine copies Core Audio buffers before their callback ends, normalizes them to 24 kHz mono PCM, and supplies the same audio to the speech provider and optional recorder. A converter can wait for more input without terminating capture. RMS levels show average volume. A peak at or above 98% of full scale displays a clipping indication for 1.5 seconds. Lower the source input gain or move back from the microphone when this repeats. A clipping indicator cannot repair audio already distorted by the microphone.

## Transcription and optional recording

Apple speech requires Speech Recognition permission and support for the selected locale. It requests on-device recognition. OpenAI Realtime requires its API key and an explicitly enabled audio-processing setting. A transcription failure keeps the audio input and optional recording running. The source shows an error and can be retried. A raw-audio write failure stops that recording and reports the failure while transcription continues.

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
