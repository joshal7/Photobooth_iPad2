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
                    
                    if stateMachine.captureMode == .gif {
                        // Clockwise 22pt perimeter bezel sweep between GIF frames
                        GIFPerimeterSweepOverlay(progress: stateMachine.gifPerimeterProgress)
                        
                        // Sleek Top-Center progress dots pill (1.5x pulsing active dot, solid completed, hollow future)
                        if stateMachine.currentGIFFrameIndex > 0 {
                            VStack {
                                GIFProgressDotsPillView(
                                    totalFrames: ConfigManager.shared.gifFrameCount,
                                    activeFrameIndex: stateMachine.currentGIFFrameIndex
                                )
                                .padding(.top, 26)
                                Spacer()
                            }
                            .transition(.opacity)
                            .zIndex(3)
                        }
                    } else {
                        // Standard Photo Mode counter in upper right
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
                }
                
            case .review(let images, let index):
                ReviewView(images: images, currentIndex: index)
                
            case .error(let message):
                ErrorView(message: message)
                
            case .sharingPrompt:
                SharingOverlayView()
                
            case .airDrop(let images):
                AirDropInstructionsView(images: images)
            }
            
            // Low Storage Warning Banner (< 2 GB free)
            if let storageWarning = stateMachine.lowStorageWarning {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                        Text(storageWarning)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.yellow.opacity(0.95))
                    .cornerRadius(20)
                    .padding(.top, 16)
                    Spacer()
                }
                .allowsHitTesting(false)
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
            
            // Standard Photo Full-Screen Flash Overlay
            if stateMachine.isFlashing {
                Color.white
                    .edgesIgnoringSafeArea(.all)
                    .transition(.opacity)
                    .zIndex(2) // Ensure it's on top
            }
            
            // GIF Mode 0.2s Crisp Perimeter Vignette Flash Overlay
            if stateMachine.isVignetteFlashing {
                GIFVignetteFlashOverlay()
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .statusBar(hidden: true)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(stateMachine)
        }
    }
}
