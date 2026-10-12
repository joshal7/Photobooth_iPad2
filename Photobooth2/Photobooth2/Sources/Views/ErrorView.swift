import SwiftUI

struct ErrorView: View {
    let message: String
    @EnvironmentObject var stateMachine: StateMachine
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.9).edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.yellow)
                
                Text("Camera Disconnected")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                Text(message)
                    .font(.body)
                    .foregroundColor(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                Button(action: {
                    stateMachine.retryConnection()
                }) {
                    Text("Retry Connection")
                        .font(.headline)
                        .foregroundColor(.black)
                        .padding()
                        .frame(minWidth: 200)
                        .background(Color.white)
                        .cornerRadius(10)
                }
                .padding(.top, 20)
                
                // Instructional text for Sony A7V USB-C connection
                VStack(alignment: .leading, spacing: 10) {
                    Text("Troubleshooting:")
                        .font(.headline)
                        .foregroundColor(.gray)
                    
                    Text("1. Ensure the Sony A7V is turned ON and Mode Dial is set to '1'")
                    Text("2. Verify the USB-C cable is plugged into the camera's USB Data port (trident icon) and the UGREEN Hub")
                    Text("3. Confirm Camera Setup > USB > USB Connection Mode is set to 'PC Remote'")
                    Text("4. Tap 'Retry Connection' above (or unplug and replug the USB-C cable)")
                }
                .font(.footnote)
                .foregroundColor(.gray)
                .padding(.top, 30)
                .padding(.horizontal)
            }
            .padding()
        }
    }
}
