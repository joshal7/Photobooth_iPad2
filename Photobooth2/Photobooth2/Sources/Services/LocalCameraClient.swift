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
    
    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    nonisolated private let ciContext = CIContext()
    
    private nonisolated final class ThreadSafeState: @unchecked Sendable {
        private let lock = NSLock()
        private var currentBackdrop: BackdropItem = .none
        private var activeCaptureMode: CaptureMode = .standard
        private var cachedOrientation: UIDeviceOrientation = .portrait
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
        checkPermissions()
    }
    
    nonisolated func updateSelectedBackdrop(_ backdrop: BackdropItem) {
        threadSafeState.setBackdrop(backdrop)
    }
    
    @MainActor
    private func refreshCachedDeviceOrientation() {
        let orientation = UIDevice.current.orientation
        if orientation.isValidInterfaceOrientation {
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
    
    private func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted { self.setupSession() }
            }
        default:
            break
        }
    }
    
    private func setupSession() {
        sessionQueue.async {
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo
            
            // Add input (Front Camera)
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                return
            }
            
            if self.session.canAddInput(input) {
                self.session.addInput(input)
            }
            
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
            DispatchQueue.main.async {
                self.isConnected = true
            }
        }
    }
    
    func connect() async throws {
        // Local camera is "connected" if session is configured
        if !session.inputs.isEmpty {
            DispatchQueue.main.async { self.isConnected = true }
        } else {
            setupSession()
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
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }
    
    func takePicture() async throws -> [String] {
        return try await withCheckedThrowingContinuation { continuation in
            self.photoContinuation = continuation
            let settings = AVCapturePhotoSettings()
            self.photoOutput.capturePhoto(with: settings, delegate: self)
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
        return true
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
        
        // Pre-orient and horizontally mirror raw front-camera frame BEFORE compositing any foreground text/frame
        let orientedMirroredCI = BackdropCompositorService.orientAndMirrorFrontCameraCIImage(
            rawCI,
            interfaceOrientation: deviceOrientation
        )
        
        guard let rawCG = self.ciContext.createCGImage(orientedMirroredCI, from: orientedMirroredCI.extent) else {
            return
        }
        
        let finalCG: CGImage
        if !selectedBackdrop.isNone {
            finalCG = BackdropCompositorService.composite(
                cgImage: rawCG,
                backdrop: selectedBackdrop,
                quality: .liveFast,
                ciContext: self.ciContext
            )
        } else {
            finalCG = rawCG
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
                    self.photoContinuation?.resume(throwing: error)
                    self.photoContinuation = nil
                }
                return
            }
            
            guard let data = photoData,
                  let image = UIImage(data: data),
                  let rawCG = image.cgImage else {
                await MainActor.run {
                    self.photoContinuation?.resume(throwing: CameraError.invalidResponse)
                    self.photoContinuation = nil
                }
                return
            }
            
            // Step 1: Orient and horizontally mirror raw front-camera frame into upright selfie coordinates
            let rawCI = CIImage(cgImage: rawCG)
            let orientedMirroredCI = BackdropCompositorService.orientAndMirrorFrontCameraCIImage(
                rawCI,
                interfaceOrientation: cachedOrientation
            )
            let uprightSubjectCG = ciCtx.createCGImage(orientedMirroredCI, from: orientedMirroredCI.extent) ?? rawCG
            
            // Step 2: Run single-pass subject auto-exposure BEFORE backdrop compositing
            let exposedSubjectUI = SonyUSBCameraClient.autoExposeCapturedUIImage(
                UIImage(cgImage: uprightSubjectCG, scale: 1.0, orientation: .up)
            )
            let exposedSubjectCG = exposedSubjectUI.cgImage ?? uprightSubjectCG
            
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
                    self.photoContinuation?.resume(throwing: CameraError.invalidResponse)
                    self.photoContinuation = nil
                }
                return
            }
            
            let filename = "local_" + UUID().uuidString + ".jpg"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            
            do {
                try finalData.write(to: url, options: .atomic)
                await MainActor.run {
                    self.photoContinuation?.resume(returning: [url.absoluteString])
                    self.photoContinuation = nil
                }
            } catch {
                await MainActor.run {
                    self.photoContinuation?.resume(throwing: error)
                    self.photoContinuation = nil
                }
            }
        }
    }
}
