import Foundation
import Combine
import UIKit

class SonyCameraClient: CameraService {
    @Published var isConnected: Bool = false
    var connectionStatus: AnyPublisher<Bool, Never> {
        $isConnected.eraseToAnyPublisher()
    }
    
    var previewStream: AnyPublisher<UIImage?, Never> {
        streamer.$currentFrame.eraseToAnyPublisher()
    }
    
    private let session: URLSession
    private let config: ConfigManager
    private let streamer = MJPEGStreamer()
    
    init(config: ConfigManager = .shared) {
        self.config = config
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15.0 // Increased to handle capture delays
        self.session = URLSession(configuration: configuration)
    }
    
    func connect() async throws {
        // 1. Check handshake (startRecMode)
        let endpoint = "\(config.cameraEndpoint)/camera"
        
        do {
            _ = try await sendRPC(method: "startRecMode", params: [], to: endpoint)
            
            // 2. Set Postview Image Size to 2M for faster transfer
            try? await setPostviewImageSize("2M")
            
            DispatchQueue.main.async { self.isConnected = true }
        } catch let error as CameraError {
            if case .apiError(let code, _) = error, code == 40402 {
                // Already in Rec Mode, consider connected
                DispatchQueue.main.async { self.isConnected = true }
                return
            }
            DispatchQueue.main.async { self.isConnected = false }
            throw error
        } catch let error as URLError {
            DispatchQueue.main.async { self.isConnected = false }
            if error.code == .timedOut || error.code == .cannotConnectToHost {
                 throw CameraError.apiError(code: -1, message: "Connection timed out.")
            }
            throw error
        } catch {
            DispatchQueue.main.async { self.isConnected = false }
            throw error
        }
    }
    
    func startLiveView() async throws {
        let endpoint = "\(config.cameraEndpoint)/camera"
        let response = try await sendRPC(method: "startLiveview", params: [], to: endpoint)
        
        guard let result = response["result"] as? [Any],
              let urlString = result.first as? String,
              let url = URL(string: urlString) else {
            throw CameraError.invalidResponse
        }
        
        // Start the internal streamer
        DispatchQueue.main.async {
            self.streamer.start(url: url)
        }
    }
    
    func stopLiveView() {
        streamer.stop()
    }
    
    func takePicture() async throws -> [String] {
        let endpoint = "\(config.cameraEndpoint)/camera"
        // actTakePicture returns a URL array
        let response = try await sendRPC(method: "actTakePicture", params: [], to: endpoint)
        
        guard let result = response["result"] as? [Any],
              let urlArray = result.first as? [String] else {
            throw CameraError.invalidResponse
        }
        return urlArray
    }
    
    func captureBurst(count: Int) async throws -> [String] {
        // Simple single-shot loop - just call takePicture multiple times
        var results: [String] = []
        for i in 0..<count {
            print("Capturing frame \(i + 1)/\(count)...")
            let urls = try await takePicture()
            results.append(contentsOf: urls)
        }
        return results
    }
    
    private func setPostviewImageSize(_ size: String) async throws {
        let endpoint = "\(config.cameraEndpoint)/camera"
        // "Original", "2M", "VGA" are common values. We use "2M".
        _ = try await sendRPC(method: "setPostviewImageSize", params: [size], to: endpoint)
    }
    
    func fetchImage(url: String) async throws -> Data {
        guard let imageURL = URL(string: url) else {
            throw CameraError.invalidResponse
        }
        
        let (data, _) = try await session.data(from: imageURL)
        return data
    }
    
    func checkConnection() async -> Bool {
        let endpoint = "\(config.cameraEndpoint)/camera"
        // Use getEvent with longpolling=false for a quick check
        do {
            _ = try await sendRPC(method: "getEvent", params: [false], to: endpoint)
            return true
        } catch {
            print("Heartbeat failed: \(error)")
            return false
        }
    }
    
    func deleteLastCapturedImages(count: Int) async throws {
        let cameraEndpoint = "\(config.cameraEndpoint)/camera"
        let avContentEndpoint = "\(config.cameraEndpoint)/avContent"
        
        // 1. Switch Camera Function to "Contents Transfer" mode
        print("Switching camera to Contents Transfer mode...")
        do {
            _ = try await sendRPC(method: "setCameraFunction", params: ["Contents Transfer"], to: cameraEndpoint, timeout: 5.0)
        } catch {
            // Camera might reboot its Wi-Fi AP immediately upon receiving the command, terminating the connection and throwing an error. We log it and proceed to wait for reconnection.
            print("setCameraFunction to Contents Transfer terminated connection or failed: \(error). Proceeding to wait for reconnection...")
        }
        
        // Restore Shooting Mode in a defer block
        defer {
            Task {
                do {
                    print("Restoring camera to Remote Shooting mode...")
                    _ = try await self.sendRPC(method: "setCameraFunction", params: ["Remote Shooting"], to: cameraEndpoint, timeout: 5.0)
                    // Re-establish rec mode handshake
                    try await self.connect()
                } catch {
                    print("Failed to restore Remote Shooting mode: \(error)")
                }
            }
        }
        
        // 2. Wait for camera to transition and iPad to reconnect (up to 25 seconds)
        print("Waiting for camera to become online in Contents Transfer mode...")
        var reconnected = false
        let startTime = Date()
        let pollParams: [String: Any] = [
            "uri": "storage:memoryCard1",
            "stIdx": 0,
            "cnt": 1,
            "view": "flat",
            "sort": "descending"
        ]
        
        while Date().timeIntervalSince(startTime) < 25.0 {
            do {
                // Try a quick RPC to see if the server is up and responsive in Contents Transfer mode.
                // We poll using a count of 1 to be highly efficient.
                _ = try await sendRPC(method: "getContentList", params: [pollParams], to: avContentEndpoint, version: "1.3", timeout: 3.0)
                reconnected = true
                print("Reconnected to camera in Contents Transfer mode!")
                break
            } catch {
                print("Camera not reachable yet (waiting for Wi-Fi reconnection...): \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: 1_500_000_000) // Sleep 1.5 seconds before retrying
            }
        }
        
        if !reconnected {
            print("Failed to reconnect to camera after mode switch.")
            throw CameraError.connectionFailed
        }
        
        // 3. Fetch Last URIs
        let getParams: [String: Any] = [
            "uri": "storage:memoryCard1",
            "stIdx": 0,
            "cnt": count,
            "view": "flat",
            "sort": "descending"
        ]
        
        let response = try await sendRPC(method: "getContentList", params: [getParams], to: avContentEndpoint, version: "1.3", timeout: 5.0)
        
        guard let result = response["result"] as? [Any],
              let contentsList = result.first as? [[String: Any]] else {
            throw CameraError.invalidResponse
        }
        
        // Extract the 'uri' from each content item
        let uris = contentsList.compactMap { $0["uri"] as? String }
        if uris.isEmpty {
            print("No URIs found to delete.")
            return
        }
        
        print("Found \(uris.count) URIs to delete. Deleting...")
        
        // 4. Delete Content
        _ = try await sendRPC(method: "deleteContent", params: [["uri": uris]], to: avContentEndpoint, version: "1.1", timeout: 5.0)
        print("Successfully deleted images from camera.")
    }
    
    // MARK: - JSON-RPC Helper
    
    private func sendRPC(method: String, params: [Any], to urlString: String, version: String = "1.0", timeout: TimeInterval = 10.0) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else {
            throw CameraError.connectionFailed
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        
        let payload: [String: Any] = [
            "method": method,
            "params": params,
            "id": 1,
            "version": version
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("RPC Failed: HTTP \(statusCode)")
            throw CameraError.apiError(code: statusCode, message: "HTTP Error \(statusCode)")
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CameraError.invalidResponse
        }
        
        if let error = json["error"] as? [Any], let code = error.first as? Int, let message = error.last as? String {
            throw CameraError.apiError(code: code, message: message)
        }
        
        return json
    }
}
