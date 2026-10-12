import SwiftUI

@main
struct Photobooth2App: App {
    @StateObject private var stateMachine = StateMachine()
    @Environment(\.scenePhase) var scenePhase
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(stateMachine)
                .onAppear {
                    stateMachine.start()
                    // Prevent auto-lock while app is running
                    UIApplication.shared.isIdleTimerDisabled = true
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        stateMachine.handleAppDidBecomeActive()
                    }
                }
        }
    }
}
