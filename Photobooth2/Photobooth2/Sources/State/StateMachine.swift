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
    case sharingPrompt(images: [String])
    case airDrop(images: [String])
    case emailSharing(images: [String])
}

nonisolated enum CaptureMode: Equatable, Sendable {
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
    @Published var isVignetteFlashing: Bool = false
    @Published var showGuidance: Bool = false
    @Published var currentPhotoNumber: Int = 0
    @Published var currentGIFFrameIndex: Int = 0
    @Published var gifPerimeterProgress: CGFloat = 0.0
    @Published var captureMode: CaptureMode = .standard
    @Published var poseIndicator: String? = nil
    @Published var isCameraConnected: Bool = false
    @Published var cameraStatusMessage: String? = nil
    @Published var lowStorageWarning: String? = nil
    @Published var selectedBackdrop: BackdropItem = .none {
        didSet {
            if oldValue.id != selectedBackdrop.id {
                BackdropCompositorService.resetLiveTemporalState()
            }
            cameraService.updateSelectedBackdrop(selectedBackdrop)
        }
    }
    @Published var isBackdropPickerExpanded: Bool = false
    
    private var cameraService: CameraService
    private let hasInjectedCameraService: Bool
    private let config: ConfigManager
    private var cancellables = Set<AnyCancellable>()
    private var serviceCancellables = Set<AnyCancellable>()
    private var activeStateTask: Task<Void, Never>?
    private var stateGeneration: UInt64 = 0
    private var disconnectDebounceTask: Task<Void, Never>?
    private var sharingPromptTimeoutTask: Task<Void, Never>?
    private var errorAutoRetryTask: Task<Void, Never>?
    
    init(cameraService: CameraService? = nil, config: ConfigManager? = nil) {
        let resolvedConfig = config ?? ConfigManager.shared
        self.config = resolvedConfig
        self.hasInjectedCameraService = (cameraService != nil)
        
        if let injectedService = cameraService {
            self.cameraService = injectedService
        } else if resolvedConfig.useLocalCamera {
            self.cameraService = LocalCameraClient()
        } else {
            self.cameraService = SonyUSBCameraClient()
        }
        
        let initialBackdrop = BackdropManager.shared.backdrop(forID: resolvedConfig.defaultBackdropID)
        self.selectedBackdrop = initialBackdrop
        self.cameraService.updateSelectedBackdrop(initialBackdrop)
        
        setupBindings()
    }
    
    deinit {
        activeStateTask?.cancel()
        disconnectDebounceTask?.cancel()
        sharingPromptTimeoutTask?.cancel()
        errorAutoRetryTask?.cancel()
    }
    
    private func isCurrentExecution(_ generation: UInt64) -> Bool {
        return !Task.isCancelled && self.stateGeneration == generation
    }
    
    private var isInCaptureState: Bool {
        if case .capture = state { return true }
        return false
    }
    
    private func setupBindings() {
        config.$useLocalCamera
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] useLocal in
                Task { @MainActor [weak self] in
                    guard let self = self, !self.hasInjectedCameraService else { return }
                    self.switchCameraService(useLocal: useLocal)
                }
            }
            .store(in: &cancellables)
            
        config.$defaultBackdropID
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newDefaultID in
                let applyChange = { @MainActor [weak self] in
                    guard let self = self else { return }
                    if case .idle = self.state {
                        self.selectedBackdrop = BackdropManager.shared.backdrop(forID: newDefaultID)
                    }
                }
                if Thread.isMainThread {
                    MainActor.assumeIsolated { applyChange() }
                } else {
                    Task { @MainActor in applyChange() }
                }
            }
            .store(in: &cancellables)
            
        config.$persistentBackdropSelection
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] isPersistent in
                let applyChange = { @MainActor [weak self] in
                    guard let self = self else { return }
                    if !isPersistent {
                        switch self.state {
                        case .capture, .processing:
                            break
                        default:
                            self.selectedBackdrop = BackdropManager.shared.backdrop(forID: self.config.defaultBackdropID)
                        }
                    }
                }
                if Thread.isMainThread {
                    MainActor.assumeIsolated { applyChange() }
                } else {
                    Task { @MainActor in applyChange() }
                }
            }
            .store(in: &cancellables)
            
        BackdropManager.shared.$availableBackdrops
            .dropFirst()
            .sink { [weak self] available in
                let applyChange = { @MainActor [weak self] in
                    guard let self = self else { return }
                    if let updated = available.first(where: { $0.id == self.selectedBackdrop.id && ($0.id == BackdropItem.noneID || $0.isEnabled) }) {
                        if updated != self.selectedBackdrop {
                            self.selectedBackdrop = updated
                        }
                    } else {
                        self.selectedBackdrop = BackdropManager.shared.backdrop(forID: self.config.defaultBackdropID)
                    }
                }
                if Thread.isMainThread {
                    MainActor.assumeIsolated { applyChange() }
                } else {
                    Task { @MainActor in applyChange() }
                }
            }
            .store(in: &cancellables)
            
        _ = EmailQueueService.shared
        bindCameraStreams()
    }
    
    func selectBackdrop(_ backdrop: BackdropItem) {
        self.selectedBackdrop = backdrop
    }
    
    private func bindCameraStreams() {
        serviceCancellables.removeAll()
        self.isCameraConnected = cameraService.isConnected
        self.cameraStatusMessage = cameraService.statusMessage
        
        cameraService.previewStream
            .receive(on: DispatchQueue.main)
            .assign(to: \.previewImage, on: self)
            .store(in: &serviceCancellables)
        
        if let sonyClient = cameraService as? SonyUSBCameraClient {
            sonyClient.$statusMessage
                .receive(on: DispatchQueue.main)
                .assign(to: \.cameraStatusMessage, on: self)
                .store(in: &serviceCancellables)
        }
        
        cameraService.connectionStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                guard let self = self else { return }
                self.isCameraConnected = connected
                self.cameraStatusMessage = self.cameraService.statusMessage
                self.handleConnectionStatusChange(connected)
            }
            .store(in: &serviceCancellables)
    }
    
    private func handleConnectionStatusChange(_ connected: Bool) {
        if connected {
            // Cancel any pending disconnect debounce
            disconnectDebounceTask?.cancel()
            disconnectDebounceTask = nil
            
            // Zero-touch auto-recovery if camera was reconnected or powered on while on error/init screen
            if case .error = state {
                transition(to: .idle)
            } else if case .initialization = state, stateGeneration > 0, activeStateTask == nil {
                transition(to: .idle)
            }
        } else {
            // 1.5-second debounce before showing an error on transient USB cable glitches
            disconnectDebounceTask?.cancel()
            disconnectDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s debounce
                guard let self = self, !Task.isCancelled else { return }
                guard !self.cameraService.isConnected else { return }
                
                switch self.state {
                case .idle, .capture:
                    let msg = self.cameraService.statusMessage ?? CameraError.connectionFailed.localizedDescription
                    self.transition(to: .error(message: msg))
                default:
                    break
                }
            }
        }
    }
    
    private func switchCameraService(useLocal: Bool) {
        activeStateTask?.cancel()
        activeStateTask = nil
        disconnectDebounceTask?.cancel()
        disconnectDebounceTask = nil
        sharingPromptTimeoutTask?.cancel()
        sharingPromptTimeoutTask = nil
        errorAutoRetryTask?.cancel()
        errorAutoRetryTask = nil
        if let sonyClient = cameraService as? SonyUSBCameraClient {
            sonyClient.shutdown()
        } else {
            cameraService.stopLiveView()
        }
        
        if useLocal {
            self.cameraService = LocalCameraClient()
        } else {
            self.cameraService = SonyUSBCameraClient()
        }
        
        self.cameraService.updateSelectedBackdrop(self.selectedBackdrop)
        bindCameraStreams()
        transition(to: .initialization)
    }
    
    func start() {
        purgeOrphanedTempFilesAndCheckStorage()
        transition(to: .initialization)
    }
    
    func handleAppDidEnterBackground() {
        cameraService.stopLiveView()
    }
    
    func handleAppDidBecomeActive() {
        EmailQueueService.shared.notifyConfigurationUpdated()
        Task { @MainActor in
            if case .idle = state {
                let isConnected = await cameraService.checkConnection()
                if isConnected {
                    try? await cameraService.startLiveView()
                } else {
                    transition(to: .initialization)
                }
            } else if case .error = state {
                if await cameraService.checkConnection() {
                    transition(to: .idle)
                }
            }
        }
    }
    
    func transition(to newState: AppState) {
        print("Transitioning to: \(newState)")
        let previousState = self.state
        
        // Preserve the in-flight GIF capture task when it transitions from .capture into .processing;
        // for all other transitions, cancel the previous state's task and advance stateGeneration.
        let isInternalCaptureToProcessing: Bool = {
            if case .capture = previousState, case .processing = newState {
                return true
            }
            return false
        }()
        if !isInternalCaptureToProcessing {
            stateGeneration &+= 1
            activeStateTask?.cancel()
            activeStateTask = nil
        }
        let generation = stateGeneration
        
        sharingPromptTimeoutTask?.cancel()
        sharingPromptTimeoutTask = nil
        errorAutoRetryTask?.cancel()
        errorAutoRetryTask = nil
        self.state = newState
        
        switch newState {
        case .initialization:
            activeStateTask = Task { @MainActor [weak self] in
                guard let self = self else { return }
                defer {
                    if self.stateGeneration == generation {
                        self.activeStateTask = nil
                    }
                }
                await self.initializeCamera(generation: generation)
            }
            
        case .idle:
            // Collapse the bottom picker between sessions; reset backdrop selection to default unless persistent selection is enabled
            self.isBackdropPickerExpanded = false
            if config.persistentBackdropSelection,
               let validCurrent = BackdropManager.shared.enabledBackdrops.first(where: { $0.id == selectedBackdrop.id }) {
                self.selectedBackdrop = validCurrent
            } else {
                self.selectedBackdrop = BackdropManager.shared.backdrop(forID: config.defaultBackdropID)
            }
            
            if case .airDrop = previousState {
                // Keep temporary .jpg files alive on disk for 90s after the AirDrop sheet closes
                // so iPadOS's background `sharingd` daemon can finish transmitting them to the iPhone.
                cleanupSessionStillImages(afterDelay: 90.0)
            } else {
                cleanupSessionStillImages(afterDelay: 0)
            }
            purgeOrphanedTempFilesAndCheckStorage()
            activeStateTask = Task { @MainActor [weak self] in
                guard let self = self, self.isCurrentExecution(generation) else { return }
                await self.startLiveView()
            }
            
        case .capture:
            self.isBackdropPickerExpanded = false
            activeStateTask = Task { @MainActor [weak self] in
                guard let self = self else { return }
                if self.captureMode == .gif {
                    await self.startGIFCaptureSequence(generation: generation)
                } else {
                    await self.startCaptureSequence(generation: generation)
                }
            }
            
        case .processing:
            cameraService.stopLiveView()
            
        case .review(let images, _):
            cameraService.stopLiveView()
            if images.isEmpty {
                transition(to: .idle)
            } else {
                activeStateTask = Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    await self.startReviewSequence(generation: generation)
                }
            }
            
        case .error:
            self.isFlashing = false
            self.isVignetteFlashing = false
            self.showGuidance = false
            self.countdown = 0
            self.currentPhotoNumber = 0
            self.currentGIFFrameIndex = 0
            self.poseIndicator = nil
            cameraService.stopLiveView()
            cleanupSessionStillImages(afterDelay: 0)
            errorAutoRetryTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s auto-retry poll
                    guard let self = self, !Task.isCancelled else { break }
                    guard case .error = self.state else { break }
                    if await self.cameraService.checkConnection() {
                        guard !Task.isCancelled, case .error = self.state else { break }
                        self.transition(to: .idle)
                        break
                    }
                    try? await self.cameraService.connect()
                    guard !Task.isCancelled, case .error = self.state else { break }
                    if self.cameraService.isConnected {
                        self.isCameraConnected = true
                        self.cameraStatusMessage = self.cameraService.statusMessage
                        self.transition(to: .idle)
                        break
                    }
                }
            }
            
        case .sharingPrompt:
            cameraService.stopLiveView()
            sharingPromptTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self = self, !Task.isCancelled else { return }
                if case .sharingPrompt = self.state {
                    self.transition(to: .idle)
                }
            }
            
        case .airDrop, .emailSharing:
            cameraService.stopLiveView()
        }
    }
    
    // MARK: - Actions
    
    private func initializeCamera(generation: UInt64) async {
        do {
            try await cameraService.connect()
            guard isCurrentExecution(generation), case .initialization = state else { return }
            self.isCameraConnected = cameraService.isConnected
            self.cameraStatusMessage = cameraService.statusMessage
            transition(to: .idle)
        } catch {
            guard isCurrentExecution(generation), case .initialization = state else { return }
            self.isCameraConnected = cameraService.isConnected
            self.cameraStatusMessage = cameraService.statusMessage
            let detailedMessage = cameraService.statusMessage ?? error.localizedDescription
            transition(to: .error(message: detailedMessage))
        }
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
        self.isBackdropPickerExpanded = false
        self.captureMode = mode
        transition(to: .capture(count: 0))
    }
    
    func selectAirDrop() {
        if case .sharingPrompt(let images) = state {
            transition(to: .airDrop(images: images))
        }
    }
    
    func selectEmailSharing() {
        if case .sharingPrompt(let images) = state {
            transition(to: .emailSharing(images: images))
        }
    }
    
    func returnToSharingPrompt() {
        if case .emailSharing(let images) = state {
            transition(to: .sharingPrompt(images: images))
        }
    }
    
    func skipSharing() {
        if case .idle = state { return }
        transition(to: .idle)
    }
    
    func retryConnection() {
        transition(to: .initialization)
    }
    
    /// Triggers a single capture with one automatic retry on transient USB/PTP errors.
    private func captureSinglePhoto() async throws -> String {
        do {
            let urls = try await cameraService.takePicture()
            guard let first = urls.first else {
                throw CameraError.invalidResponse
            }
            return first
        } catch let error as CameraError where error == .timeout {
            // takePicture() already performs a fast internal re-trigger if 0xD215 == 0;
            // rethrow immediately so we don't stall for a second full timeout window.
            throw error
        } catch {
            // Allow 1 quick retry for transient device busy / pipe states
            try await Task.sleep(nanoseconds: 150_000_000)
            let urls = try await cameraService.takePicture()
            guard let first = urls.first else {
                throw CameraError.invalidResponse
            }
            return first
        }
    }
    
    // MARK: - Standard Photo Capture Sequence
    
    private func startCaptureSequence(generation: UInt64) async {
        capturedImages.removeAll()
        self.currentPhotoNumber = 0
        
        do {
            try await cameraService.prepareForCapture(mode: .standard)
        } catch {
            self.currentPhotoNumber = 0
            guard isCurrentExecution(generation), isInCaptureState else { return }
            transition(to: .error(message: "Capture Setup Failed: \(error.localizedDescription)"))
            return
        }
        
        guard isCurrentExecution(generation), isInCaptureState else {
            await cameraService.finishCaptureSequence(mode: .standard)
            return
        }
        
        let totalPhotos = config.photoCount
        var previousCaptureTask: Task<Void, Never>? = nil
        
        for i in 0..<totalPhotos {
            // 1. Ensure previous photo's transfer finished before starting next countdown
            if let task = previousCaptureTask {
                _ = await task.result
                if !isCurrentExecution(generation) || !isInCaptureState {
                    self.currentPhotoNumber = 0
                    await cameraService.finishCaptureSequence(mode: .standard)
                    return
                }
            }
            
            // 2. Countdown
            let countTime: Int
            if i == 0 {
                if config.showGuidanceText {
                    self.showGuidance = true
                    for _ in 0..<3 {
                        if !isCurrentExecution(generation) || !isInCaptureState {
                            self.showGuidance = false
                            self.currentPhotoNumber = 0
                            await cameraService.finishCaptureSequence(mode: .standard)
                            return
                        }
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                    self.showGuidance = false
                    guard isCurrentExecution(generation), isInCaptureState else {
                        self.currentPhotoNumber = 0
                        await cameraService.finishCaptureSequence(mode: .standard)
                        return
                    }
                    self.currentPhotoNumber = i + 1
                    countTime = max(3, config.initialCountdownSec - 3)
                } else {
                    self.currentPhotoNumber = i + 1
                    countTime = config.initialCountdownSec
                }
            } else {
                self.currentPhotoNumber = i + 1
                countTime = config.interShotCountdownSec
            }
            
            if countTime > 0 {
                for t in (1...countTime).reversed() {
                    if !isCurrentExecution(generation) || !isInCaptureState {
                        self.countdown = 0
                        self.currentPhotoNumber = 0
                        await cameraService.finishCaptureSequence(mode: .standard)
                        return
                    }
                    self.countdown = t
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            self.countdown = 0
            
            guard isCurrentExecution(generation), isInCaptureState else {
                self.currentPhotoNumber = 0
                await cameraService.finishCaptureSequence(mode: .standard)
                return
            }
            
            // 3. Trigger White Screen Flash (0.5s hold + 0.5s fade = 1.0s)
            withAnimation(.linear(duration: 0)) { self.isFlashing = true }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                withAnimation(.easeIn(duration: 0.5)) { self.isFlashing = false }
            }
            
            // 4. Trigger USB Capture (~0.3s total) concurrently with the 1.0s flash fade
            previousCaptureTask = Task { @MainActor in
                do {
                    let fileURLString = try await self.captureSinglePhoto()
                    guard self.isCurrentExecution(generation), self.isInCaptureState else {
                        self.cleanupTempFiles([fileURLString])
                        return
                    }
                    self.capturedImages.append(fileURLString)
                    // When using the external Sony camera, full-res still images are stored on the camera's SD card,
                    // and the 2MP iPad copies are kept only in /tmp for preview & AirDrop and then deleted (not saved to iPad Photos).
                    if self.config.useLocalCamera {
                        self.saveToPhotoLibrary(urls: [fileURLString])
                    }
                } catch {
                    guard self.isCurrentExecution(generation), self.isInCaptureState else { return }
                    self.isFlashing = false
                    self.currentPhotoNumber = 0
                    self.transition(to: .error(message: "Capture Failed: \(error.localizedDescription)"))
                }
            }
            
            // Wait for the 1.0s flash fade to complete before advancing to the next photo countdown
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard isCurrentExecution(generation), isInCaptureState else { break }
            
            withAnimation(.spring(response: 0.25, dampingFraction: 0.78)) {
                self.currentPhotoNumber = i + 2
            }
        }
        
        if let task = previousCaptureTask {
            _ = await task.result
        }
        
        await cameraService.finishCaptureSequence(mode: .standard)
        self.currentPhotoNumber = 0
        
        guard isCurrentExecution(generation), isInCaptureState else { return }
        transition(to: .review(images: capturedImages, index: 0))
    }
    
    private func triggerGIFVignetteFlash() {
        withAnimation(.easeOut(duration: 0.03)) {
            self.isVignetteFlashing = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.20s crisp hold
            withAnimation(.easeOut(duration: 0.12)) {
                self.isVignetteFlashing = false
            }
        }
    }
    
    // MARK: - Animated GIF Capture Sequence
    
    private func startGIFCaptureSequence(generation: UInt64) async {
        print("Starting GIF Capture Sequence")
        capturedImages.removeAll()
        self.poseIndicator = nil
        self.isVignetteFlashing = false
        withAnimation(.none) {
            self.gifPerimeterProgress = 0.0
        }
        self.currentGIFFrameIndex = 0
        
        do {
            try await cameraService.prepareForCapture(mode: .gif)
        } catch {
            self.currentGIFFrameIndex = 0
            guard isCurrentExecution(generation), isInCaptureState else { return }
            transition(to: .error(message: "GIF Setup Failed: \(error.localizedDescription)"))
            return
        }
        
        guard isCurrentExecution(generation), isInCaptureState else {
            await cameraService.finishCaptureSequence(mode: .gif)
            return
        }
        
        // 1. Initial Guidance & 3-Second Countdown (with "Get Ready to Move!" at bottom)
        var countTime: Int = min(3, config.initialCountdownSec)
        if config.showGuidanceText {
            self.showGuidance = true
            for _ in 0..<3 {
                if !isCurrentExecution(generation) || !isInCaptureState {
                    self.showGuidance = false
                    self.currentGIFFrameIndex = 0
                    await cameraService.finishCaptureSequence(mode: .gif)
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            self.showGuidance = false
            guard isCurrentExecution(generation), isInCaptureState else {
                self.currentGIFFrameIndex = 0
                await cameraService.finishCaptureSequence(mode: .gif)
                return
            }
            countTime = min(3, max(1, config.initialCountdownSec))
        }
        
        // Show the Top-Center progress dots (highlighting Dot 1) once the "Look at Camera" arrow & message go away
        self.currentGIFFrameIndex = 1
        
        if countTime > 0 {
            for t in (1...countTime).reversed() {
                if !isCurrentExecution(generation) || !isInCaptureState {
                    self.countdown = 0
                    self.currentGIFFrameIndex = 0
                    await cameraService.finishCaptureSequence(mode: .gif)
                    return
                }
                self.countdown = t
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        self.countdown = 0
        
        guard isCurrentExecution(generation), isInCaptureState else {
            self.currentGIFFrameIndex = 0
            await cameraService.finishCaptureSequence(mode: .gif)
            return
        }
        
        // 2. Multi-Pose GIF Capture Loop (Enforcing "Min Time Between GIFs", default 2.0s, min 0.5s)
        let frameCount = config.gifFrameCount
        let minInterval = max(0.5, config.gifCaptureInterval)
        let poseNames = ["Second", "Third", "Fourth", "Fifth", "Sixth", "Seventh", "Eighth", "Ninth", "Tenth"]
        
        for i in 0..<frameCount {
            if !isCurrentExecution(generation) || !isInCaptureState {
                self.poseIndicator = nil
                self.currentGIFFrameIndex = 0
                withAnimation(.none) { self.gifPerimeterProgress = 0.0 }
                await cameraService.finishCaptureSequence(mode: .gif)
                return
            }
            
            self.poseIndicator = nil
            self.currentGIFFrameIndex = i + 1
            withAnimation(.none) {
                self.gifPerimeterProgress = 0.0
            }
            
            // Fire the 0.2s crisp perimeter vignette flash on every GIF frame
            triggerGIFVignetteFlash()
            let shotStart = Date()
            
            do {
                let fileURLString = try await captureSinglePhoto()
                guard isCurrentExecution(generation), isInCaptureState else {
                    cleanupTempFiles([fileURLString])
                    self.poseIndicator = nil
                    self.currentGIFFrameIndex = 0
                    withAnimation(.none) { self.gifPerimeterProgress = 0.0 }
                    await cameraService.finishCaptureSequence(mode: .gif)
                    return
                }
                capturedImages.append(fileURLString)
            } catch {
                self.isFlashing = false
                self.isVignetteFlashing = false
                self.poseIndicator = nil
                self.currentGIFFrameIndex = 0
                withAnimation(.none) { self.gifPerimeterProgress = 0.0 }
                await cameraService.finishCaptureSequence(mode: .gif)
                guard isCurrentExecution(generation), isInCaptureState else { return }
                transition(to: .error(message: "Capture Failed: \(error.localizedDescription)"))
                return
            }
            
            // Advance the active dot and sweep the 22pt clockwise perimeter trace across the reposition window
            if i < frameCount - 1 {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.78)) {
                    self.currentGIFFrameIndex = i + 2
                }
                
                let elapsed = Date().timeIntervalSince(shotStart)
                let remaining = max(0, minInterval - elapsed)
                
                if remaining > 0.05 {
                    withAnimation(.linear(duration: remaining)) {
                        self.gifPerimeterProgress = 1.0
                    }
                }
                
                let poseDisplayWindow = min(1.2, remaining)
                let prePoseWait = max(0, remaining - poseDisplayWindow)
                
                if prePoseWait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(prePoseWait * 1_000_000_000))
                }
                
                guard isCurrentExecution(generation), isInCaptureState else {
                    self.poseIndicator = nil
                    self.currentGIFFrameIndex = 0
                    withAnimation(.none) { self.gifPerimeterProgress = 0.0 }
                    await cameraService.finishCaptureSequence(mode: .gif)
                    return
                }
                
                if i < poseNames.count {
                    self.poseIndicator = "\(poseNames[i]) Pose"
                }
                
                if poseDisplayWindow > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(poseDisplayWindow * 1_000_000_000))
                }
            } else {
                // Mark all dots completed (solid white) as the final frame finishes
                withAnimation(.spring(response: 0.25, dampingFraction: 0.78)) {
                    self.currentGIFFrameIndex = frameCount + 1
                }
            }
        }
        
        self.poseIndicator = nil
        self.currentGIFFrameIndex = 0
        withAnimation(.none) {
            self.gifPerimeterProgress = 0.0
        }
        await cameraService.finishCaptureSequence(mode: .gif)
        
        guard isCurrentExecution(generation), isInCaptureState else {
            cleanupTempFiles(self.capturedImages)
            return
        }
        
        // 3. Zero-Copy GIF Creation (source frames are already local files in /tmp)
        let sourceFrameURLs = self.capturedImages
        let activeBackdrop = self.selectedBackdrop
        transition(to: .processing(message: "Creating GIF..."))
        
        let gifDuration = config.gifFrameDuration
        let gifResolution = config.gifResolution
        
        let gifURL = await Task.detached(priority: .userInitiated) {
            return GIFService.createGIF(
                from: sourceFrameURLs,
                frameDuration: gifDuration,
                resolution: gifResolution,
                backdrop: activeBackdrop
            )
        }.value
        
        // 4. Immediately delete all individual source .jpg frames from disk
        cleanupTempFiles(sourceFrameURLs)
        
        guard isCurrentExecution(generation), case .processing = state else {
            if let unusedGIF = gifURL {
                cleanupTempFiles([unusedGIF.path])
            }
            return
        }
        
        guard let finalGIFURL = gifURL else {
            transition(to: .error(message: "Failed to create GIF"))
            return
        }
        
        // 5. Save ONLY the compiled .gif to Photos
        if config.saveToPhotos {
            saveLocalFilesToLibrary(urls: [finalGIFURL])
        }
        
        // 6. Review & AirDrop ONLY the compiled .gif (never the individual frames)
        let gifOnlyItems = [finalGIFURL.absoluteString]
        self.capturedImages = gifOnlyItems
        transition(to: .review(images: gifOnlyItems, index: 0))
    }
    
    // MARK: - Review & Photo Library Persistence
    
    private func startReviewSequence(generation: UInt64) async {
        guard isCurrentExecution(generation), case .review(let images, _) = state else { return }
        
        for i in 0..<images.count {
            guard isCurrentExecution(generation), case .review = state else { return }
            
            if images[i].lowercased().hasSuffix(".gif") {
                self.currentReviewImage = nil
                if i > 0 {
                    self.state = .review(images: images, index: i)
                }
                try? await Task.sleep(nanoseconds: UInt64(config.gifPreviewDuration * 1_000_000_000))
                continue
            }
            
            // Decode UIImage BEFORE updating state/currentReviewImage to prevent 1-frame spinner flicker.
            // Note: Both Sony captures ("sony_<UUID>.jpg") and Local captures ("local_<UUID>.jpg")
            // already run single-pass subject auto-exposure BEFORE backdrop compositing, so do not
            // re-apply auto-exposure a second time on top of a composited backdrop.
            do {
                let data = try await cameraService.fetchImage(url: images[i])
                guard isCurrentExecution(generation), case .review = state else { return }
                if let image = UIImage(data: data) {
                    let isAlreadyNormalizedFile = images[i].contains("sony_") || images[i].contains("local_")
                    self.currentReviewImage = isAlreadyNormalizedFile
                        ? image
                        : SonyUSBCameraClient.autoExposeCapturedUIImage(image)
                    self.state = .review(images: images, index: i)
                    try? await Task.sleep(nanoseconds: UInt64(config.previewDurationSec) * 1_000_000_000)
                } else {
                    self.state = .review(images: images, index: i)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            } catch {
                guard isCurrentExecution(generation), case .review = state else { return }
                self.state = .review(images: images, index: i)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        
        guard isCurrentExecution(generation), case .review = state else { return }
        if config.enableImageSharing {
            // Pass `images` directly (for GIF sessions, `images` contains ONLY the .gif file)
            transition(to: .sharingPrompt(images: images))
        } else {
            transition(to: .idle)
        }
    }
    
    private func saveLocalFilesToLibrary(urls: [URL]) {
        Task.detached(priority: .background) {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { return }
            
            try? await PHPhotoLibrary.shared().performChanges {
                for url in urls {
                    let creationRequest = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = url.lastPathComponent
                    creationRequest.addResource(with: .photo, fileURL: url, options: options)
                }
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
    
    // MARK: - Temporary File Cleanup & 2GB Storage Guard
    
    /// Deletes the current session's temporary 2MP still `.jpg` images from the iPad
    /// once previewing and AirDrop (or skipping AirDrop) have completed.
    private func cleanupSessionStillImages(afterDelay delaySec: TimeInterval = 0) {
        let stillJPGs = capturedImages.filter { !$0.lowercased().hasSuffix(".gif") }
        capturedImages.removeAll()
        currentReviewImage = nil
        
        guard !stillJPGs.isEmpty else { return }
        if delaySec <= 0 {
            cleanupTempFiles(stillJPGs)
        } else {
            Task.detached(priority: .background) { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
                await self?.cleanupTempFiles(stillJPGs)
            }
        }
    }
    
    /// Immediately deletes temporary source frame files (accepts either `file://` URL strings or POSIX paths).
    func cleanupTempFiles(_ pathsOrURLs: [String]) {
        for item in pathsOrURLs {
            let fileURL: URL
            if let parsed = URL(string: item), parsed.isFileURL {
                fileURL = parsed
            } else {
                fileURL = URL(fileURLWithPath: item)
            }
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
    
    /// Purges temporary `.jpg` / `.gif` files older than 10 minutes (avoiding races with in-flight Photos saves)
    /// and checks that available iPad storage is at least 2 GB.
    private func purgeOrphanedTempFilesAndCheckStorage() {
        let tempDir = FileManager.default.temporaryDirectory
        let cutoffDate = Date().addingTimeInterval(-600) // 10 minutes ago
        let activeFilePaths = Set(capturedImages.map { item -> String in
            if let parsed = URL(string: item), parsed.isFileURL {
                return parsed.standardizedFileURL.path
            }
            return URL(fileURLWithPath: item).standardizedFileURL.path
        })
        
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for fileURL in contents {
                let ext = fileURL.pathExtension.lowercased()
                guard ext == "jpg" || ext == "gif" else { continue }
                guard !activeFilePaths.contains(fileURL.standardizedFileURL.path) else { continue }
                if let values = try? fileURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]) {
                    let modDate = values.contentModificationDate
                    let createDate = values.creationDate
                    let oldestTimestamp: Date?
                    if let m = modDate, let c = createDate {
                        oldestTimestamp = min(m, c)
                    } else {
                        oldestTimestamp = modDate ?? createDate
                    }
                    if let timestamp = oldestTimestamp, timestamp < cutoffDate {
                        try? FileManager.default.removeItem(at: fileURL)
                    }
                }
            }
        }
        
        EmailQueueService.shared.purgeExpiredFailedJobs(maxAgeDays: 7)
        
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? homeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let availableBytes = values.volumeAvailableCapacityForImportantUsage {
            if availableBytes < 2_000_000_000 { // < 2 GB
                let gb = Double(availableBytes) / 1_000_000_000.0
                self.lowStorageWarning = String(format: "Low iPad Storage (%.1f GB free)", gb)
            } else {
                self.lowStorageWarning = nil
            }
        }
    }
}
