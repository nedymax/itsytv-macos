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
        static let deviceMenuItemHeight: CGFloat = 48
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

struct NativeSegmentPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]

    var body: some View {
        Picker("View", selection: $selection) {
            ForEach(0..<options.count, id: \.self) { index in
                Text(options[index].1).tag(options[index].0)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
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
