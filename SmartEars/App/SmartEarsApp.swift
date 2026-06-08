import SwiftUI

// MARK: - SmartEars App Entry
//
// `@main` SwiftUI App. It constructs the `AppEnvironment` dependency container
// (which defaults to bundled stub/mock services so the app runs with NO secrets)
// and injects it into the environment for the root view. The full app would also
// register BGTaskScheduler tasks and activate the background AVAudioSession here
// (see AppDelegate in the App module); this entry point keeps that wiring minimal
// and compilable.
//
// `RootView` — the audio-first home screen — lives in
// `SmartEars/Features/RootView.swift`.

@main
struct SmartEarsApp: App {
    /// The single dependency container, owned for the app's lifetime.
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
        }
    }
}
