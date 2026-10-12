import Foundation
import Combine
import UIKit

class MockCameraClient: CameraService {
    @Published var isConnected: Bool = false
    var connectionStatus: AnyPublisher<Bool, Never> {
        $isConnected.eraseToAnyPublisher()
    }
    
    // Mock stream that emits a random color every frame
    private let _previewStream = PassthroughSubject<UIImage?, Never>()
    var previewStream: AnyPublisher<UIImage?, Never> {
        _previewStream.eraseToAnyPublisher()
    }
    
    private var timer: Timer?
    
    func connect() async throws {
        // Simulate network delay
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        DispatchQueue.main.async { self.isConnected = true }
    }
    
    func startLiveView() async throws {
        try await Task.sleep(nanoseconds: 500_000_000)
        // Start emitting frames
        DispatchQueue.main.async {
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 480))
                let image = renderer.image { ctx in
                    UIColor.random().setFill()
                    ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
                }
                self._previewStream.send(image)
            }
        }
    }
    
    func stopLiveView() {
        timer?.invalidate()
        timer = nil
    }
    
    func takePicture() async throws -> [String] {
        try await Task.sleep(nanoseconds: 2_000_000_000) // Simulate capture delay
        // Return mock image URLs
        return ["http://mock.local/image1.jpg"]
    }
    
    func fetchImage(url: String) async throws -> Data {
        try await Task.sleep(nanoseconds: 500_000_000)
        // Return a solid color image as mock data
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600))
        let image = renderer.image { ctx in
            UIColor.random().setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        }
        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }
    
    func checkConnection() async -> Bool {
        return true
    }
}

extension UIColor {
    static func random() -> UIColor {
        return UIColor(
            red: .random(in: 0...1),
            green: .random(in: 0...1),
            blue: .random(in: 0...1),
            alpha: 1.0
        )
    }
}
