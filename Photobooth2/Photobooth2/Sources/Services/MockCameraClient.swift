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
    
    deinit {
        timer?.invalidate()
    }
    
    func connect() async throws {
        // Simulate network delay
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        self.isConnected = true
    }
    
    func startLiveView() async throws {
        try await Task.sleep(nanoseconds: 500_000_000)
        guard !Task.isCancelled else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 720, height: 480))
            let image = renderer.image { ctx in
                UIColor.random().setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 720, height: 480))
            }
            self._previewStream.send(image)
        }
    }
    
    func stopLiveView() {
        timer?.invalidate()
        timer = nil
    }
    
    func takePicture() async throws -> [String] {
        try await Task.sleep(nanoseconds: 300_000_000) // Simulate capture delay
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 600))
        let image = renderer.image { ctx in
            UIColor.random().setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
        }
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            throw CameraError.invalidResponse
        }
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("mock_\(UUID().uuidString).jpg")
        try data.write(to: fileURL, options: .atomic)
        return [fileURL.absoluteString]
    }
    
    func fetchImage(url: String) async throws -> Data {
        if url.hasPrefix("file://"), let fileURL = URL(string: url),
           let data = try? Data(contentsOf: fileURL) {
            return data
        }
        if FileManager.default.fileExists(atPath: url),
           let data = try? Data(contentsOf: URL(fileURLWithPath: url)) {
            return data
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        // Fallback solid color image as mock data
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 600))
        let image = renderer.image { ctx in
            UIColor.random().setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
        }
        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }
    
    func checkConnection() async -> Bool {
        return isConnected
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
