import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var config = ConfigManager.shared
    @ObservedObject var backdropManager = BackdropManager.shared
    @ObservedObject var manifestStore = BackdropManifestStore.shared
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var stateMachine: StateMachine
    
    @State private var showAddCustomBackdropSheet = false
    @State private var showEventFolderImporter = false
    @State private var isBatchApplying = false
    @State private var batchProgressText: String = ""
    @State private var batchProgressFraction: Double = 0.0
    @State private var batchTask: Task<Void, Never>? = nil
    @State private var batchReportAlert: BatchApplyReport? = nil
    @State private var statusAlertMessage: String? = nil
    
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
                
                Section(
                    header: Text("Backdrops & Frames"),
                    footer: Text("Drop *_bg.jpg and/or *_fg.png files into Photobooth2/Backdrops/ in Finder and build in Xcode, or add custom backdrops directly below. During AirDrop, only .gif files and photobooth_backdrop_manifest.json are sent so SmugMug never uploads extra asset images.")
                ) {
                    Picker("Default at Session Start", selection: $config.defaultBackdropID) {
                        ForEach(backdropManager.enabledBackdrops) { item in
                            Text(item.isNone ? "Original (Real Room)" : item.displayName)
                                .tag(item.id)
                        }
                    }
                    .pickerStyle(.menu)
                    
                    let configurableItems = backdropManager.availableBackdrops.filter { !$0.isNone }
                    if configurableItems.isEmpty {
                        Text("No backdrops found. Add *_bg.jpg or *_fg.png files to Backdrops/ or tap '+ Add Custom Backdrop / Frame' below.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(configurableItems) { item in
                            HStack(spacing: 12) {
                                if let thumb = backdropManager.thumbnail(for: item) {
                                    Image(uiImage: thumb)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 54, height: 36)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                        )
                                }
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(item.displayName)
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                        if item.isCustom {
                                            Text("CUSTOM")
                                                .font(.system(size: 9, weight: .bold))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Capsule().fill(Color.blue.opacity(0.2)))
                                                .foregroundColor(.blue)
                                        }
                                    }
                                    Text(layerDescription(for: item))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                if item.hasForeground {
                                    Menu {
                                        ForEach(ForegroundFitMode.allCases, id: \.self) { fitMode in
                                            Button(action: {
                                                backdropManager.setForegroundFitMode(id: item.id, mode: fitMode)
                                            }) {
                                                HStack {
                                                    Text(fitMode.displayName)
                                                    if item.foregroundFitMode == fitMode {
                                                        Image(systemName: "checkmark")
                                                    }
                                                }
                                            }
                                        }
                                    } label: {
                                        Image(systemName: "aspectratio")
                                            .font(.system(size: 15))
                                            .foregroundColor(.secondary)
                                            .padding(.horizontal, 4)
                                    }
                                }
                                
                                if item.isCustom {
                                    Button(role: .destructive, action: {
                                        backdropManager.deleteCustomBackdrop(id: item.id)
                                    }) {
                                        Image(systemName: "trash")
                                            .font(.system(size: 14))
                                            .foregroundColor(.red)
                                    }
                                    .buttonStyle(.borderless)
                                    .padding(.trailing, 4)
                                }
                                
                                Toggle("", isOn: Binding(
                                    get: { item.isEnabled },
                                    set: { newVal in
                                        backdropManager.setBackdropEnabled(id: item.id, isEnabled: newVal)
                                    }
                                ))
                                .labelsHidden()
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    
                    Button(action: {
                        showAddCustomBackdropSheet = true
                    }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Add Custom Backdrop / Frame...")
                        }
                    }
                    
                    Button(action: {
                        backdropManager.reloadBackdrops()
                    }) {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Rescan Backdrops Folder")
                        }
                    }
                }
                
                Section(
                    header: Text("Post-Event Mac Backdrop Workflow"),
                    footer: Text("1. Tap 'AirDrop GIFs + Backdrop Manifest' on iPad to send GIFs and photobooth_backdrop_manifest.json to your Mac.\n2. Drag them into your event photo folder (with your SD card DSC0xxxx.JPG files).\n3. Open Photobooth2 on your Mac and tap 'Apply Backdrops to Event Folder...' to update matching full-res photos in-place.")
                ) {
                    Button(action: {
                        bulkAirDropGIFs()
                    }) {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("AirDrop GIFs + Backdrop Manifest (\(manifestStore.entries.count) photo records)")
                        }
                    }
                    
                    if isBatchApplying {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                ProgressView()
                                    .padding(.trailing, 6)
                                Text(batchProgressText)
                                    .font(.subheadline)
                                Spacer()
                                Button("Cancel", role: .destructive) {
                                    batchTask?.cancel()
                                }
                            }
                            ProgressView(value: batchProgressFraction)
                        }
                        .padding(.vertical, 4)
                    } else {
                        Button(action: {
                            showEventFolderImporter = true
                        }) {
                            HStack {
                                Image(systemName: "wand.and.stars")
                                Text("Apply Backdrops to Event Folder...")
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                    
                    if !manifestStore.entries.isEmpty {
                        Button(role: .destructive, action: {
                            manifestStore.clearManifest()
                        }) {
                            HStack {
                                Image(systemName: "trash")
                                Text("Clear Saved Backdrop Manifest (\(manifestStore.entries.count) entries)")
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
                        
                        // Bulk AirDrop Button (GIFs + Manifest JSON)
                        Button(action: {
                            bulkAirDropGIFs()
                        }) {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("AirDrop GIFs + Backdrop Manifest")
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
            .sheet(isPresented: $showAddCustomBackdropSheet) {
                AddCustomBackdropSheet()
            }
            .fileImporter(
                isPresented: $showEventFolderImporter,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let folderURL = urls.first {
                        runBatchApply(on: folderURL)
                    }
                case .failure(let error):
                    statusAlertMessage = "Folder selection failed: \(error.localizedDescription)"
                }
            }
            .alert(
                "Batch Backdrop Processing Complete",
                isPresented: Binding(
                    get: { batchReportAlert != nil },
                    set: { if !$0 { batchReportAlert = nil } }
                ),
                presenting: batchReportAlert
            ) { _ in
                Button("OK", role: .cancel) { batchReportAlert = nil }
            } message: { report in
                Text(report.summaryMessage)
            }
            .alert(
                "Notice",
                isPresented: Binding(
                    get: { statusAlertMessage != nil },
                    set: { if !$0 { statusAlertMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { statusAlertMessage = nil }
            } message: {
                Text(statusAlertMessage ?? "")
            }
        }
    }
    
    private func layerDescription(for item: BackdropItem) -> String {
        if item.isCombo {
            return "Background + Foreground Combo (\(item.foregroundFitMode.displayName))"
        } else if item.hasForeground {
            return "Foreground Frame (\(item.foregroundFitMode.displayName))"
        } else {
            return "Background Image (Aspect Fill)"
        }
    }
    
    private func runBatchApply(on folderURL: URL) {
        isBatchApplying = true
        batchProgressFraction = 0.0
        batchProgressText = "Scanning folder..."
        
        batchTask = Task {
            let report = await BackdropManifestStore.shared.applyBackdropsToFolder(
                folderURL: folderURL
            ) { completed, total, filename in
                Task { @MainActor in
                    self.batchProgressFraction = total > 0 ? Double(completed) / Double(total) : 0.0
                    self.batchProgressText = "Applying \(completed)/\(total): \(filename)"
                }
            }
            await MainActor.run {
                self.isBatchApplying = false
                self.batchTask = nil
                self.batchReportAlert = report
            }
        }
    }
    
    private func bulkAirDropGIFs() {
        let hours = config.gifRetrievalWindowHours
        
        Task {
            let manifestURL = BackdropManifestStore.shared.exportAirDropManifestFile()
            var shareItems: [Any] = []
            
            if let recentGIFs = try? await GIFRetrievalService.fetchRecentGIFs(hours: hours) {
                shareItems.append(contentsOf: recentGIFs)
            }
            if let manifestURL = manifestURL {
                shareItems.append(manifestURL)
            }
            
            await MainActor.run {
                if shareItems.isEmpty {
                    statusAlertMessage = "No GIFs or backdrop manifest records found in the last \(hours) hours."
                } else {
                    presentShareSheet(items: shareItems)
                }
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

// MARK: - Add Custom Backdrop / Frame Sheet

struct AddCustomBackdropSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String = ""
    @State private var backgroundData: Data? = nil
    @State private var backgroundPreview: UIImage? = nil
    @State private var foregroundData: Data? = nil
    @State private var foregroundPreview: UIImage? = nil
    @State private var showBackgroundFileImporter = false
    @State private var showForegroundFileImporter = false
    @State private var selectedBgPhotoItem: PhotosPickerItem? = nil
    @State private var selectedFgPhotoItem: PhotosPickerItem? = nil
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Backdrop Name")) {
                    TextField("e.g. Evan's Bar Mitzvah or Beach Sunset", text: $displayName)
                }
                
                Section(
                    header: Text("1. Background Image (Optional)"),
                    footer: Text("Replaces the physical background behind guests using AI person segmentation. Auto-scaled to fill.")
                ) {
                    if let preview = backgroundPreview {
                        HStack {
                            Image(uiImage: preview)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 90, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Text("Background Selected")
                                .font(.subheadline)
                            Spacer()
                            Button("Remove", role: .destructive) {
                                backgroundData = nil
                                backgroundPreview = nil
                                selectedBgPhotoItem = nil
                            }
                        }
                    }
                    
                    PhotosPicker(selection: $selectedBgPhotoItem, matching: .images) {
                        Label("Choose Background from Photos...", systemImage: "photo.on.rectangle")
                    }
                    .onChange(of: selectedBgPhotoItem) { _, newItem in
                        guard let newItem = newItem else { return }
                        Task {
                            if let data = try? await newItem.loadTransferable(type: Data.self),
                               let uiImg = UIImage(data: data) {
                                await MainActor.run {
                                    self.backgroundData = uiImg.jpegData(compressionQuality: 0.92) ?? data
                                    self.backgroundPreview = uiImg
                                }
                            }
                        }
                    }
                    
                    Button(action: {
                        showBackgroundFileImporter = true
                    }) {
                        Label("Choose Background from Files...", systemImage: "folder")
                    }
                }
                
                Section(
                    header: Text("2. Foreground Frame PNG (Optional)"),
                    footer: Text("Transparent PNG border/logo rendered in front of guests. Auto-stretched to all 4 edges.")
                ) {
                    if let preview = foregroundPreview {
                        HStack {
                            Image(uiImage: preview)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 90, height: 60)
                                .background(Color.gray.opacity(0.2))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Text("Foreground PNG Selected")
                                .font(.subheadline)
                            Spacer()
                            Button("Remove", role: .destructive) {
                                foregroundData = nil
                                foregroundPreview = nil
                                selectedFgPhotoItem = nil
                            }
                        }
                    }
                    
                    Button(action: {
                        showForegroundFileImporter = true
                    }) {
                        Label("Choose Transparent PNG from Files...", systemImage: "folder.badge.plus")
                    }
                    
                    PhotosPicker(selection: $selectedFgPhotoItem, matching: .images) {
                        Label("Choose Foreground from Photos...", systemImage: "photo")
                    }
                    .onChange(of: selectedFgPhotoItem) { _, newItem in
                        guard let newItem = newItem else { return }
                        Task {
                            if let data = try? await newItem.loadTransferable(type: Data.self),
                               let uiImg = UIImage(data: data) {
                                await MainActor.run {
                                    self.foregroundData = uiImg.pngData() ?? data
                                    self.foregroundPreview = uiImg
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Backdrop / Frame")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        _ = BackdropManager.shared.addCustomBackdrop(
                            displayName: displayName,
                            backgroundData: backgroundData,
                            foregroundPNGData: foregroundData
                        )
                        dismiss()
                    }
                    .disabled(backgroundData == nil && foregroundData == nil)
                }
            }
            .fileImporter(
                isPresented: $showBackgroundFileImporter,
                allowedContentTypes: [.image],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    let hasScope = url.startAccessingSecurityScopedResource()
                    defer { if hasScope { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
                        backgroundData = img.jpegData(compressionQuality: 0.92) ?? data
                        backgroundPreview = img
                        if displayName.isEmpty {
                            displayName = url.deletingPathExtension().lastPathComponent
                        }
                    }
                }
            }
            .fileImporter(
                isPresented: $showForegroundFileImporter,
                allowedContentTypes: [.png, .image],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    let hasScope = url.startAccessingSecurityScopedResource()
                    defer { if hasScope { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
                        foregroundData = img.pngData() ?? data
                        foregroundPreview = img
                        if displayName.isEmpty {
                            displayName = url.deletingPathExtension().lastPathComponent
                        }
                    }
                }
            }
        }
    }
}
