import SwiftUI

// MARK: - Theme

enum Theme {
    static let corner: CGFloat = 14
    static let accent = Color.accentColor
    /// The current theme's gradient (one colour for a solid theme, lightened a little to make the second stop).
    static var brandGradient: LinearGradient { ThemeStore.shared.gradient }
    static var primary: Color { ThemeStore.shared.primary }
    static var secondary: Color { ThemeStore.shared.secondary }

    static let avatarPalettes: [[Color]] = [
        [Color(hex: "#FF8A65")!, Color(hex: "#F4511E")!],
        [Color(hex: "#7986CB")!, Color(hex: "#3949AB")!],
        [Color(hex: "#4DB6AC")!, Color(hex: "#00897B")!],
        [Color(hex: "#BA68C8")!, Color(hex: "#8E24AA")!],
        [Color(hex: "#F06292")!, Color(hex: "#D81B60")!],
        [Color(hex: "#64B5F6")!, Color(hex: "#1E88E5")!],
        [Color(hex: "#FFD54F")!, Color(hex: "#FB8C00")!],
        [Color(hex: "#81C784")!, Color(hex: "#43A047")!],
    ]

    static func palette(for seed: String) -> [Color] {
        let h = seed.unicodeScalars.reduce(UInt32(5381)) { ($0 << 5) &+ $0 &+ $1.value }
        return avatarPalettes[Int(h % UInt32(avatarPalettes.count))]
    }
}

// MARK: - Card

struct CardModifier: ViewModifier {
    var padding: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            }
    }
}

extension View {
    func card(padding: CGFloat = 18) -> some View { modifier(CardModifier(padding: padding)) }

    /// Liquid Glass on macOS 26+, material fallback on older systems.
    @ViewBuilder
    func glassBackground(cornerRadius: CGFloat = 18) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.12)))
        }
    }
}

struct SectionHeader: View {
    var title: String
    var symbol: String? = nil
    var trailing: AnyView? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
            Text(title).font(.headline)
            Spacer()
            trailing
        }
    }
}

// MARK: - Avatar

struct AvatarView: View {
    var name: String
    var imageData: Data? = nil
    var size: CGFloat = 40

    private var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first(where: \.isLetter) }
        if letters.isEmpty { return "" }
        return String(letters).uppercased()
    }

    var body: some View {
        ZStack {
            if let imageData, let img = ImageCache.image(from: imageData, maxPixel: max(128, Int(size * 3))) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                let p = Theme.palette(for: name)
                LinearGradient(colors: p, startPoint: .topLeading, endPoint: .bottomTrailing)
                if initials.isEmpty {
                    Image(systemName: name.contains("-") ? "building.columns.fill" : "person.fill")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                } else {
                    Text(initials)
                        .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .shadow(color: Theme.palette(for: name)[1].opacity(0.25), radius: size * 0.1, y: size * 0.05)
        .accessibilityHidden(true)
    }
}

// MARK: - SIM

struct SimPill: View {
    var sim: SimCard?
    var compact = false

    var body: some View {
        if let sim {
            HStack(spacing: 4) {
                Circle().fill(sim.color).frame(width: 6, height: 6)
                Text(compact ? "SIM \(sim.slotIndex + 1)" : sim.pillLabel)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(sim.color)
            .background(sim.color.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(sim.color.opacity(0.22), lineWidth: 0.5))
            .help("\(sim.slotLabel) · \(sim.carrierName) · \(sim.displayName)")
        }
    }
}

/// Segmented SIM selector used by the composer and dialer.
struct SimSelector: View {
    var sims: [SimCard]
    @Binding var selection: Int?
    var showShortcutHint = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(sims) { sim in
                let on = selection == sim.subscriptionId
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = sim.subscriptionId }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "simcard.fill").font(.system(size: 10))
                        Text(sim.carrierName).font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        if showShortcutHint {
                            Text("⌘\(sim.slotIndex + 1)").font(.system(size: 9.5, weight: .medium)).opacity(0.6)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .foregroundStyle(on ? .white : sim.color)
                    .background {
                        Capsule().fill(on ? AnyShapeStyle(sim.color.gradient) : AnyShapeStyle(sim.color.opacity(0.1)))
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(sim.slotIndex + 1)")), modifiers: .command)
                .help("Send from \(sim.pillLabel)")
            }
        }
    }
}

/// Credit-card style SIM tile.
struct SimCardTile: View {
    var sim: SimCard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "simcard.fill").font(.title3)
                Text(sim.slotLabel).font(.system(.subheadline, design: .rounded, weight: .bold))
                Spacer()
                Image(systemName: "antenna.radiowaves.left.and.right").font(.subheadline)
            }
            Spacer(minLength: 14)
            Text(sim.carrierName).font(.system(.title2, design: .rounded, weight: .bold))
            Text(sim.phoneNumber.map(PhoneNumber.pretty) ?? "Number hidden by carrier")
                .font(.system(.callout, design: .monospaced))
                .opacity(0.85)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Text(sim.displayName).font(.caption.weight(.semibold))
                Spacer()
                if sim.isDefaultSms { tag("SMS") }
                if sim.isDefaultVoice { tag("Calls") }
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
        .background {
            ZStack {
                Color.black
                LinearGradient(colors: [sim.color, sim.color.opacity(0.62)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(.white.opacity(0.10)).frame(width: 180).offset(x: 120, y: -70)
                Circle().fill(.white.opacity(0.06)).frame(width: 140).offset(x: 160, y: 60)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: sim.color.opacity(0.35), radius: 14, y: 8)
    }

    private func tag(_ s: String) -> some View {
        Text("Default \(s)")
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.white.opacity(0.22), in: Capsule())
    }
}

// MARK: - Device status glyphs

struct BatteryGlyph: View {
    var status: DeviceStatusEvent?

    var body: some View {
        if let s = status {
            HStack(spacing: 4) {
                Image(systemName: symbol(s)).symbolRenderingMode(.palette)
                    .foregroundStyle(color(s), .primary.opacity(0.5))
                Text("\(s.batteryPercent)%").monospacedDigit()
            }
            .help(s.isCharging ? "Charging" : "On battery")
        }
    }

    private func symbol(_ s: DeviceStatusEvent) -> String {
        if s.isCharging { return "battery.100percent.bolt" }
        switch s.batteryPercent {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
    private func color(_ s: DeviceStatusEvent) -> Color {
        s.isCharging ? .green : (s.batteryPercent <= 20 ? .red : .primary)
    }
}

struct SignalBars: View {
    var bars: Int
    var tint: Color = .primary

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < bars ? tint : tint.opacity(0.2))
                    .frame(width: 3, height: CGFloat(4 + i * 3))
            }
        }
        .accessibilityLabel("\(bars) of 4 bars")
    }
}

struct ConnectionBadge: View {
    var mode: ConnectionMode
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().fill(mode.tint.opacity(0.3)).frame(width: 12, height: 12)
                    .scaleEffect(pulse ? 1.5 : 0.8).opacity(pulse ? 0 : 1)
                Circle().fill(mode.tint).frame(width: 7, height: 7)
            }
            Text(mode.label).font(.system(size: 11.5, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(mode.tint.opacity(0.1), in: Capsule())
        .foregroundStyle(mode.tint)
        .onAppear {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

struct BatteryRing: View {
    var percent: Int
    var charging: Bool
    var size: CGFloat = 86

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 8)
            Circle()
                .trim(from: 0, to: CGFloat(percent) / 100)
                .stroke(AngularGradient(colors: ringColors + [ringColors[0]], center: .center),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                if charging { Image(systemName: "bolt.fill").font(.caption).foregroundStyle(.green) }
                Text("\(percent)%").font(.system(size: size * 0.22, weight: .bold, design: .rounded)).monospacedDigit()
            }
        }
        .frame(width: size, height: size)
        .animation(.smooth, value: percent)
    }

    private var ringColors: [Color] {
        if charging { return [.green, .mint] }
        if percent <= 20 { return [.red, .orange] }
        return [Theme.secondary, Theme.primary]
    }
}

// MARK: - Misc

struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String
    var action: (label: String, run: () -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.brandGradient.opacity(0.12)).frame(width: 96, height: 96)
                Image(systemName: symbol)
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(Theme.brandGradient)
            }
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 300)
            if let action {
                Button(action.label, action: action.run).buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SearchField: View {
    @Binding var text: String
    var prompt = "Search"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct ToastView: View {
    var toast: Toast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.symbol).foregroundStyle(tint).font(.body.weight(.semibold))
            Text(toast.message).font(.callout.weight(.medium)).lineLimit(2)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .glassBackground(cornerRadius: 22)
        .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
    }

    private var tint: Color {
        switch toast.style {
        case .info: .accentColor
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

struct IconButton: View {
    var symbol: String
    var help: String
    var tint: Color = .primary
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(0.05), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

extension Date {
    var relativeShort: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: self, to: .now).day, days < 7 { return formatted(.dateTime.weekday(.wide)) }
        return formatted(.dateTime.day().month(.abbreviated))
    }
}

extension TimeInterval {
    var callDuration: String {
        let s = Int(self)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
