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
    
    /// Returns `true` when this manifest entry records an intentional "Original" (no background / no foreground) photo capture.
    var isNoneBackdrop: Bool {
        backdropID == BackdropItem.noneID || (backgroundFilename == nil && foregroundFilename == nil)
    }
    
    init(
        id: UUID = UUID(),
        captureTimestampUTC: Date = Date(),
        ptpFilename: String? = nil,
        exifDateTimeOriginal: String? = nil,
        exifSubSecOriginal: String? = nil,
        rgbSignature8x8: [UInt8] = [],
        backdropID: String,
        backdropDisplayName: String,
        backgroundFilename: String? = nil,
        foregroundFilename: String? = nil,
        foregroundFitMode: ForegroundFitMode = .stretchToEdges,
        customBackgroundData: Data? = nil,
        customForegroundData: Data? = nil,
        appliedToFullRes: Bool = false,
        matchedFullResFilename: String? = nil
    ) {
        self.id = id
        self.captureTimestampUTC = captureTimestampUTC
        self.ptpFilename = ptpFilename
        self.exifDateTimeOriginal = exifDateTimeOriginal
        self.exifSubSecOriginal = exifSubSecOriginal
        self.rgbSignature8x8 = rgbSignature8x8
        self.backdropID = backdropID
        self.backdropDisplayName = backdropDisplayName
        self.backgroundFilename = backgroundFilename
        self.foregroundFilename = foregroundFilename
        self.foregroundFitMode = foregroundFitMode
        self.customBackgroundData = customBackgroundData
        self.customForegroundData = customForegroundData
        self.appliedToFullRes = appliedToFullRes
        self.matchedFullResFilename = matchedFullResFilename
    }
    
    private enum CodingKeys: String, CodingKey {
        case id
        case captureTimestampUTC
        case ptpFilename
        case exifDateTimeOriginal
        case exifSubSecOriginal
        case rgbSignature8x8
        case backdropID
        case backdropDisplayName
        case backgroundFilename
        case foregroundFilename
        case foregroundFitMode
        case customBackgroundData
        case customForegroundData
        case appliedToFullRes
        case matchedFullResFilename
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        self.captureTimestampUTC = (try? container.decode(Date.self, forKey: .captureTimestampUTC)) ?? Date()
        self.ptpFilename = try? container.decodeIfPresent(String.self, forKey: .ptpFilename)
        self.exifDateTimeOriginal = try? container.decodeIfPresent(String.self, forKey: .exifDateTimeOriginal)
        self.exifSubSecOriginal = try? container.decodeIfPresent(String.self, forKey: .exifSubSecOriginal)
        self.rgbSignature8x8 = (try? container.decode([UInt8].self, forKey: .rgbSignature8x8)) ?? []
        self.backdropID = try container.decode(String.self, forKey: .backdropID)
        self.backdropDisplayName = (try? container.decode(String.self, forKey: .backdropDisplayName)) ?? self.backdropID
        self.backgroundFilename = try? container.decodeIfPresent(String.self, forKey: .backgroundFilename)
        self.foregroundFilename = try? container.decodeIfPresent(String.self, forKey: .foregroundFilename)
        self.foregroundFitMode = (try? container.decode(ForegroundFitMode.self, forKey: .foregroundFitMode)) ?? .stretchToEdges
        self.customBackgroundData = try? container.decodeIfPresent(Data.self, forKey: .customBackgroundData)
        self.customForegroundData = try? container.decodeIfPresent(Data.self, forKey: .customForegroundData)
        self.appliedToFullRes = (try? container.decode(Bool.self, forKey: .appliedToFullRes)) ?? false
        self.matchedFullResFilename = try? container.decodeIfPresent(String.self, forKey: .matchedFullResFilename)
    }
}

nonisolated struct BackdropManifestDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let defaultFilename = "photobooth_backdrop_manifest.json"
    
    var schemaVersion: Int = Self.currentSchemaVersion
    var exportedAtUTC: Date = Date()
    var entries: [PhotoBackdropManifestEntry]
    /// Deduplicated Base64-encoded image bytes keyed by filename for custom iPad-added backdrops,
    /// avoiding duplicating megabytes of image data across every entry in the JSON file.
    var customAssetsByFilename: [String: Data]? = nil
    
    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        exportedAtUTC: Date = Date(),
        entries: [PhotoBackdropManifestEntry],
        customAssetsByFilename: [String: Data]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAtUTC = exportedAtUTC
        self.entries = entries
        self.customAssetsByFilename = customAssetsByFilename
    }
    
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case exportedAtUTC
        case entries
        case customAssetsByFilename
    }
    
    private struct LossyDecodableEntry: Decodable {
        let entry: PhotoBackdropManifestEntry?
        init(from decoder: Decoder) throws {
            self.entry = try? PhotoBackdropManifestEntry(from: decoder)
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = (try? container.decode(Int.self, forKey: .schemaVersion)) ?? Self.currentSchemaVersion
        self.exportedAtUTC = (try? container.decode(Date.self, forKey: .exportedAtUTC)) ?? Date()
        if let strictEntries = try? container.decode([PhotoBackdropManifestEntry].self, forKey: .entries) {
            self.entries = strictEntries
        } else if let lossyEntries = try? container.decode([LossyDecodableEntry].self, forKey: .entries) {
            self.entries = lossyEntries.compactMap(\.entry)
        } else {
            self.entries = []
        }
        self.customAssetsByFilename = try? container.decodeIfPresent([String: Data].self, forKey: .customAssetsByFilename)
    }
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

