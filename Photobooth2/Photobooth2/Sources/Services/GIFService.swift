import Foundation
import ImageIO
import MobileCoreServices
import UniformTypeIdentifiers

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
        
        for path in imagePaths {
            let url = resolveFileURL(path)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                print("Failed to load image source at \(path)")
                continue
            }
            
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                CGImageDestinationAddImage(destination, cgImage, frameProperties as CFDictionary)
            }
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
