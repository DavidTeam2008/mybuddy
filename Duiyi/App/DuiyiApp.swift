import SwiftUI

@main
struct DuiyiApp: App {
    @State private var environment: AppEnvironment
    @State private var coordinator = AppCoordinator()

    init() {
        AppLaunchTracker.shared.begin(.appInit)
        // Environment init stays on main but is now cheap: DeferredTaskStore does
        // zero I/O, audio/synthesizer are lazy (see their files).
        let env = AppEnvironment()
        _environment = State(initialValue: env)
        AppLaunchTracker.shared.begin(.environmentReady)
    }

    var body: some Scene {
        let _ = AppLaunchTracker.shared.beginOnce(.appBody)
        WindowGroup {
            rootContent
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-liquidGlassPrototype") {
            LiquidGlassPrototypeView()
        } else {
            mainRoot
        }
        #else
        mainRoot
        #endif
    }

    private var mainRoot: some View {
        RootView()
            .environment(environment)
            .environment(coordinator)
            .preferredColorScheme(.dark)
    }
}
