# Photobooth2 (iPad + Sony USB-C PTP)

A native iOS / iPadOS photobooth kiosk application built in Swift and SwiftUI. Designed to run as an autonomous, commercial-grade photobooth kiosk at events, parties, and weddings. 

The app connects directly to external **Sony Alpha mirrorless cameras over wired USB-C PTP (Picture Transfer Protocol)** for instant live view, zero-latency burst capture, AI background replacement, and offline-first guest sharing.

---

## What the App Does

* **Autonomous Kiosk State Machine**: Seamless, guest-facing workflow:
  * **Idle Screen**: Full-screen 30 FPS Live View with "TAP TO START" prompt.
  * **Countdown Sequence**: Animated countdown with visual feedback, audio prompts, and guidance arrows directing guests to look at the camera lens instead of the screen.
  * **Zero-Latency Capture**:
    * **Photo Mode**: High-resolution capture archived to the camera's SD card while simultaneously transferring a 2MP preview to the iPad for instant review.
    * **Animated GIF Mode**: Rapid-fire multi-frame burst routed directly to the iPad's memory (bypassing the SD card write buffer completely) to produce smooth 1080p looping motion GIFs.
  * **Review & Sharing**: Interactive multi-photo / GIF playback with options to share or auto-reset to the start screen.
* **AI Virtual Green Screen & Backdrop Compositing**:
  * Real-time subject segmentation and compositing with virtual background and foreground frames across Live View, still photos, and animated GIFs without requiring a physical green screen.
  * Custom backdrop importer and management menu.
  * Generates a Triple-Lock `photobooth_backdrop_manifest.json` file for batch-applying backdrop composites to original full-resolution camera RAW/JPEG files on macOS.
* **Flexible Guest Sharing Options**:
  * **AirDrop**: Instant bulk sharing of high-resolution photos and animated GIFs directly to guest Apple devices.
  * **Offline-First Email Queue**: Guests can type their email address at the kiosk; if Wi-Fi is spotty or disconnected at the venue, emails are queued locally with SQLite/JSON persistence, exponential retry backoff, and idempotency guards, flushing automatically when the iPad connects to Wi-Fi. Supports Resend API and Gmail SMTP.
  * **QR Code Gallery**: Displays dynamic QR codes pointing to online event galleries where guests can download their full-resolution media after the event.
* **Smart Auto-Exposure & Color Grading**:
  * Automatic highlight-protected shadow lifting and exposure normalization across Live View and review frames, ensuring dim ambient light or strobe-lit settings display with natural skin tones without blowing out highlights.
  * Frame-to-frame exposure equalization across burst GIF frames to prevent brightness flicker.
* **Standalone iPad Camera & Mock Mode**:
  * Includes a built-in **iPad Camera Mode** using the iPad's internal front/rear cameras when no external camera is available.
  * Includes a **Mock Camera** mode for offline simulator development and automated QA verification.

---

## Hardware Compatibility

### 1. Compatible Sony Cameras

The app connects via wired USB using Sony's **USB PTP (Picture Transfer Protocol) / PC Remote** specification through Apple's `ImageCaptureCore` framework.

#### Primary & Recommended Cameras (BIONZ XR Generation — Protocol 3.00):
* **Sony Alpha 7R V (`ILCE-7RM5`)**
* **Sony Alpha 7 IV (`ILCE-7M4`)**
* **Sony Alpha 7CR (`ILCE-7CR`)**
* **Sony Alpha 7C II (`ILCE-7CM2`)**
* **Sony Alpha 7S III (`ILCE-7SM3`)**
* **Sony Alpha 1 (`ILCE-1`)**
* **Sony Alpha 9 III (`ILCE-9M3`)**
* **Sony Alpha 6700 (`ILCE-6700`)**
* **Sony FX3 / FX30 / ZV-E1**

#### Fallback Compatibility (BIONZ X Generation — Protocol 2.00):
* The handshake routine includes fallback support for Sony PTP Protocol 2.00 (`0x00C8`) for older Sony Alpha cameras supporting USB PC Remote tethering:
  * **Sony Alpha 7 III (`ILCE-7M3`)**
  * **Sony Alpha 7R III (`ILCE-7RM3`)**
  * **Sony Alpha 7R IV (`ILCE-7RM4`)**
  * **Sony Alpha 9 / Alpha 9 II**

> **Note on Sony A7R II (`ILCE-7RM2`)**:
> The original prototype app used the Sony A7R II over Wi-Fi (via the legacy "Smart Remote Control" PlayMemories app). That architecture was deprecated and replaced by wired USB PTP in Photobooth2 due to Wi-Fi drops, high latency, SD write delays, and iPad internet isolation. The A7R II does not support the required USB PTP RAM-buffering features used in this app.

#### Required Sony Camera Settings:
1. **USB Connection Mode**: Set to **`PC Remote`** (`Remote Shoot`).
2. **Smartphone Connection**: Set to **`Off`**.
3. **Focus Mode**: Set to **Manual Focus (`MF`)** or Release Priority.
4. **Exposure Mode**: Manual (`M`) or Memory Recall (`1`) (e.g., `1/125s`, `f/10`, `ISO 200` for strobe use).
5. **Auto Power OFF Temp.**: Set to **`High`** for all-day kiosk reliability.
6. **Physical Connection**: Use the camera's high-speed USB-C data port (marked with the USB trident icon).

---

### 2. Compatible iPad Models & iPadOS Versions

#### Operating System:
* **iPadOS 18.6+** (Configured deployment target: `IPHONEOS_DEPLOYMENT_TARGET = 18.6`). Requires an iPad capable of running iPadOS 18.

#### Hardware Requirements:
* **USB-C Port Required**: The app relies on a powered USB-C hub to provide simultaneous high-speed USB PTP camera communication and continuous USB Power Delivery (PD) to the iPad.

#### Supported iPad Hardware:
| iPad Model | Compatible Generations | Notes |
| :--- | :--- | :--- |
| **iPad (Base)** | **iPad (10th Generation)** | **Officially targeted in code.** Includes custom arrow positioning logic for the landscape-edge front camera. *(Gen 7–9 use Lightning and lack iPadOS 18 support).* |
| **iPad Air** | **iPad Air 4th Gen, 5th Gen (M1), 11" & 13" (M2)** | All USB-C models running iPadOS 18+. |
| **iPad Pro 11-inch** | **1st, 2nd, 3rd, 4th, and M4 Generations** | Layout specifically verified for `1194×834` screen dimensions in automated QA suite. |
| **iPad Pro 12.9" / 13"** | **3rd, 4th, 5th, 6th Gen and 13" M4** | Layout specifically verified for `1366×1024` 4:3 screen dimensions in automated QA suite. |
| **iPad mini** | **iPad mini 6th Gen and A17 Pro** | USB-C and iPadOS 18+ compatible (smaller display form factor). |

#### Display & Framing:
* **Fixed Landscape Orientation**: UI is locked horizontally (`UIInterfaceOrientationLandscapeRight` / `LandscapeLeft`).
* **Aspect Ratio Preservation**: Native 3:2 camera aspect ratios are preserved with automatic top/bottom letterboxing across both standard 4:3 iPads (1024×768 / 1366×1024) and 1.43:1 screens (11" 1194×834).

---

## Hardware Rig Architecture

```
[Wall AC Power] 
       │ (USB-C Power Delivery)
       ▼
[UGREEN 100W PD Hub] ──(USB Host Cable)──► [iPad (10th Gen or Pro/Air)]
       │
       └──(10Gbps USB Data)──► [Sony Camera (USB-C Data Port)]
                                     │
                                 [Hot Shoe] ──► [Godox X2T-S Strobe Trigger]
```

---

## Building and Verification

### Requirements
* Xcode 16.0+
* macOS 14.5+ or macOS 15+
* iOS / iPadOS 18.6+ SDK

### Running Automated QA Unit Tests
The repository includes a comprehensive standalone QA verification suite testing PTP protocol serialization, exposure scaling, GIF equalization, aspect ratio letterboxing, and offline email queueing:

```bash
# Run automated verification suite directly via Swift CLI:
swift Photobooth2/verify_qa.swift

# Build the project cleanly in Xcode:
xcodebuild -project Photobooth2/Photobooth2.xcodeproj -scheme Photobooth2 -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```
