import SwiftUI

struct ContentView: View {
    @EnvironmentObject var stateMachine: StateMachine

    @State private var showSettings = false
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            // Background Live View (Always visible in Idle/Capture)
            if case .idle = stateMachine.state {
                LiveView()
            } else if case .capture = stateMachine.state {
                LiveView()
            }
            
            // Overlays based on state
            switch stateMachine.state {
            case .initialization:
                ProgressView("Connecting to Camera...")
                    .foregroundColor(.white)
                    .scaleEffect(1.5)
                
            case .processing(let message):
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(2.0)
                        .colorScheme(.dark)
                    Text(message)
                        .font(.headline)
                        .foregroundColor(.white)
                }
                
            case .idle:
                ZStack {
                    if ConfigManager.shared.enableGIFMode {
                        // Split Screen UI
                        VStack(spacing: 0) {
                            // Top: GIF Mode
                            Button(action: {
                                stateMachine.triggerCapture(mode: .gif)
                            }) {
                                ZStack {
                                    Color.black.opacity(0.01) // Tappable area
                                    Text("Create an animated gif")
                                        .font(.system(size: 50, weight: .heavy))
                                        .foregroundColor(.white)
                                        .shadow(radius: 10)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            
                            // Divider / "Or"
                            ZStack {
                                Rectangle()
                                    .fill(Color.white.opacity(0.2))
                                    .frame(height: 2)
                                Text(" OR ")
                                    .font(.title)
                                    .fontWeight(.bold)
                                    .foregroundColor(.white)
                            }
                            
                            // Bottom: Standard Mode
                            Button(action: {
                                stateMachine.triggerCapture(mode: .standard)
                            }) {
                                ZStack {
                                    Color.black.opacity(0.01) // Tappable area
                                    Text("Take \(ConfigManager.shared.photoCount) Photos")
                                        .font(.system(size: 50, weight: .heavy))
                                        .foregroundColor(.white)
                                        .shadow(radius: 10)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        // Standard Single Mode
                        VStack {
                            Spacer()
                            Text("TAP TO TAKE \(ConfigManager.shared.photoCount) PHOTO\(ConfigManager.shared.photoCount == 1 ? "" : "S")")
                                .font(.system(size: 60, weight: .heavy))
                                .foregroundColor(.white)
                                .padding(.bottom, 50)
                                .shadow(radius: 10)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            stateMachine.triggerCapture(mode: .standard)
                        }
                    }
                }
                
            case .capture:
                ZStack {
                    if stateMachine.showGuidance {
                        LookAtCameraView(useLocalCamera: ConfigManager.shared.useLocalCamera)
                            .transition(.opacity)
                            .zIndex(1)
                    } else {
                        CountdownView()
                            .transition(.opacity)
                    }
                    
                    // Pose indicator for GIF captures (external camera only)
                    // Uses animation to fade in, providing visual break between pose changes
                    if let pose = stateMachine.poseIndicator {
                        Text(pose)
                            .font(.system(size: 50, weight: .heavy))
                            .foregroundColor(.white)
                            .shadow(radius: 10)
                            .transition(.asymmetric(
                                insertion: .opacity.animation(.easeIn(duration: 0.5)),
                                removal: .opacity.animation(.easeOut(duration: 0.1))
                            ))
                            .id(pose) // Force new view for each pose change, triggering animation
                    }
                    
                    // Photo counter in upper right
                    if stateMachine.currentPhotoNumber > 0 {
                        VStack {
                            HStack {
                                Spacer()
                                Text("\(stateMachine.currentPhotoNumber) of \(ConfigManager.shared.photoCount)")
                                    .font(.system(size: 60, weight: .heavy))
                                    .foregroundColor(.white)
                                    .shadow(radius: 10)
                                    .padding(.top, 50)
                                    .padding(.trailing, 50)
                            }
                            Spacer()
                        }
                    }
                }
                
            case .review(let images, let index):
                ReviewView(images: images, currentIndex: index)
                
            case .error(let message):
                ErrorView(message: message)
                
            case .wifiMismatch(let targetSSID):
                VStack(spacing: 20) {
                    Text("Connect to the Camera's WiFi")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    
                    Text("\"\(targetSSID)\"")
                        .font(.system(size: 30, weight: .heavy, design: .monospaced))
                        .foregroundColor(.yellow)
                        .padding()
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(10)
                    
                    Button(action: {
                        UIPasteboard.general.string = ConfigManager.shared.cameraPassword
                    }) {
                        HStack {
                            Image(systemName: "doc.on.doc")
                            Text("Copy Password")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.gray.opacity(0.5))
                        .cornerRadius(10)
                    }
                    .padding(.bottom, 10)
                    
                    Button(action: {
                        // Try multiple URL schemes to open Wi-Fi settings
                        let schemes = [
                            "App-Prefs:root=WIFI",
                            "App-Prefs:WIFI",
                            "prefs:root=WIFI"
                        ]
                        
                        func openScheme(index: Int) {
                            guard index < schemes.count else { return }
                            if let url = URL(string: schemes[index]) {
                                UIApplication.shared.open(url, options: [:]) { success in
                                    if !success {
                                        openScheme(index: index + 1)
                                    }
                                }
                            } else {
                                openScheme(index: index + 1)
                            }
                        }
                        
                        openScheme(index: 0)
                    }) {
                        Text("Open Wi-Fi Settings")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding()
                            .background(Color.blue)
                            .cornerRadius(10)
                    }
                    
                    Button(action: {
                        stateMachine.forceConnection()
                    }) {
                        Text("I'm connected, try anyway")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.top, 10)
                    }
                }
                .padding()
                .background(Color.black.opacity(0.8))
                .cornerRadius(20)
                
            case .sharingPrompt:
                SharingOverlayView()
                
            case .airDrop(let images):
                AirDropInstructionsView(images: images)
            }
            
            // Global Settings Button Overlay
            VStack {
                HStack {
                    Spacer()
                    Button(action: {
                        showSettings = true
                    }) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 24, weight: .light))
                            .foregroundColor(.white.opacity(0.6))
                            .padding()
                    }
                }
                Spacer()
            }
            
            // Flash Overlay
            if stateMachine.isFlashing {
                Color.white
                    .edgesIgnoringSafeArea(.all)
                    .transition(.opacity)
                    .zIndex(2) // Ensure it's on top
            }
        }
        .statusBar(hidden: true)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(stateMachine)
        }
    }
}
