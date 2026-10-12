import Foundation
import ImageIO
import MobileCoreServices
import UniformTypeIdentifiers

final class GIFService: Sendable {
    
    // No shared instance needed for stateless service
    private init() {}
    
    /// Creates an animated GIF from a list of image paths.
    /// - Parameters:
    ///   - imagePaths: List of file paths (strings) to source images.
    ///   - frameDuration: Duration for each frame in seconds.
    ///   - resolution: 0 for 720p (1280x720), 1 for 480p (640x480).
    /// - Returns: URL to the created GIF file, or nil if failed.
    nonisolated static func createGIF(from imagePaths: [String], frameDuration: Double, resolution: Int) -> URL? {
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
        
        // Determine target height
        let targetHeight: Double = (resolution == 1) ? 480 : 720
        
        // Calculate maxPixelSize based on the first image's aspect ratio
        var computedMaxPixelSize: Int = Int(targetHeight)
        
        if let firstPath = imagePaths.first,
           let url = URL(string: "file://\(firstPath)"),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
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
        
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: computedMaxPixelSize as NSNumber
        ]
        
        for path in imagePaths {
            let url = URL(fileURLWithPath: path)
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
