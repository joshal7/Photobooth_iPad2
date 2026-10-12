import SwiftUI

struct SettingsView: View {
    @ObservedObject var config = ConfigManager.shared
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var stateMachine: StateMachine
    @State private var isCleaningFrames = false
    @State private var alertMessage: String?
    @State private var showAlert = false
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Timers & Counts")) {
                    Stepper("Initial Countdown: \(config.initialCountdownSec)s", value: $config.initialCountdownSec, in: 1...10)
                    Stepper("Between Shots: \(config.interShotCountdownSec)s", value: $config.interShotCountdownSec, in: 1...10)
                    Stepper("Photo Count: \(config.photoCount)", value: $config.photoCount, in: 1...10)
                    Stepper("Preview Duration: \(config.previewDurationSec)s", value: $config.previewDurationSec, in: 1...10)
                }
                
                Section(header: Text("Animated GIF")) {
                    Toggle("Enable Animated GIF Mode", isOn: $config.enableGIFMode)
                    
                    if config.enableGIFMode {
                        // Frame Count: Max 10 frames
                        Stepper("GIF Frame Count: \(config.gifFrameCount)", value: $config.gifFrameCount, in: 2...10)
                        
                        // Capture Interval: Min 0.1s
                        // Capture Interval: Min 0.1s
                        if !config.useLocalCamera {
                            HStack {
                                Text("Capture Interval")
                                Spacer()
                                Text("-")
                                    .foregroundColor(.gray)
                            }
                        } else {
                            Stepper("Capture Interval: \(String(format: "%.2f", config.gifCaptureInterval))s", value: $config.gifCaptureInterval, in: 0.1...2.0, step: 0.05)
                        }
                        
                        // Frame Duration
                        Stepper("Frame Duration: \(String(format: "%.2f", config.gifFrameDuration))s", value: $config.gifFrameDuration, in: 0.05...1.0, step: 0.05)
                        
                        // GIF Preview Duration
                        Stepper("Photo Preview: \(String(format: "%.1f", config.gifPreviewDuration))s", value: $config.gifPreviewDuration, in: 1...30, step: 1.0)
                        
                        // Resolution
                        Picker("GIF Resolution", selection: $config.gifResolution) {
                            Text("720p").tag(0)
                            Text("480p").tag(1)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        
                        if !config.useLocalCamera {
                            if config.pendingGIFFramesToDelete > 0 {
                                Button(action: {
                                    cleanUpGIFFrames()
                                }) {
                                    HStack {
                                        if isCleaningFrames {
                                            ProgressView()
                                                .progressViewStyle(CircularProgressViewStyle())
                                                .padding(.trailing, 5)
                                            Text("Cleaning...")
                                        } else {
                                            Image(systemName: "trash")
                                            Text("Clean Up Sony Camera GIF Frames (\(config.pendingGIFFramesToDelete))")
                                        }
                                    }
                                }
                                .disabled(isCleaningFrames)
                                .foregroundColor(isCleaningFrames ? .gray : .red)
                            } else {
                                Text("No pending GIF frames to clean.")
                                    .foregroundColor(.gray)
                            }
                        }
                        
                        // GIF Retrieval Window
                        Stepper("GIF Retrieval Window: \(config.gifRetrievalWindowHours) hrs", value: $config.gifRetrievalWindowHours, in: 1...72)
                        
                        // Bulk AirDrop Button
                        Button(action: {
                            bulkAirDropGIFs()
                        }) {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("Airdrop GIFs")
                            }
                        }
                    }
                }
                
                Section(header: Text("Sharing")) {
                    Toggle("Enable Image Sharing", isOn: Binding(
                        get: { config.enableImageSharing },
                        set: { newValue in
                            config.enableImageSharing = newValue
                            if newValue {
                                // If sharing is enabled, we MUST save to photos
                                config.saveToPhotos = true
                            }
                        }
                    ))
                    
                    if config.enableImageSharing {
                        Toggle("Show Guidance Text", isOn: $config.showGuidanceText)
                    }
                    
                    Toggle("Save to Photos", isOn: Binding(
                        get: { config.saveToPhotos },
                        set: { newValue in
                            config.saveToPhotos = newValue
                            if !newValue {
                                // If saving is disabled, we CANNOT share (need local file)
                                config.enableImageSharing = false
                            }
                        }
                    ))
                    
                    Toggle("Enable QR Code", isOn: $config.isQRCodeEnabled)
                    
                    if config.isQRCodeEnabled {
                        HStack {
                            Text("Website Link")
                            Spacer()
                            TextField("https://...", text: $config.qrCodeURLString)
                                .multilineTextAlignment(.trailing)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .keyboardType(.URL)
                                .foregroundColor(.gray)
                        }
                        
                        Picker("Days Until Available", selection: $config.daysUntilPhotosAvailable) {
                            Text("1 day").tag(1)
                            Text("2 days").tag(2)
                            Text("3 days").tag(3)
                            Text("5 days").tag(5)
                            Text("7 days").tag(7)
                        }
                        .pickerStyle(.menu)
                    }
                }
                
                Section(header: Text("Camera Configuration")) {
                    Picker("Camera Source", selection: Binding(
                        get: { config.useLocalCamera ? 0 : 1 },
                        set: { config.useLocalCamera = ($0 == 0) }
                    )) {
                        Text("iPad Camera").tag(0)
                        Text("External Camera").tag(1)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    
                    if !config.useLocalCamera {
                        HStack {
                            Text("Endpoint")
                            Spacer()
                            TextField("http://...", text: $config.cameraEndpoint)
                                .multilineTextAlignment(.trailing)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .foregroundColor(.gray)
                        }
                        
                        HStack {
                            Text("Camera SSID")
                            Spacer()
                            TextField("DIRECT-xxxx:Sony", text: $config.cameraSSID)
                                .multilineTextAlignment(.trailing)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .foregroundColor(.gray)
                        }
                        
                        HStack {
                            Text("Password")
                            Spacer()
                            TextField("Password", text: $config.cameraPassword)
                                .multilineTextAlignment(.trailing)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                            
                            Button(action: {
                                UIPasteboard.general.string = config.cameraPassword
                            }) {
                                Image(systemName: "doc.on.doc")
                                    .foregroundColor(.blue)
                            }
                        }
                        
 
                        
                    }

                    
                }
                
                if !config.useLocalCamera {
                    Section(header: Text("Connection Instructions")) {
                        VStack(alignment: .leading, spacing: 10) {
                            Group {
                                Text("Required:")
                                    .font(.subheadline)
                                    .bold()
                                Text("• Open 'Smart Remote Control' app on Camera.")
                                Text("• Keep Camera and iPad plugged into power.")
                            }
                            
                            Group {
                                Text("Recommended:")
                                    .font(.subheadline)
                                    .bold()
                                    .padding(.top, 5)
                                Text("• Disable 'Auto-Join' for other Wi-Fi networks in iPad Settings.")
                                Text("• This ensures the iPad automatically reconnects to the Camera if the connection drops.")
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 5)
                    }
                }
                
                Section(header: Text("Actions")) {
                    Button("Reset to Defaults") {
                        config.resetToDefaults()
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationTitle("Settings")
            .alert(isPresented: $showAlert) {
                Alert(
                    title: Text("Camera Maintenance"),
                    message: Text(alertMessage ?? ""),
                    dismissButton: .default(Text("OK"))
                )
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        config.save()
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
    
    private func bulkAirDropGIFs() {
        let hours = config.gifRetrievalWindowHours
        
        Task {
            do {
                let urls = try await GIFRetrievalService.fetchRecentGIFs(hours: hours)
                
                await MainActor.run {
                    if urls.isEmpty {
                        // Optional: Show alert if no GIFs found (omitted for simplicity as per request "no impact to runtime logic")
                        print("No GIFs found in the last \(hours) hours.")
                    } else {
                        presentShareSheet(items: urls)
                    }
                }
            } catch {
                print("Failed to retrieve GIFs: \(error)")
            }
        }
    }
    
    private func presentShareSheet(items: [Any]) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else { return }
        
        // If a presentation is already active (e.g. Settings sheet itself), we should present from there?
        // SettingsView is likely presented as a sheet or in a nav view. 
        // We generally want to present 'on top' of the top-most controller.
        
        let topController: UIViewController = rootVC.presentedViewController ?? rootVC
        
        let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
        
        // Exclude irrelevant activities to focus on AirDrop/Save
        activityVC.excludedActivityTypes = [
            .addToReadingList,
            .assignToContact,
            .markupAsPDF
        ]
        
        // iPad Popover configuration
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = topController.view
            popover.sourceRect = CGRect(x: topController.view.bounds.midX, y: topController.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        
        topController.present(activityVC, animated: true)
    }
    
    private func cleanUpGIFFrames() {
        isCleaningFrames = true
        let count = config.pendingGIFFramesToDelete
        
        Task {
            let cameraService = SonyCameraClient(config: config)
            do {
                try await cameraService.deleteLastCapturedImages(count: count)
                
                // Wait 2.0 seconds for the camera to fully transition back to Remote Shooting mode
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                
                await MainActor.run {
                    config.pendingGIFFramesToDelete = 0
                    isCleaningFrames = false
                    alertMessage = "Successfully deleted \(count) source frames from the Sony SD card."
                    showAlert = true
                    
                    // Force the state machine to re-initialize and reconnect the camera
                    stateMachine.forceConnection()
                }
            } catch {
                print("Failed to clean up GIF frames: \(error)")
                
                // Even on failure, wait and attempt reconnect to restore state
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run {
                    isCleaningFrames = false
                    alertMessage = "Failed to clean up GIF frames. Please check your camera Wi-Fi connection and try again.\n\nError: \(error.localizedDescription)"
                    showAlert = true
                    
                    stateMachine.forceConnection()
                }
            }
        }
    }
}
