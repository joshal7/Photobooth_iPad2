import Foundation
import ImageIO
import MobileCoreServices
import UniformTypeIdentifiers
import CoreImage

final class GIFService: Sendable {
    
    nonisolated private static let sharedCIContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false
    ])
    
    // No shared instance needed for stateless service
    private init() {}
    
    private nonisolated static func resolveFileURL(_ pathOrURL: String) -> URL {
        if pathOrURL.hasPrefix("file://"), let url = URL(string: pathOrURL) {
            return url
        }
        return URL(fileURLWithPath: pathOrURL)
    }
    
    /// Derives the `.gif` filename from the first source image so that the GIF starts with the exact name
    /// of the first image (e.g. `"DSC09820.JPG"` -> `"DSC09820.gif"`, or `"sony_DSC09820_<UUID>.jpg"` -> `"DSC09820.gif"`),
    /// enabling chronological sorting by filename alongside camera `.JPG` files on macOS.
    nonisolated static func gifFilename(fromFirstImagePath firstPath: String?) -> String {
        guard let firstPath = firstPath, !firstPath.isEmpty else {
            return "\(UUID().uuidString).gif"
        }
        let url = resolveFileURL(firstPath)
        let rawStem = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawStem.isEmpty else {
            return "\(UUID().uuidString).gif"
        }
        
        // If captured by SonyUSBCameraClient with embedded camera filename ("sony_<CAMERA_STEM>_<UUID>"),
        // extract the exact camera stem (e.g. "DSC09820").
        if rawStem.hasPrefix("sony_") {
            let afterPrefix = String(rawStem.dropFirst("sony_".count))
            if afterPrefix.count > 37 {
                let uuidPart = String(afterPrefix.suffix(36))
                let sepIndex = afterPrefix.index(afterPrefix.endIndex, offsetBy: -37)
                if afterPrefix[sepIndex] == "_", UUID(uuidString: uuidPart) != nil {
                    let cameraStem = String(afterPrefix[..<sepIndex])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cameraStem.isEmpty {
                        return "\(cameraStem).gif"
                    }
                }
            }
        }
        
        return "\(rawStem).gif"
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
        guard !imagePaths.isEmpty else {
            return nil
        }
        
        let fileProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: 0 // 0 = infinite loop
            ]
        ]
        
        let frameProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: frameDuration
            ]
        ]
        
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
        
        let ciContext = Self.sharedCIContext
        
        struct FrameEntry {
            let cgImage: CGImage
            let luma: Double
            let highlightPeak: Double
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
            let (luma, highlightPeak) = SonyUSBCameraClient.measureSceneLuminance(baseCG)
            loadedFrames.append(
                FrameEntry(
                    cgImage: baseCG,
                    luma: max(luma, 0.06),
                    highlightPeak: max(highlightPeak, 0.06)
                )
            )
        }
        
        guard !loadedFrames.isEmpty else {
            return nil
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let gifFileName = gifFilename(fromFirstImagePath: imagePaths.first)
        let gifURL = tempDir.appendingPathComponent(gifFileName)
        try? FileManager.default.removeItem(at: gifURL)
        
        guard let destination = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, loadedFrames.count, nil) else {
            print("Failed to create GIF destination")
            return nil
        }
        
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)
        
        // 1. Compute the median scene luminance and median highlight peak across all subject frames in the GIF burst
        //    so any single frame that drifted in illumination is equalized BEFORE the static backdrop/frame is applied,
        //    without overexposing frames where a subject merely crouched or moved against a dark backdrop curtain.
        let sortedLumas = loadedFrames.map(\.luma).sorted()
        let sortedPeaks = loadedFrames.map(\.highlightPeak).sorted()
        let mid = sortedLumas.count / 2
        let medianLuma: Double = (sortedLumas.count % 2 == 0 && sortedLumas.count >= 2)
            ? (sortedLumas[mid - 1] + sortedLumas[mid]) * 0.5
            : sortedLumas[mid]
        let medianPeak: Double = (sortedPeaks.count % 2 == 0 && sortedPeaks.count >= 2)
            ? (sortedPeaks[mid - 1] + sortedPeaks[mid]) * 0.5
            : sortedPeaks[mid]
        
        for entry in loadedFrames {
            let lumaDeltaEV = 2.2 * log2(medianLuma / entry.luma)
            let peakDeltaEV = 2.2 * log2(medianPeak / entry.highlightPeak)
            let agreedDeltaEV: Double
            if lumaDeltaEV >= 0 {
                let headroomEV = entry.highlightPeak < 0.72
                    ? max(0.0, log2(0.72 / entry.highlightPeak) * 1.65)
                    : 0.0
                agreedDeltaEV = min(lumaDeltaEV, min(max(0.0, peakDeltaEV), headroomEV))
            } else {
                agreedDeltaEV = max(lumaDeltaEV, min(0.0, peakDeltaEV))
            }
            let clampedDeltaEV = min(max(agreedDeltaEV, -0.85), 0.85)
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
            
            CGImageDestinationAddImage(destination, finalCG, frameProperties as CFDictionary)
        }
        
        if CGImageDestinationFinalize(destination) {
            print("GIF created at \(gifURL)")
            return gifURL
        } else {
            try? FileManager.default.removeItem(at: gifURL)
            print("Failed to finalize GIF")
            return nil
        }
    }
}
