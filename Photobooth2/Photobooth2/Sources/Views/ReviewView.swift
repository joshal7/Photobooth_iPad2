import SwiftUI

struct ReviewView: View {
    let images: [String]
    let currentIndex: Int
    @EnvironmentObject var stateMachine: StateMachine
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            if currentIndex < images.count, isGIF(url: images[currentIndex]), let url = URL(string: images[currentIndex]) {
                GIFPlayerView(url: url)
                    .edgesIgnoringSafeArea(.all)
                    .transition(.opacity)
                    .id("GIF-\(currentIndex)")
            } else if let image = stateMachine.currentReviewImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
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
                Text("Reviewing \(currentIndex + 1) of \(images.count)")
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.bottom, 20)
            }
        }
    }
    
    private func isGIF(url: String) -> Bool {
        return url.lowercased().hasSuffix(".gif")
    }
}
