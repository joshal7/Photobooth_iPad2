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
            }
        }
    }
}
