import SwiftUI
import CoreImage.CIFilterBuiltins

/// Generates a high-contrast QR code image from a URL string using CoreImage.
/// Designed for large on-screen display in bright booth environments.
struct QRCodeGeneratorView: View {
    let urlString: String
    
    private static let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    private static let cacheLock = NSLock()
    private static var cachedURLString: String?
    private static var cachedQRImage: UIImage?

    var body: some View {
        if let image = Self.generateQRCode(from: urlString) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .accessibilityLabel("QR code linking to \(urlString)")
        } else {
            // Fallback if generation fails (e.g. empty string)
            Image(systemName: "qrcode")
                .font(.system(size: 100))
                .foregroundColor(.white.opacity(0.3))
        }
    }

    private static func generateQRCode(from string: String) -> UIImage? {
        guard !string.isEmpty, let data = string.data(using: .utf8) else { return nil }
        
        cacheLock.lock()
        if cachedURLString == string, let existing = cachedQRImage {
            cacheLock.unlock()
            return existing
        }
        cacheLock.unlock()

        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        // "H" = highest error correction — resilient under booth lighting / angles
        filter.setValue("H", forKey: "inputCorrectionLevel")

        guard let ciImage = filter.outputImage else { return nil }

        // The raw CIImage is tiny (~33x33 px). Scale up 10x so it renders
        // crisply at any display size without blurring.
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))

        guard let cgImage = sharedCIContext.createCGImage(scaled, from: scaled.extent) else { return nil }

        let rendered = UIImage(cgImage: cgImage)
        cacheLock.lock()
        cachedURLString = string
        cachedQRImage = rendered
        cacheLock.unlock()
        return rendered
    }
}
