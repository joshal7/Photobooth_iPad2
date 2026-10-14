import SwiftUI

struct SettingsView: View {
    @ObservedObject var config = ConfigManager.shared
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var stateMachine: StateMachine
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Camera Configuration")) {
                    Picker("Camera Source", selection: $config.useLocalCamera) {
                        Text("iPad Camera").tag(true)
                        Text("External Camera").tag(false)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    
                    if !config.useLocalCamera {
                        HStack {
                            Text("USB Connection Status")
                            Spacer()
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(stateMachine.isCameraConnected ? Color.green : Color.red)
                                    .frame(width: 10, height: 10)
                                Text(stateMachine.isCameraConnected ? "Connected (Sony USB PTP)" : "Disconnected")
                                    .foregroundColor(stateMachine.isCameraConnected ? .primary : .secondary)
                            }
                        }
                        
                        if let statusMsg = stateMachine.cameraStatusMessage, !statusMsg.isEmpty {
                            Text(statusMsg)
                                .font(.caption)
                                .foregroundColor(stateMachine.isCameraConnected ? .green : .orange)
                        }
                        
                        if !stateMachine.isCameraConnected {
                            Button(action: {
                                stateMachine.retryConnection()
                            }) {
                                HStack {
                                    Image(systemName: "arrow.clockwise")
                                    Text("Retry USB Connection")
                                }
                            }
                        }
                    }
                }
                
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
                        
                        // Min Time Between GIFs (0.5s minimum for strobe recycling, 3.0s default for guest repositioning)
                        Stepper(
                            "Min Time Between GIFs: \(String(format: "%.1f", config.gifCaptureInterval))s",
                            value: $config.gifCaptureInterval,
                            in: 0.5...5.0,
                            step: 0.5
                        )
                        
                        // Frame Duration
                        Stepper("Frame Duration: \(String(format: "%.2f", config.gifFrameDuration))s", value: $config.gifFrameDuration, in: 0.05...1.0, step: 0.05)
                        
                        // GIF Preview Duration
                        Stepper("Photo Preview: \(String(format: "%.1f", config.gifPreviewDuration))s", value: $config.gifPreviewDuration, in: 1...30, step: 1.0)
                        
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
                
                if !config.useLocalCamera {
                    Section(header: Text("Sony A7V + USB-C Hub Setup")) {
                        VStack(alignment: .leading, spacing: 10) {
                            Group {
                                Text("Camera Dial & Menu (Save to Mode Dial '1'):")
                                    .font(.subheadline)
                                    .bold()
                                Text("• Exposure: Manual (f/10, ISO 200, 1/125s) & Manual Focus (~1.75m)")
                                Text("• Setup > USB > USB Connection Mode: PC Remote")
                                Text("• Setup > Power Setting Option > Auto Power OFF Temp.: High")
                            }
                            
                            Group {
                                Text("Hardware Connections:")
                                    .font(.subheadline)
                                    .bold()
                                    .padding(.top, 5)
                                Text("• Connect Sony A7V USB-C Data Port (trident icon) to UGREEN Hub 10Gbps data port.")
                                Text("• Connect Wall Charger to UGREEN Hub 100W PD port, and Hub host cable to iPad.")
                                Text("• Attach Godox X2T-S trigger to hot shoe and set strobe to 1/4 + 0.9.")
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
}
