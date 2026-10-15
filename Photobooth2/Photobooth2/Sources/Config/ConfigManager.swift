import Foundation
import Combine

class ConfigManager: ObservableObject {
    static let shared = ConfigManager()
    
    @Published var initialCountdownSec: Int { didSet { save() } }
    @Published var interShotCountdownSec: Int { didSet { save() } }
    @Published var photoCount: Int { didSet { save() } }
    @Published var previewDurationSec: Int { didSet { save() } }
    @Published var useLocalCamera: Bool { didSet { save() } }
    @Published var saveToPhotos: Bool { didSet { save() } }
    @Published var showGuidanceText: Bool { didSet { save() } }
    @Published var enableImageSharing: Bool { didSet { save() } }
    @Published var enableGIFMode: Bool { didSet { save() } }
    @Published var gifFrameCount: Int { didSet { save() } }
    @Published var gifCaptureInterval: Double {
        didSet {
            if gifCaptureInterval < 0.5 {
                gifCaptureInterval = 0.5
            }
            save()
        }
    }
    @Published var gifFrameDuration: Double { didSet { save() } }
    @Published var gifPreviewDuration: Double { didSet { save() } }
    @Published var gifResolution: Int { didSet { save() } } // 0: 720p, 1: 480p
    @Published var gifRetrievalWindowHours: Int { didSet { save() } }

    // QR Code Configuration
    @Published var isQRCodeEnabled: Bool { didSet { save() } }
    @Published var qrCodeURLString: String { didSet { save() } }
    @Published var daysUntilPhotosAvailable: Int { didSet { save() } }
    
    // Backdrop / Foreground Frame Configuration
    @Published var defaultBackdropID: String { didSet { save() } }

    private init() {
        self.initialCountdownSec = UserDefaults.standard.object(forKey: "initialCountdownSec") as? Int ?? 5
        self.interShotCountdownSec = UserDefaults.standard.object(forKey: "interShotCountdownSec") as? Int ?? 3
        self.photoCount = UserDefaults.standard.object(forKey: "photoCount") as? Int ?? 3
        self.previewDurationSec = UserDefaults.standard.object(forKey: "previewDurationSec") as? Int ?? 4
        self.useLocalCamera = UserDefaults.standard.object(forKey: "useLocalCamera") as? Bool ?? false
        self.saveToPhotos = UserDefaults.standard.object(forKey: "saveToPhotos") as? Bool ?? true
        self.showGuidanceText = UserDefaults.standard.object(forKey: "showGuidanceText") as? Bool ?? true
        self.enableImageSharing = UserDefaults.standard.object(forKey: "enableImageSharing") as? Bool ?? true

        // Animated GIF Defaults (Min Time Between GIFs defaults to 3.0s, minimum 0.5s)
        self.enableGIFMode = UserDefaults.standard.object(forKey: "enableGIFMode") as? Bool ?? true
        self.gifFrameCount = UserDefaults.standard.object(forKey: "gifFrameCount") as? Int ?? 4
        let savedInterval = UserDefaults.standard.object(forKey: "minTimeBetweenGIFs_v2") as? Double ?? 3.0
        self.gifCaptureInterval = max(0.5, savedInterval)
        self.gifFrameDuration = UserDefaults.standard.object(forKey: "gifFrameDuration") as? Double ?? 0.25
        self.gifPreviewDuration = UserDefaults.standard.object(forKey: "gifPreviewDuration") as? Double ?? 8.0
        self.gifResolution = 0 // 1080p
        self.gifRetrievalWindowHours = UserDefaults.standard.object(forKey: "gifRetrievalWindowHours") as? Int ?? 24

        // QR Code Defaults (Enabled by default)
        self.isQRCodeEnabled = UserDefaults.standard.object(forKey: "isQRCodeEnabled_v2") as? Bool ?? true
        let currentYear = Calendar.current.component(.year, from: Date())
        self.qrCodeURLString = UserDefaults.standard.string(forKey: "qrCodeURLString") ?? "https://www.joshal.com/\(currentYear)"
        self.daysUntilPhotosAvailable = UserDefaults.standard.object(forKey: "daysUntilPhotosAvailable") as? Int ?? 2
        self.defaultBackdropID = UserDefaults.standard.string(forKey: "defaultBackdropID") ?? BackdropItem.noneID
    }
    
    func save() {
        UserDefaults.standard.set(initialCountdownSec, forKey: "initialCountdownSec")
        UserDefaults.standard.set(interShotCountdownSec, forKey: "interShotCountdownSec")
        UserDefaults.standard.set(photoCount, forKey: "photoCount")
        UserDefaults.standard.set(previewDurationSec, forKey: "previewDurationSec")
        UserDefaults.standard.set(useLocalCamera, forKey: "useLocalCamera")
        UserDefaults.standard.set(saveToPhotos, forKey: "saveToPhotos")
        UserDefaults.standard.set(showGuidanceText, forKey: "showGuidanceText")
        UserDefaults.standard.set(enableImageSharing, forKey: "enableImageSharing")

        UserDefaults.standard.set(enableGIFMode, forKey: "enableGIFMode")
        UserDefaults.standard.set(gifFrameCount, forKey: "gifFrameCount")
        UserDefaults.standard.set(max(0.5, gifCaptureInterval), forKey: "minTimeBetweenGIFs_v2")
        UserDefaults.standard.set(gifFrameDuration, forKey: "gifFrameDuration")
        UserDefaults.standard.set(gifPreviewDuration, forKey: "gifPreviewDuration")
        UserDefaults.standard.set(gifResolution, forKey: "gifResolution")
        UserDefaults.standard.set(gifRetrievalWindowHours, forKey: "gifRetrievalWindowHours")

        UserDefaults.standard.set(isQRCodeEnabled, forKey: "isQRCodeEnabled_v2")
        UserDefaults.standard.set(qrCodeURLString, forKey: "qrCodeURLString")
        UserDefaults.standard.set(daysUntilPhotosAvailable, forKey: "daysUntilPhotosAvailable")
        UserDefaults.standard.set(defaultBackdropID, forKey: "defaultBackdropID")
    }
    
    func resetToDefaults() {
        self.initialCountdownSec = 5
        self.interShotCountdownSec = 3
        self.photoCount = 3
        self.previewDurationSec = 4
        self.useLocalCamera = false
        self.saveToPhotos = true
        self.showGuidanceText = true
        self.enableImageSharing = true

        self.enableGIFMode = true
        self.gifFrameCount = 4
        self.gifCaptureInterval = 3.0
        self.gifFrameDuration = 0.25
        self.gifPreviewDuration = 6.0
        self.gifResolution = 0 // 1080p
        self.gifRetrievalWindowHours = 24

        self.isQRCodeEnabled = true
        let currentYear = Calendar.current.component(.year, from: Date())
        self.qrCodeURLString = "https://www.joshal.com/\(currentYear)"
        self.daysUntilPhotosAvailable = 2
        self.defaultBackdropID = BackdropItem.noneID
        save()
    }
}
