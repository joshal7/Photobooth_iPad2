import SwiftUI

struct CountdownView: View {
    @EnvironmentObject var stateMachine: StateMachine
    
    var body: some View {
        ZStack {
            // Transparent background to see LiveView behind
            Color.black.opacity(0.2)
            
            if stateMachine.countdown > 0 {
                Text("\(stateMachine.countdown)")
                    .font(.system(size: 400, weight: .bold))
                    .foregroundColor(.white)
                    .shadow(color: .black, radius: 10, x: 0, y: 0)
                    .transition(.scale.combined(with: .opacity))
                    .id(stateMachine.countdown) // Force transition on change
                
                if stateMachine.captureMode == .gif {
                    VStack {
                        Spacer()
                        Text("Get Ready to Move!")
                            .font(.system(size: 56, weight: .heavy))
                            .foregroundColor(.white)
                            .shadow(color: .black, radius: 10, x: 0, y: 0)
                            .padding(.bottom, 56)
                    }
                    .transition(.opacity)
                }
            }
        }
    }
}

