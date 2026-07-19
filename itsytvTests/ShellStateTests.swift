import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Itsytv

final class ShellStateTests: XCTestCase {
    func testEmptyDeviceIDsAreRejectedForHotkeys() {
        XCTAssertFalse(HotkeyStorage.isValidDeviceID(""))
        XCTAssertFalse(HotkeyStorage.isValidDeviceID("   \n"))
        XCTAssertTrue(HotkeyStorage.isValidDeviceID("living-room"))
    }

    func testStandardWindowAndHideShortcutsAreReserved() {
        let command = NSEvent.ModifierFlags.command.rawValue
        XCTAssertTrue(ShortcutKeys(modifiers: command, keyCode: UInt16(kVK_ANSI_W)).isReservedMacShortcut)
        XCTAssertTrue(ShortcutKeys(modifiers: command, keyCode: UInt16(kVK_ANSI_H)).isReservedMacShortcut)
        XCTAssertFalse(ShortcutKeys(modifiers: command, keyCode: UInt16(kVK_ANSI_K)).isReservedMacShortcut)
    }

    func testVersionComparisonHandlesDifferentComponentCounts() {
        XCTAssertTrue(VersionComparison.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertTrue(VersionComparison.isNewer("v2.0", than: "1.99.99"))
        XCTAssertFalse(VersionComparison.isNewer("1.6", than: "1.6.0"))
        XCTAssertFalse(VersionComparison.isNewer("1.5.9", than: "1.6.0"))
    }

    func testVersionComparisonToleratesPrereleaseSuffix() {
        XCTAssertTrue(VersionComparison.isNewer("1.7.0-beta.1", than: "1.6.9"))
    }

    func testRemoteButtonReleaseOutsideCancelsClick() {
        XCTAssertFalse(RemoteButtonTracking.shouldFireClick(holdFired: false, releasedInside: false))
        XCTAssertFalse(RemoteButtonTracking.shouldFireClick(holdFired: true, releasedInside: true))
        XCTAssertTrue(RemoteButtonTracking.shouldFireClick(holdFired: false, releasedInside: true))
    }
}
