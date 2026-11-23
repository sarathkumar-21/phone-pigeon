import AppKit
import AVKit

/// Plays a phone video in its own AppKit window (AVPlayerView, native transport controls).
///
/// Deliberately not hosted inside SwiftUI: on current macOS builds, hosting an AVKit
/// view via `NSViewRepresentable` aborts in `_AVKit_SwiftUI` metadata initialisation.
@MainActor
final class VideoWindowController: NSObject, NSWindowDelegate {
    private static var open: [ObjectIdentifier: VideoWindowController] = [:]

    private let window: NSWindow
    private let player: AVPlayer

    static func show(title: String, subtitle: String, item: AVPlayerItem) {
        let c = VideoWindowController(title: title, subtitle: subtitle, item: item)
        open[ObjectIdentifier(c)] = c
        c.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        c.player.play()
    }

    private init(title: String, subtitle: String, item: AVPlayerItem) {
        player = AVPlayer(playerItem: item)
        let view = AVPlayerView(frame: NSRect(x: 0, y: 0, width: 960, height: 600))
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.contentView = view
        window.title = title
        window.subtitle = subtitle
        window.isReleasedWhenClosed = false
        window.center()
        super.init()
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        player.pause()
        player.replaceCurrentItem(with: nil)
        Self.open[ObjectIdentifier(self)] = nil
    }
}
