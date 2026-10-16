import SwiftUI

struct LiveView: View {
    @EnvironmentObject var stateMachine: StateMachine
    
    /// Computes the exact aspect-fitted (`contentMode: .fit`) frame of a Live View image inside `containerSize`,
    /// ensuring 100% of the camera image, background, and foreground frame borders remain visible without clipping.
    static func fittedRect(forImageSize imageSize: CGSize, inContainerSize containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            return .zero
        }
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let fittedWidth = imageSize.width * scale
        let fittedHeight = imageSize.height * scale
        let originX = (containerSize.width - fittedWidth) * 0.5
        let originY = (containerSize.height - fittedHeight) * 0.5
        return CGRect(x: originX, y: originY, width: fittedWidth, height: fittedHeight)
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                    .edgesIgnoringSafeArea(.all)
                
                if let image = stateMachine.previewImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    // Placeholder or loading indicator
                    ZStack {
                        Color.gray.opacity(0.3)
                        ProgressView()
                            .scaleEffect(2.0)
                    }
                }
                
                // Connection status indicator
                VStack {
                    HStack {
                        Spacer()
                        Circle()
                            // We can infer streaming status if we have an image or check service connection
                            // For now, let's use a simple check or bind to a status in StateMachine if we added one.
                            // StateMachine doesn't expose isStreaming directly, but we have previewImage.
                            .fill(stateMachine.previewImage != nil ? Color.green : Color.red)
                            .frame(width: 10, height: 10)
                            .padding()
                    }
                    Spacer()
                }
            }
        }
        .edgesIgnoringSafeArea(.all)
    }
}
