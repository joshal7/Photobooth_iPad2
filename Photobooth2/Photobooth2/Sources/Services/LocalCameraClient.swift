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
    nonisolated private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    nonisolated private let ciContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    
    private nonisolated final class ThreadSafeState: @unchecked Sendable {
        private let lock = NSLock()
        private var currentBackdrop: BackdropItem = .none
        private var activeCaptureMode: CaptureMode = .standard
        private var cachedOrientation: UIDeviceOrientation = .landscapeLeft
        private var isRenderingPreview: Bool = false
        
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
            self.videoOutput.setSampleBufferDelegate(self, queue: self.sessionQueue)
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
        if let pending = self.photoContinuation {
            self.photoContinuation = nil
            pending.resume(throwing: CameraError.connectionFailed)
        }
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }
    
    func takePicture() async throws -> [String] {
        if let staleContinuation = self.photoContinuation {
            self.photoContinuation = nil
            staleContinuation.resume(throwing: CameraError.connectionFailed)
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.photoContinuation = continuation
            self.sessionQueue.async {
                guard self.session.isRunning,
                      let connection = self.photoOutput.connection(with: .video),
                      connection.isEnabled,
                      connection.isActive else {
                    DispatchQueue.main.async {
                        if let pending = self.photoContinuation {
                            self.photoContinuation = nil
                            pending.resume(throwing: CameraError.connectionFailed)
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
    
    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Frame-drop backpressure gate so fast Vision segmentation never queues up stale frames
        guard let (deviceOrientation, selectedBackdrop) = threadSafeState.tryBeginPreviewRender() else {
            return
        }
        defer {
            threadSafeState.endPreviewRender()
        }
        
        guard let cvBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let rawCI = CIImage(cvPixelBuffer: cvBuffer)
        
        // Pre-orient and horizontally mirror raw front-camera frame BEFORE compositing any foreground text/frame,
        // then render (and optionally segment/composite) in a SINGLE createCGImage GPU pass at 30 FPS.
        let orientedMirroredCI = BackdropCompositorService.orientAndMirrorFrontCameraCIImage(
            rawCI,
            interfaceOrientation: deviceOrientation
        )
        
        guard let finalCG = BackdropCompositorService.composite(
            subjectCI: orientedMirroredCI,
            backdrop: selectedBackdrop,
            quality: .liveFast,
            ciContext: self.ciContext
        ) else {
            return
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
        let ciCtx = self.ciContext
        
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            if let error = error {
                await MainActor.run {
                    let pending = self.photoContinuation
                    self.photoContinuation = nil
                    pending?.resume(throwing: error)
                }
                return
            }
            
            guard let data = photoData,
                  let image = UIImage(data: data),
                  let rawCG = image.cgImage else {
                await MainActor.run {
                    let pending = self.photoContinuation
                    self.photoContinuation = nil
                    pending?.resume(throwing: CameraError.invalidResponse)
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
            
            // Step 2: Run fast GPU subject auto-exposure BEFORE backdrop compositing
            let exposedSubjectCG = SonyUSBCameraClient.autoExposeCapturedCGImage(
                uprightSubjectCG,
                ciContext: ciCtx
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
                    ciContext: ciCtx
                )
            } else {
                finalCG = exposedSubjectCG
            }
            
            let finalImage = UIImage(cgImage: finalCG, scale: 1.0, orientation: .up)
            guard let finalData = finalImage.jpegData(compressionQuality: 0.92) else {
                await MainActor.run {
                    let pending = self.photoContinuation
                    self.photoContinuation = nil
                    pending?.resume(throwing: CameraError.invalidResponse)
                }
                return
            }
            
            let filename = "local_" + UUID().uuidString + ".jpg"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            
            do {
                try finalData.write(to: url, options: .atomic)
                await MainActor.run {
                    let pending = self.photoContinuation
                    self.photoContinuation = nil
                    pending?.resume(returning: [url.absoluteString])
                }
            } catch {
                await MainActor.run {
                    let pending = self.photoContinuation
                    self.photoContinuation = nil
                    pending?.resume(throwing: error)
                }
            }
        }
    }
}
