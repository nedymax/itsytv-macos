import AppKit
import SwiftUI

// MARK: - Design tokens

enum DS {

    // MARK: - Colors

    enum Colors {
        static var background: NSColor {
            .windowBackgroundColor
        }

        static var foreground: NSColor {
            .labelColor
        }

        static var primary: NSColor {
            .controlAccentColor
        }

        static var primaryForeground: NSColor {
            .selectedControlTextColor
        }

        static var secondary: NSColor {
            .controlBackgroundColor
        }

        static var secondaryForeground: NSColor {
            .controlTextColor
        }

        static var muted: NSColor {
            .controlBackgroundColor
        }

        static var mutedForeground: NSColor {
            .secondaryLabelColor
        }

        static var iconForeground: NSColor {
            foreground
        }

        static var remoteButton: NSColor {
            NSColor(name: nil) { appearance in
                appearance.isDark ? .underPageBackgroundColor : NSColor(white: 0.205, alpha: 1)
            }
        }

        static var remoteButtonCenter: NSColor {
            NSColor(name: nil) { appearance in
                appearance.isDark ? NSColor(white: 0.27, alpha: 1) : NSColor(white: 0.205, alpha: 1)
            }
        }

        static var remoteButtonForeground: NSColor {
            NSColor(white: 0.985, alpha: 1)
        }

        static var border: NSColor {
            .separatorColor
        }

    }

    // MARK: - Spacing

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: - Radius

    enum Radius {
        static let sm: CGFloat = 4
        static let md: CGFloat = 6
        static let lg: CGFloat = 8
        static let xl: CGFloat = 12
        static let full: CGFloat = 9999
    }

    // MARK: - Typography

    enum Typography {
        static let label = NSFont.systemFont(ofSize: 13, weight: .regular)
        static let labelMedium = NSFont.systemFont(ofSize: 13, weight: .medium)
    }

    // MARK: - Control sizes

    enum ControlSize {
        static let iconMedium: CGFloat = 14
        static let menuItemHeight: CGFloat = 28
        static let deviceMenuItemHeight: CGFloat = 40
        static let menuItemWidth: CGFloat = 260
    }
}

// MARK: - NSAppearance extension

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

// MARK: - Native segmented picker

struct NativeSegmentPicker<T: Hashable>: NSViewRepresentable {
    @Binding var selection: T
    let options: [(T, String)]

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: options.map(\.1),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectionChanged(_:))
        )
        control.segmentStyle = .capsule
        if #available(macOS 26.0, *) {
            control.borderShape = .capsule
        }
        control.segmentDistribution = .fillEqually
        control.controlSize = .large
        control.setAccessibilityLabel("Remote view")
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.selectedSegment = options.firstIndex(where: { $0.0 == selection }) ?? -1
        for (index, option) in options.enumerated() where index < control.segmentCount {
            control.setLabel(option.1, forSegment: index)
        }
    }

    final class Coordinator: NSObject {
        var parent: NativeSegmentPicker

        init(parent: NativeSegmentPicker) {
            self.parent = parent
        }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            guard sender.selectedSegment >= 0,
                  sender.selectedSegment < parent.options.count else { return }
            parent.selection = parent.options[sender.selectedSegment].0
        }
    }
}

// MARK: - Native panel controls

private struct NativePanelControlStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
        } else {
            content
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
        }
        #else
        content
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
        #endif
    }
}

extension View {
    func nativePanelControlStyle() -> some View {
        modifier(NativePanelControlStyle())
    }
}
