# Photobooth2 Standard Post-Fix QA Plan

Use this standard post-fix QA plan to validate every change to `Photobooth2` across both **Automated Simulator QA (`--verify`)** and **Hardware Verification (iPad + Sony USB-C PTP)**.

---

## 1. Automated Post-Fix Verification Suite (`verify_qa.swift` & `--verify`)

Every code change must build cleanly (`CODE_SIGNING_ALLOWED=NO`) and pass all simulated lighting & exposure QA assertions in `Photobooth2/verify_qa.swift` and `AutomatedVerificationSuite` (`Photobooth2/Sources/Verification/AutomatedVerificationSuite.swift`):

```bash
# 1. Run the Simulated Lighting & Exposure Scaling QA Unit Tests directly via Swift CLI:
swift Photobooth2/verify_qa.swift

# 2. Verify clean iOS Device & Simulator compilation:
xcodebuild -project Photobooth2/Photobooth2.xcodeproj -scheme Photobooth2 -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

### 1.1 Simulated Lighting & Exposure Scaling QA (`runLightingAndExposureQATests`)
1. **Low-Light Manual / Mode `"1"` (`ISO 200`, `1/125s` without flash)**:
   - Synthesizes a dark scene (`subjectSrgbY < 0.04`) with a dark background (`RGB = (2, 2, 3)`), warm skin tone (`RGB = (18, 12, 8)`), cool shirt (`RGB = (7, 13, 20)`), shadow step ramp (`1, 2, 4, 8, 16 / 255`), and small specular background light (`< 2%` of pixels).
   - **Verified Assertions**:
     - Scene brightness lifts from `< 0.04` into the target midtone range (`0.25 <= postSrgbY <= 0.52`), and the 90th-percentile highlight stays un-clipped (`p90 < 0.85`).
     - **Color Preservation**: Warm skin pixels retain `R > G > B` (`R - B >= 15`, `< 235`) and cool shirt pixels retain `B > G > R` (`B - R >= 12`, `< 235`), ensuring low-light captures never clip into a black-and-white stencil.
     - **Smooth Shadow Gradation**: Dark shadow steps (`1, 2, 4, 8, 16 / 255`) map monotonically to intermediate gray values (`< 210 / 255`) without 1-bit block quantization.
2. **Decent Light / Dim Auto-ISO `12800` ("A little dim on camera, but viewable")**:
   - Synthesizes a moderately dim scene (`subjectSrgbY ~ 0.31`, `p90 ~ 0.55`) with warm room walls (`RGB = (62, 55, 48)`) and viewable forehead/face highlights (`RGB = (155, 136, 120)`).
   - **Verified Assertions**:
     - Scene receives a gentle midtone lift (`postSrgbY > preSrgbY`, `<= 0.45`) while 90th-percentile highlights remain protected (`p90 < 0.82`, face `< 220 / 255` with `R > G > B` preserved) so faces and walls never blow out.
3. **Threshold Continuity (`0.36..0.45` sRGB)**:
   - Sweeps input scene brightness across the `0.42` sRGB trigger threshold and asserts `maxStepDelta < 0.030`, guaranteeing zero step jump between adjacent frames.
4. **4-Frame GIF Burst Exposure Equalization & Instant In-App Decoding**:
   - Synthesizes a 4-frame burst where Frames 1–3 are at `~0.41` sRGB and Frame 4 drifted brighter to `~0.52` sRGB (simulating Aperture Priority frame-to-frame drift).
   - **Verified Assertions**:
     - `GIFService.createGIF` equalizes all 4 frames to the burst median (`maxLuma - minLuma < 0.030`).
     - `GIFPlayerView.loadAnimatedImage` synchronously decodes all 4 frames into an animated `UIImage` in `< 100ms` (eliminating the black `WKWebView` startup delay).
     - `sony_<UUID>.jpg` files are auto-exposed **once** (never double-boosted in `StateMachine.startReviewSequence` or `GIFService.createGIF`).

### 1.2 Sony PTP Protocol & StateMachine Concurrency QA (`runTier2Tests` & `runTier3Tests`)
- **Tier 2**: Binary framing (`SDIO_Connect`, Little-Endian `UInt8`/`UInt16` payloads, `0xFFFFC002` Live View extraction, `0xD215` `ObjectInMemory` parsing).
- **Tier 3**: 3-phase Sony PTP handshake (`0xD268 = 2M`, `0xD222 = 0x0011`, `0xD231 = 2` Setting Effect OFF, `0xD25A = 0` dial unlock), mode-based storage routing (`PC+Camera` for standard photos vs `PC Only` for GIF frames), pre-capture buffer drain, zero Live View interleaving during capture, `1.5s` USB disconnect debounce + automatic recovery, and immediate `2MP` `/tmp` file cleanup after review/AirDrop.

---

## 2. Hardware Verification Checklist (iPad + Sony USB-C PTP)

### Test 2.1: Zero-Touch USB Connection on Launch / Sideload
1. Plug the Sony camera (powered ON, PC Remote mode) into the USB-C hub connected to the iPad **before** sideloading or launching `Photobooth2`.
2. Launch `Photobooth2`.
3. **Expected Result**: Even if iPadOS `icdd` takes a few seconds to release the prior process's USB session, `SonyUSBCameraClient.startAutoDiscoveryLoop` and `StateMachine`'s `errorAutoRetryTask` automatically cycle `ICDeviceBrowser` and transition to Live View (`Idle`) within 2–5 seconds without physically unplugging or replugging the cable.

### Test 2.2: Low-Light Manual / Mode `"1"` Capture & GIF
1. Set the camera mode dial to `"1"` (or `M` at `1/125s`, `f/5.6`–`f/8`, `ISO 200` without flash).
2. Verify Live View is bright and clear (`0xD231 = 2` Setting Effect OFF + single-pass Live View curve).
3. Take both a **Photo** session and a **GIF** session.
4. **Expected Result**:
   - Photo Review and saved GIF frames are brightened to natural midtones with preserved skin/room colors and expected low-light grain (never 1-bit black-and-white blocks).
   - In-app GIF Review plays all 4 frames immediately (never a black screen).

### Test 2.3: Auto-ISO `12800` & Aperture Priority Capture
1. Test with Auto-ISO (`12800`) in a dim room and with Aperture Priority in normal lighting.
2. **Expected Result**:
   - Dim Auto-ISO captures are gently brightened in Review and GIFs without blowing out faces or walls.
   - All 4 frames in an Aperture Priority GIF have uniform, locked brightness with no 4th-frame exposure jump.

