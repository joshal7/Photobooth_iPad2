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
    /// - Returns: URL to the created GIF file, or nil if failed.
    nonisolated static func createGIF(from imagePaths: [String], frameDuration: Double, resolution: Int = 0) -> URL? {
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
        
        let tempDir = FileManager.default.temporaryDirectory
        let gifURL = tempDir.appendingPathComponent("\(UUID().uuidString).gif")
        
        guard let destination = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, imagePaths.count, nil) else {
            print("Failed to create GIF destination")
            return nil
        }
        
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)
        
        // Default 1080p height
        let targetHeight: Double = 1080
        
        // Calculate maxPixelSize based on the first image's aspect ratio
        var computedMaxPixelSize: Int = Int(targetHeight)
        
        if let firstPath = imagePaths.first {
            let url = resolveFileURL(firstPath)
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
                
                let width = properties[kCGImagePropertyPixelWidth as String] as? Double ?? 0
                let height = properties[kCGImagePropertyPixelHeight as String] as? Double ?? 0
                
                if height > 0 {
                    let aspectRatio = width / height
                    // If Landscape (AR > 1), we must scale Width such that Height = targetHeight.
                    // MaxPixelSize limits the longest edge.
                    if width >= height {
                        // Landscape: Longest edge is Width.
                        // Width = Height * AR
                        computedMaxPixelSize = Int(targetHeight * aspectRatio)
                    } else {
                        // Portrait: Longest edge is Height.
                        // Height = targetHeight
                        computedMaxPixelSize = Int(targetHeight)
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
                  let rawCG = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                print("Failed to load image source at \(path)")
                continue
            }
            
            // Frames captured by SonyUSBCameraClient.takePicture() ("sony_<UUID>.jpg") are already
            // normalized and single-pass auto-exposed once when written to /tmp. Do not auto-expose
            // them a second time (which would double the gain and clip colors/highlights).
            let isAlreadyNormalizedSonyFrame = url.lastPathComponent.hasPrefix("sony_")
            let baseCG = isAlreadyNormalizedSonyFrame
                ? rawCG
                : SonyUSBCameraClient.autoExposeCapturedCGImage(rawCG, ciContext: ciContext)
            let (luma, _) = SonyUSBCameraClient.measureSceneLuminance(baseCG)
            loadedFrames.append(FrameEntry(cgImage: baseCG, luma: max(luma, 0.02)))
        }
        
        guard !loadedFrames.isEmpty else {
            return nil
        }
        
        // Compute the median scene luminance across all frames in the GIF burst so that if any
        // single frame (e.g. the 4th frame in Aperture Priority mode) varied slightly in exposure,
        // all frames are smoothly equalized to the burst's median brightness.
        let sortedLumas = loadedFrames.map(\.luma).sorted()
        let mid = sortedLumas.count / 2
        let medianLuma: Double = (sortedLumas.count % 2 == 0 && sortedLumas.count >= 2)
            ? (sortedLumas[mid - 1] + sortedLumas[mid]) * 0.5
            : sortedLumas[mid]
        
        for entry in loadedFrames {
            // Convert sRGB luminance ratio to linear stops (sRGB ~ linear^(1/2.2)) for CIExposureAdjust
            let deltaEV = 2.2 * log2(medianLuma / entry.luma)
            let clampedDeltaEV = min(max(deltaEV, -1.20), 1.20)
            let finalCG: CGImage
            if abs(clampedDeltaEV) > 0.04,
               let exposureFilter = CIFilter(name: "CIExposureAdjust") {
                let ciInput = CIImage(cgImage: entry.cgImage)
                exposureFilter.setValue(ciInput, forKey: kCIInputImageKey)
                exposureFilter.setValue(clampedDeltaEV, forKey: kCIInputEVKey)
                if let outCI = exposureFilter.outputImage,
                   let equalizedCG = ciContext.createCGImage(outCI, from: ciInput.extent) {
                    finalCG = equalizedCG
                } else {
                    finalCG = entry.cgImage
                }
            } else {
                finalCG = entry.cgImage
            }
            CGImageDestinationAddImage(destination, finalCG, frameProperties as CFDictionary)
        }
        
        if CGImageDestinationFinalize(destination) {
            print("GIF created at \(gifURL)")
            return gifURL
        } else {
            print("Failed to finalize GIF")
            return nil
        }
    }
}
