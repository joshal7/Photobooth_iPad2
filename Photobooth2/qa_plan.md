# Photobooth2 App QA Plan

Use this guide to validate the robustness of the Photobooth2 app, specifically focusing on connection stability and recovery.

## 1. Connection Robustness

### Test 1.1: Active Disconnect (Simulated Crash)
**Goal:** Verify the app detects when the camera app is closed or crashes.
1.  Connect iPad to Sony Camera Wi-Fi.
2.  Open Photobooth App and ensure Live View is active.
3.  **Action:** On the Sony Camera, press the "Menu" or "Exit" button to close the "Smart Remote Control" app.
4.  **Expected Result:** Within 5 seconds, the iPad app should show the "Connect to Camera Wi-Fi" (or Mismatch) screen.
5.  **Recovery:** Re-open "Smart Remote Control" on the camera. The iPad should eventually reconnect (or tap "Try Anyway").

### Test 1.2: Wi-Fi Drop (Range/Interference)
**Goal:** Verify the app handles Wi-Fi signal loss.
1.  Ensure Live View is active.
2.  **Action:** Walk the iPad out of range of the camera (or turn off the camera).
3.  **Expected Result:** The Live View may freeze, and within ~5-10 seconds, the app should show the connection prompt.
4.  **Recovery:** Walk back in range (or turn camera on). Ensure the iPad re-joins the *Camera's* Wi-Fi (check iOS Settings if needed). App should recover.

### Test 1.3: Background/Foreground Cycle
**Goal:** Verify connection persists after app backgrounding.
1.  Ensure Live View is active.
2.  **Action:** Press Home button on iPad to background the app. Wait 30 seconds.
3.  **Action:** Re-open Photobooth App.
4.  **Expected Result:** App should immediately resume Live View (or reconnect within 1-2 seconds).

## 2. Capture Stability

### Test 2.1: Rapid Fire
**Goal:** Verify no crashes during fast capture sequences.
1.  Set "Photo Count" to 3 and "Between Shots" to 1s.
2.  **Action:** Start a capture sequence.
3.  **Expected Result:** All 3 photos taken with minimal lag. No crashes. All photos saved to iPad Photos app.

### Test 2.2: Long Duration (Soak Test)
**Goal:** Verify stability over time.
1.  Leave the app in "Idle" (Live View) mode for 30 minutes.
2.  **Action:** Come back and trigger a capture.
3.  **Expected Result:** App should still be connected and capture immediately. If it disconnected, it should have auto-recovered or be showing the prompt.

## 3. Configuration & Reset

### Test 3.1: Reset to Defaults
**Goal:** Verify reset enforces Wi-Fi check.
1.  Connect iPad to Home Wi-Fi (NOT Camera).
2.  Go to Settings -> Reset to Defaults.
3.  **Expected Result:** App switches to "Sony Camera" mode and **immediately** shows the "Connect to Camera Wi-Fi" screen.

## Reporting Issues
If you encounter any errors, please note:
- **What happened?** (e.g., "App froze", "Showed error X")
- **What were you doing?** (e.g., "Just finished a photo", "App was idle")
- **Time of occurrence** (helps trace logs)
