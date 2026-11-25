import SwiftUI

struct HomeView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppCoordinator.self) private var coordinator

    @State private var viewModel: HomeViewModel?
    @State private var isSettingsPresented = false

    private var language: AppLanguage { environment.preferences.userLanguage }

    var body: some View {
        let _ = AppLaunchTracker.shared.beginOnce(.homeBody)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if viewModel?.showsStorageBanner == true {
                    StorageUnavailableBanner(language: language) {
                        Task { await viewModel?.retry() }
                    }
                }

                if let viewModel, !viewModel.unfinished.isEmpty {
                    Text(Copy.unfinishedTasks(for: language))
                        .font(.footnote)
                        .foregroundStyle(Tokens.accentText)
                    ForEach(viewModel.unfinished) { task in
                        Button {
                            environment.preferences.appMode = task.feature.appMode
                            coordinator.open(task.feature.route)
                        } label: {
                            HistoryRow(task: task, language: language)
                        }
                        .buttonStyle(.plain)
                    }
                }

                ForEach(FeatureRegistry.visible) { feature in
                    HomeModuleCard(
                        title: feature.title(language),
                        subtitle: feature.subtitle(language),
                        symbolName: feature.symbolName,
                        background: Tokens.featureCard(feature.id),
                        accent: Tokens.featureAccent(feature.id)
                    ) {
                        environment.preferences.appMode = feature.id.appMode
                        coordinator.open(feature.id.route)
                    }
                    .accessibilityIdentifier("home-module-\(feature.id.rawValue)")
                    .accessibilityLabel(feature.title(language))
                    .accessibilityHint(feature.subtitle(language))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(Tokens.canvas.ignoresSafeArea())
        .navigationTitle(Copy.homeTitle(for: language))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    coordinator.open(.history)
                } label: {
                    ToolbarGlyph(systemName: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("home-history")
                .accessibilityLabel(Copy.historyTitle(for: language))
                Button {
                    isSettingsPresented = true
                } label: {
                    ToolbarGlyph(systemName: "gearshape")
                }
                .accessibilityIdentifier("settings-open")
                .accessibilityLabel(Copy.settingsTitle(for: language))
            }
        }
        .onAppear { AppLaunchTracker.shared.begin(.homeAppear) }
        .task(priority: .utility) {
            // Deferred: let Home paint empty first, then fill unfinished tasks.
            // Triggers DeferredTaskStore resolve off the first-frame transaction.
            AppLaunchTracker.shared.begin(.homeTaskStart)
            let viewModel = self.viewModel ?? HomeViewModel(store: environment.taskStore)
            self.viewModel = viewModel
            await viewModel.load()
            AppLaunchTracker.shared.begin(.homeTaskEnd)
        }
        .sheet(isPresented: $isSettingsPresented) {
            HomeSettingsSheet()
        }
    }
}

#Preview("Home") {
    HomePreview.root
}

@MainActor
enum HomePreview {
    static var root: some View {
        let preferences = PreferencesStore(defaults: UserDefaults(suiteName: "duiyi.home.preview") ?? .standard)
        preferences.userLanguage = .zhHans
        let environment = AppEnvironment(
            preferences: preferences,
            taskStore: InMemoryTaskStore()
        )
        return NavigationStack {
            HomeView()
        }
        .environment(environment)
        .environment(AppCoordinator())
    }
}
