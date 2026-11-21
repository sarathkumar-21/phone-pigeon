import SwiftUI

/// The phone's notifications, newest first, grouped by app. Clearing one here clears it on the phone too.
struct NotificationsView: View {
    @Environment(AppState.self) private var app

    private var groups: [(app: String, package: String, items: [PhoneNotification])] {
        var order: [String] = []
        var map: [String: [PhoneNotification]] = [:]
        for n in app.notifications {
            if map[n.packageName] == nil { order.append(n.packageName) }
            map[n.packageName, default: []].append(n)
        }
        return order.map { (map[$0]![0].appName, $0, map[$0]!) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notifications").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("From your phone, live").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear All") { app.clearNotifications() }
                    .disabled(app.notifications.filter(\.canDismiss).isEmpty)
            }
            .padding(20)
            Divider()
            if app.notifications.isEmpty {
                EmptyStateView(symbol: "bell.slash", title: "No notifications",
                                   message: "Notifications from your other phone apps appear here. If nothing shows up, open PhonePigeon on the phone, make sure Notifications is on, and allow Notification access.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(groups, id: \.package) { g in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    icon(g.package).frame(width: 20, height: 20)
                                    Text(g.app).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                }
                                ForEach(g.items) { n in row(n) }
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    @ViewBuilder private func icon(_ package: String) -> some View {
        if let img = app.appIcon(for: package) {
            Image(nsImage: img).resizable().clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: "app.fill").foregroundStyle(.secondary)
        }
    }

    private func row(_ n: PhoneNotification) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if !n.title.isEmpty { Text(n.title).font(.headline).lineLimit(2) }
                if !n.text.isEmpty { Text(n.text).font(.callout).foregroundStyle(.secondary).lineLimit(6) }
                Text(n.postedAt.relativeShort).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if n.canDismiss {
                Button { app.dismissNotification(n.id) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear on Mac and phone")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassBackground(cornerRadius: 12)
    }
}
