import Foundation
import Combine
import UIKit

class MJPEGStreamer: NSObject, ObservableObject, URLSessionDataDelegate {
    @Published var currentFrame: UIImage?
    @Published var isStreaming: Bool = false
    
    private var session: URLSession!
    private var dataTask: URLSessionDataTask?
    private var receivedData = Data()
    // Pre-define markers
    private let soi = Data([0xFF, 0xD8])
    private let eoi = Data([0xFF, 0xD9])
    
    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15.0
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Create session with self as delegate
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    
    func start(url: URL) {
        stop()
        
        Task { @MainActor in
            self.isStreaming = true
        }
        
        let request = URLRequest(url: url)
        dataTask = session.dataTask(with: request)
        dataTask?.resume()
    }
    
    func stop() {
        Task { @MainActor in
            self.isStreaming = false
        }
        dataTask?.cancel()
        dataTask = nil
        receivedData.removeAll(keepingCapacity: true)
    }
    
    // MARK: - URLSessionDataDelegate
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedData.append(data)
        
        // Optimization: To prevent lag, we want to find the *latest* complete frame
        // and discard everything before it.
        
        // Search backwards for EOI (End of Image)
        if let eoiRange = receivedData.range(of: eoi, options: .backwards, in: receivedData.startIndex..<receivedData.endIndex) {
            
            // Search backwards for SOI (Start of Image) before the EOI
            if let soiRange = receivedData.range(of: soi, options: .backwards, in: 0..<eoiRange.upperBound) {
                
                // We found a frame!
                let jpegData = receivedData[soiRange.lowerBound..<eoiRange.upperBound]
                
                // Decode image
                if let image = UIImage(data: jpegData) {
                    Task { @MainActor in
                        self.currentFrame = image
                    }
                }
                
                // CRITICAL: Discard everything up to the end of this frame.
                // This ensures we don't process old frames and keeps the buffer small.
                // If there was a newer partial frame after this EOI, it is preserved.
                receivedData.removeSubrange(0..<eoiRange.upperBound)
                
            } else {
                // Found EOI but no SOI? This means we have the tail end of a frame
                // but missed the start (or it was discarded).
                // Discard up to EOI to resync.
                receivedData.removeSubrange(0..<eoiRange.upperBound)
            }
        }
        
        // Safety: Prevent buffer from growing indefinitely if no markers are found
        if receivedData.count > 10_000_000 { // 10MB
            receivedData.removeAll(keepingCapacity: true)
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            print("MJPEG Stream error: \(error)")
        }
        Task { @MainActor in
            self.isStreaming = false
        }
    }
}
