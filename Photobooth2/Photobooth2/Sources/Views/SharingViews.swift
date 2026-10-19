import SwiftUI

struct SharingOverlayView: View {
    @EnvironmentObject var stateMachine: StateMachine
    @ObservedObject private var config = ConfigManager.shared
    
    private var isGIFSession: Bool {
        if case .sharingPrompt(let images) = stateMachine.state {
            let lower = images.map { $0.lowercased() }
            return lower.contains { $0.hasSuffix(".gif") } && !lower.contains { $0.hasSuffix(".jpg") || $0.hasSuffix(".jpeg") || $0.hasSuffix(".png") }
        }
        return false
    }
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
                .edgesIgnoringSafeArea(.all)
            
            GeometryReader { geo in
                if config.isQRCodeEnabled {
                    // ── Split layout: prompt on top, QR code on bottom ──
                    VStack(spacing: 0) {
                        // Top half: existing prompt + buttons
                        VStack(spacing: 30) {
                            Spacer()
                            
                            Text(isGIFSession ? "Would you like your GIF?" : "Would you like your photos?")
                                .font(.system(size: 40, weight: .bold))
                                .foregroundColor(.white)
                            
                            sharingButtons
                            
                            Spacer()
                        }
                        .frame(height: geo.size.height * 0.5)
                        
                        // Divider
                        Rectangle()
                            .fill(Color.white.opacity(0.2))
                            .frame(height: 1)
                        
                        // Bottom half: QR code
                        VStack(spacing: 16) {
                            Spacer()
                            
                            let days = config.daysUntilPhotosAvailable
                            let mediaNoun = isGIFSession ? "animated GIFs" : "photos"
                            Text("Full resolution \(mediaNoun) available for download within \(days) day\(days == 1 ? "" : "s") here:")
                                .font(.title3)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                            
                            QRCodeGeneratorView(urlString: config.qrCodeURLString)
                                .frame(maxWidth: geo.size.height * 0.35, maxHeight: geo.size.height * 0.35)
                            
                            Spacer()
                        }
                        .frame(height: geo.size.height * 0.5 - 1) // account for divider
                    }
                } else {
                    // ── Original full-screen layout ──
                    VStack(spacing: 30) {
                        Spacer()
                        
                        Text(isGIFSession ? "Would you like your GIF?" : "Would you like your photos?")
                            .font(.system(size: 40, weight: .bold))
                            .foregroundColor(.white)
                        
                        sharingButtons
                        
                        Spacer()
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
    }
    
    /// Extracted so both branches share identical button markup.
    private var sharingButtons: some View {
        HStack(spacing: 40) {
            // 1. AirDrop Button
            Button(action: {
                stateMachine.selectAirDrop()
            }) {
                VStack(spacing: 6) {
                    Image(systemName: "airplayaudio") // Closest to AirDrop
                        .font(.system(size: 50))
                    Text("AirDrop")
                        .font(.headline)
                    Text("(iPhone Only)")
                        .font(.caption)
                }
                .frame(width: 200, height: 200)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(20)
            }
            
            // 2. Email Button (Right next to AirDrop)
            if config.isEmailSharingEnabled {
                Button(action: {
                    stateMachine.selectEmailSharing()
                }) {
                    VStack(spacing: 6) {
                        Image(systemName: "envelope.fill")
                            .font(.system(size: 50))
                        Text("Email")
                            .font(.headline)
                        Text("(Any Phone)")
                            .font(.caption)
                    }
                    .frame(width: 200, height: 200)
                    .background(Color.teal)
                    .foregroundColor(.white)
                    .cornerRadius(20)
                }
            }
            
            // 3. No Thanks Button
            Button(action: {
                stateMachine.skipSharing()
            }) {
                VStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 50))
                    Text("No Thanks")
                        .font(.headline)
                }
                .frame(width: 200, height: 200)
                .background(Color.gray)
                .foregroundColor(.white)
                .cornerRadius(20)
            }
        }
    }
}



struct AirDropInstructionsView: View {
    @EnvironmentObject var stateMachine: StateMachine
    let images: [String]
    
    @State private var isPreparing = false
    @State private var isSheetPresented = false
    
    @State private var resetWorkItem: DispatchWorkItem?
    @State private var pollTimer: Timer?
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            ZStack {
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("(1) Settings > General > Airdrop > Everyone for 10 minutes")
                            .font(.title2)
                            .bold()
                            .foregroundColor(.white)
                        
                        Text("(2) Click the Airdrop button below")
                            .font(.title2)
                            .bold()
                            .foregroundColor(.white)
                    }
                    .fixedSize()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
                    
                    Spacer()
                    
                    if isPreparing {
                        VStack(spacing: 20) {
                            ProgressView()
                                .scaleEffect(1.5)
                                .colorScheme(.dark)
                            Text("Preparing images...")
                                .font(.headline)
                                .foregroundColor(.white)
                        }
                    } else {
                        Text("Sharing...")
                            .font(.headline)
                            .foregroundColor(.white.opacity(0.7))
                    }
                    
                    Spacer()
                }
                
                // Overlay "Done" button
                VStack {
                    HStack {
                        Spacer()
                        Button(action: {
                            closeShareSheetAndFinish()
                        }) {
                            Text("Done")
                                .font(.headline)
                                .bold()
                                .foregroundColor(.white)
                                .padding(.horizontal, 30)
                                .padding(.vertical, 15)
                                .background(Color.blue)
                                .cornerRadius(30)
                        }
                        .padding(40)
                    }
                    Spacer()
                }
            }
        }
        .onAppear {
            if !isSheetPresented {
                startAirDropProcess()
            }
        }
        .onDisappear {
            cancelReset()
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }
    
    private func closeShareSheetAndFinish() {
        cancelReset()
        pollTimer?.invalidate()
        pollTimer = nil
        isSheetPresented = false
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController,
           rootVC.presentedViewController != nil {
            rootVC.dismiss(animated: true) {
                if case .airDrop = stateMachine.state {
                    stateMachine.skipSharing()
                }
            }
        } else if case .airDrop = stateMachine.state {
            stateMachine.skipSharing()
        }
    }
    
    private func startAirDropProcess() {
        isPreparing = true
        cancelReset()
        pollTimer?.invalidate()
        pollTimer = nil
        
        var items: [Any] = []
        for path in images {
            let fileURL: URL
            if path.hasPrefix("file://"), let url = URL(string: path) {
                fileURL = URL(fileURLWithPath: url.path)
            } else {
                fileURL = URL(fileURLWithPath: path)
            }
            if FileManager.default.fileExists(atPath: fileURL.path) {
                items.append(fileURL)
            }
        }
        
        isPreparing = false
        isSheetPresented = true
        presentShareSheet(items: items)
    }
    
    private func presentShareSheet(items: [Any]) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else {
            isSheetPresented = false
            return
        }
        
        let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
        
        // Exclude common non-AirDrop activities
        var excludedTypes: [UIActivity.ActivityType] = [
            .message,
            .mail,
            .print,
            .copyToPasteboard,
            .assignToContact,
            .saveToCameraRoll,
            .addToReadingList,
            .postToFlickr,
            .postToVimeo,
            .postToTencentWeibo,
            .postToTwitter,
            .postToFacebook,
            .openInIBooks,
            .markupAsPDF
        ]
        
        // Try to exclude "Save to Files" and others using raw strings
        excludedTypes.append(UIActivity.ActivityType(rawValue: "com.apple.CloudDocsUI.AddToiCloudDrive"))
        excludedTypes.append(UIActivity.ActivityType(rawValue: "com.apple.reminders.RemindersEditorExtension"))
        excludedTypes.append(UIActivity.ActivityType(rawValue: "com.apple.mobilenotes.SharingExtension"))
        
        activityVC.excludedActivityTypes = excludedTypes
        
        // iPad requires source view/rect for popover
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = rootVC.view
            popover.sourceRect = CGRect(x: rootVC.view.bounds.midX, y: rootVC.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        
        activityVC.completionWithItemsHandler = { _, completed, _, _ in
            print("ActivityVC Completion Handler Called. Completed: \(completed)")
            
            isSheetPresented = false
            self.pollTimer?.invalidate()
            self.pollTimer = nil
            self.cancelReset()
            
            // Wait a brief moment to ensure the sheet is fully dismissed before changing state.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if case .airDrop = stateMachine.state {
                    print("Executing skipSharing() from handler")
                    stateMachine.skipSharing()
                }
            }
        }
        
        rootVC.present(activityVC, animated: true)
        
        // Start 120s timer for the Share Sheet interaction (allows time to enable AirDrop on iPhone + transfer)
        scheduleReset(delay: 120.0)
        
        // SAFETY POLL: Check every 1s if the VC is still presented.
        // If the system dismisses it (e.g. after AirDrop) but fails to call the handler,
        // this will catch it and reset the app.
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak rootVC] _ in
            Task { @MainActor [weak rootVC] in
                guard let rootVC = rootVC else {
                    pollTimer?.invalidate()
                    pollTimer = nil
                    return
                }
                
                // Stop polling if we are no longer in the sharing state
                if !isSheetPresented {
                    pollTimer?.invalidate()
                    pollTimer = nil
                    return
                }
                
                if rootVC.presentedViewController == nil {
                    print("Safety Poll: Share Sheet is gone but handler didn't fire. Forcing reset.")
                    pollTimer?.invalidate()
                    pollTimer = nil
                    isSheetPresented = false
                    cancelReset()
                    if case .airDrop = stateMachine.state {
                        stateMachine.skipSharing()
                    }
                }
            }
        }
    }
    
    private func scheduleReset(delay: TimeInterval) {
        cancelReset()
        let item = DispatchWorkItem {
            print("Inactivity timeout. Resetting.")
            closeShareSheetAndFinish()
        }
        resetWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelReset() {
        resetWorkItem?.cancel()
        resetWorkItem = nil
    }
}

struct EmailSharingView: View {
    @EnvironmentObject var stateMachine: StateMachine
    @ObservedObject private var config = ConfigManager.shared
    @ObservedObject private var emailQueue = EmailQueueService.shared
    
    let images: [String]
    
    private var isGIFSession: Bool {
        let lower = images.map { $0.lowercased() }
        return lower.contains { $0.hasSuffix(".gif") } && !lower.contains { $0.hasSuffix(".jpg") || $0.hasSuffix(".jpeg") || $0.hasSuffix(".png") }
    }
    
    @State private var emailInput: String = ""
    @State private var confirmationCopy: EmailConfirmationCopy? = nil
    @State private var inactivityTask: Task<Void, Never>? = nil
    @State private var autoReturnTask: Task<Void, Never>? = nil
    @FocusState private var isEmailFocused: Bool
    
    private let quickDomains = ["@gmail.com", "@icloud.com", "@yahoo.com", "@outlook.com", "@hotmail.com"]
    
    nonisolated static func applyDomainShortcut(_ domain: String, to currentInput: String) -> String {
        let trimmed = currentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDomain = domain.hasPrefix("@") ? domain : "@\(domain)"
        if let atIndex = trimmed.firstIndex(of: "@") {
            let localPart = String(trimmed[..<atIndex])
            return localPart + normalizedDomain
        } else {
            return trimmed + normalizedDomain
        }
    }
    
    private var isEmailValid: Bool {
        EmailQueueService.isValidEmail(emailInput)
    }
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.92)
                .edgesIgnoringSafeArea(.all)
            
            if let confirmation = confirmationCopy {
                // Confirmation card shown briefly while background worker sends or queues the email
                VStack(spacing: 24) {
                    Image(
                        systemName: !confirmation.isConfigured
                            ? "exclamationmark.triangle.fill"
                            : (confirmation.isOnline ? "paperplane.circle.fill" : "wifi.circle.fill")
                    )
                    .font(.system(size: 84))
                    .foregroundColor(!confirmation.isConfigured ? .orange : (confirmation.isOnline ? .green : .teal))
                    
                    Text(confirmation.title)
                        .font(.system(size: 40, weight: .bold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                    
                    Text(confirmation.subtitle)
                        .font(.title2)
                        .foregroundColor(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 720)
                        .padding(.horizontal, 32)
                    
                    Button(action: {
                        finishAndReturnToIdle()
                    }) {
                        Text("Done")
                            .font(.title3.weight(.bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 48)
                            .padding(.vertical, 16)
                            .background(Color.teal)
                            .cornerRadius(14)
                    }
                    .padding(.top, 8)
                }
                .padding(40)
                .transition(.scale.combined(with: .opacity))
            } else {
                // Email Entry UI positioned cleanly in top portion of screen above the iPad landscape keyboard
                VStack(spacing: 18) {
                    HStack {
                        if !emailQueue.isConfigured {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("Setup Needed in Settings (⚙️): Enter Gmail App Password or Resend Key to send queued emails")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.orange)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.orange.opacity(0.16))
                            .cornerRadius(12)
                        }
                        Spacer()
                        Button(action: {
                            cancelAndReturnToSharingPrompt()
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.uturn.backward.circle.fill")
                                Text("Back")
                            }
                            .font(.headline)
                            .foregroundColor(.white.opacity(0.85))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.15))
                            .cornerRadius(20)
                        }
                    }
                    .padding(.horizontal, 36)
                    .padding(.top, 20)
                    
                    VStack(spacing: 8) {
                        Text(isGIFSession ? "Email Your GIF" : "Email Your Photos")
                            .font(.system(size: 38, weight: .bold))
                            .foregroundColor(.white)
                        
                        Text(emailQueue.isNetworkConnected
                             ? "Enter your email for instant background delivery."
                             : (isGIFSession
                                ? "iPad is currently offline — enter your email and your GIF will be sent automatically when the iPad connects to Wi-Fi."
                                : "iPad is currently offline — enter your email and your photos will be sent automatically when the iPad connects to Wi-Fi."))
                            .font(.title3)
                            .foregroundColor(.white.opacity(0.75))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    
                    // Email Input Field + Send Button Row
                    HStack(spacing: 16) {
                        HStack {
                            Image(systemName: "envelope.fill")
                                .font(.title2)
                                .foregroundColor(.teal)
                                .padding(.leading, 8)
                            
                            TextField("name@example.com", text: $emailInput)
                                .font(.system(size: 28, weight: .medium))
                                .foregroundColor(.white)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .submitLabel(.send)
                                .focused($isEmailFocused)
                                .onSubmit {
                                    if isEmailValid {
                                        submitEmail()
                                    }
                                }
                            
                            if !emailInput.isEmpty {
                                Button(action: {
                                    emailInput = ""
                                    resetInactivityTimer()
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.title2)
                                        .foregroundColor(.gray)
                                }
                                .padding(.trailing, 8)
                            }
                        }
                        .padding(.vertical, 16)
                        .padding(.horizontal, 14)
                        .background(Color.white.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(isEmailValid ? Color.teal : Color.white.opacity(0.35), lineWidth: 2)
                        )
                        .cornerRadius(14)
                        
                        Button(action: {
                            submitEmail()
                        }) {
                            HStack(spacing: 10) {
                                Image(systemName: "paperplane.fill")
                                Text("Send")
                            }
                            .font(.system(size: 26, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 34)
                            .padding(.vertical, 18)
                            .background(isEmailValid ? Color.teal : Color.gray.opacity(0.45))
                            .cornerRadius(14)
                        }
                        .disabled(!isEmailValid)
                    }
                    .frame(maxWidth: 780)
                    .padding(.horizontal, 32)
                    
                    // Quick-Tap Domain Completion Chips
                    HStack(spacing: 12) {
                        ForEach(quickDomains, id: \.self) { domain in
                            Button(action: {
                                emailInput = Self.applyDomainShortcut(domain, to: emailInput)
                                resetInactivityTimer()
                            }) {
                                Text(domain)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(Color.white.opacity(0.16))
                                    .cornerRadius(20)
                            }
                        }
                    }
                    
                    Spacer()
                }
            }
        }
        .onAppear {
            resetInactivityTimer()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                isEmailFocused = true
            }
        }
        .onChange(of: emailInput) { _, _ in
            resetInactivityTimer()
        }
        .onDisappear {
            inactivityTask?.cancel()
            inactivityTask = nil
            autoReturnTask?.cancel()
            autoReturnTask = nil
        }
    }
    
    private func submitEmail() {
        let trimmed = emailInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard EmailQueueService.isValidEmail(trimmed), confirmationCopy == nil else { return }
        
        isEmailFocused = false
        inactivityTask?.cancel()
        inactivityTask = nil
        
        let onlineNow = emailQueue.isNetworkConnected
        let configuredNow = emailQueue.checkHasConfiguredCredentials()
        
        // Synchronously hard-link / copy session media (< 2ms) before transitioning back to .idle
        _ = EmailQueueService.shared.enqueue(
            recipientEmail: trimmed,
            mediaPaths: images,
            galleryURLString: config.qrCodeURLString
        )
        
        withAnimation(.easeInOut(duration: 0.2)) {
            confirmationCopy = EmailQueueService.confirmationMessage(
                forEmail: trimmed,
                isOnline: onlineNow,
                isConfigured: configuredNow,
                mediaOrFilenames: images
            )
        }
        
        let autoDismissNs = EmailQueueService.postSubmitDismissDurationNanoseconds(
            isOnline: onlineNow,
            isConfigured: configuredNow
        )
        autoReturnTask?.cancel()
        autoReturnTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: autoDismissNs)
            guard !Task.isCancelled else { return }
            finishAndReturnToIdle()
        }
    }
    
    private func cancelAndReturnToSharingPrompt() {
        inactivityTask?.cancel()
        inactivityTask = nil
        autoReturnTask?.cancel()
        autoReturnTask = nil
        isEmailFocused = false
        stateMachine.returnToSharingPrompt()
    }
    
    private func finishAndReturnToIdle() {
        inactivityTask?.cancel()
        inactivityTask = nil
        autoReturnTask?.cancel()
        autoReturnTask = nil
        isEmailFocused = false
        stateMachine.skipSharing()
    }
    
    private func resetInactivityTimer() {
        inactivityTask?.cancel()
        guard confirmationCopy == nil else { return }
        inactivityTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000_000) // 60s inactivity timeout
            guard !Task.isCancelled else { return }
            finishAndReturnToIdle()
        }
    }
}

struct ActionButtonStyle: ButtonStyle {
    let color: Color
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding()
            .frame(minWidth: 120)
            .background(color)
            .foregroundColor(.white)
            .cornerRadius(10)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
    }
}
