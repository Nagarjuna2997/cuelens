# Camera studio and virtual output

CueLens processes camera frames locally through AVFoundation, Vision, and Core Image. The Studio preview and the detached video window show the processed feed. Preview guides, controls, and posture messages are drawn by the interface and excluded from the virtual-camera image.

## Start and frame yourself

1. Click **Start Camera** in Studio, or open **Camera**, choose a camera and supported resolution/frame rate, then click **Start Selected Camera**. Stop the camera before changing its source or format.
2. Select **Center**, **Left third**, or **Right third**. **Automatic framing** follows the detected face with a smoothed crop. Adjust **Zoom** and **Headroom** to keep your face and upper torso comfortably visible.
3. Adjust **Tracking sensitivity** and **Dead zone**. Lower sensitivity and a larger dead zone reduce small crop movements.
4. **Recenter** resets the framing and unlocks it. **Lock Framing** holds the crop. Detection loss causes a safe fallback toward a wider frame.
5. Use **Before and After** to inspect original and processed video. **Bypass** immediately uses the original image. **Float Video Preview** creates a movable, resizable preview window.

The format picker lists formats reported by the selected camera. The app prefers 1280×720 at 30 fps when supported. That is a benchmark target. The preview reports observed frame rate, processing time, and dropped frames. Actual performance depends on the device, lighting, enabled effects, and system load.

## Desk calibration and posture cues

Enable **Posture coaching**, sit naturally with your shoulders visible, and click **Calibrate Desk Position**. Recalibrate after changing the camera, seat, or monitor position. **Reset** removes the baseline.

The local tracker compares face placement and visible shoulder alignment with the calibration. Supported cues include centering, moving back, shoulder alignment, and returning to the seated baseline. Cues require sustained deviation and a cooldown. Each cue can be disabled under **Choose cues**, and **Cue sensitivity** controls tolerance. Obscured or low-confidence observations suspend the affected cues. Camera height is a manual setup instruction: position the lens near eye level before calibration. The two-dimensional tracker does not measure physical camera height or automatically tell you to raise it.

These observations describe visible framing and position. They do not evaluate personality, emotion, honesty, or medical conditions. Apple Vision supplies body-joint observations used by the implementation. [Vision body pose documentation](https://developer.apple.com/documentation/vision/vndetecthumanbodyposerequest)

## Picture effects

- **Background** selects the original background, blur, or a user-selected image. **Mask quality** changes the segmentation accuracy/performance balance. **Blur strength** changes blur radius.
- **Exposure adjustment** and **Color adjustment** provide independent controls.
- **Lift shadows gently** and **Light denoising** provide optional image adjustments.
- **Bypass** disables processing in the outgoing frame. Under sustained processing pressure, expensive background effects and denoising are reduced automatically. The preview status shows the fallback.

Vision generates a person mask used for the background composite. Test hair, glasses, moving hands, and similar foreground/background colors with your own camera. A missing mask uses the original background. [Vision person segmentation documentation](https://developer.apple.com/documentation/vision/vngeneratepersonsegmentationrequest)

## Eye contact

**Built-in eye contact correction** is an experimental local Core ML feature, off by default. In **Camera**, use **Install Local Models…** to select a folder containing a compatible `FLX-L.mlmodelc` / `FLX-R.mlmodelc` pair you have permission to use. The app validates both models before replacing an existing pair. Model weights are not bundled with CueLens. Select a physical camera, enable **Enable local eye correction**, and start the camera; **Correction strength** adjusts the effect.

The processor uses learned eye warps and lighting adjustments. It bypasses correction for uncertain or closed eyes, large head turns, missing models, processing errors, and resource pressure. **Before and After** compares raw and processed video; **Bypass** restores the original frame. The preview reports whether correction was applied or why it was bypassed. Automatic framing changes crop position; neither feature reconstructs head pose.

Native model execution and localized eye processing have been verified on this Mac. Natural eye contact while reading, blink and identity preservation, glasses, varied lighting, and the image received by another meeting participant still need live quality validation. The model assumes a laptop camera above the screen and does not guarantee centered eyes at every angle. See [the integration and validation notes](gaze.md) for installation details, measured evidence, and model distribution limits.

## Send video to a meeting app

The optional Core Media I/O extension exposes **CueLens Camera** at 1280×720/30. The host renders processed camera images into its video stream. It provides no microphone device. Its use requires a signed extension build, macOS activation, and selection in the receiving app. [Apple camera extension documentation](https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o)

1. Follow [the signed camera build instructions](distribution.md#optional-camera-extension), and install the signed host in `/Applications`.
2. Open **Camera → Enable Camera Extension…**, request activation, and complete the administrator approval in macOS settings.
3. Start the physical camera preview, refresh extension status, and choose **Send Video to CueLens Camera**.
4. Reopen the meeting app if necessary and select **CueLens Camera** as its video input. Confirm the processed image from a receiving device.
5. **Stop Sending Video**, **Stop**, **End**, or the emergency shortcut stops the corresponding output.

If the camera is absent, check that the installed app contains the extension, signing and provisioning succeeded, activation was approved, and the meeting app has refreshed its devices. A format mismatch can mean an older 640×480 extension is installed. Rebuild and activate the matching version. The exact validation state is recorded in [the compatibility matrix](validation.md).
