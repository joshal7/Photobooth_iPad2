import Foundation
import ImageIO
import MobileCoreServices
import UniformTypeIdentifiers
import CoreImage

final class GIFService: Sendable {
    
    // No shared instance needed for stateless service
    private init() {}
    
    private nonisolated static func resolveFileURL(_ pathOrURL: String) -> URL {
        if pathOrURL.hasPrefix("file://"), let url = URL(string: pathOrURL) {
            return url
        }
        return URL(fileURLWithPath: pathOrURL)
    }

    /// Creates an animated GIF from a list of image paths or file:// URLs at 1080p resolution.
    /// - Parameters:
    ///   - imagePaths: List of file paths or file:// URL strings to source images.
    ///   - frameDuration: Duration for each frame in seconds.
    ///   - resolution: Unused legacy parameter (defaults to 1080p).
    ///   - backdrop: Optional background/foreground preset to composite onto each equalized frame.
    ///   - customMaskProvider: Optional custom person-mask provider for deterministic QA tests.
    /// - Returns: URL to the created GIF file, or nil if failed.
    nonisolated static func createGIF(
        from imagePaths: [String],
        frameDuration: Double,
        resolution: Int = 0,
        backdrop: BackdropItem = .none,
        additionalSearchDirectories: [URL] = [],
        customMaskProvider: ((CIImage) -> CIImage?)? = nil
    ) -> URL? {
        let fileProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: 0, // 0 = infinite loop
                kCGImagePropertyGIFHasGlobalColorMap as String: true
            ]
        ]
        
        let frameProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: frameDuration,
                kCGImagePropertyGIFUnclampedDelayTime as String: frameDuration
            ]
        ]
        
        let tempDir = FileManager.default.temporaryDirectory
        let gifURL = tempDir.appendingPathComponent("\(UUID().uuidString).gif")
        
        guard let destination = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, imagePaths.count, nil) else {
            print("Failed to create GIF destination")
            return nil
        }
        
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)
        
        // Default 1080p height (1620x1080 at 3:2 landscape aspect ratio)
        let targetHeight: Double = 1080
        let defaultThreeByTwoMaxPixelSize = Int((targetHeight * Double(BackdropCompositorService.targetPhotoboothAspectRatio)).rounded())
        
        // Calculate maxPixelSize based on the first image's aspect ratio (minimum 1620 for 1080p 3:2 output)
        var computedMaxPixelSize: Int = defaultThreeByTwoMaxPixelSize
        
        if let firstPath = imagePaths.first {
            let url = resolveFileURL(firstPath)
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
                
                let width = properties[kCGImagePropertyPixelWidth as String] as? Double ?? 0
                let height = properties[kCGImagePropertyPixelHeight as String] as? Double ?? 0
                
                if height > 0 {
                    let aspectRatio = width / height
                    if width >= height {
                        computedMaxPixelSize = max(defaultThreeByTwoMaxPixelSize, Int((targetHeight * aspectRatio).rounded()))
                    } else {
                        computedMaxPixelSize = defaultThreeByTwoMaxPixelSize
                    }
                }
            }
        }
        
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: computedMaxPixelSize as NSNumber
        ]
        
        let ciContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
        
        struct FrameEntry {
            let cgImage: CGImage
            let luma: Double
        }
        
        var loadedFrames: [FrameEntry] = []
        loadedFrames.reserveCapacity(imagePaths.count)
        
        for path in imagePaths {
            let url = resolveFileURL(path)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let rawThumbCG = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                print("Failed to load image source at \(path)")
                continue
            }
            
            let rawCG = BackdropCompositorService.cropToLandscapeThreeByTwo(rawThumbCG)
            
            // Frames captured by SonyUSBCameraClient.takePicture() ("sony_<UUID>.jpg") or LocalCameraClient
            // ("local_<UUID>.jpg") are already normalized and single-pass auto-exposed once when written to /tmp.
            let fileName = url.lastPathComponent
            let isAlreadyNormalizedFrame = fileName.hasPrefix("sony_") || fileName.hasPrefix("local_")
            let baseCG = isAlreadyNormalizedFrame
                ? rawCG
                : SonyUSBCameraClient.autoExposeCapturedCGImage(rawCG, ciContext: ciContext)
            let (luma, _) = SonyUSBCameraClient.measureSceneLuminance(baseCG)
            loadedFrames.append(FrameEntry(cgImage: baseCG, luma: max(luma, 0.02)))
        }
        
        guard !loadedFrames.isEmpty else {
            return nil
        }
        
        // 1. Compute the median scene luminance across all raw subject frames in the GIF burst
        //    so any single frame that drifted in exposure is equalized BEFORE the static backdrop/frame is applied.
        let sortedLumas = loadedFrames.map(\.luma).sorted()
        let mid = sortedLumas.count / 2
        let medianLuma: Double = (sortedLumas.count % 2 == 0 && sortedLumas.count >= 2)
            ? (sortedLumas[mid - 1] + sortedLumas[mid]) * 0.5
            : sortedLumas[mid]
        
        for entry in loadedFrames {
            let deltaEV = 2.2 * log2(medianLuma / entry.luma)
            let clampedDeltaEV = min(max(deltaEV, -1.20), 1.20)
            let equalizedSubjectCG: CGImage
            if abs(clampedDeltaEV) > 0.04,
               let exposureFilter = CIFilter(name: "CIExposureAdjust") {
                let ciInput = CIImage(cgImage: entry.cgImage)
                exposureFilter.setValue(ciInput, forKey: kCIInputImageKey)
                exposureFilter.setValue(clampedDeltaEV, forKey: kCIInputEVKey)
                if let outCI = exposureFilter.outputImage,
                   let equalizedCG = ciContext.createCGImage(outCI, from: ciInput.extent) {
                    equalizedSubjectCG = equalizedCG
                } else {
                    equalizedSubjectCG = entry.cgImage
                }
            } else {
                equalizedSubjectCG = entry.cgImage
            }
            
            // 2. Apply high-quality (.captureAccurate) Background / Foreground compositing AFTER subject equalization
            //    so static backgrounds and foreground frames remain 100% constant in brightness across all frames.
            let finalCG: CGImage
            if !backdrop.isNone {
                finalCG = BackdropCompositorService.composite(
                    cgImage: equalizedSubjectCG,
                    backdrop: backdrop,
                    quality: .captureAccurate,
                    ciContext: ciContext,
                    additionalSearchDirectories: additionalSearchDirectories,
                    customMaskProvider: customMaskProvider
                )
            } else {
                finalCG = equalizedSubjectCG
            }
            
            let opaqueFinalCG = makeOpaqueRGBCGImage(finalCG)
            CGImageDestinationAddImage(destination, opaqueFinalCG, frameProperties as CFDictionary)
        }
        
        if CGImageDestinationFinalize(destination) {
            if let rawData = try? Data(contentsOf: gifURL) {
                let strictGIF89a = ensureStrictGIF89aData(rawData)
                try? strictGIF89a.write(to: gifURL, options: .atomic)
            }
            print("GIF created at \(gifURL)")
            return gifURL
        } else {
            print("Failed to finalize GIF")
            return nil
        }
    }
    
    /// Ensures a CGImage uses an opaque RGB bitmap layout (`noneSkipLast`) without an active alpha channel
    /// so ImageIO's GIF89a encoder does not allocate a transparent palette index or mark frames `HasAlpha = 1`.
    nonisolated static func makeOpaqueRGBCGImage(_ image: CGImage) -> CGImage {
        let alphaInfo = image.alphaInfo
        if alphaInfo == .none || alphaInfo == .noneSkipLast || alphaInfo == .noneSkipFirst {
            return image
        }
        let width = image.width
        let height = image.height
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? image
    }
    
    /// Fixes Apple ImageIO's `CGImageDestination` quirk where multi-frame animated GIFs are written with a
    /// `GIF87a` magic header (`47 49 46 38 37 61`) and `Transparent Color Flag = 1` (`HasAlpha = 1`) on opaque frames.
    /// Converts the header to strict `GIF89a` (`47 49 46 38 39 61`) and clears the transparent flag on all GCE blocks
    /// so Gmail iOS's Download-to-Camera-Roll handler and `PHPhotoLibrary` recognize and save it as an animated GIF.
    nonisolated static func ensureStrictGIF89aData(_ data: Data) -> Data {
        guard data.count >= 14 else { return data }
        var bytes = [UInt8](data)
        guard bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46,
              bytes[3] == 0x38, (bytes[4] == 0x37 || bytes[4] == 0x39), bytes[5] == 0x61 else {
            return data
        }
        // Force strict "GIF89a" magic signature
        bytes[4] = 0x39
        
        let lsdPacked = bytes[10]
        let hasGCT = (lsdPacked & 0x80) != 0
        let gctEntries = hasGCT ? (1 << ((Int(lsdPacked) & 0x07) + 1)) : 0
        var i = 13 + gctEntries * 3
        
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x21 {
                guard i + 2 < bytes.count else { break }
                let label = bytes[i + 1]
                if label == 0xF9 && bytes[i + 2] == 0x04 && i + 7 < bytes.count && bytes[i + 7] == 0x00 {
                    var packed = bytes[i + 3] & 0xFE // Clear Transparent Color Flag (bit 0)
                    if ((packed >> 2) & 0x07) == 0 {
                        packed |= (1 << 2) // Disposal Method = 1 (Do Not Dispose)
                    }
                    bytes[i + 3] = packed
                    bytes[i + 6] = 0x00
                    i += 8
                } else {
                    i += 2
                    while i < bytes.count {
                        let subLen = Int(bytes[i])
                        i += 1
                        if subLen == 0 { break }
                        i += subLen
                    }
                }
            } else if b == 0x2C {
                guard i + 10 < bytes.count else { break }
                let lctPacked = bytes[i + 9]
                let hasLCT = (lctPacked & 0x80) != 0
                let lctEntries = hasLCT ? (1 << ((Int(lctPacked) & 0x07) + 1)) : 0
                i += 10 + lctEntries * 3
                guard i < bytes.count else { break }
                i += 1 // LZW minimum code size
                while i < bytes.count {
                    let subLen = Int(bytes[i])
                    i += 1
                    if subLen == 0 { break }
                    i += subLen
                }
            } else if b == 0x3B {
                break
            } else {
                break
            }
        }
        return Data(bytes)
    }
}
