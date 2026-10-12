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
                
                // Instructional text for SSID issue
                VStack(alignment: .leading, spacing: 10) {
                    Text("Troubleshooting:")
                        .font(.headline)
                        .foregroundColor(.gray)
                    
                    Text("1. Go to iPad Settings > Wi-Fi")
                    Text("2. Select 'DIRECT-xxxx:Sony'")
                    Text("3. Tap 'Retry' above")
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
