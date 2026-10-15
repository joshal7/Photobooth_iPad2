import SwiftUI
import UniformTypeIdentifiers

struct ErrorView: View {
    let message: String
    @EnvironmentObject var stateMachine: StateMachine
    
    @State private var showEventFolderImporter = false
    @State private var isBatchApplying = false
    @State private var batchProgressText: String = ""
    @State private var batchProgressFraction: Double = 0.0
    @State private var batchTask: Task<Void, Never>? = nil
    @State private var batchReportAlert: BatchApplyReport? = nil
    
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
                
                HStack(spacing: 16) {
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
                    
                    if isBatchApplying {
                        VStack(spacing: 6) {
                            ProgressView(value: batchProgressFraction)
                                .frame(width: 220)
                            Text(batchProgressText)
                                .font(.caption)
                                .foregroundColor(.cyan)
                            Button("Cancel", role: .destructive) {
                                batchTask?.cancel()
                            }
                            .font(.caption)
                        }
                        .padding(10)
                        .background(Color.white.opacity(0.12))
                        .cornerRadius(10)
                    } else {
                        Button(action: {
                            showEventFolderImporter = true
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "wand.and.stars")
                                Text("Apply Backdrops to Folder...")
                            }
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding()
                            .frame(minWidth: 240)
                            .background(Color.blue)
                            .cornerRadius(10)
                        }
                    }
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
                    Text("4. Tap 'Retry Connection' above (or tap 'Apply Backdrops to Folder...' on Mac for post-event batch processing)")
                }
                .font(.footnote)
                .foregroundColor(.gray)
                .padding(.top, 30)
                .padding(.horizontal)
            }
            .padding()
        }
        .fileImporter(
            isPresented: $showEventFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let folderURL = urls.first {
                runBatchApply(on: folderURL)
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
}
