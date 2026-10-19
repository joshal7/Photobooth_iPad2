import SwiftUI

@main
struct Photobooth2App: App {
    @StateObject private var stateMachine = StateMachine()
    @Environment(\.scenePhase) var scenePhase
    @State private var hasStarted = false
    
    init() {
        #if DEBUG
        if CommandLine.arguments.contains("--verify") {
            Task { @MainActor in
                await AutomatedVerificationSuite.runAllAndExit()
            }
        }
        #endif
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(stateMachine)
                .onAppear {
                    #if DEBUG
                    if CommandLine.arguments.contains("--verify") {
                        return
                    }
                    #endif
                    if !hasStarted {
                        hasStarted = true
                        stateMachine.start()
                    }
                    // Prevent auto-lock while app is running
                    UIApplication.shared.isIdleTimerDisabled = true
                }
                .onChange(of: scenePhase) { _, newPhase in
                    #if DEBUG
                    if CommandLine.arguments.contains("--verify") {
                        return
                    }
                    #endif
                    switch newPhase {
                    case .active:
                        UIApplication.shared.isIdleTimerDisabled = true
                        stateMachine.handleAppDidBecomeActive()
                    case .background:
                        stateMachine.handleAppDidEnterBackground()
                    default:
                        break
                    }
                }
        }
    }
}
