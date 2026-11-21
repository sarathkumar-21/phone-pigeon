import SwiftUI

/// Floating in-window call card (mirrors the CallKit banner described in spec §9.3).
struct ActiveCallView: View {
    @Environment(AppState.self) private var app
    @State private var showKeypad = false
    private var layout: AppState.CallLayout { get { app.callLayout } nonmutating set { app.callLayout = newValue } }
    @State private var dtmf = ""

    var body: some View {
        if let call = app.activeCall {
            Group {
                switch layout {
                case .bar: corner(compact(call))
                case .card: corner(expanded(call))
                case .full: fullScreen(call)
                }
            }
            // Every call starts as the small card (controls, photo, timer). Full window is opt-in; the arrows switch between them.
            .onAppear { startLayout(for: call) }
            .onChange(of: call.id) { startLayout(for: call) }
            .animation(.spring(duration: 0.4), value: layout)
            .animation(.spring(duration: 0.4), value: showKeypad)
            .animation(.spring(duration: 0.4), value: call.state)
        }
    }

    /// Whether the big, full-window layout is showing (bigger buttons).
    private var big: Bool { layout == .full }

    private func startLayout(for call: CallSession) {
        dtmf = ""; showKeypad = false
        layout = app.settings.fullWindowCalls ? .full : .card
    }

    private func corner<V: View>(_ v: V) -> some View {
        v.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    // MARK: Full screen

    private func fullScreen(_ call: CallSession) -> some View {
        ZStack {
            backdrop(call)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    SimPill(sim: app.sim(call.subscriptionId))
                    if let plan = app.redial, plan.callId == call.id { redialChip(plan) }
                    Spacer()
                    if call.state != .ringingIncoming {
                        Button { layout = .bar } label: {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 34, height: 34)
                                .background(.white.opacity(0.14), in: Circle())
                        }
                        .buttonStyle(.plain).help("Shrink to a small call bar")
                    }
                }
                .padding(.leading, 96).padding(.trailing, 28).padding(.top, 20)

                Spacer(minLength: 12)

                VStack(spacing: 14) {
                    PulsingAvatar(name: call.title, imageData: call.photo, size: 190,
                                  active: call.state == .ringingIncoming || call.state == .dialingOutgoing)
                    Text(call.title)
                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.6)
                    statusLine(call)
                        .font(.system(size: 19, weight: .regular).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.8))
                        .transaction { $0.animation = nil }
                    if call.contactName != nil {
                        Text(PhoneNumber.pretty(call.remoteAddress)).font(.callout).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(.horizontal, 40)

                Spacer(minLength: 12)

                if showKeypad && call.state == .active { keypad.padding(.bottom, 18).transition(.scale(scale: 0.92).combined(with: .opacity)) }

                controls(call)

                if call.state == .active || call.state == .dialingOutgoing {
                    Label(call.audioOnMac ? app.audio.status.label : "Audio stays on the phone",
                          systemImage: call.audioOnMac ? "headphones" : "iphone.radiowaves.left.and.right")
                        .font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        .padding(.top, 16)
                }
            }
            .padding(.bottom, 34)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
        .onChange(of: call.id) { dtmf = ""; showKeypad = false }
    }

    /// The contact's photo, blurred and darkened, behind everything; without a photo, a gradient from the contact's colour.
    private func backdrop(_ call: CallSession) -> some View {
        ZStack {
            Color.black
            if let data = call.photo, let img = ImageCache.image(from: data, maxPixel: 512) {
                Color.clear.overlay {
                    Image(nsImage: img).resizable().scaledToFill().saturation(1.25).blur(radius: 70).scaleEffect(1.25)
                }
                .clipped()
            } else {
                LinearGradient(colors: Theme.palette(for: call.title).map { $0.opacity(0.85) }, startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            LinearGradient(colors: [.black.opacity(0.30), .black.opacity(0.62)], startPoint: .top, endPoint: .bottom)
        }
    }

    @ViewBuilder private func statusLine(_ call: CallSession) -> some View {
        switch call.state {
        case .ringingIncoming: Text("Incoming call…")
        case .dialingOutgoing: Text("Calling…")
        case .holding: Text("On hold")
        case .active: CallTimer(call: call)
        case .disconnected: Text("Call ended")
        }
    }

    private func redialChip(_ plan: RedialState) -> some View {
        Label("Auto-redial · try \(plan.attempt) of \(plan.maxAttempts)", systemImage: "arrow.triangle.2.circlepath")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.white.opacity(0.14), in: Capsule())
    }

    private var keypad: some View {
        VStack(spacing: 8) {
            Text(dtmf.isEmpty ? " " : dtmf).font(.title3.monospaced()).foregroundStyle(.white)
            Grid(horizontalSpacing: 12, verticalSpacing: 10) {
                ForEach(0..<4) { r in
                    GridRow {
                        ForEach(0..<3) { c in
                            let d = ["1","2","3","4","5","6","7","8","9","*","0","#"][r * 3 + c]
                            Button {
                                dtmf.append(d)
                                app.performCallAction(.sendDtmf, digit: d)
                            } label: {
                                Text(d).font(.system(size: 20, design: .rounded)).foregroundStyle(.white)
                                    .frame(width: 50, height: 50).background(Circle().fill(.white.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func controls(_ call: CallSession) -> some View {
        if call.state == .ringingIncoming {
            HStack(spacing: big ? 90 : 44) {
                roundAction("Decline", symbol: "phone.down.fill", color: .red) { app.performCallAction(.reject) }
                roundAction("Answer", symbol: "phone.fill", color: .green) { app.performCallAction(.answer) }
            }
        } else {
            HStack(spacing: big ? 18 : 8) {
                toggleAction(call.isMuted ? "Unmute" : "Mute", symbol: call.isMuted ? "mic.slash.fill" : "mic.fill", on: call.isMuted) {
                    app.performCallAction(.toggleMute)
                }
                .disabled(call.state != .active)
                toggleAction("Keypad", symbol: "circle.grid.3x3.fill", on: showKeypad) { showKeypad.toggle() }
                    .disabled(call.state != .active)
                routeButton(call)
                recordButton(call)
            }
            .padding(.bottom, big ? 10 : 0)
            roundAction(app.redial != nil && call.state != .active ? "Stop" : "End", symbol: "phone.down.fill", color: .red) {
                app.performCallAction(.endCall)
            }
        }
    }

    // MARK: Compact

    private func compact(_ call: CallSession) -> some View {
        HStack(spacing: 10) {
            AvatarView(name: call.title, imageData: call.photo, size: 26)
            Circle().fill(app.recorder.isRecording ? .red : (call.state == .active ? .green : .orange)).frame(width: 8, height: 8)
            Text(call.title).font(.callout.weight(.semibold)).lineLimit(1)
            CallTimer(call: call).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Button { app.performCallAction(.endCall) } label: {
                Image(systemName: "phone.down.fill").foregroundStyle(.white).padding(7).background(Circle().fill(.red))
            }
            .buttonStyle(.plain)
            Button { layout = .card } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Show the call controls")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .glassBackground(cornerRadius: 24)
        .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
    }

    // MARK: Expanded

    private func expanded(_ call: CallSession) -> some View {
        VStack(spacing: 18) {
            HStack {
                SimPill(sim: app.sim(call.subscriptionId))
                Spacer()
                if call.state != .ringingIncoming {
                    Button { layout = .bar } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).help("Shrink to a small bar")
                }
                Button { layout = .full } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).help("Show the call full window")
            }

            VStack(spacing: 10) {
                PulsingAvatar(name: call.title, imageData: call.photo, size: 84, active: call.state == .ringingIncoming || call.state == .dialingOutgoing)
                Text(call.title).font(.system(size: 22, weight: .semibold, design: .rounded))
                Group {
                    switch call.state {
                    case .ringingIncoming: Text("Incoming call…")
                    case .dialingOutgoing: Text("Calling…")
                    case .holding: Text("On hold")
                    case .active: CallTimer(call: call)
                    case .disconnected: Text("Call ended")
                    }
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
                .transaction { $0.animation = nil }
                if call.contactName != nil {
                    Text(PhoneNumber.pretty(call.remoteAddress)).font(.caption).foregroundStyle(.white.opacity(0.55))
                }
            }

            if showKeypad && call.state == .active { keypad.transition(.scale(scale: 0.9).combined(with: .opacity)) }

            controls(call)

            if call.state == .active || call.state == .dialingOutgoing {
                Label(call.audioOnMac ? app.audio.status.label : "Audio stays on the phone",
                      systemImage: call.audioOnMac ? "headphones" : "iphone.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .padding(22)
        .frame(width: 320)
        .background {
            ZStack {
                Color(white: 0.09)
                LinearGradient(colors: [(app.sim(call.subscriptionId)?.color ?? .accentColor).opacity(0.55), .clear],
                               startPoint: .top, endPoint: .center)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
        .environment(\.colorScheme, .dark)
        .onChange(of: call.id) { dtmf = ""; showKeypad = false }
    }

    /// Mac ↔ Phone Speaker ↔ Phone Earpiece (spec §5.3.7). Click cycles, the menu jumps directly.
    private func routeButton(_ call: CallSession) -> some View {
        let routes = AudioRoute.selectable
        let current = routes.contains(call.audioRoute) ? call.audioRoute : .mac
        let next = routes[(routes.firstIndex(of: current)! + 1) % routes.count]
        return toggleAction("On \(current.label)", symbol: current.symbol, on: current == .mac) {
            app.setAudioRoute(next)
        }
        .contextMenu {
            ForEach(routes, id: \.self) { r in
                Button("Audio on \(r.label)", systemImage: r.symbol) { app.setAudioRoute(r) }
            }
        }
        .help("Audio: \(current.label). Click for \(next.label); right-click for all routes.")
    }

    /// Records on the Mac (needs the call audio routed here). Red while recording.
    private func recordButton(_ call: CallSession) -> some View {
        let on = app.recorder.isRecording
        return Button { app.toggleRecording() } label: {
            VStack(spacing: 6) {
                Image(systemName: on ? "stop.fill" : "record.circle")
                    .font(.system(size: big ? 22 : 17, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: big ? 60 : 46, height: big ? 60 : 46)
                    .background(Circle().fill(on ? AnyShapeStyle(.red.gradient) : AnyShapeStyle(.white.opacity(0.14))))
                    .overlay { if on { PulseRing() } }
                    .contentTransition(.symbolEffect(.replace))
                if on, let start = app.recorder.startedAt {
                    TimelineView(.periodic(from: start, by: 1)) { ctx in
                        Text(ctx.date.timeIntervalSince(start).callDuration).font(.caption2.monospacedDigit()).foregroundStyle(.red)
                    }
                } else {
                    Text("Record").font(.caption2).foregroundStyle(.white.opacity(0.75))
                }
            }
            .frame(width: big ? 76 : 62)
        }
        .buttonStyle(.plain)
        .disabled(call.state != .active || (!call.audioOnMac && !on))
        .help(call.audioOnMac ? (on ? "Stop and save the recording" : "Record this call on your Mac")
                              : "Move the call audio to your Mac to record it")
    }

    private func roundAction(_ title: String, symbol: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: big ? 28 : 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: big ? 78 : 60, height: big ? 78 : 60)
                    .background(Circle().fill(color.gradient))
                    .shadow(color: color.opacity(0.5), radius: 10, y: 4)
                Text(title).font(.caption).foregroundStyle(.white.opacity(0.8))
            }
        }
        .buttonStyle(.plain)
    }

    private func toggleAction(_ title: String, symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: big ? 22 : 17, weight: .medium))
                    .foregroundStyle(on ? .black : .white)
                    .frame(width: big ? 60 : 46, height: big ? 60 : 46)
                    .background(Circle().fill(on ? .white : .white.opacity(0.14)))
                    .contentTransition(.symbolEffect(.replace))
                Text(title).font(.caption2).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            }
            .frame(width: big ? 76 : 62)
        }
        .buttonStyle(.plain)
    }
}

struct CallTimer: View {
    var call: CallSession

    var body: some View {
        if let start = call.startedAt {
            TimelineView(.periodic(from: start, by: 1)) { ctx in
                Text(ctx.date.timeIntervalSince(start).callDuration)
            }
        } else {
            Text(call.state == .dialingOutgoing ? "Calling…" : "Ringing…")
        }
    }
}

struct PulsingAvatar: View {
    var name: String
    var imageData: Data? = nil
    var size: CGFloat = 84
    var active: Bool
    @State private var animate = false

    var body: some View {
        ZStack {
            if active {
                ForEach(0..<3) { i in
                    Circle()
                        .stroke(.white.opacity(0.35), lineWidth: 1.5)
                        .frame(width: size, height: size)
                        .scaleEffect(animate ? 1.7 : 1)
                        .opacity(animate ? 0 : 0.8)
                        .animation(.easeOut(duration: 2).repeatForever(autoreverses: false).delay(Double(i) * 0.6), value: animate)
                }
            }
            AvatarView(name: name, imageData: imageData, size: size)
        }
        .frame(height: size * 1.2)
        .onAppear { animate = true }
    }
}

private struct PulseRing: View {
    @State private var on = false
    var body: some View {
        Circle().stroke(.red.opacity(0.7), lineWidth: 2)
            .scaleEffect(on ? 1.35 : 1).opacity(on ? 0 : 0.9)
            .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: on)
            .onAppear { on = true }
    }
}
