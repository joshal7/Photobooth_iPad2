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
    
    private var photoContinuation: CheckedContinuation<[String], Error>?
    
    override init() {
        super.init()
        checkPermissions()
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
        guard let fileURL = URL(string: url) else {
            throw CameraError.invalidResponse
        }
        return try Data(contentsOf: fileURL)
    }
    
    func checkConnection() async -> Bool {
        return true
    }
    
    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let cvBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: cvBuffer)
        
        Task { @MainActor in
            // Rotate to match UI orientation
            let orientation = UIDevice.current.orientation
            let imageOrientation: UIImage.Orientation
            
            switch orientation {
            case .portrait: imageOrientation = .right
            case .portraitUpsideDown: imageOrientation = .left
            case .landscapeLeft: imageOrientation = .down
            case .landscapeRight: imageOrientation = .up
            default: imageOrientation = .right
            }
            
            let context = CIContext()
            if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
                let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: imageOrientation)
                _previewStream.send(uiImage)
            }
        }
    }
    
    // MARK: - AVCapturePhotoCaptureDelegate
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let photoData = photo.fileDataRepresentation()
        
        Task { @MainActor in
            if let error = error {
                photoContinuation?.resume(throwing: error)
                photoContinuation = nil
                return
            }
            
            guard let data = photoData, let image = UIImage(data: data) else {
                photoContinuation?.resume(throwing: CameraError.invalidResponse)
                photoContinuation = nil
                return
            }
            
            // Determine orientation
            let orientation = UIDevice.current.orientation
            let imageOrientation: UIImage.Orientation
            
            // For Front Camera, we want to MIRROR the result so it looks like the preview.
            // Standard orientations are:
            // Portrait -> Right
            // LandscapeLeft -> Down
            // LandscapeRight -> Up
            //
            // To Mirror:
            // Portrait -> LeftMirrored (This flips it horizontally relative to Right)
            // Actually, let's look at the standard mappings:
            // .right -> .leftMirrored ? No, .right is 90 deg CW.
            //
            // Let's try explicit mapping for Front Camera Mirroring:
            switch orientation {
            case .portrait: imageOrientation = .leftMirrored
            case .portraitUpsideDown: imageOrientation = .rightMirrored
            case .landscapeLeft: imageOrientation = .downMirrored
            case .landscapeRight: imageOrientation = .upMirrored
            default: imageOrientation = .leftMirrored
            }
            
            // Create rotated image
            // Note: We need to actually redraw the image to bake in the orientation if we want it to persist correctly
            // across all viewers, or we can just set the orientation metadata.
            // For simplicity and robustness, let's create a new UIImage with the correct orientation metadata
            // and then save that.
            
            guard let cgImage = image.cgImage else {
                photoContinuation?.resume(throwing: CameraError.invalidResponse)
                photoContinuation = nil
                return
            }
            
            let rotatedImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: imageOrientation)
            
            // Convert back to data (JPEG)
            // We use a high quality compression
            guard let finalData = rotatedImage.jpegData(compressionQuality: 0.9) else {
                photoContinuation?.resume(throwing: CameraError.invalidResponse)
                photoContinuation = nil
                return
            }
            
            // Save to temporary file
            let filename = UUID().uuidString + ".jpg"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            
            do {
                try finalData.write(to: url)
                photoContinuation?.resume(returning: [url.absoluteString])
            } catch {
                photoContinuation?.resume(throwing: error)
            }
            photoContinuation = nil
        }
    }
}
