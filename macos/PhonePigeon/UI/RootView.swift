import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ZStack {
            if app.isPaired && !app.showAddPhone {
                MainView().transition(.opacity)
            } else {
                OnboardingView().transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.5), value: app.isPaired && !app.showAddPhone)
        .overlay(alignment: .top) {
            if let toast = app.toast {
                ToastView(toast: toast)
                    .padding(.top, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if app.activeCall != nil {
                ActiveCallView()
                    .padding(22)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9)),
                                            removal: .opacity.combined(with: .scale(scale: 0.95))))
            }
        }
        .frame(minWidth: 980, minHeight: 640)
    }
}

struct MainView: View {
    @Environment(AppState.self) private var app
    @State private var visibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: $visibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 290)
        } detail: {
            Group {
                switch app.section {
                case .overview: OverviewView()
                case .messages: MessagesView()
                case .calls: CallsView()
                case .photos: PhotosView()
                case .files: FilesView()
                case .notifications: NotificationsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .sheet(isPresented: $app.showNewMessage) { NewMessageSheet() }
        .onChange(of: app.section) { _, new in if new == .calls { app.callSeenAt = .now } }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        List(selection: Binding(get: { app.section }, set: { if let s = $0 { app.section = s } })) {
            DeviceHeader()
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(app.section == .overview ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1.5)
                }
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy) { app.section = .overview } }
                .help("Phone overview")
                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 12, trailing: 4))
                .selectionDisabled()

            if !app.offlinePhones.isEmpty {
                Button { app.removeOfflinePhones() } label: {
                    Label("\(app.offlinePhones.count) offline phone\(app.offlinePhones.count == 1 ? "" : "s") · Remove", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Old or duplicate pairings that can't connect. Removing them also deletes their saved messages on this Mac.")
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 8, trailing: 4))
                .selectionDisabled()
            }

            Section("Phone") {
                ForEach(AppState.Section.tabs) { s in
                    Label(s.title, systemImage: s.symbol)
                        .badge(badge(for: s))
                        .tag(s)
                }
            }

            if !app.sims.isEmpty {
                Section("SIM Cards") {
                    ForEach(app.sims) { sim in
                        Button {
                            app.simFilter = app.simFilter == sim.subscriptionId ? nil : sim.subscriptionId
                            app.section = .messages
                        } label: {
                            HStack(spacing: 9) {
                                RoundedRectangle(cornerRadius: 4).fill(sim.color.gradient).frame(width: 16, height: 20)
                                    .overlay(Text("\(sim.slotIndex + 1)").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white))
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(sim.carrierName).font(.callout.weight(.medium))
                                    Text(sim.displayName).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if app.simFilter == sim.subscriptionId {
                                    Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(sim.color)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Filter conversations by \(sim.pillLabel)")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button { app.showNewMessage = true } label: {
                    Label("New Message", systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("n", modifiers: .command)
            }
            .padding(12)
        }
    }

    private func badge(for s: AppState.Section) -> Int {
        switch s {
        case .messages: app.unreadTotal
        case .calls: app.missedSinceSeen
        case .notifications: app.notificationCount
        default: 0
        }
    }
}

struct DeviceHeader: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.brandGradient).frame(width: 38, height: 38)
                    Image(systemName: "iphone.gen3").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.pairing?.deviceName ?? "Phone").font(.headline).lineLimit(1)
                    Text(app.pairing?.osVersion ?? "").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                PhoneSwitcher()
            }
            HStack(spacing: 8) {
                ConnectionBadge(mode: app.connection).fixedSize()
                Spacer(minLength: 0)
                if let b = app.battery {
                    Image(systemName: b.bluetoothHfpConnected ? "headphones" : "headphones.slash")
                        .foregroundStyle(b.bluetoothHfpConnected ? Color.green : Color.secondary)
                        .help(b.bluetoothHfpConnected ? "Bluetooth call audio connected" : "Bluetooth call audio not connected")
                    BatteryGlyph(status: b).font(.caption.weight(.medium)).fixedSize()
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Lists every paired phone (connection dot, unread count) and lets you switch or add one.
struct PhoneSwitcher: View {
    @Environment(AppState.self) private var app
    @State private var open = false

    private var othersUnread: Int {
        app.phones.filter { $0.id != app.current?.id }.reduce(0) { $0 + $1.unreadTotal }
    }

    private func dot(_ mode: ConnectionMode) -> Color {
        switch mode {
        case .lan, .demo: .green
        case .cloud: .teal
        case .connecting: .orange
        case .offline: .secondary
        }
    }

    var body: some View {
        // A popover rather than a menu: a menu row can't hold a second button, and each phone needs its own trash can.
        Button { open.toggle() } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(6)
                if othersUnread > 0 {
                    Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                }
            }
        }
        .buttonStyle(.plain)
        .help(app.phones.count > 1 ? "Switch phone" : "Phones")
        .popover(isPresented: $open, arrowEdge: .trailing) { list }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Phones").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 4)
            ForEach(app.phones) { p in
                HStack(spacing: 8) {
                    Button {
                        app.selectPhone(p.id)
                        open = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: p.id == app.current?.id ? "checkmark" : "")
                                .frame(width: 14).foregroundStyle(Color.accentColor)
                            Circle().fill(dot(p.connection)).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(p.name).lineLimit(1)
                                Text(p.connection.label + (p.unreadTotal > 0 ? " · \(p.unreadTotal) unread" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 12)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button {
                        open = false
                        app.confirmRemovePhone(p.id)
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove \(p.name)")
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
            }
            Divider().padding(.vertical, 4)
            Button { open = false; app.showAddPhone = true } label: { Label("Add Phone…", systemImage: "plus") }
                .buttonStyle(.plain).padding(.horizontal, 10).padding(.vertical, 4)
            if app.offlinePhones.count > 1 {
                Button(role: .destructive) { open = false; app.removeOfflinePhones() } label: {
                    Label("Remove \(app.offlinePhones.count) Offline Phones…", systemImage: "trash")
                }
                .buttonStyle(.plain).padding(.horizontal, 10).padding(.vertical, 4)
            }
        }
        .padding(.vertical, 10)
        .frame(minWidth: 280)
    }
}
