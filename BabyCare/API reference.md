### 📘 Meta Wearables DAT v0.4 API Reference 

**Frameworks:** `MWDATCore` (Connection/Lifecycle) & `MWDATCamera` (Media/Streaming)

#### 1. MWDATCore: Device Discovery & Management

The entry point for any Meta Wearables app. It handles finding the glasses (Ray-Ban Meta, etc.) and managing their state.

* **`Wearables` (Main Interface):** * Access via `Wearables.shared`.
* `register(selector:)`: Primary method to start the connection flow. Uses a `DeviceSelector`.
* `unregister()`: Clean up resources.


* **`DeviceSelector` (Protocol):** * `AutoDeviceSelector()`: Automatically finds and connects to the best available wearable.
* `SpecificDeviceSelector(identifier:)`: Connects to a specific known device.


* **`Device` (Class):** Represents the hardware.
* Properties: `id`, `type` (e.g., `.raybanMeta`), `state`.


* **`DeviceStateSession` (Class):** * Observe live updates like `hingeState` (open/closed), `linkState` (connected/disconnected), and battery.
* **Permissions:** * `Permission` enum: Includes `.camera`, `.microphone`.
* Check status using `PermissionStatus`.



#### 2. MWDATCamera: Real-time Streaming & Capture

Used for accessing the wearable's camera feed once a device is connected.

* **`StreamSession` (Class):** The core class for video streaming.
* `init(device:config:)`: Initialize with a `Device` object and a `StreamSessionConfig`.
* `startStream()` / `stopStream()`: Controls the flow.
* `state`: Monitor via `StreamSessionState` (`.connecting`, `.streaming`, `.stopped`).


* **`StreamSessionConfig` (Struct):** * Set `resolution` (via `StreamingResolution`), `codec` (via `VideoCodec`), and `bitrate`.
* **`VideoFrame` (Struct):** * The payload received during streaming. Contains `pixelBuffer` (CVPixelBuffer) for rendering or AI processing.
* **`PhotoCaptureFormat` (Enum):** Defines quality/type for still images.

#### 3. Common Design Patterns for Coding

* **Async/Await:** The SDK heavily utilizes Swift's structured concurrency. Most `start` or `register` calls are `async`.
* **Delegates/Announcers:** Uses an "Announcer" pattern for event listening. To listen for frames:
```swift
session.announcer.addListener(self)

```


* **Error Handling:** Watch for `WearablesError`, `StreamSessionError`, and `PermissionError`.

#### 4. Typical Integration Flow

1. **Initialize:** `try await Wearables.shared.register(selector: AutoDeviceSelector())`
2. **Request Permissions:** Check camera/mic permissions via `Wearables.shared`.
3. **Start Camera:** ```swift
let config = StreamSessionConfig(resolution: .v720p, codec: .h264)
let session = StreamSession(device: myDevice, config: config)
try await session.startStream()
```

```


4. **Handle Frames:** Implement the listener protocol to receive `VideoFrame` and extract the `pixelBuffer`.

---

**Pro-tip:** "When rendering the `VideoFrame.pixelBuffer`, remember that the Meta Wearables feed may require specific orientation handling based on the `VideoFrameSize` metadata provided in the stream."
