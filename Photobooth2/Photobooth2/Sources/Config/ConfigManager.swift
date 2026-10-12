import Foundation
import Combine

class ConfigManager: ObservableObject {
    static let shared = ConfigManager()
    
    @Published var initialCountdownSec: Int { didSet { save() } }
    @Published var interShotCountdownSec: Int { didSet { save() } }
    @Published var photoCount: Int { didSet { save() } }
    @Published var previewDurationSec: Int { didSet { save() } }
    @Published var cameraEndpoint: String { didSet { save() } }
    @Published var cameraSSID: String { didSet { save() } }
    @Published var cameraPassword: String { didSet { save() } }
    @Published var useLocalCamera: Bool { didSet { save() } }
    @Published var saveToPhotos: Bool { didSet { save() } }
    @Published var showGuidanceText: Bool { didSet { save() } }
    @Published var enableImageSharing: Bool { didSet { save() } }
    @Published var enableGIFMode: Bool { didSet { save() } }
    @Published var gifFrameCount: Int { didSet { save() } }
    @Published var gifCaptureInterval: Double { didSet { save() } }
    @Published var gifFrameDuration: Double { didSet { save() } }
    @Published var gifPreviewDuration: Double { didSet { save() } }
    @Published var gifResolution: Int { didSet { save() } } // 0: 720p, 1: 480p
    @Published var gifRetrievalWindowHours: Int { didSet { save() } }
    @Published var pendingGIFFramesToDelete: Int { didSet { save() } }

    // QR Code Configuration
    @Published var isQRCodeEnabled: Bool { didSet { save() } }
    @Published var qrCodeURLString: String { didSet { save() } }
    @Published var daysUntilPhotosAvailable: Int { didSet { save() } }

    private init() {
        // Load from UserDefaults or use defaults
        self.initialCountdownSec = UserDefaults.standard.object(forKey: "initialCountdownSec") as? Int ?? 5
        self.interShotCountdownSec = UserDefaults.standard.object(forKey: "interShotCountdownSec") as? Int ?? 3
        self.photoCount = UserDefaults.standard.object(forKey: "photoCount") as? Int ?? 3
        self.previewDurationSec = UserDefaults.standard.object(forKey: "previewDurationSec") as? Int ?? 4
        self.cameraEndpoint = UserDefaults.standard.string(forKey: "cameraEndpoint") ?? "http://192.168.122.1:8080/sony"
        self.cameraSSID = UserDefaults.standard.string(forKey: "cameraSSID") ?? "DIRECT-1EE0:Sony_a7rii"
        self.cameraPassword = UserDefaults.standard.string(forKey: "cameraPassword") ?? "KjTb5LPc"
        self.useLocalCamera = UserDefaults.standard.object(forKey: "useLocalCamera") as? Bool ?? false
        self.saveToPhotos = UserDefaults.standard.object(forKey: "saveToPhotos") as? Bool ?? true // Default to true
        self.showGuidanceText = UserDefaults.standard.object(forKey: "showGuidanceText") as? Bool ?? true // Default to true
        self.enableImageSharing = UserDefaults.standard.object(forKey: "enableImageSharing") as? Bool ?? true // Default to true

        // Animated GIF Defaults
        self.enableGIFMode = UserDefaults.standard.object(forKey: "enableGIFMode") as? Bool ?? true
        self.gifFrameCount = UserDefaults.standard.object(forKey: "gifFrameCount") as? Int ?? 4
        self.gifCaptureInterval = UserDefaults.standard.object(forKey: "gifCaptureInterval") as? Double ?? 0.25
        self.gifFrameDuration = UserDefaults.standard.object(forKey: "gifFrameDuration") as? Double ?? 0.25
        self.gifPreviewDuration = UserDefaults.standard.object(forKey: "gifPreviewDuration") as? Double ?? 8.0
        self.gifResolution = UserDefaults.standard.object(forKey: "gifResolution") as? Int ?? 0 // Default 720p
        self.gifRetrievalWindowHours = UserDefaults.standard.object(forKey: "gifRetrievalWindowHours") as? Int ?? 24
        self.pendingGIFFramesToDelete = UserDefaults.standard.object(forKey: "pendingGIFFramesToDelete") as? Int ?? 0

        // QR Code Defaults
        self.isQRCodeEnabled = UserDefaults.standard.object(forKey: "isQRCodeEnabled") as? Bool ?? false
        let currentYear = Calendar.current.component(.year, from: Date())
        self.qrCodeURLString = UserDefaults.standard.string(forKey: "qrCodeURLString") ?? "https://www.joshal.com/\(currentYear)"
        self.daysUntilPhotosAvailable = UserDefaults.standard.object(forKey: "daysUntilPhotosAvailable") as? Int ?? 2
        
        // Migration: Fix old default SSID if present
        if self.cameraSSID == "DIRECT-xxxx:Sony" {
            self.cameraSSID = "DIRECT-1EE0:Sony_a7rii"
            // Also ensure password is correct if it was empty/default
            if self.cameraPassword.isEmpty {
                self.cameraPassword = "KjTb5LPc"
            }
            save()
        }
    }
    
    func save() {
        UserDefaults.standard.set(initialCountdownSec, forKey: "initialCountdownSec")
        UserDefaults.standard.set(interShotCountdownSec, forKey: "interShotCountdownSec")
        UserDefaults.standard.set(photoCount, forKey: "photoCount")
        UserDefaults.standard.set(previewDurationSec, forKey: "previewDurationSec")
        UserDefaults.standard.set(cameraEndpoint, forKey: "cameraEndpoint")
        UserDefaults.standard.set(cameraSSID, forKey: "cameraSSID")
        UserDefaults.standard.set(cameraPassword, forKey: "cameraPassword")
        UserDefaults.standard.set(useLocalCamera, forKey: "useLocalCamera")
        UserDefaults.standard.set(saveToPhotos, forKey: "saveToPhotos")
        UserDefaults.standard.set(showGuidanceText, forKey: "showGuidanceText")
        UserDefaults.standard.set(enableImageSharing, forKey: "enableImageSharing")

        UserDefaults.standard.set(enableGIFMode, forKey: "enableGIFMode")
        UserDefaults.standard.set(gifFrameCount, forKey: "gifFrameCount")
        UserDefaults.standard.set(gifCaptureInterval, forKey: "gifCaptureInterval")
        UserDefaults.standard.set(gifFrameDuration, forKey: "gifFrameDuration")
        UserDefaults.standard.set(gifPreviewDuration, forKey: "gifPreviewDuration")
        UserDefaults.standard.set(gifResolution, forKey: "gifResolution")
        UserDefaults.standard.set(gifRetrievalWindowHours, forKey: "gifRetrievalWindowHours")
        UserDefaults.standard.set(pendingGIFFramesToDelete, forKey: "pendingGIFFramesToDelete")

        UserDefaults.standard.set(isQRCodeEnabled, forKey: "isQRCodeEnabled")
        UserDefaults.standard.set(qrCodeURLString, forKey: "qrCodeURLString")
        UserDefaults.standard.set(daysUntilPhotosAvailable, forKey: "daysUntilPhotosAvailable")
    }
    
    func resetToDefaults() {
        self.initialCountdownSec = 5
        self.interShotCountdownSec = 3
        self.photoCount = 3
        self.previewDurationSec = 4
        self.cameraEndpoint = "http://192.168.122.1:8080/sony"
        self.cameraSSID = "DIRECT-1EE0:Sony_a7rii"
        self.cameraPassword = "KjTb5LPc"
        self.useLocalCamera = false
        self.saveToPhotos = true
        self.showGuidanceText = true
        self.enableImageSharing = true

        self.enableGIFMode = true
        self.gifFrameCount = 4
        self.gifCaptureInterval = 0.25
        self.gifFrameDuration = 0.25
        self.gifPreviewDuration = 6.0
        self.gifResolution = 0 // 720p
        self.gifRetrievalWindowHours = 24
        self.pendingGIFFramesToDelete = 0

        self.isQRCodeEnabled = false
        let currentYear = Calendar.current.component(.year, from: Date())
        self.qrCodeURLString = "https://www.joshal.com/\(currentYear)"
        self.daysUntilPhotosAvailable = 2
        save()
    }
}
