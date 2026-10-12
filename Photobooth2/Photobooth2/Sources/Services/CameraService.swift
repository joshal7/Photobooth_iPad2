import UIKit
import Combine
import Foundation

protocol CameraService: AnyObject {
    var isConnected: Bool { get }
    var connectionStatus: AnyPublisher<Bool, Never> { get }
    var previewStream: AnyPublisher<UIImage?, Never> { get }
    var statusMessage: String? { get }
    
    func connect() async throws
    func startLiveView() async throws
    func stopLiveView()
    
    /// Configures camera storage routing and shutter state prior to a capture sequence.
    func prepareForCapture(mode: CaptureMode) async throws
    
    /// Restores storage state after a capture sequence completes.
    func finishCaptureSequence(mode: CaptureMode) async
    
    /// Triggers a single capture and returns local `file://` URLs of the downloaded JPEG(s).
    func takePicture() async throws -> [String]
    
    /// Reads image data from a local `file://` URL.
    func fetchImage(url: String) async throws -> Data
    
    /// Checks if the connection to the camera is still active.
    func checkConnection() async -> Bool
}

extension CameraService {
    var statusMessage: String? { nil }
    func prepareForCapture(mode: CaptureMode) async throws {}
    func finishCaptureSequence(mode: CaptureMode) async {}
}

enum CameraError: Error, Equatable {
    case connectionFailed
    case usbMassStorageModeDetected
    case usbPermissionDenied
    case ptpHandshakeFailed(String)
    case invalidResponse
    case timeout
    case apiError(code: Int, message: String)
}

extension CameraError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Sony camera not detected over USB. Ensure the camera is powered on, set to Mode Dial '1' (Remote Shoot USB), and connected via the USB-C hub."
        case .usbMassStorageModeDetected:
            return "Sony camera is connected in 'Mass Storage' mode. Rotate the camera Mode Dial to '1' or set MENU → Setup → USB → USB Connection Mode to 'Remote Shoot (PC Remote)'."
        case .usbPermissionDenied:
            return "USB camera access was denied. Please allow camera and external device access in iPad Settings → Privacy & Security."
        case .ptpHandshakeFailed(let detail):
            return "USB Remote Shoot handshake failed (\(detail)). Ensure 'Smartphone Connection' is set to Off on the camera."
        case .invalidResponse:
            return "Received an invalid response from the camera over USB."
        case .timeout:
            return "The camera timed out while capturing. Ensure the lens is set to Manual Focus (MF) or Release Priority."
        case .apiError(let code, let message):
            return "Camera PTP Error (0x\(String(code, radix: 16, uppercase: true))): \(message)"
        }
    }
}
