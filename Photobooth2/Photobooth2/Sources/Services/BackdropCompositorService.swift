import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import ImageIO
import UIKit

enum SegmentationQuality: Sendable {
    case liveFast
    case captureAccurate
}

final class BackdropCompositorService: Sendable {
    
    private nonisolated final class AssetImageCache: @unchecked Sendable {
        static let shared = AssetImageCache()
        private let lock = NSLock()
        private var cache: [String: CIImage] = [:]
        private let fastSegmentationLock = NSLock()
        private var reusableFastRequest: VNGeneratePersonSegmentationRequest?
        
        func image(forKey key: String, loader: () -> CIImage?) -> CIImage? {
            lock.lock()
            if let existing = cache[key] {
                lock.unlock()
                return existing
            }
            lock.unlock()
            
            guard let loaded = loader() else { return nil }
            lock.lock()
            if cache.count >= 8 {
                cache.removeAll()
            }
            cache[key] = loaded
            lock.unlock()
            return loaded
        }
        
        func clear() {
            lock.lock()
            cache.removeAll()
            lock.unlock()
        }
        
        func performFastSegmentation(on ciImage: CIImage) -> CVPixelBuffer? {
            fastSegmentationLock.lock()
            defer { fastSegmentationLock.unlock() }
            
            let request: VNGeneratePersonSegmentationRequest
            if let existing = reusableFastRequest {
                request = existing
            } else {
                let req = VNGeneratePersonSegmentationRequest()
                req.qualityLevel = .fast
                req.outputPixelFormat = kCVPixelFormatType_OneComponent8
                reusableFastRequest = req
                request = req
            }
            
            let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
            do {
                try handler.perform([request])
                return request.results?.first?.pixelBuffer
            } catch {
                return nil
            }
        }
    }
    
    nonisolated static func clearCache() {
        AssetImageCache.shared.clear()
    }
    
    // MARK: - 3-Layer Compositing (Background -> Segmented Subject -> Foreground Frame)
    
    /// Composites `backdrop` onto `cgImage` using the 3-layer stack:
    /// 1. Background image (auto-scaled via Aspect-Fill + Center Crop)
    /// 2. Subject image (segmented via Vision when a Background is present; untouched when Foreground-only)
    /// 3. Foreground transparent PNG frame (scaled via `backdrop.foregroundFitMode`, defaulting to Stretch-to-Edges)
    nonisolated static func composite(
        cgImage: CGImage,
        backdrop: BackdropItem,
        quality: SegmentationQuality,
        ciContext: CIContext,
        customBackgroundData: Data? = nil,
        customForegroundData: Data? = nil,
        additionalSearchDirectories: [URL] = [],
        customMaskProvider: ((CIImage) -> CIImage?)? = nil
    ) -> CGImage {
        guard !backdrop.isNone else { return cgImage }
        let subjectCI = CIImage(cgImage: cgImage)
        return composite(
            subjectCI: subjectCI,
            backdrop: backdrop,
            quality: quality,
            ciContext: ciContext,
            customBackgroundData: customBackgroundData,
            customForegroundData: customForegroundData,
            additionalSearchDirectories: additionalSearchDirectories,
            customMaskProvider: customMaskProvider
        ) ?? cgImage
    }
    
    /// Single-pass `CIImage` compositor used by both `composite(cgImage:...)` and 30 FPS `LocalCameraClient` Live View
    /// (avoiding an intermediate `createCGImage` pass before segmentation).
    nonisolated static func composite(
        subjectCI: CIImage,
        backdrop: BackdropItem,
        quality: SegmentationQuality,
        ciContext: CIContext,
        customBackgroundData: Data? = nil,
        customForegroundData: Data? = nil,
        additionalSearchDirectories: [URL] = [],
        customMaskProvider: ((CIImage) -> CIImage?)? = nil
    ) -> CGImage? {
        let rawExtent = subjectCI.extent
        let targetWidth = rawExtent.width
        let targetHeight = rawExtent.height
        guard targetWidth > 1, targetHeight > 1 else { return nil }
        
        let normalizedSubject: CIImage
        if rawExtent.minX != 0 || rawExtent.minY != 0 {
            normalizedSubject = subjectCI.transformed(by: CGAffineTransform(translationX: -rawExtent.minX, y: -rawExtent.minY))
        } else {
            normalizedSubject = subjectCI
        }
        let targetExtent = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        
        guard !backdrop.isNone else {
            return ciContext.createCGImage(normalizedSubject, from: targetExtent)
        }
        
        // Load optional Background CIImage
        let bgCI: CIImage? = loadLayerCIImage(
            filename: backdrop.backgroundFilename,
            customData: customBackgroundData,
            cachePrefix: "bg_\(backdrop.id)",
            additionalSearchDirectories: additionalSearchDirectories
        )
        
        // Load optional Foreground CIImage
        let fgCI: CIImage? = loadLayerCIImage(
            filename: backdrop.foregroundFilename,
            customData: customForegroundData,
            cachePrefix: "fg_\(backdrop.id)",
            additionalSearchDirectories: additionalSearchDirectories
        )
        
        guard bgCI != nil || fgCI != nil else {
            return ciContext.createCGImage(normalizedSubject, from: targetExtent)
        }
        
        // Layer 1 + Layer 2: Background Replacement (only runs Vision segmentation if a background image is active)
        var compositedCI: CIImage = normalizedSubject
        if let rawBg = bgCI {
            let scaledBg = scaleImage(rawBg, to: targetExtent, mode: .aspectFill)
            if let maskCI = generatePersonMask(
                for: normalizedSubject,
                targetExtent: targetExtent,
                quality: quality,
                customMaskProvider: customMaskProvider
            ) {
                if let blendFilter = CIFilter(name: "CIBlendWithMask") {
                    blendFilter.setValue(normalizedSubject, forKey: kCIInputImageKey)
                    blendFilter.setValue(scaledBg, forKey: kCIInputBackgroundImageKey)
                    blendFilter.setValue(maskCI, forKey: kCIInputMaskImageKey)
                    if let blended = blendFilter.outputImage?.cropped(to: targetExtent) {
                        compositedCI = blended
                    }
                }
            }
        }
        
        // Layer 3: Foreground Frame Overlay (alpha-composited in front of subject & background)
        if let rawFg = fgCI {
            let scaledFg = scaleImage(rawFg, to: targetExtent, mode: backdrop.foregroundFitMode)
            compositedCI = scaledFg.composited(over: compositedCI).cropped(to: targetExtent)
        }
        
        return ciContext.createCGImage(compositedCI, from: targetExtent)
    }
    
    // MARK: - Vision Person Segmentation + Edge Feathering
    
    nonisolated private static func generatePersonMask(
        for subjectCI: CIImage,
        targetExtent: CGRect,
        quality: SegmentationQuality,
        customMaskProvider: ((CIImage) -> CIImage?)?
    ) -> CIImage? {
        if let provider = customMaskProvider, let customMask = provider(subjectCI) {
            return scaleImage(customMask, to: targetExtent, mode: .stretchToEdges)
        }
        
        let maskPixelBuffer: CVPixelBuffer?
        switch quality {
        case .liveFast:
            maskPixelBuffer = AssetImageCache.shared.performFastSegmentation(on: subjectCI)
        case .captureAccurate:
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .accurate
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            let handler = VNImageRequestHandler(ciImage: subjectCI, options: [:])
            try? handler.perform([request])
            maskPixelBuffer = request.results?.first?.pixelBuffer
        }
        
        guard let pixelBuffer = maskPixelBuffer else { return nil }
        let rawMaskCI = CIImage(cvPixelBuffer: pixelBuffer)
        let maskExtent = rawMaskCI.extent
        guard maskExtent.width > 0, maskExtent.height > 0 else { return nil }
        
        let scaleX = targetExtent.width / maskExtent.width
        let scaleY = targetExtent.height / maskExtent.height
        var scaledMask = rawMaskCI
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .cropped(to: targetExtent)
        
        // Apply proportional soft edge feathering so hair & shoulder boundaries blend naturally without stair-stepping
        let blurRadius = max(0.8, min(3.5, targetExtent.width * 0.0008))
        scaledMask = scaledMask
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
            .cropped(to: targetExtent)
        
        return scaledMask
    }
    
    // MARK: - Resolution Auto-Scaling Helper
    
    nonisolated static func scaleImage(
        _ image: CIImage,
        to targetExtent: CGRect,
        mode: ForegroundFitMode
    ) -> CIImage {
        let srcExtent = image.extent
        guard srcExtent.width > 0, srcExtent.height > 0 else { return image }
        
        // Normalize origin to (0, 0) first
        let normalized = image.transformed(by: CGAffineTransform(translationX: -srcExtent.minX, y: -srcExtent.minY))
        
        switch mode {
        case .stretchToEdges:
            let sx = targetExtent.width / srcExtent.width
            let sy = targetExtent.height / srcExtent.height
            return normalized
                .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                .transformed(by: CGAffineTransform(translationX: targetExtent.minX, y: targetExtent.minY))
                .cropped(to: targetExtent)
            
        case .aspectFill:
            let scale = max(targetExtent.width / srcExtent.width, targetExtent.height / srcExtent.height)
            let scaledW = srcExtent.width * scale
            let scaledH = srcExtent.height * scale
            let offsetX = targetExtent.minX + (targetExtent.width - scaledW) * 0.5
            let offsetY = targetExtent.minY + (targetExtent.height - scaledH) * 0.5
            return normalized
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
                .cropped(to: targetExtent)
            
        case .aspectFit:
            let scale = min(targetExtent.width / srcExtent.width, targetExtent.height / srcExtent.height)
            let scaledW = srcExtent.width * scale
            let scaledH = srcExtent.height * scale
            let offsetX = targetExtent.minX + (targetExtent.width - scaledW) * 0.5
            let offsetY = targetExtent.minY + (targetExtent.height - scaledH) * 0.5
            return normalized
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
                .cropped(to: targetExtent)
        }
    }
    
    nonisolated private static func decodeBitmapBackedCIImage(from source: CGImageSource) -> CIImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) {
            return CIImage(cgImage: cg)
        }
        return nil
    }
    
    /// Returns `true` only if all declared layers (`backgroundFilename` and/or `foregroundFilename`)
    /// of `backdrop` can be resolved either via embedded `Data` or on disk.
    nonisolated static func hasResolvableAssets(
        for backdrop: BackdropItem,
        customBackgroundData: Data? = nil,
        customForegroundData: Data? = nil,
        additionalSearchDirectories: [URL] = []
    ) -> Bool {
        if backdrop.isNone { return false }
        var hasAnyLayer = false
        if let bgName = backdrop.backgroundFilename, !bgName.isEmpty {
            hasAnyLayer = true
            let hasBgData = (customBackgroundData != nil && !(customBackgroundData?.isEmpty ?? true))
            let hasBgFile = BackdropManager.resolveAssetURL(filename: bgName, additionalSearchDirectories: additionalSearchDirectories) != nil
            if !hasBgData && !hasBgFile {
                return false
            }
        }
        if let fgName = backdrop.foregroundFilename, !fgName.isEmpty {
            hasAnyLayer = true
            let hasFgData = (customForegroundData != nil && !(customForegroundData?.isEmpty ?? true))
            let hasFgFile = BackdropManager.resolveAssetURL(filename: fgName, additionalSearchDirectories: additionalSearchDirectories) != nil
            if !hasFgData && !hasFgFile {
                return false
            }
        }
        return hasAnyLayer
    }
    
    nonisolated private static func loadLayerCIImage(
        filename: String?,
        customData: Data?,
        cachePrefix: String,
        additionalSearchDirectories: [URL]
    ) -> CIImage? {
        if let data = customData, !data.isEmpty {
            let key = "\(cachePrefix)_data_\(data.count)_\(data.hashValue)"
            return AssetImageCache.shared.image(forKey: key) {
                if let src = CGImageSourceCreateWithData(data as CFData, nil),
                   let decoded = decodeBitmapBackedCIImage(from: src) {
                    return decoded
                }
                return CIImage(data: data, options: [.applyOrientationProperty: true])
            }
        }
        guard let filename = filename, !filename.isEmpty else { return nil }
        let dirScope = additionalSearchDirectories.first?.path ?? ""
        let key = dirScope.isEmpty
            ? "\(cachePrefix)_file_\(filename)"
            : "\(cachePrefix)_dir_\(dirScope)_file_\(filename)"
        return AssetImageCache.shared.image(forKey: key) {
            guard let url = BackdropManager.resolveAssetURL(
                filename: filename,
                additionalSearchDirectories: additionalSearchDirectories
            ) else { return nil }
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let decoded = decodeBitmapBackedCIImage(from: src) {
                return decoded
            }
            return CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
        }
    }
    
    // MARK: - Front-Camera Selfie Pre-Mirroring Helper (iPad-Only Mode)
    
    /// Orients and horizontally mirrors a raw front-camera `CIImage` into upright display coordinates
    /// BEFORE any backdrop or foreground frame is composited, so the guest sees a natural mirror
    /// while foreground text (e.g. "Evan's Bar Mitzvah") stays 100% right-side up and un-reversed.
    nonisolated static func orientAndMirrorFrontCameraCIImage(
        _ rawCIImage: CIImage,
        interfaceOrientation: UIDeviceOrientation
    ) -> CIImage {
        // Step 1: Rotate raw front-camera sensor buffer to upright display coordinates
        // matching LocalCameraClient's UIImage.Orientation mapping:
        // .portrait -> .right (90 CW), .portraitUpsideDown -> .left (90 CCW),
        // .landscapeLeft -> .down (180), .landscapeRight -> .up (0).
        let uprightExif: CGImagePropertyOrientation
        switch interfaceOrientation {
        case .portrait:
            uprightExif = .right
        case .portraitUpsideDown:
            uprightExif = .left
        case .landscapeLeft:
            uprightExif = .down
        case .landscapeRight:
            uprightExif = .up
        default:
            uprightExif = .right
        }
        let upright = rawCIImage.oriented(forExifOrientation: Int32(uprightExif.rawValue))
        let ext = upright.extent
        let normalizedUpright = upright.transformed(
            by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY)
        )
        
        // Step 2: Horizontally mirror the upright subject image so selfie motion feels like a natural mirror,
        // while any subsequently composited foreground text/frame remains un-mirrored.
        return normalizedUpright
            .transformed(by: CGAffineTransform(scaleX: -1.0, y: 1.0))
            .transformed(by: CGAffineTransform(translationX: ext.width, y: 0))
    }
    
    /// Horizontally mirrors an already-upright `CGImage` (used in deterministic QA tests for front-camera selfie pre-mirroring).
    nonisolated static func mirrorCGImageHorizontally(_ cgImage: CGImage, ciContext: CIContext) -> CGImage {
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let ci = CIImage(cgImage: cgImage)
            .transformed(by: CGAffineTransform(scaleX: -1.0, y: 1.0))
            .transformed(by: CGAffineTransform(translationX: w, y: 0))
        return ciContext.createCGImage(ci, from: CGRect(x: 0, y: 0, width: w, height: h)) ?? cgImage
    }
    
    // MARK: - Triple-Lock Metadata & 8x8 Perceptual RGB Signature
    
    /// Parses the camera filename (e.g. `"DSC04821.JPG"`) from an ISO 15740 PTP `ObjectInfo` (`0x1008`) response payload.
    nonisolated static func parsePTPObjectInfoFilename(from data: Data?) -> String? {
        guard let data = data, data.count >= 16 else { return nil }
        
        func tryParseUTF16Filename(at offset: Int) -> String? {
            guard offset >= 0, offset + 1 < data.count else { return nil }
            let charCount = Int(data[data.startIndex + offset])
            guard charCount >= 5, charCount <= 64, offset + 1 + (charCount * 2) <= data.count else { return nil }
            var scalars: [UInt16] = []
            scalars.reserveCapacity(charCount)
            for i in 0..<charCount {
                let lo = UInt16(data[data.startIndex + offset + 1 + (i * 2)])
                let hi = UInt16(data[data.startIndex + offset + 1 + (i * 2) + 1])
                let codeUnit = lo | (hi << 8)
                if codeUnit == 0 { break }
                // Must be printable ASCII filename characters
                guard codeUnit >= 0x20 && codeUnit <= 0x7E else { return nil }
                scalars.append(codeUnit)
            }
            guard scalars.count >= 5 else { return nil }
            let str = String(utf16CodeUnits: scalars, count: scalars.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let upper = str.uppercased()
            if (upper.hasSuffix(".JPG") || upper.hasSuffix(".JPEG") || upper.hasSuffix(".ARW") || upper.hasSuffix(".HEIF")),
               !upper.contains("/") && !upper.contains("\\") {
                return str
            }
            return nil
        }
        
        // Check standard ISO 15740 offsets first: 52 (raw ObjectInfo dataset) and 64 (12-byte PTP container + 52-byte ObjectInfo)
        for offset in [52, 64] {
            if let found = tryParseUTF16Filename(at: offset) {
                return found
            }
        }
        // Fallback scan in case camera firmware uses a vendor-specific header offset
        let maxScan = min(data.count - 10, 160)
        if maxScan > 0 {
            for offset in 0..<maxScan where offset != 52 && offset != 64 {
                if let found = tryParseUTF16Filename(at: offset) {
                    return found
                }
            }
        }
        return nil
    }
    
    /// Extracts the camera's EXIF `DateTimeOriginal` (or TIFF `DateTime`) and `SubSecTimeOriginal` from image data
    /// without decoding the full pixel buffer (`< 0.1ms` header-only read).
    nonisolated static func extractEXIFTimestamps(from imageData: Data) -> (dateTimeOriginal: String?, subSecOriginal: String?) {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (nil, nil)
        }
        return extractEXIFTimestamps(fromProperties: props)
    }
    
    nonisolated static func extractEXIFTimestamps(from fileURL: URL) -> (dateTimeOriginal: String?, subSecOriginal: String?, backdropAppliedID: String?) {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (nil, nil, nil)
        }
        let (dt, sub) = extractEXIFTimestamps(fromProperties: props)
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let userComment = exif?[kCGImagePropertyExifUserComment] as? String
        var appliedID: String? = nil
        if let comment = userComment, comment.hasPrefix("PB2_BACKDROP:") {
            appliedID = String(comment.dropFirst("PB2_BACKDROP:".count))
        }
        return (dt, sub, appliedID)
    }
    
    nonisolated private static func extractEXIFTimestamps(fromProperties props: [CFString: Any]) -> (dateTimeOriginal: String?, subSecOriginal: String?) {
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let dt = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        let subSec = (exif?[kCGImagePropertyExifSubsecTimeOriginal] as? String)
            ?? (exif?[kCGImagePropertyExifSubsecTime] as? String)
        return (dt, subSec)
    }
    
    /// Parses an EXIF date string (`"YYYY:MM:DD HH:MM:SS"`) into a `Date` for $\pm 2\text{s}$ timestamp window matching.
    nonisolated static func parseEXIFDate(_ exifString: String?, subSec: String? = nil) -> Date? {
        guard let exifString = exifString, !exifString.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let baseDate = formatter.date(from: exifString) else { return nil }
        if let sub = subSec, let frac = Double("0.\(sub.trimmingCharacters(in: .whitespaces))") {
            return baseDate.addingTimeInterval(frac)
        }
        return baseDate
    }
    
    /// Computes a compact 192-byte (`8x8x3` RGB) perceptual color signature from the center 80% of `cgImage`.
    nonisolated static func computeRGBSignature8x8(from cgImage: CGImage) -> [UInt8] {
        let gridSize = 8
        let totalBytes = gridSize * gridSize * 4
        var rgba = [UInt8](repeating: 0, count: totalBytes)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        
        let srcW = CGFloat(cgImage.width)
        let srcH = CGFloat(cgImage.height)
        let cropRect = CGRect(
            x: srcW * 0.10,
            y: srcH * 0.10,
            width: max(1, srcW * 0.80),
            height: max(1, srcH * 0.80)
        )
        let croppedCG = cgImage.cropping(to: cropRect) ?? cgImage
        
        rgba.withUnsafeMutableBytes { ptr in
            guard let baseAddress = ptr.baseAddress,
                  let ctx = CGContext(
                      data: baseAddress,
                      width: gridSize,
                      height: gridSize,
                      bitsPerComponent: 8,
                      bytesPerRow: gridSize * 4,
                      space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(croppedCG, in: CGRect(x: 0, y: 0, width: gridSize, height: gridSize))
        }
        
        var rgb = [UInt8]()
        rgb.reserveCapacity(gridSize * gridSize * 3)
        for i in 0..<(gridSize * gridSize) {
            rgb.append(rgba[i * 4])
            rgb.append(rgba[i * 4 + 1])
            rgb.append(rgba[i * 4 + 2])
        }
        return rgb
    }
    
    /// Computes the mean normalized L1 distance (`0.0 ... 1.0`) between two `8x8x3` RGB signatures.
    nonisolated static func signatureDistance(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1.0 }
        var sumDiff: Int = 0
        for i in 0..<a.count {
            sumDiff += abs(Int(a[i]) - Int(b[i]))
        }
        return Double(sumDiff) / (Double(a.count) * 255.0)
    }
}
