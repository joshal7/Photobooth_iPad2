import SwiftUI
import WebKit

struct GIFPlayerView: UIViewRepresentable {
    let url: URL
    
    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = false // Transparent background
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false // Prevent scrolling
        webView.scrollView.backgroundColor = .clear
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Load file URL
        // If url is file://, readAccessURL should be the directory containing it
        if url.isFileURL {
            let dir = url.deletingLastPathComponent()
            uiView.loadFileURL(url, allowingReadAccessTo: dir)
        } else {
            uiView.load(URLRequest(url: url))
        }
    }
}
