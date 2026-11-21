import AppKit
import SwiftUI

/// A colour theme: one colour (solid) or two (a gradient).
struct AppTheme: Identifiable, Hashable {
    let id: String
    let name: String
    /// One or two `#RRGGBB` colours. Text on them is white, so they stay on the darker side.
    let colors: [String]

    var isGradient: Bool { colors.count > 1 }

    static let pigeon = AppTheme(id: "pigeon", name: "Pigeon", colors: ["#6B5BF9", "#3B8CFF"])

    static let gradients: [AppTheme] = [
        pigeon,
        AppTheme(id: "ocean", name: "Ocean", colors: ["#0A5CD6", "#12A8D8"]),
        AppTheme(id: "sunset", name: "Sunset", colors: ["#E8483C", "#F08A24"]),
        AppTheme(id: "berry", name: "Berry", colors: ["#B02FD0", "#E8479B"]),
        AppTheme(id: "forest", name: "Forest", colors: ["#0F8F6F", "#3DB86B"]),
        AppTheme(id: "ember", name: "Ember", colors: ["#D9262C", "#F07C1B"]),
        AppTheme(id: "midnight", name: "Midnight", colors: ["#1D2B64", "#6A3FA0"]),
        AppTheme(id: "slate", name: "Slate", colors: ["#3A4A6B", "#6B7A9B"]),
    ]

    static let solids: [AppTheme] = [
        AppTheme(id: "indigo", name: "Indigo", colors: ["#5B5BE0"]),
        AppTheme(id: "teal", name: "Teal", colors: ["#0F9AA0"]),
        AppTheme(id: "rose", name: "Rose", colors: ["#D9407A"]),
        AppTheme(id: "amber", name: "Amber", colors: ["#C77B0A"]),
        AppTheme(id: "graphite", name: "Graphite", colors: ["#5A5F6B"]),
    ]

    static let all = gradients + solids
    static func preset(_ id: String) -> AppTheme? { all.first { $0.id == id } }
}

/// The colours the interface is drawn with right now. A shared, observable object so views that read it while drawing
/// (`Theme.brandGradient`, `Theme.primary`…) redraw when the theme changes.
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    private(set) var primary = Color(hex: AppTheme.pigeon.colors[0])!
    private(set) var secondary = Color(hex: AppTheme.pigeon.colors[1])!
    private(set) var tintWindows = true

    var gradient: LinearGradient { LinearGradient(colors: [primary, secondary], startPoint: .topLeading, endPoint: .bottomTrailing) }

    func apply(_ s: AppSettings) {
        let hexes: [String]
        if s.themeId == "custom" {
            hexes = s.customThemeGradient ? [s.customThemeA, s.customThemeB] : [s.customThemeA]
        } else {
            hexes = (AppTheme.preset(s.themeId) ?? .pigeon).colors
        }
        let first = Color(hex: hexes[0]) ?? Color(hex: AppTheme.pigeon.colors[0])!
        // A solid theme still gets a gentle gradient (the same colour, a little lighter) so gradients look consistent.
        let second = hexes.count > 1 ? (Color(hex: hexes[1]) ?? first) : first.lightened(0.22)
        if first != primary { primary = first }
        if second != secondary { secondary = second }
        if s.tintWindows != tintWindows { tintWindows = s.tintWindows }
    }
}

extension Color {
    /// `#RRGGBB` in sRGB (for saving a colour picked in a ColorPicker).
    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .systemIndigo
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }

    func lightened(_ amount: Double) -> Color {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .systemIndigo
        return Color(nsColor: c.blended(withFraction: amount, of: .white) ?? c)
    }
}

/// The window background, with a faint wash of the theme in the corner.
struct ThemedBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = ThemeStore.shared
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if theme.tintWindows {
                LinearGradient(colors: [theme.primary.opacity(scheme == .dark ? 0.18 : 0.10),
                                        theme.secondary.opacity(scheme == .dark ? 0.08 : 0.05), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }
}

// MARK: - Settings: picking a theme

struct ThemePicker: View {
    @Environment(AppState.self) private var app
    private let columns = [GridItem(.adaptive(minimum: 76, maximum: 96), spacing: 12)]

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 14) {
            group("Gradients", AppTheme.gradients)
            group("Solid colours", AppTheme.solids)

            VStack(alignment: .leading, spacing: 8) {
                Text("Your own").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    swatch(id: "custom", name: "Custom", colors: app.settings.customThemeGradient
                           ? [app.settings.customThemeA, app.settings.customThemeB] : [app.settings.customThemeA])
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            ColorPicker("Colour", selection: Binding(
                                get: { Color(hex: app.settings.customThemeA) ?? .accentColor },
                                set: { app.settings.customThemeA = $0.hexString; app.settings.themeId = "custom" }))
                            if app.settings.customThemeGradient {
                                ColorPicker("Second colour", selection: Binding(
                                    get: { Color(hex: app.settings.customThemeB) ?? .accentColor },
                                    set: { app.settings.customThemeB = $0.hexString; app.settings.themeId = "custom" }))
                            }
                        }
                        Toggle("Two-colour gradient", isOn: Binding(
                            get: { app.settings.customThemeGradient },
                            set: { app.settings.customThemeGradient = $0; app.settings.themeId = "custom" }))
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func group(_ title: String, _ themes: [AppTheme]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(themes) { t in swatch(id: t.id, name: t.name, colors: t.colors) }
            }
        }
    }

    private func swatch(id: String, name: String, colors: [String]) -> some View {
        let on = app.settings.themeId == id
        let a = Color(hex: colors[0]) ?? .accentColor
        let b = colors.count > 1 ? (Color(hex: colors[1]) ?? a) : a.lightened(0.22)
        return Button { app.settings.themeId = id } label: {
            VStack(spacing: 5) {
                ZStack {
                    Circle().fill(LinearGradient(colors: [a, b], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 42, height: 42)
                        .shadow(color: a.opacity(0.35), radius: 6, y: 3)
                    if on { Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.white) }
                }
                .padding(3)
                .overlay(Circle().strokeBorder(on ? Color.primary.opacity(0.7) : .clear, lineWidth: 2))
                Text(name).font(.caption2).foregroundStyle(on ? .primary : .secondary)
            }
            .frame(width: 70)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(colors.count > 1 ? "\(name) (two-colour gradient)" : "\(name) (single colour)")
    }
}
