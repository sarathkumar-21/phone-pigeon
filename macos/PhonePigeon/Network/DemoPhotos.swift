import AppKit

/// Generated profile pictures for the demo phone's contacts (emoji portraits on a soft gradient), so the demo shows
/// what a contact photo looks like on the call screen without shipping real people's pictures.
enum DemoPhotos {
    private static let faces: [String: String] = [
        "Ananya Rao": "👩🏽‍💻", "Rahul Menon": "🧑🏻‍💻", "Mom": "👵🏾", "Priya Sharma": "👩🏻‍🦰", "Arjun Nair": "🧑🏽",
        "Dr. Meera Iyer": "👩🏽‍⚕️", "Kabir Singh": "👨🏽‍🦱", "Sara Thomas": "👩🏼",
    ]

    static func has(_ name: String) -> Bool { faces[name] != nil }

    static func portrait(for name: String, size: Int) -> Data? {
        guard let face = faces[name] else { return nil }
        let palette = Theme.palette(for: name).map { NSColor($0) }
        let s = CGFloat(size)
        let image = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
            NSGradient(colors: palette)?.draw(in: rect, angle: 315)
            NSGradient(colors: [NSColor.white.withAlphaComponent(0.35), .clear])?
                .draw(fromCenter: NSPoint(x: s * 0.3, y: s * 0.75), radius: 0, toCenter: NSPoint(x: s * 0.3, y: s * 0.75), radius: s * 0.8, options: [])
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: s * 0.62)]
            let text = NSAttributedString(string: face, attributes: attrs)
            let box = text.size()
            text.draw(at: NSPoint(x: (s - box.width) / 2, y: (s - box.height) / 2 - s * 0.02))
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
