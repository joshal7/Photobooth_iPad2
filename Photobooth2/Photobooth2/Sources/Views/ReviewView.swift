import SwiftUI

struct ReviewView: View {
    let images: [String]
    let currentIndex: Int
    @EnvironmentObject var stateMachine: StateMachine
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            if currentIndex >= 0, currentIndex < images.count, isGIF(url: images[currentIndex]) {
                GIFPlayerView(url: resolveFileURL(images[currentIndex]))
                    .edgesIgnoringSafeArea(.all)
                    .transition(.opacity)
                    .id("GIF-\(currentIndex)")
            } else if let image = stateMachine.currentReviewImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .edgesIgnoringSafeArea(.all)
                    .transition(.opacity)
                    .id(currentIndex)
            } else {
                ProgressView()
                    .scaleEffect(2.0)
                    .colorScheme(.dark)
            }
            
            // Optional: Overlay showing "Reviewing X of N"
            VStack {
                Spacer()
                Text("Reviewing \(min(max(currentIndex + 1, 1), max(images.count, 1))) of \(images.count)")
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.bottom, 20)
            }
        }
        .edgesIgnoringSafeArea(.all)
    }
    
    private func isGIF(url: String) -> Bool {
        return url.lowercased().hasSuffix(".gif")
    }
    
    private func resolveFileURL(_ pathOrURL: String) -> URL {
        if pathOrURL.hasPrefix("file://"), let parsed = URL(string: pathOrURL) {
            return parsed
        }
        return URL(fileURLWithPath: pathOrURL)
    }
}
