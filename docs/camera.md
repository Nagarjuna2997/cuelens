# Eye contact and virtual camera

The original feed is available in Camera preview. Eye Contact is an experimental, local adjustment to the eye region. It uses Apple Vision landmarks and blends shifted pixels from the original frame with Core Image. It tracks the lens look and, optionally, the reading position. The correction has a small range. It falls back to the original feed for blinks, uncertain landmarks, larger head angles, and resource pressure. It cannot reconstruct eye details hidden by lids or glasses.

1. Open **Camera**, select a physical camera, and click **Start Preview**.
2. Turn on **Eye Contact (Experimental)**. Leave **Compare with original** enabled so you can see both feeds.
3. Select **Calibrate Camera Look**, look at the lens for about two seconds, then select **Calibrate Reading Position** and look at your notes. Adjust **Correction strength** if needed. Recalibrate after changing camera or seating position.
4. With an approved extension build, click **Send Video to CueLens Camera**. Choose **CueLens Camera** in your meeting app. If the extension or video feed is unavailable, select your physical camera. Use **Stop Preview** or the emergency shortcut to stop the camera.

Virtual camera source and feed compiled for Apple Silicon and Intel. Xcode on the development Mac lacked an active developer account and matching provisioning profile, so activation and meeting-app selection remain unverified. See [signing instructions](distribution.md#optional-camera-build).

NVIDIA Broadcast requires Windows and a supported NVIDIA RTX device. The current Mac has Apple Silicon. The projects reviewed below use different gaze methods and licenses. No model weights from these projects are bundled.

| Candidate | What was established |
| --- | --- |
| NVIDIA Broadcast and Maxine | NVIDIA lists Windows and RTX for Broadcast. The Maxine Eye Contact model card specifies CUDA hardware and NVIDIA terms. [Broadcast](https://www.nvidia.com/en-us/geforce/broadcasting/broadcast-app/), [model card](https://build.nvidia.com/nvidia/eyecontact/modelcard) |
| GazeLock | MIT app code. Its documentation distinguishes debug refiner weights from a trained model and describes constraints on UnityEyes-based training. [Repository](https://github.com/devkoriel/gazelock), [training notes](https://github.com/devkoriel/gazelock/blob/main/ML/README.md) |
| Gaze Correction Camera | BSD-3-Clause app code. The readme describes separately supplied gaze and landmark weights. Redistribution rights for those weights and frame quality on this Mac remain unverified. [Repository](https://github.com/WangWilly/gaze-correction-cam) |
| CoreML Eye Contact | The repository describes ONNX models and an Apple Silicon path. A model redistribution license could not be verified. [Repository](https://github.com/KypMon/coreml-eye-contact) |

A production eye-contact feature still needs a validated model with clear redistribution terms and an actual comparison in live calls across head angles, lighting, glasses, and hardware.
