Integration overview
Updated: Feb 19, 2026

You can also reference this website: https://deepwiki.com/facebook/meta-wearables-dat-ios

Overview
The Wearables Device Access Toolkit lets your mobile app integrate with supported AI glasses. An integration establishes a session with the device so your app can access supported sensors on the user’s glasses. Users start a session from your app, and then interact through their glasses. They can:
Speak to your app through the device’s microphones
Send video or photos from the device’s camera
Pause, resume, or stop the session by tapping the glasses, taking them off, or closing the hinges
Play audio to the user through the device’s speakers
Supported device
Ray-Ban Meta (Gen 1 and Gen 2) and Meta Ray-Ban Display glasses are supported by the Meta Wearables Device Access Toolkit.
Integration lifecycle
Registration: The user connects your app to their wearable device by tapping a call-to-action in your app. This is a one‑time flow. After registration, your app can identify and connect to the user’s device when your app is open. The flow deeplinks the user to the Meta AI app for confirmation, then returns them to your app.
Permissions: The first time your app attempts to access the user’s camera, you must request permission. The user can allow always, allow once, or deny. Your app deeplinks the user to the Meta AI app to confirm the requested permission, and then Meta AI returns them to your app. Microphone access uses the Hands‑Free Profile (HFP), so you request those permissions through iOS or Android platform dialogs.
Session: After registration and permissions, the user can start a session. During a session, the user engages with your app on their device.
Sessions
All integrations with Meta AI glasses run as sessions. Only one session can run on a device at a time, and certain features are unavailable while your session is active. Users can pause, resume, or stop your session by closing the hinges, taking the glasses off (when wear detection is enabled), or tapping the glasses. Learn more in Session lifecycle.
Key components
MWDATCore is the foundation for your integration. It handles:
App registration with the user’s device and registration state
Device discovery and management
Permission requests and state management
Telemetry
MWDATCamera handles camera access and:
Resolution and frame rate selection
Starting a video stream and sending/listening for pause, resume, and stop signals
Receiving frames from devices
Capturing a single frame during a stream and delivering it to your app
Photo format
For more, check out our API reference documentation: iOS, Android.
Microphones and speakers
Use mobile platform functions to access the device over Bluetooth. To use the device’s microphones for input, use HFP (Hands-Free Profile). Audio is streamed as 8 kHz mono from the device to your app.
App management
After registration, your app appears in the user’s App Connections list in the Meta AI app, where permissions can be unregistered or managed.
Next steps
See real-world integration concepts on our blog.
Start building your first integration with our step‑by‑step guides for iOS and Android.


Integrate Wearables Device Access Toolkit into your iOS app
Updated: Feb 2, 2026
Overview
This guide explains how to add Wearables Device Access Toolkit registration, streaming, and photo capture to an existing iOS app. For a complete working sample, compare with the provided sample app.
Prerequisites
Complete the environment, glasses, and GitHub configuration steps in Setup.
Your integration must use a registered bundle identifier. To register or manage bundle IDs, see Apple’s Register an App ID and Bundle IDs documentation.
Step 1: Add info properties
In your app’s Info.plist or using Xcode UI, insert the required keys so the Meta AI app can callback to your app and discover the glasses. AppLinkURLScheme is required so that the Meta AI app can callback to your application. The example below uses myexampleapp as a placeholder. Adjust the scheme to match your project.
Add the MetaAppID key to provide the Wearables Device Access Toolkit with your application ID - omit or use 0 for it if you are using Developer Mode. Published apps receive a dedicated value (see Manage projects) from the Wearables Developer Center.
Note: If you pre-process Info.plist, the :// suffix will be stripped unless you add the -traditional-cpp flag. See Apple Technical Note TN2175.
<!-- Configure custom URL scheme for Meta AI callbacks -->
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleTypeRole</key>
    <string>Editor</string>
    <key>CFBundleURLName</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>myexampleapp</string>
    </array>
  </dict>
</array>

<!-- Allow Meta AI (fb-viewapp) to call the app -->
<key>LSApplicationQueriesSchemes</key>
<array>
  <string>fb-viewapp</string>
</array>

<!-- External Accessory protocol for Meta Wearables -->
<key>UISupportedExternalAccessoryProtocols</key>
<array>
  <string>com.meta.ar.wearable</string>
</array>

<!-- Background modes for Bluetooth and external accessories -->
<key>UIBackgroundModes</key>
<array>
  <string>bluetooth-peripheral</string>
  <string>external-accessory</string>
</array>
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Needed to connect to Meta Wearables</string>

<!-- Wearables Device Access Toolkit configuration -->
<key>MWDAT</key>
<dict>
  <key>AppLinkURLScheme</key>
  <string>myexampleapp://</string>
  <key>MetaAppID</key>
  <string>0</string>
</dict>

Step 2: Add the SDK Swift package
Add the SDK through Swift Package Manager.
In Xcode, select File > Add Package Dependencies...
Search for https://github.com/facebook/meta-wearables-dat-ios in the top right corner.
Select meta-wearables-dat-ios.
Set the version to one of the available versions.
Click Add Package.
Select the target to which you want to add the package.
Click Add Package.
Import the required modules in any Swift files that use the SDK.
import MWDATCamera
import MWDATCore

Step 3: Initialize the SDK
Call Wearables.configure() once when your app launches.
func configureWearables() {
  do {
    try Wearables.configure()
  } catch {
    assertionFailure("Failed to configure Wearables SDK: \(error)")
  }
}

Step 4: Launch registration from your app
Register your application with the Meta AI app either at startup or when the user wants to turn on your wearables integration.
func startRegistration() throws {
  try Wearables.shared.startRegistration()
}

func startUnregistration() throws {
  try Wearables.shared.startUnregistration()
}

func handleWearablesCallback(url: URL) async throws {
  _ = try await Wearables.shared.handleUrl(url)
}

Observe registration and device updates.
let wearables = Wearables.shared

Task {
  for await state in wearables.registrationStateStream() {
    // Update your registration UI or model
  }
}

Task {
  for await devices in wearables.devicesStream() {
    // Update the list of available glasses
  }
}

Step 5: Manage camera permissions
Check permission status before streaming and request access if necessary.
var cameraStatus: PermissionStatus = .denied
...
cameraStatus = try await wearables.checkPermissionStatus(.camera)
...
cameraStatus = try await wearables.requestPermission(.camera)

Step 6: Start a camera stream
Create a StreamSession, observe its state, and display frames. You can use an auto device selector to make smart decision for the user to select a device. This example uses AutoDeviceSelector to make a decision for the user. Alternatively, you can use a specific device selector, SpecificDeviceSelector, if you provide a UI for the user to select a device.
You can request resolution and frame rate control using StreamSessionConfig. Valid frameRate values are 2, 7, 15, 24, or 30 FPS. resolution can be set to:
high: 720 x 1280
medium: 504 x 896
low: 360 x 640
StreamSessionState transitions through stopping, stopped, waitingForDevice, starting, streaming, and paused.
Register callbacks to collect frames and state events.
// Let the SDK auto-select from available devices
let deviceSelector = AutoDeviceSelector(wearables: wearables)
let config = StreamSessionConfig(
  videoCodec: VideoCodec.raw,
  resolution: StreamingResolution.low,
  frameRate: 24)
streamSession = StreamSession(streamSessionConfig: config, deviceSelector: deviceSelector)

let stateToken = session.statePublisher.listen { state in
  Task { @MainActor in
    // Update your streaming UI state
  }
}

let frameToken = session.videoFramePublisher.listen { frame in
  guard let image = frame.makeUIImage() else { return }
  Task { @MainActor in
    // Render the frame in your preview surface
  }
}

Task { await session.start() }

Resolution and frame rate are constrained by the Bluetooth Classic connection between the user’s phone and their glasses. To manage limited bandwidth, an automatic ladder reduces quality as needed. It first lowers the resolution by one step (for example, from High to Medium). If bandwidth remains constrained, it then reduces the frame rate (for example, 30 to 24), but never below 15 fps.
The image delivered to your app may appear lower quality than expected, even when the resolution reports “High” or “Medium.” This is due to per‑frame compression that adapts to available Bluetooth Classic bandwidth. Requesting a lower resolution, a lower frame rate, or both can yield higher visual quality with less compression loss.
Step 7: Capture and share photos
Listen for photoDataPublisher events and handle the returned PhotoData. Then, when a stream session is active, call capturePhoto.
_ = session.photoDataPublisher.listen { photoData in
  let data = photoData.data
  // Convert to UIImage or hand off to your storage layer
}

session.capturePhoto(format: .jpeg)

Next steps
See details on permission flows in Permissions and registration.
See details on session lifecycles in Session lifecycle.
Test without a device with Mock Device Kit.
Compare against the iOS sample app.
Prepare for release with Manage projects and Set up release channels in the Wearables Developer Center.



Session lifecycle
Updated: Nov 17, 2025
Overview
The Wearables Device Access Toolkit runs work inside sessions. Meta glasses expose two experience types:
Device sessions grant sustained access to device sensors and outputs.
Transactions are short, system-owned interactions (for example, notifications or “Hey Meta”).
When your app requests a device session, the glasses grant or revoke access as needed, the app observes state, and the system decides when to change it.
Device session states
SessionState is device-driven and delivered asynchronously through StateFlow.
State    Meaning    App expectation
STOPPED
Session is inactive and not reconnecting.
Free resources. Wait for user action.
RUNNING
Session is active and streaming data.
Perform live work.
PAUSED
Session is temporarily suspended.
Hold work. Paths may resume.
Note:SessionState does not expose the reason for a transition.
Observe device session transitions
Use the SDK flow to track SessionState and react without assuming the cause of a change. For an Android integration:
Wearables.getDeviceSessionState(deviceId).collect { state ->
    when (state) {
        SessionState.RUNNING -> onRunning()
        SessionState.PAUSED -> onPaused()
        SessionState.STOPPED -> onStopped()
    }
}

Recommended reactions:
On RUNNING, confirm UI shows that the device session is live.
On PAUSED, keep the connection and wait for RUNNING or STOPPED.
On STOPPED, release device resources and allow the user to restart.
Common device session transitions
The device can change SessionState when:
The user performs a system gesture that opens another experience.
Another app or system feature starts a device session.
The user removes or folds the glasses, disconnecting Bluetooth.
The user removes the app from the Meta AI companion app.
Connectivity between the companion app and the glasses drops.
Many events lead to STOPPED, while some gestures pause a session and later resume it.
Pause and resume
When SessionState changes to PAUSED:
The device keeps the connection alive.
Streams stop delivering data while paused.
The device resumes streaming by returning to RUNNING.
Your app should not attempt to restart a device session while it is paused.
Device availability
Use device metadata to detect availability. Hinge position is not exposed, but it influences connectivity.
Wearables.devicesMetadata[deviceId]?.collect { metadata ->
    if (metadata.available) {
        onDeviceAvailable()
    } else {
        onDeviceUnavailable()
    }
}

Expected effects:
Closing the hinges disconnects Bluetooth, stops active streams, and forces SessionState to STOPPED.
Opening the hinges restores Bluetooth when the glasses are nearby, but does not restart the device session. Start a new session after metadata.available becomes true.
Implementation checklist
Subscribe to getDeviceSessionState and handle all SessionState values.
Monitor devicesMetadata for availability before starting work.
Release resources only after receiving STOPPED or loss of availability.
Avoid inferring transition causes. Instead, rely only on observable state.



Permissions and registration
Updated: Feb 5, 2026
Overview
The Wearables Device Access Toolkit separates app registration and device permissions. All permission grants occur through the Meta AI app. Permissions work across multiple linked wearables.
Camera permissions are granted at the app level. However, each device will need to confirm permissions specifically, in turn allowing your app to support a set of devices with individual permissions.
To create an integration, follow this guidance to build your first integration for Android or iOS.
Registration
Your app registers with the Meta AI app to be an permitted integration. This establishes the connection between your app and the glasses platform. Registration happens once through Meta AI app with glasses connected. Users see your app name in the list of connected apps. They can unregister anytime through the Meta AI app. You can also implement an unregistration flow is desired.
Device permissions
After registration, request specific permissions (see possible values for Android and iOS). The Meta AI app runs the permission grant flow. Users choose Allow once (temporary) or Allow always (persistent).
User experience flow
Illustrating the user experience flow for permissions and using features.
Without registration, permission requests fail.
With registration but no permissions, your app connects but cannot access camera.
Multi-device permission behavior
Users can link multiple glasses to Meta AI. The toolkit handles this transparently.
How it works
Users can have multiple pairs of glasses. Permission granted on any linked device allows your app to use that feature. When checking permissions, Wearables Device Access Toolkit queries all connected devices. If any device has the permission granted, your app receives “granted” status.
Practical implications
You don’t track which specific device has permissions. Permission checks return granted if any connected device has approved. If all devices disconnect, permission checks will indicate unavailability. Users manage permissions per device in the Meta AI app.
Distribution and registration
Testing vs. production have different permission requirements. When developer mode is activated, registration is always allowed. When a build is distributed, users must be in the proper release channel to get the app. This is controlled by the MWDAT application ID.
For setting up developer mode, see Getting started with the Wearables Device Access Toolkit.
For details on creating release channels, see Manage projects in Developer Center.
This page also explains where to find the APPLICATION_ID that must be added to your production manifest/bundle configuration.


Use device microphones and speakers
Updated: Nov 14, 2025
Overview
Device audio uses two Bluetooth profiles:
A2DP (Advanced Audio Distribution Profile) for high‑quality, output‑only media
HFP (Hands‑Free Profile) for two‑way voice communication
Integrating sessions with HFP
Wearables Device Access Toolkit sessions share microphone and speaker access with the system Bluetooth stack on the glasses.
iOS sample code
// Set up the audio session
let audioSession = AVAudioSession.sharedInstance()
try audioSession.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth])
try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

Note: When planning to use HFP and streaming simultaneously, ensure that HFP is fully configured before initiating any streaming session that requires audio functionality.
func startStreamSessionWithAudio() async {
  // Set up the HFP audio session
  startAudioSession()

  // Instead of waiting for a fixed 2 seconds, use a state-based coordination that waits for HFP to be ready
  try? await Task.sleep(nanoseconds: 2 * NSEC_PER_SEC)

  // Start the stream session as usual
  await streamSession.start()
}



