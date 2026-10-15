import Foundation

nonisolated enum ForegroundFitMode: String, Codable, CaseIterable, Sendable {
    case stretchToEdges = "stretch"
    case aspectFit = "fit"
    case aspectFill = "fill"
    
    var title: String {
        switch self {
        case .stretchToEdges: return "Stretch to Edges (Best for Borders)"
        case .aspectFit: return "Fit Entire Frame"
        case .aspectFill: return "Fill & Crop"
        }
    }
    
    var displayName: String { title }
}

nonisolated struct BackdropItem: Identifiable, Codable, Equatable, Sendable {
    static let noneID = "none"
    
    static let none = BackdropItem(
        id: noneID,
        displayName: "Original",
        backgroundFilename: nil,
        foregroundFilename: nil,
        foregroundFitMode: .stretchToEdges,
        isBundled: true,
        isEnabled: true
    )
    
    let id: String
    var displayName: String
    var backgroundFilename: String?
    var foregroundFilename: String?
    var foregroundFitMode: ForegroundFitMode = .stretchToEdges
    var isBundled: Bool = false
    var isEnabled: Bool = true
    
    var isNone: Bool {
        id == Self.noneID || (backgroundFilename == nil && foregroundFilename == nil)
    }
    
    var hasBackground: Bool {
        guard let bg = backgroundFilename else { return false }
        return !bg.isEmpty
    }
    
    var hasForeground: Bool {
        guard let fg = foregroundFilename else { return false }
        return !fg.isEmpty
    }
    
    var isCombo: Bool {
        hasBackground && hasForeground
    }
    
    var isCustom: Bool {
        !isNone && !isBundled
    }
    
    var badgeLabel: String {
        if isNone { return "Live Room" }
        if hasBackground && hasForeground { return "Bg + Frame" }
        if hasBackground { return "Background" }
        return "Frame"
    }
}

nonisolated struct PhotoBackdropManifestEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let captureTimestampUTC: Date
    
    /// Lock 1: Camera filename parsed from Sony PTP `0x1008` `GetObjectInfo` dataset (e.g., `"DSC04821.JPG"`), if reported.
    var ptpFilename: String?
    
    /// Lock 2: Camera EXIF `DateTimeOriginal` string (`"YYYY:MM:DD HH:MM:SS"`) extracted from the raw JPEG before normalization.
    var exifDateTimeOriginal: String?
    var exifSubSecOriginal: String?
    
    /// Lock 3: 192-byte (`8x8x3`) sRGB perceptual signature of the un-composited subject image to disambiguate same-second shots.
    var rgbSignature8x8: [UInt8]
    
    let backdropID: String
    let backdropDisplayName: String
    var backgroundFilename: String?
    var foregroundFilename: String?
    var foregroundFitMode: ForegroundFitMode
    
    /// Optional Base64-encoded image bytes embedded directly in JSON ONLY for custom backdrops created in-app on the iPad
    /// (so the Mac app can apply them at full resolution without writing extra `.jpg`/`.png` files into the SmugMug folder).
    var customBackgroundData: Data?
    var customForegroundData: Data?
    
    var appliedToFullRes: Bool = false
    var matchedFullResFilename: String? = nil
}

nonisolated struct BackdropManifestDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let defaultFilename = "photobooth_backdrop_manifest.json"
    
    var schemaVersion: Int = Self.currentSchemaVersion
    var exportedAtUTC: Date = Date()
    var entries: [PhotoBackdropManifestEntry]
}

nonisolated struct BatchApplyReport: Equatable, Sendable {
    let totalManifestEntries: Int
    let newlyAppliedCount: Int
    let skippedAlreadyAppliedCount: Int
    let unmatchedCount: Int
    let appliedFilenames: [String]
    
    var summaryText: String {
        if totalManifestEntries == 0 {
            return "No backdrop manifest entries found in this folder."
        }
        return "Applied backdrops to \(newlyAppliedCount) photo\(newlyAppliedCount == 1 ? "" : "s") • \(skippedAlreadyAppliedCount) already applied • \(unmatchedCount) unmatched."
    }
    
    var summaryMessage: String { summaryText }
}
