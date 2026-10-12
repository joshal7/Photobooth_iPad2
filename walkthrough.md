# Photobooth2 App Walkthrough

## Overview
The iPad Photobooth2 app has been implemented as an iOS application and Swift Package. It includes a `MockCameraClient` to allow testing without physical hardware.

## Verification Steps

### 1. Open in Xcode
1.  Open `Photobooth2/Photobooth2.xcodeproj` in Xcode.
2.  Select the `Photobooth2` scheme and target device/simulator.

### 2. Mock Mode Verification
The app is currently configured to use `MockCameraClient` by default (controlled by `StateMachine.useMockCamera`).

1.  **Launch the App**: You should see the "Connecting to Camera..." spinner, followed quickly by the "TAP TO START" screen (Idle State).
2.  **Start Session**: Tap anywhere on the screen.
3.  **Countdown**: You should see a countdown (5s).
4.  **Capture**: The screen will flash white (simulating capture).
5.  **Repeat**: This will repeat 3 times (as per config) with a 2s interval.
6.  **Review**: After capturing, the app will show the captured images (solid colors in Mock mode) for 4 seconds each.
7.  **Reset**: The app will return to the "TAP TO START" screen.

### 3. Configuration
You can modify default settings in `ConfigManager.swift`:
- `initialCountdownSec`
- `interShotCountdownSec`
- `photoCount`

### 4. Real Hardware
To test with real camera hardware:
1.  Connect iPad to Camera Wi-Fi / network.
2.  Change `StateMachine.useMockCamera` to `false`.
3.  Run the app.

## Artifacts
- **Xcode Project**: `Photobooth2/Photobooth2.xcodeproj`
- **Source Code**: `Photobooth2/Photobooth2/Sources`
- **Package Definition**: `Package.swift`
