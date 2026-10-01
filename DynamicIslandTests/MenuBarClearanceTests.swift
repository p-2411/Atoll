import XCTest
@testable import Atoll

/// The screen these use is a 16" MacBook Pro: 1728pt wide, notch 185pt wide and
/// centred, so the menu bar's left strip runs 0...771.5 and its right strip
/// 956.5...1728.
final class MenuBarClearanceTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    private let gap: CGFloat = 8
    private var notchedScreen: MenuBarLayout.ScreenGeometry {
        .init(frame: screen, notchXRange: 771.5...956.5)
    }

    private func collides(
        surfaceWidth: CGFloat,
        left: CGFloat? = nil,
        right: CGFloat? = nil,
        screen: CGRect? = nil
    ) -> Bool {
        MenuBarLayout.surfaceCollides(
            surfaceWidth: surfaceWidth,
            screenFrame: screen ?? self.screen,
            obstacles: .init(leftInset: left, rightInset: right),
            gap: gap
        )
    }

    /// A menu bar item `width` wide starting at `x`, in the menu bar strip.
    private func item(x: CGFloat, width: CGFloat, on screen: CGRect? = nil) -> CGRect {
        let frame = screen ?? self.screen
        return CGRect(x: x, y: frame.maxY - 33, width: width, height: 24)
    }

    // MARK: - Collision

    func testNothingMeasuredNeverCollides() {
        XCTAssertFalse(collides(surfaceWidth: 1000))
    }

    func testShortMenusLeaveTheActivityAlone() {
        // 300pt of surface is centred at 864, so it begins at 714. Menus ending
        // at 606 are nowhere near it.
        XCTAssertFalse(collides(surfaceWidth: 300, left: 606))
    }

    func testMenusReachingTheSurfaceCollide() {
        XCTAssertTrue(collides(surfaceWidth: 300, left: 720))
    }

    func testTheGapAloneIsEnoughToCollide() {
        // Menus end 4pt short of the surface: not covered, but flush enough to
        // read as touching.
        XCTAssertTrue(collides(surfaceWidth: 300, left: 710))
        XCTAssertFalse(collides(surfaceWidth: 300, left: 705))
    }

    func testStatusItemsReachingTheSurfaceCollide() {
        // The surface ends at 1014, so status items starting at 1010 -- 718pt in
        // from the right edge -- are under it.
        XCTAssertTrue(collides(surfaceWidth: 300, right: 718))
        XCTAssertFalse(collides(surfaceWidth: 300, right: 700))
    }

    func testAWiderActivityCollidesSooner() {
        // 520pt begins at 604, before the same menus that cleared 300pt.
        XCTAssertTrue(collides(surfaceWidth: 520, left: 606))
        XCTAssertFalse(collides(surfaceWidth: 300, left: 606))
    }

    func testNoSurfaceNeverCollides() {
        XCTAssertFalse(collides(surfaceWidth: 0, left: 1700, right: 1700))
    }

    func testAnExternalDisplayIsMeasuredOnItsOwnGeometry() {
        // A screen that does not start at x=0: insets are from its own edges.
        // Centre is -662, so 300pt of surface spans -812...-512.
        let sidecar = CGRect(x: -1324, y: 124, width: 1324, height: 993)
        XCTAssertTrue(collides(surfaceWidth: 300, left: 520, screen: sidecar))
        XCTAssertFalse(collides(surfaceWidth: 300, left: 400, screen: sidecar))
        XCTAssertTrue(collides(surfaceWidth: 300, right: 520, screen: sidecar))
    }

    // MARK: - Reducing item frames

    func testTheItemNearestTheNotchSetsEachSide() {
        let obstacles = MenuBarLayout.obstacles(
            itemFrames: [
                item(x: 10, width: 34),      // Apple menu
                item(x: 557, width: 49),     // Help
                item(x: 1100, width: 30),    // a status item
                item(x: 1650, width: 70),    // the clock
            ],
            screens: [notchedScreen]
        )
        XCTAssertEqual(obstacles.leftInset, 606)
        XCTAssertEqual(obstacles.rightInset, 628)
    }

    func testItemsHiddenBehindTheNotchAreIgnored() {
        // macOS tucks overflowing items under the camera housing, where there is
        // nothing visible for an activity to cover.
        let obstacles = MenuBarLayout.obstacles(
            itemFrames: [item(x: 800, width: 40), item(x: 760, width: 20)],
            screens: [notchedScreen]
        )
        XCTAssertNil(obstacles.leftInset)
        XCTAssertNil(obstacles.rightInset)
    }

    func testMenusOverflowingPastTheCentreCountOnTheRight() {
        // A screen without a notch lays menus out straight across its middle.
        let plain = MenuBarLayout.ScreenGeometry(frame: screen, notchXRange: nil)
        let obstacles = MenuBarLayout.obstacles(itemFrames: [item(x: 880, width: 60)], screens: [plain])
        XCTAssertNil(obstacles.leftInset)
        XCTAssertEqual(obstacles.rightInset, 848)
    }

    func testItemsOffEveryScreenAreIgnored() {
        let obstacles = MenuBarLayout.obstacles(
            itemFrames: [CGRect(x: 5000, y: 5000, width: 30, height: 24)],
            screens: [notchedScreen]
        )
        XCTAssertEqual(obstacles, MenuBarLayout.Obstacles())
    }

    func testZeroWidthItemsAreIgnored() {
        let obstacles = MenuBarLayout.obstacles(itemFrames: [item(x: 700, width: 0)], screens: [notchedScreen])
        XCTAssertNil(obstacles.leftInset)
    }

    func testItemsOnASecondDisplayAreInsetFromThatDisplay() {
        let sidecarFrame = CGRect(x: -1324, y: 124, width: 1324, height: 993)
        let sidecar = MenuBarLayout.ScreenGeometry(frame: sidecarFrame, notchXRange: nil)
        let obstacles = MenuBarLayout.obstacles(
            itemFrames: [item(x: -1100, width: 50, on: sidecarFrame)],
            screens: [notchedScreen, sidecar]
        )
        XCTAssertEqual(obstacles.leftInset, 274)
    }
}
