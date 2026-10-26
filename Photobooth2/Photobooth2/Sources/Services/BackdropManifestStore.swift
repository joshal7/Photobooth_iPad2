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
        
        var loadedDocs: [BackdropManifestDocument] = []
        if let data = try? Data(contentsOf: url),
           let decoded = try? Self.makeJSONDecoder().decode(BackdropManifestDocument.self, from: data) {
            loadedDocs.append(decoded)
        }
        if customStoreURL == nil,
           let dirFiles = try? FileManager.default.contentsOfDirectory(
               at: defaultDir,
               includingPropertiesForKeys: [.contentModificationDateKey],
               options: [.skipsHiddenFiles]
           ) {
            for fileURL in dirFiles where fileURL.standardizedFileURL != url.standardizedFileURL {
                let lower = fileURL.lastPathComponent.lowercased()
                guard lower.hasSuffix(".json") && lower.contains("manifest") else { continue }
                if let data = try? Data(contentsOf: fileURL),
                   let decoded = try? Self.makeJSONDecoder().decode(BackdropManifestDocument.self, from: data) {
                    loadedDocs.append(decoded)
                }
            }
        }
        
        let initialDoc = loadedDocs.isEmpty
            ? BackdropManifestDocument(entries: [])
            : Self.sanitizeAndMergeManifestDocuments(loadedDocs)
        self.storage = Storage(storeFileURL: url, initialDocument: initialDoc)
        if loadedDocs.count > 1 {
            saveLocked()
        }
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
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let str = try? container.decode(String.self) {
                let fracFormatter = ISO8601DateFormatter()
                fracFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let d = fracFormatter.date(from: str) {
                    return d
                }
                let stdFormatter = ISO8601DateFormatter()
                stdFormatter.formatOptions = [.withInternetDateTime]
                if let d = stdFormatter.date(from: str) {
                    return d
                }
            }
            if let timestamp = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: timestamp)
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date format in manifest JSON")
        }
        return decoder
    }
    
    /// Extracts the uppercased filename stem without extension (e.g. `"DSC09816.JPG"` -> `"DSC09816"`).
    /// Also normalizes Finder duplicate suffixes on camera filenames (e.g. `"DSC09816 2.JPG"` or `"DSC09816 (1).JPG"` -> `"DSC09816"`).
    nonisolated static func canonicalFilenameStem(_ filename: String?) -> String? {
        guard let raw = filename?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let lastComponent = (raw as NSString).lastPathComponent
        var stem = (lastComponent as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !stem.isEmpty else { return nil }
        
        // If Finder appended a duplicate suffix like "DSC09816 (1)" or "DSC09816 2" or "DSC09816 COPY",
        // strip the suffix only when the base stem starts with a standard camera prefix + digits.
        let cameraPrefixes = ["DSC", "_DSC", "DSCF", "IMG_", "_MG_"]
        if cameraPrefixes.contains(where: { stem.hasPrefix($0) }) {
            if let spaceIdx = stem.firstIndex(of: " ") {
                let baseCandidate = String(stem[..<spaceIdx])
                if baseCandidate.count >= 6 && baseCandidate.last?.isNumber == true {
                    stem = baseCandidate
                }
            }
        }
        return stem
    }
    
    /// Sanitizes and merges one or more `BackdropManifestDocument` instances:
    /// 1. Self-heals any entry whose `matchedFullResFilename` stem conflicts with its `ptpFilename` stem.
    /// 2. Deduplicates entries by `id` and by exact capture identity (`ptpStem + exifDateTimeOriginal + exifSubSecOriginal`),
    ///    preferring newer records while preserving embedded custom asset data.
    /// 3. Sorts entries chronologically by `captureTimestampUTC`.
    nonisolated static func sanitizeAndMergeManifestDocuments(_ documents: [BackdropManifestDocument]) -> BackdropManifestDocument {
        guard !documents.isEmpty else {
            return BackdropManifestDocument(entries: [])
        }
        
        var mergedCustomAssets: [String: Data] = [:]
        var entriesByID: [UUID: PhotoBackdropManifestEntry] = [:]
        var orderedIDs: [UUID] = []
        
        for doc in documents {
            if let customMap = doc.customAssetsByFilename {
                for (k, v) in customMap where !v.isEmpty {
                    mergedCustomAssets[k] = v
                }
            }
            
            for var entry in doc.entries {
                // Self-heal corrupted `matchedFullResFilename` from any prior run where the matched filename stem
                // conflicted with the camera's reported `ptpFilename` stem (e.g. `ptpFilename: "DSC09816.JPG"` vs `matchedFullResFilename: "DSC09838.JPG"`).
                if let ptpStem = canonicalFilenameStem(entry.ptpFilename),
                   let matchedStem = canonicalFilenameStem(entry.matchedFullResFilename),
                   ptpStem != matchedStem {
                    entry.matchedFullResFilename = nil
                    entry.appliedToFullRes = false
                }
                
                if let existing = entriesByID[entry.id] {
                    let newer = entry.captureTimestampUTC >= existing.captureTimestampUTC ? entry : existing
                    let older = entry.captureTimestampUTC >= existing.captureTimestampUTC ? existing : entry
                    var combined = newer
                    if combined.ptpFilename == nil { combined.ptpFilename = older.ptpFilename }
                    if combined.exifDateTimeOriginal == nil { combined.exifDateTimeOriginal = older.exifDateTimeOriginal }
                    if combined.exifSubSecOriginal == nil { combined.exifSubSecOriginal = older.exifSubSecOriginal }
                    if combined.rgbSignature8x8.isEmpty { combined.rgbSignature8x8 = older.rgbSignature8x8 }
                    if combined.customBackgroundData == nil { combined.customBackgroundData = older.customBackgroundData }
                    if combined.customForegroundData == nil { combined.customForegroundData = older.customForegroundData }
                    if combined.matchedFullResFilename == nil { combined.matchedFullResFilename = older.matchedFullResFilename }
                    combined.appliedToFullRes = (combined.matchedFullResFilename != nil) && (newer.appliedToFullRes || older.appliedToFullRes)
                    entriesByID[entry.id] = combined
                } else {
                    orderedIDs.append(entry.id)
                    entriesByID[entry.id] = entry
                }
            }
        }
        
        // Deduplicate entries that share the exact same camera capture identity (same ptpStem + EXIF timestamp + subsecond)
        var dedupedEntries: [PhotoBackdropManifestEntry] = []
        var captureKeyIndexMap: [String: Int] = [:]
        
        let sortedCandidates = orderedIDs.compactMap { entriesByID[$0] }.sorted { a, b in
            if a.captureTimestampUTC != b.captureTimestampUTC {
                return a.captureTimestampUTC < b.captureTimestampUTC
            }
            return (a.ptpFilename ?? "") < (b.ptpFilename ?? "")
        }
        
        for entry in sortedCandidates {
            if let ptpStem = canonicalFilenameStem(entry.ptpFilename),
               let exifDT = entry.exifDateTimeOriginal?.trimmingCharacters(in: .whitespacesAndNewlines),
               !exifDT.isEmpty {
                let sub = entry.exifSubSecOriginal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let key = "\(ptpStem)|\(exifDT)|\(sub)"
                if let existingIdx = captureKeyIndexMap[key] {
                    var updated = entry
                    let prev = dedupedEntries[existingIdx]
                    if updated.customBackgroundData == nil { updated.customBackgroundData = prev.customBackgroundData }
                    if updated.customForegroundData == nil { updated.customForegroundData = prev.customForegroundData }
                    if updated.matchedFullResFilename == nil { updated.matchedFullResFilename = prev.matchedFullResFilename }
                    updated.appliedToFullRes = (updated.matchedFullResFilename != nil) && (updated.appliedToFullRes || prev.appliedToFullRes)
                    dedupedEntries[existingIdx] = updated
                    continue
                }
                captureKeyIndexMap[key] = dedupedEntries.count
            }
            dedupedEntries.append(entry)
        }
        
        let latestExportDate = documents.map(\.exportedAtUTC).max() ?? Date()
        return BackdropManifestDocument(
            schemaVersion: BackdropManifestDocument.currentSchemaVersion,
            exportedAtUTC: latestExportDate,
            entries: dedupedEntries,
            customAssetsByFilename: mergedCustomAssets.isEmpty ? nil : mergedCustomAssets
        )
    }
    
    // MARK: - Recording Captures on iPad
    
    nonisolated func recordCapture(
        uncompositedCGImage: CGImage,
        rawJPEGData: Data,
        ptpObjectInfoData: Data?,
        backdrop: BackdropItem
    ) {
        let ptpFilename = BackdropCompositorService.parsePTPObjectInfoFilename(from: ptpObjectInfoData)
        let (exifDT, exifSub) = BackdropCompositorService.extractEXIFTimestamps(from: rawJPEGData)
        
        // Record all backdrop captures, plus `.none` ("Original") captures that carry camera metadata (`ptpFilename` or `exifDT`)
        // so intentional No-Background photos claim their SD card file and supersede any deleted/formatted earlier shots.
        guard !backdrop.isNone || ptpFilename != nil || exifDT != nil else { return }
        
        let signature = BackdropCompositorService.computeRGBSignature8x8(from: uncompositedCGImage)
        
        // Deduplicate custom iPad-only backdrop bytes at the document level (`customAssetsByFilename`)
        // so taking 100+ photos with a custom backdrop never duplicates megabytes of Base64 data per entry.
        var customAssetsToStore: [String: Data] = [:]
        if !backdrop.isNone {
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
        }
        
        let entry = PhotoBackdropManifestEntry(
            id: UUID(),
            captureTimestampUTC: Date(),
            ptpFilename: ptpFilename,
            exifDateTimeOriginal: exifDT,
            exifSubSecOriginal: exifSub,
            rgbSignature8x8: signature,
            backdropID: backdrop.isNone ? BackdropItem.noneID : backdrop.id,
            backdropDisplayName: backdrop.isNone ? BackdropItem.none.displayName : backdrop.displayName,
            backgroundFilename: backdrop.isNone ? nil : backdrop.backgroundFilename,
            foregroundFilename: backdrop.isNone ? nil : backdrop.foregroundFilename,
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
        
        if let existingIdx = storage.document.entries.firstIndex(where: { $0.id == entry.id }) {
            storage.document.entries[existingIdx] = entry
        } else if let ptpStem = Self.canonicalFilenameStem(entry.ptpFilename),
                  let exifDT = entry.exifDateTimeOriginal?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !exifDT.isEmpty,
                  let dupIdx = storage.document.entries.firstIndex(where: {
                      Self.canonicalFilenameStem($0.ptpFilename) == ptpStem &&
                      $0.exifDateTimeOriginal?.trimmingCharacters(in: .whitespacesAndNewlines) == exifDT &&
                      ($0.exifSubSecOriginal ?? "") == (entry.exifSubSecOriginal ?? "")
                  }) {
            storage.document.entries[dupIdx] = entry
        } else {
            storage.document.entries.append(entry)
        }
        
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
        storage.document = Self.sanitizeAndMergeManifestDocuments([updatedDoc])
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
        
        let exportDoc = Self.sanitizeAndMergeManifestDocuments([
            BackdropManifestDocument(
                schemaVersion: BackdropManifestDocument.currentSchemaVersion,
                exportedAtUTC: Date(),
                entries: recentEntries,
                customAssetsByFilename: referencedCustomAssets.isEmpty ? nil : referencedCustomAssets
            )
        ])
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
        let stemUpper: String
        let exifDateTimeOriginal: String?
        let exifDate: Date?
        var alreadyAppliedBackdropID: String?
        var cachedSignature8x8: [UInt8]?
    }
    
    /// Applies the backdrops recorded in `photobooth_backdrop_manifest.json` (and any additional `*manifest*.json` files)
    /// directly onto the matching full-resolution SD card JPEGs inside `folderURL` in-place
    /// (creating zero duplicate files and zero extra image files).
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
        
        // 1. Discover and merge ALL manifest `.json` files in `folderURL`
        //    (e.g. `photobooth_backdrop_manifest.json`, `photobooth_backdrop_manifest 2.json`,
        //    `photobooth_backdrop_manifest (1).json`, `manifest.json`), falling back to `fallbackStore` if none exist.
        let folderContents = try fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        
        let candidateManifestURLs = folderContents
            .filter { url in
                let lower = url.lastPathComponent.lowercased()
                guard lower.hasSuffix(".json") else { return false }
                return lower == BackdropManifestDocument.defaultFilename
                    || lower.contains("manifest")
                    || lower.contains("backdrop")
            }
            .sorted { a, b in
                let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if dateA != dateB { return dateA < dateB }
                return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            }
        
        var decodedFolderDocs: [BackdropManifestDocument] = []
        var validManifestURLsInFolder: [URL] = []
        let decoder = makeJSONDecoder()
        for mURL in candidateManifestURLs {
            if let data = try? Data(contentsOf: mURL),
               let decoded = try? decoder.decode(BackdropManifestDocument.self, from: data) {
                decodedFolderDocs.append(decoded)
                validManifestURLsInFolder.append(mURL)
            }
        }
        
        // If `folderURL` is a subfolder (e.g. `bad/` or `Good/`) and the manifest `.json` sits in its parent directory,
        // also check the immediate parent directory as a read-only manifest source before falling back to `fallbackStore`.
        if decodedFolderDocs.isEmpty {
            let parentURL = folderURL.deletingLastPathComponent()
            if parentURL.standardizedFileURL != folderURL.standardizedFileURL,
               let parentContents = try? fm.contentsOfDirectory(
                   at: parentURL,
                   includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                   options: [.skipsHiddenFiles]
               ) {
                let parentManifestURLs = parentContents
                    .filter { url in
                        let lower = url.lastPathComponent.lowercased()
                        guard lower.hasSuffix(".json") else { return false }
                        return lower == BackdropManifestDocument.defaultFilename
                            || lower.contains("manifest")
                            || lower.contains("backdrop")
                    }
                    .sorted { a, b in
                        let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                        let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                        if dateA != dateB { return dateA < dateB }
                        return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
                    }
                for mURL in parentManifestURLs {
                    if let data = try? Data(contentsOf: mURL),
                       let decoded = try? decoder.decode(BackdropManifestDocument.self, from: data) {
                        decodedFolderDocs.append(decoded)
                    }
                }
            }
        }
        
        var manifestDoc: BackdropManifestDocument
        if !decodedFolderDocs.isEmpty {
            manifestDoc = sanitizeAndMergeManifestDocuments(decodedFolderDocs)
        } else {
            manifestDoc = sanitizeAndMergeManifestDocuments([fallbackStore.currentDocument()])
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
            // Ignore any backdrop asset files or temporary GIF frame JPEGs if placed in the same folder
            if nameUpper.hasSuffix("_BG.JPG") || nameUpper.hasSuffix("_BG.JPEG")
                || nameUpper.hasSuffix("_FG.JPG") || nameUpper.hasSuffix("_FG.JPEG")
                || nameUpper.hasPrefix("SONY_GIF_") {
                continue
            }
            let stemUpper = canonicalFilenameStem(nameUpper) ?? (nameUpper as NSString).deletingPathExtension
            let (dtStr, subStr, appliedID) = BackdropCompositorService.extractEXIFTimestamps(from: url)
            let parsedDate = BackdropCompositorService.parseEXIFDate(dtStr, subSec: subStr)
            candidates.append(
                CandidatePhotoFile(
                    url: url,
                    filenameUpper: nameUpper,
                    stemUpper: stemUpper,
                    exifDateTimeOriginal: dtStr,
                    exifDate: parsedDate,
                    alreadyAppliedBackdropID: appliedID,
                    cachedSignature8x8: nil
                )
            )
        }
        
        // Sort candidates deterministically by filename
        candidates.sort { $0.filenameUpper.localizedStandardCompare($1.filenameUpper) == .orderedAscending }
        
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
        
        let totalCount = manifestDoc.entries.count
        let entryPtpStems: [String?] = manifestDoc.entries.map { canonicalFilenameStem($0.ptpFilename) }
        let entryExifDates: [Date?] = manifestDoc.entries.map {
            BackdropCompositorService.parseEXIFDate($0.exifDateTimeOriginal, subSec: $0.exifSubSecOriginal)
        }
        
        // Self-Heal Pre-Pass: Validate any existing `matchedFullResFilename` against the actual folder candidates
        // and strict filename/EXIF compatibility rules. If a prior buggy run stamped a mismatched filename or if the
        // file does not exist in this folder with a compatible EXIF timestamp, clear the stale match state.
        for i in 0..<totalCount {
            if let prevMatched = manifestDoc.entries[i].matchedFullResFilename,
               let prevStem = canonicalFilenameStem(prevMatched) {
                if let ptpStem = entryPtpStems[i], ptpStem != prevStem {
                    manifestDoc.entries[i].matchedFullResFilename = nil
                    manifestDoc.entries[i].appliedToFullRes = false
                    continue
                }
                let hasCompatibleFile = candidates.contains { cand in
                    guard cand.filenameUpper == prevMatched.uppercased() || cand.stemUpper == prevStem else {
                        return false
                    }
                    if let eDate = entryExifDates[i], let cDate = cand.exifDate {
                        return abs(cDate.timeIntervalSince(eDate)) <= 3.0
                    }
                    return true
                }
                if !hasCompatibleFile {
                    manifestDoc.entries[i].matchedFullResFilename = nil
                    manifestDoc.entries[i].appliedToFullRes = false
                }
            } else if manifestDoc.entries[i].appliedToFullRes {
                manifestDoc.entries[i].appliedToFullRes = false
            }
        }
        
        // =========================================================================================
        // 3. Global Multi-Pass Priority Matching Engine
        //    Prevents deleted test shots or SD-card-formatted stale entries from ever stealing
        //    files belonging to later captures.
        // =========================================================================================
        var matchedCandidateForEntry: [Int: Int] = [:]
        var usedCandidateIndices = Set<Int>()
        
        // PASS 1: Entries with a known camera `ptpFilename` (e.g. `"DSC09830.JPG"` -> stem `"DSC09830"`).
        //         - MUST match a candidate with the exact same filename stem (`cand.stemUpper == ptpStem`).
        //         - MUST pass EXIF DateTimeOriginal compatibility (`<= 3.0s`) whenever both have EXIF dates
        //           (protecting against SD card format in `Reset` mode or camera filename reuse after deletion).
        //         - MUST pass 8x8 RGB perceptual signature sanity check (`< 0.28` with EXIF match, `< 0.18` without EXIF)
        //           unless the candidate already has `PB2_BACKDROP:<same backdropID>`.
        //         - CRITICAL VETO: Any entry with a non-nil `ptpFilename` that does not match in Pass 1
        //           is NEVER allowed to fall back to Pass 2 or Pass 3 and steal a different `DSC0xxxx.JPG` file!
        struct Pass1MatchCandidate {
            let entryIdx: Int
            let candIdx: Int
            let candidatePriorityRank: Int
            let sameAppliedBackdrop: Bool
            let timeDiff: Double
            let sigDist: Double
            let captureUTC: Date
        }
        var pass1Pool: [Pass1MatchCandidate] = []
        for entryIdx in 0..<totalCount {
            guard let ptpStem = entryPtpStems[entryIdx] else { continue }
            let entry = manifestDoc.entries[entryIdx]
            let eDate = entryExifDates[entryIdx]
            
            for candIdx in candidates.indices {
                let cand = candidates[candIdx]
                guard cand.stemUpper == ptpStem else { continue }
                
                // EXIF Timestamp Veto: if both entry and candidate have EXIF timestamps, they must be within ±3.0s
                var timeDiff: Double = 0.0
                if let eDate = eDate, let cDate = cand.exifDate {
                    timeDiff = abs(cDate.timeIntervalSince(eDate))
                    guard timeDiff <= 3.0 else { continue }
                }
                
                let sameApplied = (cand.alreadyAppliedBackdropID != nil && cand.alreadyAppliedBackdropID == entry.backdropID)
                    || (entry.isNoneBackdrop && cand.alreadyAppliedBackdropID == nil)
                
                var sigDist: Double = 0.0
                if !(cand.alreadyAppliedBackdropID != nil && cand.alreadyAppliedBackdropID == entry.backdropID),
                   !entry.rgbSignature8x8.isEmpty {
                    guard let candSig = getCandidateSignature(at: candIdx) else { continue }
                    sigDist = BackdropCompositorService.signatureDistance(entry.rgbSignature8x8, candSig)
                    let maxAllowedDist = (eDate != nil && cand.exifDate != nil) ? 0.28 : 0.18
                    guard sigDist < maxAllowedDist else { continue }
                }
                
                // Prefer verified un-composited original camera JPEGs (rank 0, e.g. fresh SD card copy or `DSC0xxxx 2.JPG`
                // placed alongside an older already-processed `DSC0xxxx.JPG`) over already-stamped files (rank 1).
                let priorityRank: Int
                if cand.alreadyAppliedBackdropID == nil {
                    priorityRank = 0
                } else if sameApplied {
                    priorityRank = 1
                } else {
                    priorityRank = 2
                }
                
                pass1Pool.append(
                    Pass1MatchCandidate(
                        entryIdx: entryIdx,
                        candIdx: candIdx,
                        candidatePriorityRank: priorityRank,
                        sameAppliedBackdrop: sameApplied,
                        timeDiff: timeDiff,
                        sigDist: sigDist,
                        captureUTC: entry.captureTimestampUTC
                    )
                )
            }
        }
        
        pass1Pool.sort { a, b in
            if a.candidatePriorityRank != b.candidatePriorityRank {
                return a.candidatePriorityRank < b.candidatePriorityRank
            }
            if abs(a.timeDiff - b.timeDiff) > 0.05 {
                return a.timeDiff < b.timeDiff
            }
            if abs(a.sigDist - b.sigDist) > 0.015 {
                return a.sigDist < b.sigDist
            }
            return a.captureUTC > b.captureUTC
        }
        
        for match in pass1Pool {
            guard matchedCandidateForEntry[match.entryIdx] == nil,
                  !usedCandidateIndices.contains(match.candIdx) else {
                continue
            }
            matchedCandidateForEntry[match.entryIdx] = match.candIdx
            usedCandidateIndices.insert(match.candIdx)
        }
        
        // PASS 2: Entries WITHOUT `ptpFilename` (`entryPtpStems[entryIdx] == nil`), matched via
        //         EXIF DateTimeOriginal Window (±3.0s) + 8x8 Perceptual RGB Signature Disambiguation (`< 0.25`).
        struct Pass2MatchCandidate {
            let entryIdx: Int
            let candIdx: Int
            let sameAppliedBackdrop: Bool
            let sigDist: Double
            let timeDiff: Double
        }
        var pass2Pool: [Pass2MatchCandidate] = []
        for entryIdx in 0..<totalCount {
            // Only entries without a camera `ptpFilename` can match across arbitrary candidate filenames
            guard entryPtpStems[entryIdx] == nil,
                  matchedCandidateForEntry[entryIdx] == nil,
                  let eDate = entryExifDates[entryIdx] else {
                continue
            }
            let entry = manifestDoc.entries[entryIdx]
            
            for candIdx in candidates.indices where !usedCandidateIndices.contains(candIdx) {
                let cand = candidates[candIdx]
                guard let cDate = cand.exifDate else { continue }
                let timeDiff = abs(cDate.timeIntervalSince(eDate))
                guard timeDiff <= 3.0 else { continue }
                
                let sameApplied = (cand.alreadyAppliedBackdropID != nil && cand.alreadyAppliedBackdropID == entry.backdropID)
                var sigDist: Double = 0.0
                if !sameApplied {
                    if !entry.rgbSignature8x8.isEmpty {
                        guard let candSig = getCandidateSignature(at: candIdx) else { continue }
                        sigDist = BackdropCompositorService.signatureDistance(entry.rgbSignature8x8, candSig)
                        guard sigDist < 0.25 else { continue }
                    } else {
                        sigDist = 0.20
                    }
                }
                
                pass2Pool.append(
                    Pass2MatchCandidate(
                        entryIdx: entryIdx,
                        candIdx: candIdx,
                        sameAppliedBackdrop: sameApplied,
                        sigDist: sigDist,
                        timeDiff: timeDiff
                    )
                )
            }
        }
        
        pass2Pool.sort { a, b in
            if a.sameAppliedBackdrop != b.sameAppliedBackdrop {
                return a.sameAppliedBackdrop && !b.sameAppliedBackdrop
            }
            if abs(a.sigDist - b.sigDist) > 0.005 {
                return a.sigDist < b.sigDist
            }
            return a.timeDiff < b.timeDiff
        }
        
        for match in pass2Pool {
            guard matchedCandidateForEntry[match.entryIdx] == nil,
                  !usedCandidateIndices.contains(match.candIdx) else {
                continue
            }
            matchedCandidateForEntry[match.entryIdx] = match.candIdx
            usedCandidateIndices.insert(match.candIdx)
        }
        
        // PASS 3: Fallback Pure 8x8 Perceptual RGB Signature Match (`< 0.08`)
        //         ONLY when `ptpFilename` is nil AND EXIF `DateTimeOriginal` was genuinely absent on either side!
        //         Never allowed to override conflicting EXIF timestamps (`> 3.0s`).
        struct Pass3MatchCandidate {
            let entryIdx: Int
            let candIdx: Int
            let sigDist: Double
        }
        var pass3Pool: [Pass3MatchCandidate] = []
        for entryIdx in 0..<totalCount {
            guard entryPtpStems[entryIdx] == nil,
                  matchedCandidateForEntry[entryIdx] == nil else {
                continue
            }
            let entry = manifestDoc.entries[entryIdx]
            guard !entry.rgbSignature8x8.isEmpty else { continue }
            let eDate = entryExifDates[entryIdx]
            
            for candIdx in candidates.indices where !usedCandidateIndices.contains(candIdx) {
                let cand = candidates[candIdx]
                // Strict EXIF Presence Veto: if BOTH entry and candidate have EXIF timestamps,
                // they were already evaluated in Pass 2 (and rejected because their timestamps were > 3.0s apart).
                guard eDate == nil || cand.exifDate == nil else { continue }
                
                guard let candSig = getCandidateSignature(at: candIdx) else { continue }
                let dist = BackdropCompositorService.signatureDistance(entry.rgbSignature8x8, candSig)
                if dist < 0.08 {
                    pass3Pool.append(Pass3MatchCandidate(entryIdx: entryIdx, candIdx: candIdx, sigDist: dist))
                }
            }
        }
        
        pass3Pool.sort { $0.sigDist < $1.sigDist }
        for match in pass3Pool {
            guard matchedCandidateForEntry[match.entryIdx] == nil,
                  !usedCandidateIndices.contains(match.candIdx) else {
                continue
            }
            matchedCandidateForEntry[match.entryIdx] = match.candIdx
            usedCandidateIndices.insert(match.candIdx)
        }
        
        // Track which camera filename stems were matched in this folder so if an earlier deleted/formatted shot
        // had the exact same `DSC0xxxx` stem as a newer shot that matched in this folder, we know it was superseded.
        var matchedPtpStemsInFolder = Set<String>()
        for (entryIdx, _) in matchedCandidateForEntry {
            if let stem = entryPtpStems[entryIdx] {
                matchedPtpStemsInFolder.insert(stem)
            }
        }
        
        // 4. Execute In-Place Full-Resolution Backdrop Compositing on Matched Candidates
        let ciContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
        var newlyApplied = 0
        var skippedAlreadyApplied = 0
        var unmatched = 0
        var appliedFilenames: [String] = []
        
        let actionableTotalCount = manifestDoc.entries.enumerated().filter { idx, entry in
            guard !entry.isNoneBackdrop else { return false }
            if matchedCandidateForEntry[idx] == nil,
               let stem = entryPtpStems[idx],
               matchedPtpStemsInFolder.contains(stem) {
                // Superseded by a newer capture with the same camera filename in this folder
                return false
            }
            return true
        }.count
        var actionableProcessedIndex = 0
        
        for entryIndex in 0..<totalCount {
            if Task.isCancelled { break }
            let entry = manifestDoc.entries[entryIndex]
            
            // Handle intentional "Original" (`.none`) photo records:
            // They have already claimed their candidate index in `usedCandidateIndices` during Pass 1/2/3
            // so no other entry can ever touch their JPEG, and we leave the file on disk completely untouched.
            if entry.isNoneBackdrop {
                if let targetIdx = matchedCandidateForEntry[entryIndex] {
                    manifestDoc.entries[entryIndex].appliedToFullRes = true
                    manifestDoc.entries[entryIndex].matchedFullResFilename = candidates[targetIdx].url.lastPathComponent
                }
                continue
            }
            
            guard let targetIdx = matchedCandidateForEntry[entryIndex] else {
                if let stem = entryPtpStems[entryIndex], matchedPtpStemsInFolder.contains(stem) {
                    // This camera filename was reused by a newer capture in the same folder after delete/format
                    continue
                }
                unmatched += 1
                continue
            }
            
            actionableProcessedIndex += 1
            let candidate = candidates[targetIdx]
            
            // Idempotency Check: if the JPEG file itself already has the matching `PB2_BACKDROP:<backdropID>` EXIF tag,
            // skip re-applying! (If the user replaced the JPEG with a fresh un-composited copy from the SD card,
            // `alreadyAppliedBackdropID` is nil so it will re-apply cleanly.)
            if candidate.alreadyAppliedBackdropID == entry.backdropID {
                if let healDate = BackdropCompositorService.parseEXIFDateInLocalTimeZone(
                    candidate.exifDateTimeOriginal ?? entry.exifDateTimeOriginal,
                    subSec: entry.exifSubSecOriginal
                ) {
                    Self.restoreFileCreationDate(healDate, for: candidate.url, fileManager: fm)
                }
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
            
            progressCallback?(actionableProcessedIndex, max(1, actionableTotalCount), candidate.url.lastPathComponent)
            
            // 5. Apply Full-Resolution Auto-Exposure + .captureAccurate Backdrop Compositing inside autoreleasepool
            let didApply: Bool = autoreleasepool {
                let existingCreationDate = (try? fm.attributesOfItem(atPath: candidate.url.path)[.creationDate] as? Date)
                    ?? (try? candidate.url.resourceValues(forKeys: [.creationDateKey]).creationDate)
                guard let src = CGImageSourceCreateWithURL(candidate.url as CFURL, nil) else { return false }
                let rawProps = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
                let originalCaptureDate = BackdropCompositorService.parseEXIFCaptureDate(
                    fromProperties: rawProps,
                    fallbackEXIFDateTime: entry.exifDateTimeOriginal ?? candidate.exifDateTimeOriginal,
                    fallbackSubSec: entry.exifSubSecOriginal
                ) ?? existingCreationDate
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
                if exifDict[kCGImagePropertyExifDateTimeOriginal] == nil,
                   let fallbackDT = entry.exifDateTimeOriginal ?? candidate.exifDateTimeOriginal {
                    exifDict[kCGImagePropertyExifDateTimeOriginal] = fallbackDT
                }
                if exifDict[kCGImagePropertyExifDateTimeDigitized] == nil,
                   let origDT = (exifDict[kCGImagePropertyExifDateTimeOriginal] as? String) ?? entry.exifDateTimeOriginal {
                    exifDict[kCGImagePropertyExifDateTimeDigitized] = origDT
                }
                updatedProps[kCGImagePropertyExifDictionary] = exifDict
                updatedProps[kCGImageDestinationLossyCompressionQuality] = 0.94
                
                CGImageDestinationAddImage(dest, compositedFullCG, updatedProps as CFDictionary)
                guard CGImageDestinationFinalize(dest) else { return false }
                
                do {
                    try (outData as Data).write(to: candidate.url, options: .atomic)
                    if let captureDate = originalCaptureDate {
                        Self.restoreFileCreationDate(captureDate, for: candidate.url, fileManager: fm)
                    }
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
        
        // Save updated manifest (with `appliedToFullRes = true` flags) back to all discovered manifest files in the folder
        // (or fallbackStore) so re-running is 100% idempotent even when multiple manifest JSON files exist in the folder.
        if !validManifestURLsInFolder.isEmpty {
            if let updatedData = try? makeJSONEncoder().encode(manifestDoc) {
                for mURL in validManifestURLsInFolder {
                    try? updatedData.write(to: mURL, options: .atomic)
                }
            }
        } else {
            fallbackStore.updateDocument(manifestDoc)
        }
        
        return BatchApplyReport(
            totalManifestEntries: actionableTotalCount,
            newlyAppliedCount: newlyApplied,
            skippedAlreadyAppliedCount: skippedAlreadyApplied,
            unmatchedCount: unmatched,
            appliedFilenames: appliedFilenames
        )
    }
    
    /// Restores the file's creation date (and modification date so APFS `btime <= mtime` holds)
    /// to the original photo capture timestamp after an atomic in-place write.
    nonisolated static func restoreFileCreationDate(
        _ captureDate: Date,
        for fileURL: URL,
        fileManager: FileManager = .default
    ) {
        try? fileManager.setAttributes(
            [.creationDate: captureDate, .modificationDate: captureDate],
            ofItemAtPath: fileURL.path
        )
        var resourceValues = URLResourceValues()
        resourceValues.creationDate = captureDate
        resourceValues.contentModificationDate = captureDate
        var mutableURL = fileURL
        try? mutableURL.setResourceValues(resourceValues)
    }
}
