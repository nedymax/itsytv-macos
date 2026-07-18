import AppKit
import XCTest
@testable import itsytv

final class PanelPositioningTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private let panelSize = NSSize(width: 176, height: 400)

    func testValidSavedOriginIsPreserved() {
        let origin = PanelPositioning.resolvedOrigin(
            savedOrigin: NSPoint(x: 100, y: 200),
            panelSize: panelSize,
            visibleFrames: [screen],
            statusItemFrame: nil
        )
        XCTAssertEqual(origin, NSPoint(x: 100, y: 200))
    }

    func testPartiallyOffscreenSavedOriginIsClamped() {
        let origin = PanelPositioning.resolvedOrigin(
            savedOrigin: NSPoint(x: 1320, y: 200),
            panelSize: panelSize,
            visibleFrames: [screen],
            statusItemFrame: nil
        )
        XCTAssertEqual(origin, NSPoint(x: 1264, y: 200))
    }

    func testMostlyOffscreenSavedOriginFallsBackToStatusItem() {
        let statusItem = NSRect(x: 1200, y: 900, width: 24, height: 24)
        let origin = PanelPositioning.resolvedOrigin(
            savedOrigin: NSPoint(x: -170, y: -390),
            panelSize: panelSize,
            visibleFrames: [screen],
            statusItemFrame: statusItem
        )
        XCTAssertEqual(origin, NSPoint(x: 1124, y: 500))
    }
}

final class PanelKeyboardRoutingTests: XCTestCase {
    func testRoutesOnlyToActiveKeyPanel() {
        XCTAssertTrue(PanelKeyboardRouting.shouldHandle(
            panelIsVisible: true,
            panelIsKey: true,
            panelIsApplicationKeyWindow: true,
            eventTargetsPanel: true
        ))
    }

    func testDoesNotRouteToSettingsOrInactivePanel() {
        XCTAssertFalse(PanelKeyboardRouting.shouldHandle(
            panelIsVisible: true,
            panelIsKey: false,
            panelIsApplicationKeyWindow: false,
            eventTargetsPanel: false
        ))
    }
}
