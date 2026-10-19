import Foundation
import Combine
import ImageIO
import UniformTypeIdentifiers
import CoreImage
import UIKit

final class BackdropManifestStore: ObservableObject, @unchecked Sendable {
    nonisolated static let shared = BackdropManifestStore()
    
    @Published private(set) var entries: [PhotoBackdropManifestEntry] = []
    
    private nonisolated final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var document: BackdropManifestDocument
        let storeFileURL: URL
        
        init(storeFileURL: URL, initialDocument: BackdropManifestDocument) {
            self.storeFileURL = storeFileURL
            self.document = initialDocument
        }
    }
    
    private nonisolated let storage: Storage
    
    nonisolated init(customStoreURL: URL? = nil) {
        let defaultDir = BackdropManager.documentsBackdropsDirectory
        try? FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)
        let url = customStoreURL ?? defaultDir.appendingPathComponent(BackdropManifestDocument.defaultFilename)
        
        let initialDoc: BackdropManifestDocument
        if let data = try? Data(contentsOf: url),
           let decoded = try? Self.makeJSONDecoder().decode(BackdropManifestDocument.self, from: data) {
            initialDoc = decoded
        } else {
            initialDoc = BackdropManifestDocument(entries: [])
        }
        self.storage = Storage(storeFileURL: url, initialDocument: initialDoc)
        let initialEntries = initialDoc.entries
        Task { @MainActor [weak self] in
            self?.entries = initialEntries
        }
    }
    
    nonisolated private static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
    
    nonisolated private static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
    
    // MARK: - Recording Captures on iPad
    
    nonisolated func recordCapture(
        uncompositedCGImage: CGImage,
        rawJPEGData: Data,
        ptpObjectInfoData: Data?,
        backdrop: BackdropItem
    ) {
        guard !backdrop.isNone else { return }
        
        let ptpFilename = BackdropCompositorService.parsePTPObjectInfoFilename(from: ptpObjectInfoData)
        let (exifDT, exifSub) = BackdropCompositorService.extractEXIFTimestamps(from: rawJPEGData)
        let signature = BackdropCompositorService.computeRGBSignature8x8(from: uncompositedCGImage)
        
        // Deduplicate custom iPad-only backdrop bytes at the document level (`customAssetsByFilename`)
        // so taking 100+ photos with a custom backdrop never duplicates megabytes of Base64 data per entry.
        var customAssetsToStore: [String: Data] = [:]
        if let bgFile = backdrop.backgroundFilename,
           BackdropManager.isCustomDocumentsOnlyAsset(filename: bgFile),
           let url = BackdropManager.resolveAssetURL(filename: bgFile),
           let data = try? Data(contentsOf: url) {
            customAssetsToStore[bgFile] = data
        }
        if let fgFile = backdrop.foregroundFilename,
           BackdropManager.isCustomDocumentsOnlyAsset(filename: fgFile),
           let url = BackdropManager.resolveAssetURL(filename: fgFile),
           let data = try? Data(contentsOf: url) {
            customAssetsToStore[fgFile] = data
        }
        
        let entry = PhotoBackdropManifestEntry(
            id: UUID(),
            captureTimestampUTC: Date(),
            ptpFilename: ptpFilename,
            exifDateTimeOriginal: exifDT,
            exifSubSecOriginal: exifSub,
            rgbSignature8x8: signature,
            backdropID: backdrop.id,
            backdropDisplayName: backdrop.displayName,
            backgroundFilename: backdrop.backgroundFilename,
            foregroundFilename: backdrop.foregroundFilename,
            foregroundFitMode: backdrop.foregroundFitMode,
            customBackgroundData: nil,
            customForegroundData: nil,
            appliedToFullRes: false,
            matchedFullResFilename: nil
        )
        
        appendEntry(entry, newCustomAssets: customAssetsToStore)
    }
    
    nonisolated func appendEntry(_ entry: PhotoBackdropManifestEntry, newCustomAssets: [String: Data] = [:]) {
        storage.lock.lock()
        // Prune entries older than 7 days to keep manifest lean across events
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        storage.document.entries.removeAll { $0.captureTimestampUTC < sevenDaysAgo }
        storage.document.entries.append(entry)
        if !newCustomAssets.isEmpty {
            var map = storage.document.customAssetsByFilename ?? [:]
            for (k, v) in newCustomAssets {
                map[k] = v
            }
            storage.document.customAssetsByFilename = map
        }
        storage.document.exportedAtUTC = Date()
        saveLocked()
        let snapshot = storage.document.entries
        storage.lock.unlock()
        
        Task { @MainActor [weak self] in
            self?.entries = snapshot
        }
    }
    
    nonisolated func allEntries() -> [PhotoBackdropManifestEntry] {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.document.entries
    }
    
    nonisolated func currentDocument() -> BackdropManifestDocument {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.document
    }
    
    nonisolated func updateDocument(_ updatedDoc: BackdropManifestDocument) {
        storage.lock.lock()
        storage.document = updatedDoc
        saveLocked()
        let snapshot = storage.document.entries
        storage.lock.unlock()
        
        Task { @MainActor [weak self] in
            self?.entries = snapshot
        }
    }
    
    nonisolated func clearAllEntries() {
        storage.lock.lock()
        storage.document.entries.removeAll()
        storage.document.customAssetsByFilename = nil
        saveLocked()
        storage.lock.unlock()
        
        Task { @MainActor [weak self] in
            self?.entries = []
        }
    }
    
    func clearManifest() {
        clearAllEntries()
    }
    
    nonisolated private func saveLocked() {
        guard let data = try? Self.makeJSONEncoder().encode(storage.document) else { return }
        try? data.write(to: storage.storeFileURL, options: .atomic)
    }
    
    /// Exports `photobooth_backdrop_manifest.json` containing entries from the last `hours` window
    /// to a temporary URL ready for AirDrop alongside the event's `.gif` files.
    /// Returns `nil` if there are no manifest entries within the window.
    nonisolated func exportManifestFile(hours: Int = 72) throws -> URL? {
        storage.lock.lock()
        let cutoff = Date().addingTimeInterval(-Double(max(1, hours)) * 3600.0)
        let recentEntries = storage.document.entries.filter { $0.captureTimestampUTC >= cutoff }
        let storedCustomMap = storage.document.customAssetsByFilename ?? [:]
        storage.lock.unlock()
        
        guard !recentEntries.isEmpty else { return nil }
        
        // Include only the custom assets actually referenced by `recentEntries`
        var referencedCustomAssets: [String: Data] = [:]
        for entry in recentEntries {
            for fname in [entry.backgroundFilename, entry.foregroundFilename].compactMap({ $0 }) {
                if referencedCustomAssets[fname] == nil {
                    if let existing = storedCustomMap[fname] {
                        referencedCustomAssets[fname] = existing
                    } else if BackdropManager.isCustomDocumentsOnlyAsset(filename: fname),
                              let url = BackdropManager.resolveAssetURL(filename: fname),
                              let data = try? Data(contentsOf: url) {
                        referencedCustomAssets[fname] = data
                    }
                }
            }
        }
        
        let exportDoc = BackdropManifestDocument(
            schemaVersion: BackdropManifestDocument.currentSchemaVersion,
            exportedAtUTC: Date(),
            entries: recentEntries,
            customAssetsByFilename: referencedCustomAssets.isEmpty ? nil : referencedCustomAssets
        )
        let data = try Self.makeJSONEncoder().encode(exportDoc)
        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(BackdropManifestDocument.defaultFilename)
        try data.write(to: exportURL, options: .atomic)
        return exportURL
    }
    
    nonisolated func exportAirDropManifestFile(hours: Int = 72) -> URL? {
        return try? exportManifestFile(hours: hours)
    }
    
    nonisolated func applyBackdropsToFolder(
        folderURL: URL,
        progressHandler: (@Sendable (Int, Int, String) -> Void)? = nil
    ) async -> BatchApplyReport {
        return await Task.detached(priority: .userInitiated) {
            (try? Self.applyBackdropsToFolder(
                folderURL: folderURL,
                fallbackStore: self,
                customMaskProvider: nil,
                progressCallback: progressHandler
            )) ?? BatchApplyReport(
                totalManifestEntries: 0,
                newlyAppliedCount: 0,
                skippedAlreadyAppliedCount: 0,
                unmatchedCount: 0,
                appliedFilenames: []
            )
        }.value
    }
    
    // MARK: - Mac Post-Event In-Place Full-Resolution Batch Processor
    
    private struct CandidatePhotoFile {
        let url: URL
        let filenameUpper: String
        let exifDateTimeOriginal: String?
        let exifDate: Date?
        var alreadyAppliedBackdropID: String?
        var cachedSignature8x8: [UInt8]?
    }
    
    /// Applies the backdrops recorded in `photobooth_backdrop_manifest.json` directly onto the matching
    /// full-resolution SD card JPEGs inside `folderURL` in-place (creating zero duplicate files and zero extra image files).
    nonisolated static func applyBackdropsToFolder(
        folderURL: URL,
        fallbackStore: BackdropManifestStore = .shared,
        customMaskProvider: ((CIImage) -> CIImage?)? = nil,
        progressCallback: (@Sendable (Int, Int, String) -> Void)? = nil
    ) throws -> BatchApplyReport {
        let didStartScoped = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didStartScoped {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }
        
        let fm = FileManager.default
        
        // 1. Locate `photobooth_backdrop_manifest.json` (or any `*backdrop_manifest*.json`) in `folderURL`,
        //    falling back to the local store if none is in the folder.
        let folderContents = try fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        
        var manifestURLInFolder: URL? = folderContents.first {
            $0.lastPathComponent.lowercased() == BackdropManifestDocument.defaultFilename
        }
        if manifestURLInFolder == nil {
            manifestURLInFolder = folderContents.first {
                let lower = $0.lastPathComponent.lowercased()
                return lower.hasSuffix(".json") && lower.contains("backdrop") && lower.contains("manifest")
            }
        }
        
        var manifestDoc: BackdropManifestDocument
        if let mURL = manifestURLInFolder,
           let data = try? Data(contentsOf: mURL),
           let decoded = try? makeJSONDecoder().decode(BackdropManifestDocument.self, from: data) {
            manifestDoc = decoded
        } else {
            manifestDoc = fallbackStore.currentDocument()
        }
        
        guard !manifestDoc.entries.isEmpty else {
            return BatchApplyReport(
                totalManifestEntries: 0,
                newlyAppliedCount: 0,
                skippedAlreadyAppliedCount: 0,
                unmatchedCount: 0,
                appliedFilenames: []
            )
        }
        
        // 2. Fast Header-Only Indexing of all candidate full-res JPEGs in `folderURL` (< 0.1ms per file)
        var candidates: [CandidatePhotoFile] = []
        for url in folderContents {
            let ext = url.pathExtension.lowercased()
            guard ext == "jpg" || ext == "jpeg" else { continue }
            let nameUpper = url.lastPathComponent.uppercased()
            // Ignore any backdrop asset files if the user happened to store `_bg` / `_fg` in the same folder
            if nameUpper.hasSuffix("_BG.JPG") || nameUpper.hasSuffix("_BG.JPEG") || nameUpper.hasSuffix("_FG.JPG") {
                continue
            }
            let (dtStr, subStr, appliedID) = BackdropCompositorService.extractEXIFTimestamps(from: url)
            let parsedDate = BackdropCompositorService.parseEXIFDate(dtStr, subSec: subStr)
            candidates.append(
                CandidatePhotoFile(
                    url: url,
                    filenameUpper: nameUpper,
                    exifDateTimeOriginal: dtStr,
                    exifDate: parsedDate,
                    alreadyAppliedBackdropID: appliedID,
                    cachedSignature8x8: nil
                )
            )
        }
        
        // Helper to lazily compute the 8x8 RGB signature using a fast 128px thumbnail decode
        func getCandidateSignature(at index: Int) -> [UInt8]? {
            if let existing = candidates[index].cachedSignature8x8 {
                return existing
            }
            let url = candidates[index].url
            let thumbOpts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCache: false,
                kCGImageSourceThumbnailMaxPixelSize: 128 as NSNumber
            ]
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let thumbCG = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else {
                return nil
            }
            let croppedThumbCG = BackdropCompositorService.cropToLandscapeThreeByTwo(thumbCG)
            let sig = BackdropCompositorService.computeRGBSignature8x8(from: croppedThumbCG)
            candidates[index].cachedSignature8x8 = sig
            return sig
        }
        
        let ciContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
        var usedCandidateIndices = Set<Int>()
        var newlyApplied = 0
        var skippedAlreadyApplied = 0
        var unmatched = 0
        var appliedFilenames: [String] = []
        
        let totalCount = manifestDoc.entries.count
        
        for entryIndex in 0..<totalCount {
            if Task.isCancelled { break }
            let entry = manifestDoc.entries[entryIndex]
            
            var matchedCandidateIdx: Int? = nil
            
            // LOCK 0: Previously matched filename from an earlier run on this folder
            if let prevMatched = entry.matchedFullResFilename?.uppercased(), !prevMatched.isEmpty {
                if let idx = candidates.indices.first(where: { candidates[$0].filenameUpper == prevMatched && !usedCandidateIndices.contains($0) }) {
                    matchedCandidateIdx = idx
                }
            }
            
            // LOCK 1: Exact PTP Filename Match (e.g., "DSC04821.JPG")
            if matchedCandidateIdx == nil, let ptpName = entry.ptpFilename?.uppercased(), !ptpName.isEmpty {
                if let idx = candidates.indices.first(where: { candidates[$0].filenameUpper == ptpName && !usedCandidateIndices.contains($0) }) {
                    matchedCandidateIdx = idx
                }
            }
            
            // LOCK 2 + LOCK 3: EXIF DateTimeOriginal Window (±3.0s) + 8x8 Perceptual RGB Signature Disambiguation
            if matchedCandidateIdx == nil, let entryExifDate = BackdropCompositorService.parseEXIFDate(entry.exifDateTimeOriginal, subSec: entry.exifSubSecOriginal) {
                var timeWindowIndices: [Int] = []
                for (idx, cand) in candidates.enumerated() where !usedCandidateIndices.contains(idx) {
                    if let candDate = cand.exifDate, abs(candDate.timeIntervalSince(entryExifDate)) <= 3.0 {
                        timeWindowIndices.append(idx)
                    }
                }
                
                if !timeWindowIndices.isEmpty {
                    if entry.rgbSignature8x8.isEmpty {
                        matchedCandidateIdx = timeWindowIndices.first
                    } else {
                        var bestIdx: Int? = nil
                        var bestDist = Double.greatestFiniteMagnitude
                        for idx in timeWindowIndices {
                            if let candSig = getCandidateSignature(at: idx) {
                                let dist = BackdropCompositorService.signatureDistance(entry.rgbSignature8x8, candSig)
                                if dist < bestDist {
                                    bestDist = dist
                                    bestIdx = idx
                                }
                            }
                        }
                        if let winner = bestIdx, bestDist < 0.25 {
                            matchedCandidateIdx = winner
                        } else if timeWindowIndices.count == 1,
                                  let singleIdx = timeWindowIndices.first,
                                  candidates[singleIdx].alreadyAppliedBackdropID == entry.backdropID {
                            // Already-composited file on a second run whose RGB signature changed after backdrop replacement
                            matchedCandidateIdx = singleIdx
                        }
                    }
                }
            }
            
            // FALLBACK LOCK 3: Pure 8x8 Perceptual RGB Signature Match (if EXIF DateTimeOriginal was absent)
            if matchedCandidateIdx == nil, !entry.rgbSignature8x8.isEmpty {
                var bestIdx: Int? = nil
                var bestDist = Double.greatestFiniteMagnitude
                for idx in candidates.indices where !usedCandidateIndices.contains(idx) {
                    if let candSig = getCandidateSignature(at: idx) {
                        let dist = BackdropCompositorService.signatureDistance(entry.rgbSignature8x8, candSig)
                        if dist < bestDist {
                            bestDist = dist
                            bestIdx = idx
                        }
                    }
                }
                if let winner = bestIdx, bestDist < 0.10 {
                    matchedCandidateIdx = winner
                }
            }
            
            guard let targetIdx = matchedCandidateIdx else {
                if entry.appliedToFullRes {
                    skippedAlreadyApplied += 1
                } else {
                    unmatched += 1
                }
                continue
            }
            
            let candidate = candidates[targetIdx]
            usedCandidateIndices.insert(targetIdx)
            
            // Idempotency Check: if the JPEG file itself already has the `PB2_BACKDROP:` EXIF tag, skip re-applying!
            // (If the user replaced the JPEG with a fresh un-composited copy from the SD card, `alreadyAppliedBackdropID`
            // is nil so it will re-apply cleanly.)
            if candidate.alreadyAppliedBackdropID != nil {
                manifestDoc.entries[entryIndex].appliedToFullRes = true
                manifestDoc.entries[entryIndex].matchedFullResFilename = candidate.url.lastPathComponent
                skippedAlreadyApplied += 1
                continue
            }
            
            let resolvedCustomBgData = entry.customBackgroundData
                ?? entry.backgroundFilename.flatMap { manifestDoc.customAssetsByFilename?[$0] }
            let resolvedCustomFgData = entry.customForegroundData
                ?? entry.foregroundFilename.flatMap { manifestDoc.customAssetsByFilename?[$0] }
            
            let backdropItem = BackdropItem(
                id: entry.backdropID,
                displayName: entry.backdropDisplayName,
                backgroundFilename: entry.backgroundFilename,
                foregroundFilename: entry.foregroundFilename,
                foregroundFitMode: entry.foregroundFitMode,
                isBundled: false,
                isEnabled: true
            )
            
            // Safety Guard: Verify that the required backdrop/foreground asset(s) actually exist on disk or in embedded JSON
            // BEFORE modifying the full-res JPEG or stamping `PB2_BACKDROP:` in its EXIF metadata.
            guard BackdropCompositorService.hasResolvableAssets(
                for: backdropItem,
                customBackgroundData: resolvedCustomBgData,
                customForegroundData: resolvedCustomFgData,
                additionalSearchDirectories: [folderURL]
            ) else {
                unmatched += 1
                continue
            }
            
            progressCallback?(entryIndex + 1, totalCount, candidate.url.lastPathComponent)
            
            // 3. Apply Full-Resolution Auto-Exposure + .captureAccurate Backdrop Compositing inside autoreleasepool
            let didApply: Bool = autoreleasepool {
                guard let src = CGImageSourceCreateWithURL(candidate.url as CFURL, nil) else { return false }
                let rawProps = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
                let rawWidth = (rawProps[kCGImagePropertyPixelWidth] as? Int) ?? 0
                let rawHeight = (rawProps[kCGImagePropertyPixelHeight] as? Int) ?? 0
                let maxDim = max(rawWidth, rawHeight, 8192)
                
                // Decode full-res upright CGImage
                let fullResOpts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCache: false,
                    kCGImageSourceThumbnailMaxPixelSize: maxDim as NSNumber
                ]
                guard let decodedFullCG = CGImageSourceCreateThumbnailAtIndex(src, 0, fullResOpts as CFDictionary)
                    ?? CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                    return false
                }
                
                // Step A: Center-crop to landscape 3:2 (no-op for native 3:2 captures) and horizontally mirror
                // the external camera subject to match the iPad Live View / Review framing,
                // then run single-pass highlight-protected auto-exposure on the subject FIRST before compositing.
                let rawFullCG = BackdropCompositorService.cropToLandscapeThreeByTwo(decodedFullCG)
                let mirroredFullCG = BackdropCompositorService.mirrorCGImageHorizontally(rawFullCG, ciContext: ciContext)
                let exposedFullCG = SonyUSBCameraClient.autoExposeCapturedCGImage(mirroredFullCG, ciContext: ciContext)
                
                // Step B: Composite BackdropItem at full native resolution
                let compositedFullCG = BackdropCompositorService.composite(
                    cgImage: exposedFullCG,
                    backdrop: backdropItem,
                    quality: .captureAccurate,
                    ciContext: ciContext,
                    customBackgroundData: resolvedCustomBgData,
                    customForegroundData: resolvedCustomFgData,
                    additionalSearchDirectories: [folderURL],
                    customMaskProvider: customMaskProvider
                )
                
                // Step C: Encode back to JPEG preserving original EXIF metadata + idempotency tag, and overwrite atomically in-place
                let outData = NSMutableData()
                guard let dest = CGImageDestinationCreateWithData(outData, UTType.jpeg.identifier as CFString, 1, nil) else {
                    return false
                }
                
                var updatedProps = rawProps
                // Pixel buffer is already oriented upright by CreateThumbnailWithTransform
                updatedProps[kCGImagePropertyOrientation] = 1
                var exifDict = (updatedProps[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
                exifDict[kCGImagePropertyExifUserComment] = "PB2_BACKDROP:\(entry.backdropID)"
                updatedProps[kCGImagePropertyExifDictionary] = exifDict
                updatedProps[kCGImageDestinationLossyCompressionQuality] = 0.94
                
                CGImageDestinationAddImage(dest, compositedFullCG, updatedProps as CFDictionary)
                guard CGImageDestinationFinalize(dest) else { return false }
                
                do {
                    try (outData as Data).write(to: candidate.url, options: .atomic)
                    return true
                } catch {
                    return false
                }
            }
            
            if didApply {
                newlyApplied += 1
                appliedFilenames.append(candidate.url.lastPathComponent)
                manifestDoc.entries[entryIndex].appliedToFullRes = true
                manifestDoc.entries[entryIndex].matchedFullResFilename = candidate.url.lastPathComponent
                candidates[targetIdx].alreadyAppliedBackdropID = entry.backdropID
            } else {
                unmatched += 1
            }
        }
        
        // Save updated manifest (with `appliedToFullRes = true` flags) back to the folder (or fallbackStore) so re-running is idempotent
        if let mURL = manifestURLInFolder {
            if let updatedData = try? makeJSONEncoder().encode(manifestDoc) {
                try? updatedData.write(to: mURL, options: .atomic)
            }
        } else {
            fallbackStore.updateDocument(manifestDoc)
        }
        
        return BatchApplyReport(
            totalManifestEntries: totalCount,
            newlyAppliedCount: newlyApplied,
            skippedAlreadyAppliedCount: skippedAlreadyApplied,
            unmatchedCount: unmatched,
            appliedFilenames: appliedFilenames
        )
    }
}
