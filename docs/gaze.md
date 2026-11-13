# Eye-contact correction: integration status

Reviewed November 13, 2026. **CueLens does not currently redirect pupils or head pose.** Its camera framing changes the crop; posture coaching observes visible position. Neither makes an off-camera gaze appear centered. The existing eye-contact status therefore remains **Unavailable**.

An acceptable integration needs a usable camera-processing SDK or an independently installed virtual-camera provider, appropriate model and distribution rights, and observed correction on this Mac. A toggle, face detector, or geometric pixel shift does not establish that capability. No third-party app, model, or account was installed or activated during this review.

## Evaluated routes

| Route | Official evidence | CueLens decision |
| --- | --- | --- |
| Effects SDK | The vendor supports native macOS, Metal, and CVPixelBuffer input. Its eye-contact feature page explicitly says this capability is not included by default and requires discussion of requirements, timelines, and integration. | A potential commercial SDK route. Vendor access, a feature-enabled package, and a suitable integration/distribution license are still needed; the standard SDK is not evidence that gaze correction is available. [Platform support](https://effectssdk.ai/), [eye-contact availability](https://effectssdk.ai/features/eye-contact-correction) |
| NVIDIA Maxine / Broadcast | NVIDIA documents the local Eye Contact SDK for Windows and Linux with NVIDIA GPUs. It also documents a separate Eye Contact NIM/API service. | The local SDK is not a native Apple-silicon implementation. A server-backed integration would be a separate deliverable requiring service access, deployment/licensing review, measured latency, and explicit consent to send camera video. Nothing in CueLens uploads video for this purpose. [Local SDK](https://developer.nvidia.com/blog/improve-human-connection-in-video-conferences-with-nvidia-maxine-eye-contact/), [NIM/API route](https://developer.nvidia.com/blog/advancing-telepresence-and-next-generation-digital-humans-with-nvidia-maxine/) |
| GazeAt / Gaze Correction Camera | The associated public project describes a learned gaze-warp model, downloadable weights, dlib/MediaPipe paths, and virtual-camera output. Its source license is BSD-3-Clause; that alone does not settle every bundled model's rights. | Not selected under the request to avoid open-source models. No public embeddable SDK was found in the reviewed documentation. A mounted GazeAt 1.1 installer was inspected only for bundle/signature metadata; it was not installed or run, and its binary provenance was not independently matched to a published checksum. [Project](https://github.com/WangWilly/gaze-correction-cam), [source license](https://github.com/WangWilly/gaze-correction-cam/blob/master/LICENSE) |
| iContact Camera | The vendor places a physical USB camera closer to the user's eye line; its optional Control app adjusts exposure, white balance, focus, zoom, and audio. | Physical lens placement can improve the eye line, but this is not a pupil-redirection model for CueLens to embed. [Camera setup](https://icontactcamera.com/blogs/support-buying/mac-windows-chromeos-linux-compatibility), [Control app](https://icontactcamera.com/blogs/support-app/how-do-i-get-icontact-control) |
| AICONTACT | The vendor advertises Mac virtual-camera eye-contact software and separately offers built-in licensing by arrangement. The reviewed page does not supply a current Apple-silicon SDK package, API reference, or verified compatibility evidence for this Mac. | A commercial candidate to evaluate with the vendor, not an activated or validated CueLens dependency. [Vendor information](https://facestream.ai/aicontact-free) |

The reviewed Iris Cam App Store listing describes composition guidance, filters, and portrait controls. It does not document live gaze redirection, a Mac virtual-camera feed, or an embedding SDK; it is not a verified solution to this requirement. [Developer listing](https://apps.apple.com/tn/app/iris-cam-ai-camera/id6795394901)

## External virtual-camera path

CueLens's camera picker accepts camera devices exposed through AVFoundation and excludes its own virtual output to prevent feedback. If an authorized gaze-correction app exposes a supported virtual camera, the intended path is:

`Physical camera → vendor correction → vendor virtual camera → CueLens preview/effects`

The meeting app can select the vendor camera directly. Relaying additional CueLens effects into a meeting requires the separately signed and activated CueLens Camera extension. Neither path has been validated with a gaze-correction provider on this Mac. CueLens cannot infer that a vendor's correction is enabled merely because its camera is selected, and must not report native correction as active on that basis.

## Quality limits and acceptance

Natural correction has a working range. NVIDIA's published implementation recommends roughly a 20-degree pitch/yaw cone, reduces correction as the eyes move farther away, and disables it for large head rotations or obscured eyes. This is evidence about that implementation, not a measured CueLens limit or a guarantee for other vendors. [NVIDIA working range and occlusion handling](https://developer.nvidia.com/blog/improve-human-connection-in-video-conferences-with-nvidia-maxine-eye-contact/)

Before enabling a future module, compare raw and corrected video while reading near and far from the lens, blinking, turning the head, wearing glasses, and moving in varied light. Verify identity and eyelid preservation, graceful fallback, instant bypass, bounded queues, actual frame rate/latency, and the image received by a separate meeting client. Until those checks pass, keep correction unavailable rather than promise eyes will stay centered at every angle.
