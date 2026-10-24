import Foundation
import Combine
import AVFoundation
import UIKit

class LocalCameraClient: NSObject, CameraService, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    @Published var isConnected: Bool = false
    var connectionStatus: AnyPublisher<Bool, Never> {
        $isConnected.eraseToAnyPublisher()
    }
    
    private let _previewStream = PassthroughSubject<UIImage?, Never>()
    var previewStream: AnyPublisher<UIImage?, Never> {
        _previewStream.eraseToAnyPublisher()
    }
    
    nonisolated(unsafe) private let session = AVCaptureSession()
    nonisolated(unsafe) private let photoOutput = AVCapturePhotoOutput()
    nonisolated(unsafe) private let videoOutput = AVCaptureVideoDataOutput()
    nonisolated private let sessionQueue = DispatchQueue(label: "camera.session.queue", qos: .userInitiated)
    nonisolated private let videoOutputQueue = DispatchQueue(label: "camera.video.queue", qos: .userInteractive)
    nonisolated private let ciContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    nonisolated private let photoCIContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    
    private nonisolated final class ThreadSafeState: @unchecked Sendable {
        private let lock = NSLock()
        private var currentBackdrop: BackdropItem = .none
        private var activeCaptureMode: CaptureMode = .standard
        private var cachedOrientation: UIDeviceOrientation = .landscapeLeft
        private var isRenderingPreview: Bool = false
        private var latestSubjectCGImage: CGImage? = nil
        private var latestSubjectSequence: UInt64 = 0
        
        func setBackdrop(_ backdrop: BackdropItem) {
            lock.lock()
            currentBackdrop = backdrop
            lock.unlock()
        }
        
        func setCaptureMode(_ mode: CaptureMode) {
            lock.lock()
            activeCaptureMode = mode
            lock.unlock()
        }
        
        func setOrientation(_ orientation: UIDeviceOrientation) {
            lock.lock()
            cachedOrientation = orientation
            lock.unlock()
        }
        
        func setLatestSubjectFrame(_ cgImage: CGImage) {
            lock.lock()
            latestSubjectCGImage = cgImage
            latestSubjectSequence &+= 1
            lock.unlock()
        }
        
        func latestSubjectFrame() -> (image: CGImage?, sequence: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            return (latestSubjectCGImage, latestSubjectSequence)
        }
        
        func clearLatestSubjectFrame() {
            lock.lock()
            latestSubjectCGImage = nil
            lock.unlock()
        }
        
        func snapshot() -> (backdrop: BackdropItem, mode: CaptureMode, orientation: UIDeviceOrientation) {
            lock.lock()
            defer { lock.unlock() }
            return (currentBackdrop, activeCaptureMode, cachedOrientation)
        }
        
        func tryBeginPreviewRender() -> (orientation: UIDeviceOrientation, backdrop: BackdropItem)? {
            lock.lock()
            defer { lock.unlock() }
            guard !isRenderingPreview else { return nil }
            isRenderingPreview = true
            return (cachedOrientation, currentBackdrop)
        }
        
        func endPreviewRender() {
            lock.lock()
            isRenderingPreview = false
            lock.unlock()
        }
    }
    
    nonisolated private let threadSafeState = ThreadSafeState()
    private var photoContinuation: CheckedContinuation<[String], Error>?
    private var activePhotoRequestID: UInt64 = 0
    private var photoWatchdogTask: Task<Void, Never>?
    
    override init() {
        super.init()
        Task { @MainActor [weak self] in
            self?.refreshCachedDeviceOrientation()
        }
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            setupSession()
        }
    }
    
    nonisolated func updateSelectedBackdrop(_ backdrop: BackdropItem) {
        threadSafeState.setBackdrop(backdrop)
    }
    
    @MainActor
    private func refreshCachedDeviceOrientation() {
        if ProcessInfo.processInfo.isiOSAppOnMac {
            threadSafeState.setOrientation(.landscapeRight)
            return
        }
        // Prioritize the active UIWindowScene interface orientation so a tilted iPad in a photobooth stand
        // or with Rotation Lock enabled always matches the landscape UI orientation on screen.
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            switch scene.interfaceOrientation {
            case .landscapeLeft:
                // UIInterfaceOrientation.landscapeLeft (home/USB-C left) == UIDeviceOrientation.landscapeRight
                threadSafeState.setOrientation(.landscapeRight)
                return
            case .landscapeRight:
                // UIInterfaceOrientation.landscapeRight (home/USB-C right) == UIDeviceOrientation.landscapeLeft
                threadSafeState.setOrientation(.landscapeLeft)
                return
            default:
                break
            }
        }
        let orientation = UIDevice.current.orientation
        if orientation == .landscapeLeft || orientation == .landscapeRight {
            threadSafeState.setOrientation(orientation)
        }
    }
    
    func prepareForCapture(mode: CaptureMode) async throws {
        refreshCachedDeviceOrientation()
        threadSafeState.setCaptureMode(mode)
    }
    
    func finishCaptureSequence(mode: CaptureMode) async {
        threadSafeState.setCaptureMode(.standard)
    }
    
    nonisolated func seedLatestSubjectFrameForTesting(_ cgImage: CGImage) {
        threadSafeState.setLatestSubjectFrame(cgImage)
    }
    
    /// Must only be called on `sessionQueue`. Returns `true` if the session has a valid video input.
    nonisolated private func configureSessionOnQueueIfNeeded() -> Bool {
        if !self.session.inputs.isEmpty {
            return true
        }
        
        self.session.beginConfiguration()
        self.session.sessionPreset = .photo
        
        // Add input (Front Camera on iPad, or default FaceTime camera on Mac)
        let preferredDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
        guard let device = preferredDevice,
              let input = try? AVCaptureDeviceInput(device: device),
              self.session.canAddInput(input) else {
            self.session.commitConfiguration()
            return false
        }
        
        self.session.addInput(input)
        
        // Add outputs
        if self.session.canAddOutput(self.photoOutput) {
            self.session.addOutput(self.photoOutput)
        }
        
        if self.session.canAddOutput(self.videoOutput) {
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.setSampleBufferDelegate(self, queue: self.videoOutputQueue)
            self.session.addOutput(self.videoOutput)
        }
        
        self.session.commitConfiguration()
        return true
    }
    
    private func setupSession() {
        sessionQueue.async {
            let configured = self.configureSessionOnQueueIfNeeded()
            DispatchQueue.main.async {
                self.isConnected = configured
            }
        }
    }
    
    func connect() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else {
                self.isConnected = false
                throw CameraError.connectionFailed
            }
        } else if status != .authorized {
            self.isConnected = false
            throw CameraError.connectionFailed
        }
        
        let configured: Bool = await withCheckedContinuation { continuation in
            sessionQueue.async {
                let ok = self.configureSessionOnQueueIfNeeded()
                continuation.resume(returning: ok)
            }
        }
        self.isConnected = configured
        if !configured {
            throw CameraError.connectionFailed
        }
    }
    
    func startLiveView() async throws {
        sessionQueue.async {
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }
    
    func stopLiveView() {
        self.photoWatchdogTask?.cancel()
        self.photoWatchdogTask = nil
        if let pending = self.photoContinuation {
            self.photoContinuation = nil
            pending.resume(throwing: CameraError.connectionFailed)
        }
        threadSafeState.clearLatestSubjectFrame()
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }
    
    private func resolvePhotoContinuation(requestID: UInt64, result: Result<[String], Error>) {
        guard self.activePhotoRequestID == requestID,
              let pending = self.photoContinuation else {
            return
        }
        self.photoContinuation = nil
        self.photoWatchdogTask?.cancel()
        self.photoWatchdogTask = nil
        pending.resume(with: result)
    }
    
    func takePicture() async throws -> [String] {
        refreshCachedDeviceOrientation()
        let (selectedBackdrop, captureMode, _) = self.threadSafeState.snapshot()
        
        // In GIF mode, capture directly from the live 30 FPS camera stream so back-to-back
        // multi-pose captures never stall or drop frames inside AVCapturePhotoOutput's 12MP still pipeline.
        if captureMode == .gif {
            let captureStartNs = DispatchTime.now().uptimeNanoseconds
            var cachedFrame = self.threadSafeState.latestSubjectFrame().image
            if cachedFrame == nil {
                for _ in 0..<10 {
                    try? await Task.sleep(nanoseconds: 25_000_000)
                    cachedFrame = self.threadSafeState.latestSubjectFrame().image
                    if cachedFrame != nil { break }
                }
            }
            if let subjectCG = cachedFrame {
                let ciCtx = self.photoCIContext
                let fileURLString = try await Task.detached(priority: .userInitiated) {
                    try Self.processAndSaveUprightSubjectCGImage(
                        subjectCG,
                        selectedBackdrop: selectedBackdrop,
                        captureMode: .gif,
                        ciContext: ciCtx
                    )
                }.value
                // Ensure at least ~50ms (~3 display frames) elapsed so SwiftUI cleanly renders
                // the per-frame vignette flash and gifPerimeterProgress = 0.0 reset before sweeping to 1.0.
                let elapsedNs = DispatchTime.now().uptimeNanoseconds - captureStartNs
                if elapsedNs < 50_000_000 {
                    try? await Task.sleep(nanoseconds: 50_000_000 - elapsedNs)
                }
                return [fileURLString]
            }
        }
        
        self.photoWatchdogTask?.cancel()
        self.photoWatchdogTask = nil
        if let staleContinuation = self.photoContinuation {
            self.photoContinuation = nil
            staleContinuation.resume(throwing: CameraError.connectionFailed)
        }
        
        self.activePhotoRequestID &+= 1
        let requestID = self.activePhotoRequestID
        
        return try await withCheckedThrowingContinuation { continuation in
            self.photoContinuation = continuation
            
            // Watchdog fallback so a stalled AVCapturePhotoOutput callback can never hang the capture sequence
            self.photoWatchdogTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard let self = self, !Task.isCancelled else { return }
                guard self.activePhotoRequestID == requestID, self.photoContinuation != nil else { return }
                
                let (backdrop, mode, _) = self.threadSafeState.snapshot()
                let fallbackCG = self.threadSafeState.latestSubjectFrame().image
                let ciCtx = self.photoCIContext
                if let fallbackCG = fallbackCG,
                   let urlString = try? await Task.detached(priority: .userInitiated, operation: {
                       try Self.processAndSaveUprightSubjectCGImage(
                           fallbackCG,
                           selectedBackdrop: backdrop,
                           captureMode: mode,
                           ciContext: ciCtx
                       )
                   }).value {
                    self.resolvePhotoContinuation(requestID: requestID, result: .success([urlString]))
                } else {
                    self.resolvePhotoContinuation(requestID: requestID, result: .failure(CameraError.timeout))
                }
            }
            
            self.sessionQueue.async {
                guard self.session.isRunning,
                      let connection = self.photoOutput.connection(with: .video),
                      connection.isEnabled,
                      connection.isActive else {
                    let (backdrop, mode, _) = self.threadSafeState.snapshot()
                    let fallbackCG = self.threadSafeState.latestSubjectFrame().image
                    let ciCtx = self.photoCIContext
                    if let fallbackCG = fallbackCG,
                       let urlString = try? Self.processAndSaveUprightSubjectCGImage(
                           fallbackCG,
                           selectedBackdrop: backdrop,
                           captureMode: mode,
                           ciContext: ciCtx
                       ) {
                        DispatchQueue.main.async {
                            self.resolvePhotoContinuation(requestID: requestID, result: .success([urlString]))
                        }
                    } else {
                        DispatchQueue.main.async {
                            self.resolvePhotoContinuation(requestID: requestID, result: .failure(CameraError.connectionFailed))
                        }
                    }
                    return
                }
                let settings = AVCapturePhotoSettings()
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }
    
    func fetchImage(url: String) async throws -> Data {
        // For local files, we can just read from disk
        let fileURL: URL
        if url.hasPrefix("file://"), let parsed = URL(string: url) {
            fileURL = parsed
        } else {
            fileURL = URL(fileURLWithPath: url)
        }
        return try Data(contentsOf: fileURL)
    }
    
    func checkConnection() async -> Bool {
        return isConnected
    }
    
    nonisolated static func processAndSaveUprightSubjectCGImage(
        _ uprightCG: CGImage,
        selectedBackdrop: BackdropItem,
        captureMode: CaptureMode,
        ciContext: CIContext
    ) throws -> String {
        // Step 1: Ensure max dimensions do not exceed photobooth standard 2MP (1620x1080)
        let scaledSubjectCG: CGImage
        let maxWidth: CGFloat = 1620.0
        if CGFloat(uprightCG.width) > maxWidth {
            let scale = maxWidth / CGFloat(uprightCG.width)
            let scaledCI = CIImage(cgImage: uprightCG)
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let targetRect = CGRect(
                x: scaledCI.extent.origin.x.rounded(),
                y: scaledCI.extent.origin.y.rounded(),
                width: maxWidth,
                height: scaledCI.extent.height.rounded()
            )
            let croppedCI = scaledCI.cropped(to: targetRect)
            scaledSubjectCG = ciContext.createCGImage(croppedCI, from: croppedCI.extent) ?? uprightCG
        } else {
            scaledSubjectCG = uprightCG
        }
        
        // Step 2: Run fast GPU subject auto-exposure BEFORE backdrop compositing
        let exposedSubjectCG = SonyUSBCameraClient.autoExposeCapturedCGImage(
            scaledSubjectCG,
            ciContext: ciContext
        )
        
        // Step 3: For standard photo captures, apply high-accuracy backdrop/foreground compositing now.
        // For GIF captures, leave the frame un-composited so GIFService.createGIF can equalize luminance
        // across all 4 frames first and then composite the backdrop/foreground with .captureAccurate.
        let finalCG: CGImage
        if captureMode == .standard && !selectedBackdrop.isNone {
            finalCG = BackdropCompositorService.composite(
                cgImage: exposedSubjectCG,
                backdrop: selectedBackdrop,
                quality: .captureAccurate,
                ciContext: ciContext
            )
        } else {
            finalCG = exposedSubjectCG
        }
        
        let finalImage = UIImage(cgImage: finalCG, scale: 1.0, orientation: .up)
        guard let finalData = finalImage.jpegData(compressionQuality: 0.92) else {
            throw CameraError.invalidResponse
        }
        
        let filename = "local_" + UUID().uuidString + ".jpg"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try finalData.write(to: url, options: .atomic)
        return url.absoluteString
    }
    
    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Frame-drop backpressure gate so fast Vision segmentation never queues up stale frames
        guard let (deviceOrientation, selectedBackdrop) = threadSafeState.tryBeginPreviewRender() else {
            return
        }
        defer {
            threadSafeState.endPreviewRender()
        }
        
        // Pre-orient and horizontally mirror raw front-camera frame into a standalone CGImage
        // inside an inner scope so the camera's CMSampleBuffer / CVPixelBuffer is released immediately.
        let uprightSubjectCG: CGImage? = {
            guard let cvBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
            let rawCI = CIImage(cvPixelBuffer: cvBuffer)
            let orientedMirroredCI = BackdropCompositorService.orientAndMirrorFrontCameraCIImage(
                rawCI,
                interfaceOrientation: deviceOrientation
            )
            let rawExtent = orientedMirroredCI.extent
            guard rawExtent.width > 1, rawExtent.height > 1 else { return nil }
            let normalizedCI: CIImage
            if rawExtent.minX != 0 || rawExtent.minY != 0 {
                normalizedCI = orientedMirroredCI.transformed(
                    by: CGAffineTransform(translationX: -rawExtent.minX, y: -rawExtent.minY)
                )
            } else {
                normalizedCI = orientedMirroredCI
            }
            let targetExtent = CGRect(
                x: 0,
                y: 0,
                width: rawExtent.width.rounded(),
                height: rawExtent.height.rounded()
            )
            return self.ciContext.createCGImage(normalizedCI, from: targetExtent)
        }()
        
        guard let subjectCG = uprightSubjectCG else { return }
        threadSafeState.setLatestSubjectFrame(subjectCG)
        
        let finalCG: CGImage
        if selectedBackdrop.isNone {
            finalCG = subjectCG
        } else {
            guard let compositedCG = BackdropCompositorService.composite(
                subjectCI: CIImage(cgImage: subjectCG),
                backdrop: selectedBackdrop,
                quality: .liveFast,
                ciContext: self.ciContext
            ) else {
                return
            }
            finalCG = compositedCG
        }
        
        let uiImage = UIImage(cgImage: finalCG, scale: 1.0, orientation: .up)
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.refreshCachedDeviceOrientation()
            self._previewStream.send(uiImage)
        }
    }
    
    // MARK: - AVCapturePhotoCaptureDelegate
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let photoData = photo.fileDataRepresentation()
        let (selectedBackdrop, captureMode, cachedOrientation) = self.threadSafeState.snapshot()
        let fallbackCG = self.threadSafeState.latestSubjectFrame().image
        let ciCtx = self.photoCIContext
        
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            let requestID = await MainActor.run { self.activePhotoRequestID }
            
            if let error = error {
                if let fallbackCG = fallbackCG,
                   let urlString = try? Self.processAndSaveUprightSubjectCGImage(
                       fallbackCG,
                       selectedBackdrop: selectedBackdrop,
                       captureMode: captureMode,
                       ciContext: ciCtx
                   ) {
                    await MainActor.run {
                        self.resolvePhotoContinuation(requestID: requestID, result: .success([urlString]))
                    }
                } else {
                    await MainActor.run {
                        self.resolvePhotoContinuation(requestID: requestID, result: .failure(error))
                    }
                }
                return
            }
            
            guard let data = photoData,
                  let image = UIImage(data: data),
                  let rawCG = image.cgImage else {
                if let fallbackCG = fallbackCG,
                   let urlString = try? Self.processAndSaveUprightSubjectCGImage(
                       fallbackCG,
                       selectedBackdrop: selectedBackdrop,
                       captureMode: captureMode,
                       ciContext: ciCtx
                   ) {
                    await MainActor.run {
                        self.resolvePhotoContinuation(requestID: requestID, result: .success([urlString]))
                    }
                } else {
                    await MainActor.run {
                        self.resolvePhotoContinuation(requestID: requestID, result: .failure(CameraError.invalidResponse))
                    }
                }
                return
            }
            
            // Step 1: Orient and horizontally mirror raw front-camera frame into upright 3:2 selfie coordinates,
            // and scale 12MP captures down to the photobooth standard 2MP (1620x1080) on the GPU in a single pass.
            let rawCI = CIImage(cgImage: rawCG)
            var orientedMirroredCI = BackdropCompositorService.orientAndMirrorFrontCameraCIImage(
                rawCI,
                interfaceOrientation: cachedOrientation
            )
            let maxWidth: CGFloat = 1620.0
            if orientedMirroredCI.extent.width > maxWidth {
                let scale = maxWidth / orientedMirroredCI.extent.width
                orientedMirroredCI = orientedMirroredCI
                    .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let targetRect = CGRect(
                    x: orientedMirroredCI.extent.origin.x.rounded(),
                    y: orientedMirroredCI.extent.origin.y.rounded(),
                    width: maxWidth,
                    height: (orientedMirroredCI.extent.height).rounded()
                )
                orientedMirroredCI = orientedMirroredCI.cropped(to: targetRect)
            }
            let uprightSubjectCG = ciCtx.createCGImage(orientedMirroredCI, from: orientedMirroredCI.extent) ?? rawCG
            
            do {
                let urlString = try Self.processAndSaveUprightSubjectCGImage(
                    uprightSubjectCG,
                    selectedBackdrop: selectedBackdrop,
                    captureMode: captureMode,
                    ciContext: ciCtx
                )
                await MainActor.run {
                    self.resolvePhotoContinuation(requestID: requestID, result: .success([urlString]))
                }
            } catch {
                await MainActor.run {
                    self.resolvePhotoContinuation(requestID: requestID, result: .failure(error))
                }
            }
        }
    }
    
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCapturePhotoSettings, error: Error?) {
        guard let error = error else { return }
        let (selectedBackdrop, captureMode, _) = self.threadSafeState.snapshot()
        let fallbackCG = self.threadSafeState.latestSubjectFrame().image
        let ciCtx = self.photoCIContext
        
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            let requestID = await MainActor.run { self.activePhotoRequestID }
            if let fallbackCG = fallbackCG,
               let urlString = try? Self.processAndSaveUprightSubjectCGImage(
                   fallbackCG,
                   selectedBackdrop: selectedBackdrop,
                   captureMode: captureMode,
                   ciContext: ciCtx
               ) {
                await MainActor.run {
                    self.resolvePhotoContinuation(requestID: requestID, result: .success([urlString]))
                }
            } else {
                await MainActor.run {
                    self.resolvePhotoContinuation(requestID: requestID, result: .failure(error))
                }
            }
        }
    }
}
