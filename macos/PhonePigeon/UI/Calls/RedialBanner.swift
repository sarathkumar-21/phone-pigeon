import SwiftUI

/// Shown between auto-redial attempts: who is called next, how long is left, and a way to stop.
struct RedialBanner: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if let plan = app.redial, let next = plan.nextAt, app.activeCall == nil {
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                let left = max(0, Int(ceil(next.timeIntervalSince(ctx.date))))
                let fraction = max(0, min(1, next.timeIntervalSince(ctx.date) / Double(max(plan.delay, 1))))
                HStack(spacing: 14) {
                    ZStack {
                        Circle().stroke(.secondary.opacity(0.25), lineWidth: 3)
                        Circle().trim(from: 0, to: fraction).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(left)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                    }
                    .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("No answer from \(app.displayName(for: plan.number))").font(.callout.weight(.semibold))
                        Text("Calling again in \(left) s · try \(plan.attempt + 1) of \(plan.maxAttempts)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Call now") { app.redialNow() }.controlSize(.small)
                    Button("Stop", role: .cancel) { app.cancelRedial() }.controlSize(.small)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .glassBackground(cornerRadius: 22)
                .shadow(color: .black.opacity(0.2), radius: 18, y: 8)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
