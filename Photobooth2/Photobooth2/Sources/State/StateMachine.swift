import Foundation
import Combine
import SwiftUI
import Photos

enum AppState: Equatable {
    case initialization
    case idle
    case capture(count: Int)
    case processing(message: String)
    case review(images: [String], index: Int)
    case error(message: String)
    case wifiMismatch(targetSSID: String)
    case sharingPrompt(images: [String])
    case airDrop(images: [String])
}

enum CaptureMode: Equatable {
    case standard
    case gif
}
@MainActor
class StateMachine: ObservableObject {
    @Published var state: AppState = .initialization
    @Published var previewImage: UIImage?
    @Published var currentReviewImage: UIImage?
    @Published var capturedImages: [String] = []
    @Published var countdown: Int = 0
    @Published var isFlashing: Bool = false
    @Published var showGuidance: Bool = false
    @Published var currentPhotoNumber: Int = 0
    @Published var captureMode: CaptureMode = .standard
    @Published var poseIndicator: String? = nil
    
    private var cameraService: CameraService
    private let config: ConfigManager
    private var cancellables = Set<AnyCancellable>()
    private var heartbeatTimer: Timer?
    private var bypassWifiCheck: Bool = false
    
    init() {
        self.config = ConfigManager.shared
        
        // Initialize service based on config
        if config.useLocalCamera {
            self.cameraService = LocalCameraClient()
        } else {
            self.cameraService = SonyCameraClient(config: config)
        }
        
        setupBindings()
        setupHeartbeat()
    }
    
    private func setupBindings() {
        // Listen for config changes to switch camera service
        config.$useLocalCamera
            .dropFirst()
            .sink { [weak self] useLocal in
                Task { @MainActor [weak self] in
                    self?.switchCameraService(useLocal: useLocal)
                }
            }
            .store(in: &cancellables)
            
        bindPreviewStream()
    }
    
    private func bindPreviewStream() {
        // Subscribe to the current service's preview stream
        cameraService.previewStream
            .receive(on: DispatchQueue.main)
            .assign(to: \.previewImage, on: self)
            .store(in: &cancellables)
    }
    
    private func switchCameraService(useLocal: Bool) {
        // Stop current service
        cameraService.stopLiveView()
        
        // Switch service
        if useLocal {
            self.cameraService = LocalCameraClient()
            // Disconnect from camera Wi-Fi to allow fallback to home Wi-Fi
            WifiManager.shared.disconnectFromCameraWifi(ssid: config.cameraSSID)
        } else {
            self.cameraService = SonyCameraClient(config: config)
            // Auto-connect to camera Wi-Fi
            Task {
                try? await WifiManager.shared.connectToCameraWifi(ssid: config.cameraSSID, password: config.cameraPassword)
            }
        }
        
        // Re-bind stream
        bindPreviewStream()
        
        // Reset bypass flag to enforce checks
        bypassWifiCheck = false
        
        // Re-initialize
        transition(to: .initialization)
    }
    
    func start() {
        transition(to: .initialization)
    }
    
    func handleAppDidBecomeActive() {
        Task { @MainActor in
            print("App became active, checking connection...")
            
            // Only restart if we are in a state that expects a live view
            if case .idle = state {
                // Check connection first
                let isConnected = await cameraService.checkConnection()
                if isConnected {
                    // Restart live view
                    print("Connection healthy, restarting live view")
                    try? await cameraService.startLiveView()
                } else {
                    // Connection lost while backgrounded
                    print("Connection lost while backgrounded")
                    if !config.useLocalCamera {
                        transition(to: .wifiMismatch(targetSSID: config.cameraSSID))
                    } else {
                        transition(to: .error(message: "Camera disconnected"))
                    }
                }
            } else if case .wifiMismatch = state {
                // If we were already mismatching, check again
                if !config.useLocalCamera {
                    transition(to: .wifiMismatch(targetSSID: config.cameraSSID))
                }
            }
        }
    }
    
    func transition(to newState: AppState) {
        print("Transitioning to: \(newState)")
        self.state = newState
        
        switch newState {
        case .initialization:
            Task { await initializeCamera() }
            
        case .idle:
            Task { await startLiveView() }
            
        case .capture:
            Task {
                if self.captureMode == .gif {
                     await startGIFCaptureSequence()
                } else {
                    await startCaptureSequence()
                }
            }
            
        case .processing:
            break
            
        case .review(let images, _):
            if images.isEmpty {
                transition(to: .idle)
            } else {
                Task { await startReviewSequence() }
            }
            
        case .error:
            break
            
        case .wifiMismatch(let targetSSID):
            Task { await monitorWifiConnection(targetSSID: targetSSID) }
            
        case .sharingPrompt(_):
            // Start 10s timeout
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                await MainActor.run {
                    if case .sharingPrompt = self.state {
                        self.transition(to: .idle)
                    }
                }
            }
            
        case .airDrop:
            break // Handled by UI interactions
        }
    }
    
    // MARK: - Actions
    
    private func initializeCamera() async {
        // If using external camera, check Wi-Fi first
        if !config.useLocalCamera && !bypassWifiCheck {
            let currentSSID = await WifiManager.shared.getCurrentSSID()
            
            // Strict check: If SSID is nil (unknown) OR doesn't match, show prompt.
            // This avoids the long timeout if we are not connected.
            if currentSSID != config.cameraSSID {
                print("Wi-Fi Mismatch: Current: \(String(describing: currentSSID)), Target: \(config.cameraSSID)")
                transition(to: .wifiMismatch(targetSSID: config.cameraSSID))
                return
            }
        }
        
        // Reset bypass flag for next time
        bypassWifiCheck = false

        do {
            try await cameraService.connect()
            await startLiveView()
            transition(to: .idle)
        } catch {
            // If connection fails and we are external, maybe we are on wrong wifi?
            if !config.useLocalCamera {
                 transition(to: .wifiMismatch(targetSSID: config.cameraSSID))
            } else {
                transition(to: .error(message: "Failed to connect to camera: \(error.localizedDescription)"))
            }
        }
    }
    
    func forceConnection() {
        bypassWifiCheck = true
        transition(to: .initialization)
    }
    
    private func monitorWifiConnection(targetSSID: String) async {
        while case .wifiMismatch = state {
            // 1. Check SSID (Fastest)
            let currentSSID = await WifiManager.shared.getCurrentSSID()
            if currentSSID == targetSSID {
                print("SSID Matched: \(targetSSID)")
                transition(to: .initialization)
                return
            }
            
            // 2. Probe Camera (Robust fallback)
            // Even if SSID is nil or wrong (e.g. permission issue), try to reach the camera.
            // We use a short timeout to avoid blocking.
            if await probeCameraConnection() {
                print("Camera Probe Successful! Force connecting...")
                forceConnection()
                return
            }
            
            // Poll every 2 seconds
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
    
    private func probeCameraConnection() async -> Bool {
        // Construct a simple URL to check reachability.
        // Sony cameras usually have a DD.xml or similar, but checking the root or /sony might work.
        // We'll try the endpoint URL.
        guard let url = URL(string: config.cameraEndpoint) else { return false }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 1.0 // Short timeout for probing
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if response is HTTPURLResponse {
                // If we get ANY response (even 404 or 500), it means the device is reachable.
                // Sony cameras might return 200 or 403/404 depending on the path.
                return true
            }
        } catch {
            // Ignore errors
        }
        return false
    }
    
    private func startLiveView() async {
        do {
            try await cameraService.startLiveView()
        } catch {
            print("Failed to start live view: \(error)")
        }
    }
    
    func triggerCapture(mode: CaptureMode = .standard) {
        guard case .idle = state else { return }
        self.captureMode = mode
        transition(to: .capture(count: 0))
    }
    
    func selectAirDrop() {
        if case .sharingPrompt(let images) = state {
            transition(to: .airDrop(images: images))
        }
    }
    
    func selectTextLater() {
        // Removed
    }
    
    func skipSharing() {
        transition(to: .idle)
    }
    
    func submitPhoneNumber(_ number: String) {
        // Removed
    }
    

    private func startCaptureSequence() async {
        capturedImages.removeAll()
        
        let totalPhotos = config.photoCount
        var previousCaptureTask: Task<Void, Never>? = nil
        
        for i in 0..<totalPhotos {
            // 1. Wait for previous capture to finish (if any)
            // We do this BEFORE the countdown to ensure that once the countdown starts,
            // nothing stops us from triggering at 0.
            if let task = previousCaptureTask {
                _ = await task.result
                // If previous capture failed (transitioned to error), abort sequence
                if case .error = state { return }
            }
            
            // 2. Countdown
            var countTime: Int
            
            if i == 0 {
                // First photo: Show guidance first (if enabled), then countdown
                if config.showGuidanceText {
                    self.showGuidance = true
                    // Wait 3 seconds for guidance
                    for _ in 0..<3 {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                    self.showGuidance = false
                    
                    // Set photo number AFTER guidance completes
                    self.currentPhotoNumber = i + 1
                    
                    // Calculate remaining countdown
                    // Reduce initial countdown by 3s, but ensure minimum of 3s
                    countTime = max(3, config.initialCountdownSec - 3)
                } else {
                    // Guidance disabled, set photo number immediately
                    self.currentPhotoNumber = i + 1
                    // Guidance disabled, use full initial countdown
                    countTime = config.initialCountdownSec
                }
            } else {
                // Subsequent photos - number was already set at end of previous iteration
                // (after flash fade completed)
                countTime = config.interShotCountdownSec
            }
            
            // Run countdown
            for t in (1...countTime).reversed() {
                // Abort if error occurred externally
                if case .error = state { return }
                
                self.countdown = t
                
                // Hide photo counter when countdown reaches 1
                if t == 1 {
                    self.currentPhotoNumber = 0
                }
                
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            self.countdown = 0
            
            

            
            // 3. Trigger & Flash
            // Start flash immediately (no fade in)
            withAnimation(.linear(duration: 0)) { self.isFlashing = true }
            
            // Schedule flash to end
            Task {
                // Hold white for 0.5s
                try? await Task.sleep(nanoseconds: 500_000_000)
                
                await MainActor.run {
                    // Fade out over 0.5s
                    withAnimation(.easeIn(duration: 0.5)) { self.isFlashing = false }
                }
            }
            
            // 4. Start Capture in Background
            // We start this task and move immediately to the next loop iteration (next countdown)
            // The next iteration will await this task before triggering *its* capture.
            previousCaptureTask = Task {
                var retries = 5
                var captureSuccess = false
                
                while retries > 0 && !captureSuccess {
                    do {
                        print("Triggering capture at \(Date())")
                        let urls = try await cameraService.takePicture()
                        print("Capture returned at \(Date())")
                        
                        await MainActor.run {
                            if let first = urls.first {
                                self.capturedImages.append(first)
                            }
                        }
                        
                        self.saveToPhotoLibrary(urls: urls)
                        captureSuccess = true
                        
                    } catch let error as CameraError {
                        if case .apiError(let code, _) = error, code == 1 {
                            print("Camera busy (Error 1). Retrying in 2s...")
                            retries -= 1
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                        } else {
                            print("Camera Error: \(error)")
                            await MainActor.run {
                                transition(to: .error(message: "Capture Failed: \(error.localizedDescription)"))
                            }
                            return
                        }
                    } catch let error as URLError {
                        if error.code == .timedOut || error.code == .networkConnectionLost || error.code == .notConnectedToInternet {
                            print("Network error (\(error.code.rawValue)). Retrying in 2s...")
                            retries -= 1
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                        } else {
                             print("Network Error: \(error)")
                             await MainActor.run {
                                 transition(to: .error(message: "Network Error: \(error.localizedDescription)"))
                             }
                             return
                        }
                    } catch {
                        print("Unexpected error: \(error)")
                         await MainActor.run {
                             transition(to: .error(message: "Error: \(error.localizedDescription)"))
                         }
                         return
                    }
                }
                
                if !captureSuccess {
                     await MainActor.run {
                         transition(to: .error(message: "Failed to capture photo after multiple attempts. Check camera connection."))
                     }
                }
            }
            
            // Wait for flash to finish fading before starting next countdown visual
            // The flash takes 1.0s total (0.5 hold + 0.5 fade).
            // We want the next countdown to start *after* the fade is done.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            
            // Set the next photo number if there is one (for subsequent photos)
            // This will appear as soon as the flash fade completes
            if i + 1 < totalPhotos {
                self.currentPhotoNumber = i + 2  // Next photo number (1-indexed)
            }
        }
        
        // Wait for the final capture to finish
        if let task = previousCaptureTask {
            _ = await task.result
        }
        
        // Clear photo counter
        self.currentPhotoNumber = 0
        
        // Clear photo counter
        self.currentPhotoNumber = 0
        
        transition(to: .review(images: capturedImages, index: 0))
    }
    
    private func startGIFCaptureSequence() async {
        print("Starting GIF Capture Sequence")
        capturedImages.removeAll()
        
        // 1. Countdown
        var countTime: Int = config.initialCountdownSec
        
        // Guidance
        if config.showGuidanceText {
            self.showGuidance = true
            // Wait 3 seconds for guidance
            for _ in 0..<3 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            self.showGuidance = false
            
            // Calculate remaining countdown
            countTime = max(3, config.initialCountdownSec - 3)
        }
        
        // Run countdown
        for t in (1...countTime).reversed() {
            self.countdown = t
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        self.countdown = 0
        
        // Trigger Flash
        withAnimation(.linear(duration: 0)) { self.isFlashing = true }
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.5)) { self.isFlashing = false }
            }
        }
        
        // 2. Burst Capture
        let frameCount = config.gifFrameCount
        let interval = config.gifCaptureInterval
        
        if config.useLocalCamera {
            // iPad Camera: Use existing adaptive loop
            for i in 0..<frameCount {
                do {
                    if i == 0 {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                    
                    let startTime = Date()
                    print("Triggering GIF frame \(i+1)")
                    let urls = try await cameraService.takePicture()
                    if let first = urls.first {
                        capturedImages.append(first)
                    }
                    
                    let elapsed = Date().timeIntervalSince(startTime)
                    let remaining = max(0, interval - elapsed)
                    if remaining > 0 {
                         try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    }
                } catch {
                    print("Failed to capture GIF frame \(i): \(error)")
                }
            }
        } else {
            // External Camera (Sony): Robust loop with parallel UI updates
            let poseNames = ["Second", "Third", "Fourth", "Fifth", "Sixth", "Seventh", "Eighth", "Ninth", "Tenth"]
            
            for i in 0..<frameCount {
                var retries = 5
                var captureSuccess = false
                
                while retries > 0 && !captureSuccess {
                    do {
                        // Clear pose indicator right before trigger
                        await MainActor.run { self.poseIndicator = nil }
                        
                        if i == 0 && retries == 5 {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                        }
                        
                        print("Triggering GIF frame \(i+1) (Sony)...")
                        
                        // Parallel UI Update: trigger capture but show next pose while processing
                        let currentI = i
                        async let captureTask = cameraService.takePicture()
                        
                        // In parallel, wait 1s (shutter fired) then show next pose prompt
                        if currentI < frameCount - 1 && currentI < poseNames.count {
                            Task {
                                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s after shutter
                                await MainActor.run {
                                    self.poseIndicator = "\(poseNames[currentI]) Pose"
                                }
                            }
                        }
                        
                        let urls = try await captureTask
                        if let first = urls.first {
                            capturedImages.append(first)
                            print("Frame \(i+1) captured successfully")
                            captureSuccess = true
                        }
                    } catch let error as CameraError {
                        if case .apiError(let code, _) = error, code == 1 {
                            print("Camera busy (Error 1). Retrying in 2s...")
                            retries -= 1
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                        } else {
                            await MainActor.run { self.isFlashing = false; self.poseIndicator = nil }
                            transition(to: .error(message: "Capture Failed: \(error.localizedDescription)"))
                            return
                        }
                    } catch let error as URLError {
                        if error.code == .timedOut || error.code == .networkConnectionLost || error.code == .notConnectedToInternet {
                            print("Network error (\(error.code.rawValue)). Retrying in 2s...")
                            retries -= 1
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                        } else {
                            await MainActor.run { self.isFlashing = false; self.poseIndicator = nil }
                            transition(to: .error(message: "Capture Failed: \(error.localizedDescription)"))
                            return
                        }
                    } catch {
                        print("Unexpected error during capture: \(error)")
                        await MainActor.run { self.isFlashing = false; self.poseIndicator = nil }
                        transition(to: .error(message: "Capture Failed: \(error.localizedDescription)"))
                        return
                    }
                }
                
                if !captureSuccess {
                    print("Failed to capture frame \(i+1) after all retries")
                    await MainActor.run { self.isFlashing = false; self.poseIndicator = nil }
                    transition(to: .error(message: "Camera connection lost. Please check Wi-Fi and restart the camera."))
                    return
                }
            }
            
            // Final cleanup
            await MainActor.run { self.poseIndicator = nil }
        }
        
        // 3. Transfer & Processing
        transition(to: .processing(message: "Downloading images..."))
        
        var tempPaths: [String] = []
        
        for (index, urlString) in capturedImages.enumerated() {
             await MainActor.run {
                if case .processing = self.state {
                    self.state = .processing(message: "Downloading \(index + 1) of \(capturedImages.count)...")
                }
            }
            
            do {
                let data = try await cameraService.fetchImage(url: urlString)
                
                let filename = UUID().uuidString + ".jpg"
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                try data.write(to: tempURL)
                tempPaths.append(tempURL.path)
            } catch {
                print("Failed to download image \(index): \(error)")
            }
        }
        
        // 4. Create GIF
        await MainActor.run {
             self.state = .processing(message: "Creating GIF...")
        }
        
        let gifDuration = config.gifFrameDuration
        let gifResolution = config.gifResolution
        
        let gifURL = await Task.detached(priority: .userInitiated) {
            return GIFService.createGIF(from: tempPaths, frameDuration: gifDuration, resolution: gifResolution)
        }.value
        
        // Clean up temporary source frame files from disk
        cleanupTempFiles(tempPaths)
        
        if !config.useLocalCamera {
            // Defer the deletion to avoid 20-30s Wi-Fi drops mid-session
            let frameCount = capturedImages.count
            await MainActor.run {
                config.pendingGIFFramesToDelete += frameCount
            }
        }
        
        guard let finalGIFURL = gifURL else {
            transition(to: .error(message: "Failed to create GIF"))
            return
        }
        
        // 5. Save to Photos — only the final GIF, not the individual source frames
        if config.saveToPhotos {
            saveLocalFilesToLibrary(urls: [finalGIFURL])
        }
        
        // 6. Review
        // ONLY pass the GIF for review, as requested
        let reviewItems = [finalGIFURL.absoluteString]
        
        transition(to: .review(images: reviewItems, index: 0))
    }
    
    private func saveLocalFilesToLibrary(urls: [URL]) {
        Task.detached(priority: .background) {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { return }
            
            try? await PHPhotoLibrary.shared().performChanges {
                for url in urls {
                    let creationRequest = PHAssetCreationRequest.forAsset()
                    if url.pathExtension.lowercased() == "gif" {
                         creationRequest.addResource(with: .photo, fileURL: url, options: nil)
                    } else {
                         creationRequest.addResource(with: .photo, fileURL: url, options: nil)
                    }
                }
            }
        }
    }
    
    /// Removes temporary source frame files from disk after GIF creation.
    private func cleanupTempFiles(_ paths: [String]) {
        for path in paths {
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                print("Failed to clean up temp file at \(path): \(error)")
            }
        }
    }
    
    private func saveToPhotoLibrary(urls: [String]) {
        guard config.saveToPhotos else { return }
        let service = self.cameraService
        
        Task.detached(priority: .background) {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { return }
            
            for urlString in urls {
                do {
                    let data = try await service.fetchImage(url: urlString)
                    
                    try await PHPhotoLibrary.shared().performChanges {
                        let creationRequest = PHAssetCreationRequest.forAsset()
                        creationRequest.addResource(with: .photo, data: data, options: nil)
                    }
                } catch {
                    print("Failed to save photo: \(error)")
                }
            }
        }
    }

    private func startReviewSequence() async {
        guard case .review(let images, _) = state else { return }
        
        for i in 0..<images.count {
            self.state = .review(images: images, index: i)
            self.currentReviewImage = nil
            
            if images[i].lowercased().hasSuffix(".gif") {
                 try? await Task.sleep(nanoseconds: UInt64(config.gifPreviewDuration) * 1_000_000_000)
                 continue
            }

            do {
                let data = try await cameraService.fetchImage(url: images[i])
                if let image = UIImage(data: data) {
                    self.currentReviewImage = image
                    try? await Task.sleep(nanoseconds: UInt64(config.previewDurationSec) * 1_000_000_000)
                } else {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            } catch {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        
        if config.enableImageSharing {
            var shareItems = images
            
            // If in GIF mode, ensure we also share the source images (which were hidden from review)
            if self.captureMode == .gif {
                // Determine source images. We have them in 'capturedImages' (remote URLs) or 'tempPaths'
                // But ShareSheet logic handles downloads.
                // However, wait: capturedImages contians REMOTE URLs. tempPaths were local.
                // startGIFCaptureSequence downloaded them to tempPaths.
                // capturedImages has the remote URLs.
                // If we pass remote URLs to SharingViews, it will download them AGAIN.
                // Better to use the local tempPaths if we can.
                // But StateMachine doesn't persist `tempPaths` instance variable.
                // We should probably rely on `capturedImages` (remote) and let SharingView re-download? 
                // Or: Since we just downloaded them to tempPaths, passing the remote URLs is inefficient.
                // But we lost tempPaths scope.
                // Compromise: Pass `capturedImages` (remote). SharingViews logic handles download.
                // Ideally, we'd pass the temp paths.
                shareItems.append(contentsOf: self.capturedImages)
            }
            
            transition(to: .sharingPrompt(images: shareItems))
        } else {
            transition(to: .idle)
        }
    }
    
    func retryConnection() {
        transition(to: .initialization)
    }
    
    // MARK: - Heartbeat
    
    private func setupHeartbeat() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if case .error = self.state { return }
                if case .initialization = self.state { return }
                
                // Check connection status
                let isConnected = await self.cameraService.checkConnection()
                
                if !isConnected {
                    print("Heartbeat: Connection lost!")
                    // If we lose connection, treat it as a Wi-Fi mismatch/disconnect
                    // This will prompt the user to reconnect
                    if !self.config.useLocalCamera {
                        self.transition(to: .wifiMismatch(targetSSID: self.config.cameraSSID))
                    } else {
                        // For local camera, this shouldn't happen, but good to handle
                        self.transition(to: .error(message: "Camera disconnected"))
                    }
                }
            }
        }
    }
}
