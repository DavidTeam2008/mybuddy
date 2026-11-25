import CoreGraphics
import Foundation
import Testing
@testable import Duiyi

@MainActor
struct EdgeSwipeBackPolicyTests {
    private let startY: CGFloat = 400

    @Test("Accepts a leading-edge right swipe")
    func acceptsLeadingEdgeRightSwipe() {
        #expect(
            EdgeSwipeBackPolicy.shouldPop(
                hasPreviousPage: true,
                startLocation: CGPoint(x: 12, y: startY),
                translation: CGSize(width: 120, height: 20)
            )
        )
    }

    @Test("Rejects a swipe when there is no previous page")
    func rejectsAtRoot() {
        #expect(
            !EdgeSwipeBackPolicy.shouldPop(
                hasPreviousPage: false,
                startLocation: CGPoint(x: 12, y: startY),
                translation: CGSize(width: 120, height: 20)
            )
        )
    }

    @Test("Rejects a swipe that starts away from the leading edge")
    func rejectsNonEdgeStart() {
        #expect(
            !EdgeSwipeBackPolicy.shouldPop(
                hasPreviousPage: true,
                startLocation: CGPoint(x: 80, y: startY),
                translation: CGSize(width: 120, height: 20)
            )
        )
    }

    @Test("Rejects a short horizontal swipe")
    func rejectsShortSwipe() {
        #expect(
            !EdgeSwipeBackPolicy.shouldPop(
                hasPreviousPage: true,
                startLocation: CGPoint(x: 12, y: startY),
                translation: CGSize(width: 30, height: 10)
            )
        )
    }

    @Test("Defers to the system pop gesture on task detail")
    func defersToSystemPopOnTaskDetail() {
        #expect(
            EdgeSwipeBackPolicy.defersToSystemPop(topRoute: .taskDetail(UUID()))
        )
        #expect(!EdgeSwipeBackPolicy.defersToSystemPop(topRoute: .history))
        #expect(!EdgeSwipeBackPolicy.defersToSystemPop(topRoute: .conversation))
        #expect(!EdgeSwipeBackPolicy.defersToSystemPop(topRoute: nil))
    }

    @Test("Rejects a mostly vertical swipe")
    func rejectsVerticalSwipe() {
        #expect(
            !EdgeSwipeBackPolicy.shouldPop(
                hasPreviousPage: true,
                startLocation: CGPoint(x: 12, y: startY),
                translation: CGSize(width: 60, height: 79)
            )
        )
        #expect(
            !EdgeSwipeBackPolicy.shouldPop(
                hasPreviousPage: true,
                startLocation: CGPoint(x: 12, y: startY),
                translation: CGSize(width: 120, height: 120)
            )
        )
    }
}
