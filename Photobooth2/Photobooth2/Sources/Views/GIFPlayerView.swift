import SwiftUI
import UIKit
import ImageIO

struct GIFPlayerView: UIViewRepresentable {
    let url: URL
    
    final class Coordinator {
        var loadedURL: URL?
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        
        let imageView = UIImageView()
        imageView.tag = 1001
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .clear
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageView)
        
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        
        return container
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        guard let imageView = uiView.viewWithTag(1001) as? UIImageView else { return }
        guard context.coordinator.loadedURL != url || imageView.image == nil else { return }
        context.coordinator.loadedURL = url
        
        if let animated = Self.loadAnimatedImage(from: url) {
            imageView.image = animated
            imageView.startAnimating()
        }
    }
    
    static func loadAnimatedImage(from url: URL) -> UIImage? {
        let resolvedURL: URL
        if url.isFileURL {
            resolvedURL = url
        } else if let parsed = URL(string: url.absoluteString), parsed.isFileURL {
            resolvedURL = parsed
        } else {
            resolvedURL = URL(fileURLWithPath: url.path)
        }
        
        guard let source = CGImageSourceCreateWithURL(resolvedURL as CFURL, nil) else {
            return UIImage(contentsOfFile: resolvedURL.path)
        }
        
        let count = CGImageSourceGetCount(source)
        guard count > 1 else {
            if let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                return UIImage(cgImage: cg)
            }
            return UIImage(contentsOfFile: resolvedURL.path)
        }
        
        var frames: [UIImage] = []
        frames.reserveCapacity(count)
        var totalDuration: Double = 0
        
        for i in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            var frameDelay: Double = 0.5
            if let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any],
               let gifDict = props[kCGImagePropertyGIFDictionary as String] as? [String: Any] {
                if let unclamped = gifDict[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double, unclamped > 0.01 {
                    frameDelay = unclamped
                } else if let delay = gifDict[kCGImagePropertyGIFDelayTime as String] as? Double, delay > 0.01 {
                    frameDelay = delay
                }
            }
            totalDuration += frameDelay
            frames.append(UIImage(cgImage: cgImage))
        }
        
        guard !frames.isEmpty else { return nil }
        return UIImage.animatedImage(with: frames, duration: max(0.2, totalDuration))
    }
}

