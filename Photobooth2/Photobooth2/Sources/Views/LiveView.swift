import SwiftUI

struct LiveView: View {
    @EnvironmentObject var stateMachine: StateMachine
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                
                if let image = stateMachine.previewImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        // Mirror if using local camera for natural feel
                        .scaleEffect(x: ConfigManager.shared.useLocalCamera ? -1 : 1, y: 1)
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
    }
}
