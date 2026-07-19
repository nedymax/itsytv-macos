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

    func testDeviceMenuPresentationSeparatesConnectionAndPairingState() {
        XCTAssertEqual(DeviceMenuPresentationState(isConnected: true, isPaired: true), .connected)
        XCTAssertEqual(DeviceMenuPresentationState(isConnected: false, isPaired: true), .paired)
        XCTAssertEqual(DeviceMenuPresentationState(isConnected: false, isPaired: false), .available)
        XCTAssertTrue(DeviceMenuPresentationState.paired.usesAccentColor)
        XCTAssertFalse(DeviceMenuPresentationState.available.usesAccentColor)
    }

    func testNowPlayingRefreshPolicyIsBoundedToMissingPresentationData() {
        XCTAssertFalse(NowPlayingRefreshPolicy.shouldRefresh(NowPlayingRefreshKey(
            isConnected: false,
            title: nil,
            artist: nil,
            album: nil,
            hasArtwork: false
        )))
        XCTAssertTrue(NowPlayingRefreshPolicy.shouldRefresh(NowPlayingRefreshKey(
            isConnected: true,
            title: nil,
            artist: nil,
            album: nil,
            hasArtwork: false
        )))
        XCTAssertTrue(NowPlayingRefreshPolicy.shouldRefresh(NowPlayingRefreshKey(
            isConnected: true,
            title: "Episode",
            artist: nil,
            album: nil,
            hasArtwork: false
        )))
        XCTAssertFalse(NowPlayingRefreshPolicy.shouldRefresh(NowPlayingRefreshKey(
            isConnected: true,
            title: "Episode",
            artist: nil,
            album: nil,
            hasArtwork: true
        )))
        XCTAssertEqual(NowPlayingRefreshPolicy.retryDelays, [0, 2, 5])
    }

    func testArtworkCacheFileNameEscapesPathSeparators() {
        let name = AppIconLoader.cacheFileName(bundleID: "com.example/app")
        XCTAssertFalse(name.contains("/"))
        XCTAssertTrue(name.hasSuffix(".image"))
    }
}
