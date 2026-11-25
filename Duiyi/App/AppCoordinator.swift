import SwiftUI

@MainActor
@Observable
final class AppCoordinator {
    /// Typed path so navigation policy can inspect the top route.
    var path: [AppRoute] = []

    func open(_ route: AppRoute) {
        path.append(route)
    }

    func popToHome() {
        path = []
    }

    /// Collapses the stack to history in one write, so a detail-side delete
    /// cannot straddle a pop and a push.
    func returnToHistory() {
        path = [.history]
    }

    func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    func replaceModule(_ feature: FeatureID) {
        path = [feature.route]
    }

    func showEndedTask(_ id: UUID) {
        path = [.history, .taskDetail(id)]
    }
}

extension FeatureID {
    var route: AppRoute {
        switch self {
        case .faceToFace: return .conversation
        case .simultaneous: return .interpretation
        case .meeting: return .meeting
        }
    }
}
