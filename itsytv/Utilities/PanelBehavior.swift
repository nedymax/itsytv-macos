import AppKit

enum PanelPositioning {
    static func resolvedOrigin(
        savedOrigin: NSPoint?,
        panelSize: NSSize,
        visibleFrames: [NSRect],
        statusItemFrame: NSRect?
    ) -> NSPoint? {
        guard !visibleFrames.isEmpty, panelSize.width > 0, panelSize.height > 0 else { return nil }

        if let savedOrigin, savedOrigin.x.isFinite, savedOrigin.y.isFinite {
            let savedFrame = NSRect(origin: savedOrigin, size: panelSize)
            if let screen = bestScreen(for: savedFrame, in: visibleFrames),
               intersectionRatio(savedFrame, screen) >= 0.5 {
                return clamp(savedOrigin, panelSize: panelSize, to: screen)
            }
        }

        if let statusItemFrame {
            let proposed = NSPoint(
                x: statusItemFrame.midX - panelSize.width / 2,
                y: statusItemFrame.minY - panelSize.height
            )
            let anchor = NSPoint(x: statusItemFrame.midX, y: statusItemFrame.midY)
            let screen = visibleFrames.first(where: { $0.contains(anchor) })
                ?? visibleFrames.min(by: { distance(from: anchor, to: $0) < distance(from: anchor, to: $1) })!
            return clamp(proposed, panelSize: panelSize, to: screen)
        }

        let screen = visibleFrames[0]
        let proposed = NSPoint(x: screen.midX - panelSize.width / 2, y: screen.maxY - panelSize.height)
        return clamp(proposed, panelSize: panelSize, to: screen)
    }

    static func clamp(_ origin: NSPoint, panelSize: NSSize, to visibleFrame: NSRect) -> NSPoint {
        let maxX = max(visibleFrame.minX, visibleFrame.maxX - panelSize.width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - panelSize.height)
        return NSPoint(
            x: min(max(origin.x, visibleFrame.minX), maxX),
            y: min(max(origin.y, visibleFrame.minY), maxY)
        )
    }

    private static func bestScreen(for frame: NSRect, in visibleFrames: [NSRect]) -> NSRect? {
        visibleFrames.max { frame.intersection($0).area < frame.intersection($1).area }
    }

    private static func intersectionRatio(_ frame: NSRect, _ visibleFrame: NSRect) -> CGFloat {
        guard frame.area > 0 else { return 0 }
        return frame.intersection(visibleFrame).area / frame.area
    }

    private static func distance(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let dx = max(max(rect.minX - point.x, 0), point.x - rect.maxX)
        let dy = max(max(rect.minY - point.y, 0), point.y - rect.maxY)
        return hypot(dx, dy)
    }
}

enum PanelKeyboardRouting {
    static func shouldHandle(
        panelIsVisible: Bool,
        panelIsKey: Bool,
        panelIsApplicationKeyWindow: Bool,
        eventTargetsPanel: Bool
    ) -> Bool {
        panelIsVisible && panelIsKey && panelIsApplicationKeyWindow && eventTargetsPanel
    }
}

private extension NSRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
