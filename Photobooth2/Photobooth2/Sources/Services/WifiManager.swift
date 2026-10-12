import Foundation
import NetworkExtension

class WifiManager {
    static let shared = WifiManager()
    
    private init() {}
    
    func connectToCameraWifi(ssid: String, password: String) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let configuration = NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
            configuration.joinOnce = true // Don't auto-join forever, just this session
            
            NEHotspotConfigurationManager.shared.apply(configuration) { error in
                if let error = error {
                    if error.localizedDescription == "already associated." {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume()
                }
            }
        }
    }
    
    func disconnectFromCameraWifi(ssid: String) {
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
    }
    
    func getCurrentSSID() async -> String? {
        return await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.ssid)
            }
        }
    }
}
