import Foundation
import UIKit
import Combine

final class BackdropManager: ObservableObject {
    static let shared = BackdropManager()
    
    @Published private(set) var availableBackdrops: [BackdropItem] = [.none]
    
    var allBackdrops: [BackdropItem] {
        availableBackdrops
    }
    
    /// Only enabled backdrops (always starting with `.none` "Original") for the main-screen guest carousel.
    var enabledBackdrops: [BackdropItem] {
        let enabled = availableBackdrops.filter { $0.id == BackdropItem.noneID || $0.isEnabled }
        if enabled.first?.id == BackdropItem.noneID {
            return enabled
        }
        return [.none] + enabled.filter { $0.id != BackdropItem.noneID }
    }
    
    private let disabledIDsKey = "Photobooth2.disabledBackdropIDs"
    private let fitModesKey = "Photobooth2.backdropFitModes"
    private var thumbnailCache: [String: UIImage] = [:]
    
    private init() {
        ensureDocumentsBackdropsDirectoryExists()
        reloadBackdrops()
    }
    
    nonisolated static var documentsBackdropsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("Backdrops", isDirectory: true)
    }
    
    nonisolated static var sourceTreeBackdropsDirectory: URL {
        // Resolves `<repo>/Photobooth2/Photobooth2/Backdrops` dynamically from `#filePath`
        let thisFile = URL(fileURLWithPath: #filePath)
        let targetRoot = thisFile
            .deletingLastPathComponent() // Services
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // Photobooth2
        return targetRoot.appendingPathComponent("Backdrops", isDirectory: true)
    }
    
    private func ensureDocumentsBackdropsDirectoryExists() {
        try? FileManager.default.createDirectory(
            at: Self.documentsBackdropsDirectory,
            withIntermediateDirectories: true
        )
    }
    
    func reloadBackdrops() {
        ensureDocumentsBackdropsDirectoryExists()
        let disabledIDs = Set(UserDefaults.standard.stringArray(forKey: disabledIDsKey) ?? [])
        let savedFitModes = (UserDefaults.standard.dictionary(forKey: fitModesKey) as? [String: String]) ?? [:]
        
        var searchDirs: [(url: URL, isBundled: Bool, requireExplicitSuffix: Bool)] = []
        
        // 1. App Bundle Backdrops/ subdirectory (if preserved as folder)
        if let bundleURL = Bundle.main.resourceURL {
            let bundleBackdrops = bundleURL.appendingPathComponent("Backdrops", isDirectory: true)
            if FileManager.default.fileExists(atPath: bundleBackdrops.path) {
                searchDirs.append((bundleBackdrops, true, false))
            }
            // 2. App Bundle root (Xcode PBXFileSystemSynchronizedRootGroup flattens resource files here)
            searchDirs.append((bundleURL, true, true))
        }
        
        // 3. On Mac, also scan the project's Backdrops/ folder directly if present so newly dropped files
        //    are immediately available on Mac without needing to rebuild the Mac target.
        let sourceBackdrops = Self.sourceTreeBackdropsDirectory
        if FileManager.default.fileExists(atPath: sourceBackdrops.path) {
            searchDirs.append((sourceBackdrops, true, false))
        }
        let macProjectBackdrops = URL(fileURLWithPath: "/Users/joshal/workspace/PhotoboothApp2/Photobooth2/Photobooth2/Backdrops", isDirectory: true)
        if macProjectBackdrops.standardizedFileURL != sourceBackdrops.standardizedFileURL,
           FileManager.default.fileExists(atPath: macProjectBackdrops.path) {
            searchDirs.append((macProjectBackdrops, true, false))
        }
        
        // 4. Documents/Backdrops/ (in-app added or Files.app dropped backdrops)
        searchDirs.append((Self.documentsBackdropsDirectory, false, false))
        
        let discovered = Self.discoverBackdrops(from: searchDirs, disabledIDs: disabledIDs, fitModes: savedFitModes)
        self.availableBackdrops = [.none] + discovered
        self.thumbnailCache.removeAll()
        BackdropCompositorService.clearCache()
        
        // If the configured defaultBackdropID was disabled or deleted, reset it to `.none` so the Settings Picker stays valid
        let currentDefault = ConfigManager.shared.defaultBackdropID
        if currentDefault != BackdropItem.noneID,
           !self.enabledBackdrops.contains(where: { $0.id == currentDefault }) {
            ConfigManager.shared.defaultBackdropID = BackdropItem.noneID
        }
    }
    
    func backdrop(forID id: String) -> BackdropItem {
        if id == BackdropItem.noneID { return .none }
        return availableBackdrops.first(where: { $0.id == id && $0.isEnabled }) ?? .none
    }
    
    func setBackdropEnabled(_ id: String, isEnabled: Bool) {
        guard id != BackdropItem.noneID else { return }
        var disabled = Set(UserDefaults.standard.stringArray(forKey: disabledIDsKey) ?? [])
        if isEnabled {
            disabled.remove(id)
        } else {
            disabled.insert(id)
        }
        UserDefaults.standard.set(Array(disabled), forKey: disabledIDsKey)
        reloadBackdrops()
    }
    
    func setBackdropEnabled(id: String, isEnabled: Bool) {
        setBackdropEnabled(id, isEnabled: isEnabled)
    }
    
    func setForegroundFitMode(for id: String, fitMode: ForegroundFitMode) {
        var map = (UserDefaults.standard.dictionary(forKey: fitModesKey) as? [String: String]) ?? [:]
        map[id] = fitMode.rawValue
        UserDefaults.standard.set(map, forKey: fitModesKey)
        reloadBackdrops()
    }
    
    func setForegroundFitMode(id: String, mode: ForegroundFitMode) {
        setForegroundFitMode(for: id, fitMode: mode)
    }
    
    /// Adds a custom Background and/or Foreground PNG into `Documents/Backdrops/` using the standard `_bg` / `_fg` naming convention.
    @discardableResult
    func addCustomBackdrop(
        displayName: String,
        backgroundData: Data?,
        backgroundExtension: String = "jpg",
        foregroundPNGData: Data?,
        fitMode: ForegroundFitMode = .stretchToEdges
    ) -> BackdropItem? {
        ensureDocumentsBackdropsDirectoryExists()
        let rawTrimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = rawTrimmed.isEmpty ? "Custom Backdrop" : rawTrimmed
        guard backgroundData != nil || foregroundPNGData != nil else { return nil }
        
        let safeStem = trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let id = Self.normalizedID(from: safeStem)
        
        // Remove any previous custom files for this ID in Documents/Backdrops/ so replacing a Combo with a BG-only
        // (or vice-versa) never leaves stale layers behind.
        let dir = Self.documentsBackdropsDirectory
        if let existing = availableBackdrops.first(where: { $0.id == id && !$0.isBundled }) {
            if let oldBg = existing.backgroundFilename {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(oldBg))
            }
            if let oldFg = existing.foregroundFilename {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(oldFg))
            }
        }
        
        if let bgData = backgroundData {
            let ext = backgroundExtension.lowercased().isEmpty ? "jpg" : backgroundExtension.lowercased()
            let bgURL = dir.appendingPathComponent("\(safeStem)_bg.\(ext)")
            try? bgData.write(to: bgURL, options: .atomic)
        }
        if let fgData = foregroundPNGData {
            let fgURL = dir.appendingPathComponent("\(safeStem)_fg.png")
            try? fgData.write(to: fgURL, options: .atomic)
        }
        
        setForegroundFitMode(for: id, fitMode: fitMode)
        setBackdropEnabled(id, isEnabled: true)
        return availableBackdrops.first(where: { $0.id == id })
    }
    
    /// Removes a custom backdrop's files from `Documents/Backdrops/` (or disables a bundled backdrop).
    func removeBackdrop(_ item: BackdropItem) {
        guard item.id != BackdropItem.noneID else { return }
        let docsDir = Self.documentsBackdropsDirectory
        var removedFile = false
        
        if let bgName = item.backgroundFilename {
            let candidate = docsDir.appendingPathComponent(bgName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                try? FileManager.default.removeItem(at: candidate)
                removedFile = true
            }
        }
        if let fgName = item.foregroundFilename {
            let candidate = docsDir.appendingPathComponent(fgName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                try? FileManager.default.removeItem(at: candidate)
                removedFile = true
            }
        }
        
        if !removedFile {
            // If it's a baked-in bundle asset, mark it disabled so it hides from the carousel
            setBackdropEnabled(item.id, isEnabled: false)
        } else {
            reloadBackdrops()
        }
    }
    
    func deleteCustomBackdrop(id: String) {
        if let item = availableBackdrops.first(where: { $0.id == id }) {
            removeBackdrop(item)
        }
    }
    
    // MARK: - Static Discovery & File Resolution (Callable from Any Thread & QA Suite)
    
    nonisolated static func normalizedID(from baseName: String) -> String {
        let lower = baseName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = CharacterSet.alphanumerics
        let parts = lower.components(separatedBy: allowed.inverted).filter { !$0.isEmpty }
        return parts.joined(separator: "_")
    }
    
    nonisolated static func humanizeDisplayName(from rawStem: String) -> String {
        let spaced = rawStem
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spaced.isEmpty else { return "Backdrop" }
        // Preserve existing capitalization if the user typed capitals, otherwise Title Case
        if spaced != spaced.lowercased() {
            return spaced
        }
        return spaced.capitalized
    }
    
    private enum AssetRole {
        case background(stem: String)
        case foreground(stem: String)
    }
    
    nonisolated private static func isTransparentCenterPNG(url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "png",
              let img = UIImage(contentsOfFile: url.path),
              let cg = img.cgImage else {
            return false
        }
        let alphaInfo = cg.alphaInfo
        let hasAlpha = (alphaInfo == .premultipliedLast || alphaInfo == .premultipliedFirst || alphaInfo == .last || alphaInfo == .first)
        guard hasAlpha else { return false }
        
        let sampleW = 16
        let sampleH = 16
        var rgba = [UInt8](repeating: 255, count: sampleW * sampleH * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &rgba,
            width: sampleW,
            height: sampleH,
            bitsPerComponent: 8,
            bytesPerRow: sampleW * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.clear(CGRect(x: 0, y: 0, width: sampleW, height: sampleH))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: sampleW, height: sampleH))
        
        // Check if center 8x8 region contains transparent cutout pixels (alpha < 180)
        var transparentCount = 0
        for y in 4..<12 {
            for x in 4..<12 {
                let a = rgba[(y * sampleW + x) * 4 + 3]
                if a < 180 {
                    transparentCount += 1
                }
            }
        }
        return transparentCount >= 8
    }
    
    nonisolated private static func classifyBackdropFile(url: URL, requireExplicitSuffix: Bool) -> AssetRole? {
        let filename = url.lastPathComponent
        guard !filename.hasPrefix("."), !filename.hasPrefix("_thumb_") else { return nil }
        let lowerName = filename.lowercased()
        if lowerName.hasPrefix("icon_") || lowerName.hasPrefix("appicon") || lowerName.hasPrefix("launch") || lowerName.hasPrefix("sony_") || lowerName.hasPrefix("local_") || lowerName.hasPrefix("mock_") {
            return nil
        }
        
        let ext = url.pathExtension.lowercased()
        let supportedExts: Set<String> = ["jpg", "jpeg", "png", "heic", "webp", "tif", "tiff"]
        guard supportedExts.contains(ext) else { return nil }
        
        let rawStem = url.deletingPathExtension().lastPathComponent
        let lowerStem = rawStem.lowercased()
        
        let bgSuffixes = ["_bg", "-bg", " bg", "_background", "-background"]
        for suffix in bgSuffixes {
            if lowerStem.hasSuffix(suffix) {
                let cleanStem = String(rawStem.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanStem.isEmpty else { return nil }
                return .background(stem: cleanStem)
            }
        }
        
        let fgSuffixes = ["_fg_fill", "-fg-fill", "_fg", "-fg", " fg", "_frame", "-frame", " frame", "_foreground", "-foreground"]
        for suffix in fgSuffixes {
            if lowerStem.hasSuffix(suffix) {
                let cleanStem = String(rawStem.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanStem.isEmpty else { return nil }
                return .foreground(stem: cleanStem)
            }
        }
        
        // When scanning the root of `.app` bundle, require explicit `_bg` / `_fg` / `_frame` suffixes
        // so random app icons or UI assets are never mistaken for backdrops.
        if requireExplicitSuffix {
            return nil
        }
        
        // Inside a dedicated `Backdrops/` directory, also support subfolder conventions (`Backgrounds/` vs `Foregrounds/`),
        // transparent-center PNG frames without `_fg`, or standalone opaque files (`-> background`).
        let parentFolder = url.deletingLastPathComponent().lastPathComponent.lowercased()
        if parentFolder.contains("foreground") || parentFolder.contains("frame") {
            return .foreground(stem: rawStem)
        }
        if ext == "png" && isTransparentCenterPNG(url: url) {
            return .foreground(stem: rawStem)
        }
        return .background(stem: rawStem)
    }
    
    /// Scans one or more directories and pairs matching `*_bg.*` and `*_fg.*` files by base name.
    nonisolated static func discoverBackdrops(
        in directories: [URL]
    ) -> [BackdropItem] {
        let specs = directories.map { (url: $0, isBundled: false, requireExplicitSuffix: false) }
        return discoverBackdrops(from: specs, disabledIDs: [], fitModes: [:])
    }
    
    nonisolated static func discoverBackdrops(
        from directories: [(url: URL, isBundled: Bool, requireExplicitSuffix: Bool)],
        disabledIDs: Set<String>,
        fitModes: [String: String]
    ) -> [BackdropItem] {
        struct PartialEntry {
            var id: String
            var displayName: String
            var backgroundFilename: String?
            var foregroundFilename: String?
            var isBundled: Bool
        }
        
        var entriesByID: [String: PartialEntry] = [:]
        var orderedIDs: [String] = []
        let fm = FileManager.default
        
        for dirSpec in directories {
            guard let enumerator = fm.enumerator(
                at: dirSpec.url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            
            var fileURLs: [URL] = []
            for case let fileURL as URL in enumerator {
                // If scanning bundle root (`requireExplicitSuffix == true`), do not recurse into subdirectories
                if dirSpec.requireExplicitSuffix && fileURL.deletingLastPathComponent().standardizedFileURL != dirSpec.url.standardizedFileURL {
                    continue
                }
                fileURLs.append(fileURL)
            }
            fileURLs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            
            for fileURL in fileURLs {
                guard let role = classifyBackdropFile(url: fileURL, requireExplicitSuffix: dirSpec.requireExplicitSuffix) else {
                    continue
                }
                
                switch role {
                case .background(let stem):
                    let id = normalizedID(from: stem)
                    guard !id.isEmpty, id != BackdropItem.noneID else { continue }
                    if entriesByID[id] == nil {
                        orderedIDs.append(id)
                        entriesByID[id] = PartialEntry(
                            id: id,
                            displayName: humanizeDisplayName(from: stem),
                            backgroundFilename: fileURL.lastPathComponent,
                            foregroundFilename: nil,
                            isBundled: dirSpec.isBundled
                        )
                    } else {
                        // Prefer user Documents override if present, or fill missing background slot
                        if !dirSpec.isBundled || entriesByID[id]?.backgroundFilename == nil {
                            entriesByID[id]?.backgroundFilename = fileURL.lastPathComponent
                        }
                    }
                    
                case .foreground(let stem):
                    let id = normalizedID(from: stem)
                    guard !id.isEmpty, id != BackdropItem.noneID else { continue }
                    if entriesByID[id] == nil {
                        orderedIDs.append(id)
                        entriesByID[id] = PartialEntry(
                            id: id,
                            displayName: humanizeDisplayName(from: stem),
                            backgroundFilename: nil,
                            foregroundFilename: fileURL.lastPathComponent,
                            isBundled: dirSpec.isBundled
                        )
                    } else {
                        if !dirSpec.isBundled || entriesByID[id]?.foregroundFilename == nil {
                            entriesByID[id]?.foregroundFilename = fileURL.lastPathComponent
                        }
                    }
                }
            }
        }
        
        return orderedIDs.compactMap { id in
            guard let entry = entriesByID[id] else { return nil }
            let fitMode = fitModes[id].flatMap(ForegroundFitMode.init(rawValue:)) ?? .stretchToEdges
            return BackdropItem(
                id: entry.id,
                displayName: entry.displayName,
                backgroundFilename: entry.backgroundFilename,
                foregroundFilename: entry.foregroundFilename,
                foregroundFitMode: fitMode,
                isBundled: entry.isBundled,
                isEnabled: !disabledIDs.contains(entry.id)
            )
        }
    }
    
    /// Resolves a backdrop asset filename (e.g. `"Eiffel Tower_bg.jpg"`) across Documents, App Bundle, Mac Project Folder, or additional search folders.
    nonisolated static func resolveAssetURL(
        filename: String?,
        additionalSearchDirectories: [URL] = []
    ) -> URL? {
        guard let filename = filename, !filename.isEmpty else { return nil }
        let fm = FileManager.default
        
        // If already a full path that exists
        if filename.hasPrefix("/"), fm.fileExists(atPath: filename) {
            return URL(fileURLWithPath: filename)
        }
        if filename.hasPrefix("file://"), let url = URL(string: filename), fm.fileExists(atPath: url.path) {
            return url
        }
        
        var candidateDirs: [URL] = []
        candidateDirs.append(contentsOf: additionalSearchDirectories)
        candidateDirs.append(documentsBackdropsDirectory)
        
        if let bundleURL = Bundle.main.resourceURL {
            candidateDirs.append(bundleURL.appendingPathComponent("Backdrops", isDirectory: true))
            candidateDirs.append(bundleURL)
        }
        
        candidateDirs.append(sourceTreeBackdropsDirectory)
        let macProjectBackdrops = URL(fileURLWithPath: "/Users/joshal/workspace/PhotoboothApp2/Photobooth2/Photobooth2/Backdrops", isDirectory: true)
        candidateDirs.append(macProjectBackdrops)
        
        for dir in candidateDirs {
            let direct = dir.appendingPathComponent(filename)
            if fm.fileExists(atPath: direct.path) {
                return direct
            }
        }
        return nil
    }
    
    /// Returns true if the given backdrop is a custom (non-bundled) asset stored only in the iPad's Documents folder,
    /// meaning its bytes should be Base64-embedded into `photobooth_backdrop_manifest.json` for the Mac.
    nonisolated static func isCustomDocumentsOnlyAsset(filename: String?) -> Bool {
        guard let filename = filename, !filename.isEmpty else { return false }
        let docsURL = documentsBackdropsDirectory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: docsURL.path) else { return false }
        
        if let bundleURL = Bundle.main.resourceURL {
            if FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("Backdrops").appendingPathComponent(filename).path) {
                return false
            }
            if FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(filename).path) {
                return false
            }
        }
        return true
    }
    
    // MARK: - Carousel Composite Thumbnail Generator
    
    func thumbnail(for item: BackdropItem) -> UIImage? {
        if item.isNone { return nil }
        if let cached = thumbnailCache[item.id] {
            return cached
        }
        
        let size = CGSize(width: 168, height: 112)
        let renderer = UIGraphicsImageRenderer(size: size)
        let bgURL = Self.resolveAssetURL(filename: item.backgroundFilename)
        let fgURL = Self.resolveAssetURL(filename: item.foregroundFilename)
        
        let bgImage = bgURL.flatMap { UIImage(contentsOfFile: $0.path) }
        let fgImage = fgURL.flatMap { UIImage(contentsOfFile: $0.path) }
        
        let thumb = renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            
            // 1. Background layer (aspect fill) or dark room grid placeholder for frame-only
            if let bg = bgImage {
                let bgSize = bg.size
                if bgSize.width > 0 && bgSize.height > 0 {
                    let scale = max(size.width / bgSize.width, size.height / bgSize.height)
                    let drawW = bgSize.width * scale
                    let drawH = bgSize.height * scale
                    let drawRect = CGRect(
                        x: (size.width - drawW) * 0.5,
                        y: (size.height - drawH) * 0.5,
                        width: drawW,
                        height: drawH
                    )
                    bg.draw(in: drawRect)
                }
            } else {
                UIColor(white: 0.18, alpha: 1.0).setFill()
                ctx.fill(rect)
            }
            
            // 2. Subtle person silhouette indicator in center
            if let personIcon = UIImage(systemName: "person.2.fill")?.withTintColor(
                UIColor.white.withAlphaComponent(bgImage != nil ? 0.82 : 0.45),
                renderingMode: .alwaysOriginal
            ) {
                let iconW: CGFloat = 54
                let iconH: CGFloat = 42
                let iconRect = CGRect(
                    x: (size.width - iconW) * 0.5,
                    y: size.height - iconH - 12,
                    width: iconW,
                    height: iconH
                )
                personIcon.draw(in: iconRect)
            }
            
            // 3. Foreground frame layer
            if let fg = fgImage {
                fg.draw(in: rect)
            }
        }
        
        thumbnailCache[item.id] = thumb
        return thumb
    }
}
