import AppKit

/// Gera o ícone da barra: símbolo SF + bolinha de saúde colorida.
/// A imagem é não-template (para a cor da bolinha aparecer); o símbolo é pintado
/// com `labelColor`, resolvido na hora do desenho, então acompanha barra clara/escura.
@MainActor
enum StatusIcon {
    private static var cache: [Health: NSImage] = [:]

    static func image(for health: Health) -> NSImage {
        if let cached = cache[health] { return cached }
        let img = make(health)
        cache[health] = img
        return img
    }

    private static func make(_ health: Health) -> NSImage {
        let size = NSSize(width: 22, height: 18)
        let dotColor = health.nsColor
        let img = NSImage(size: size, flipped: false) { rect in
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                .applying(.init(paletteColors: [NSColor.labelColor]))
            guard let symbol = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return false }

            let s = symbol.size
            let symbolRect = NSRect(x: 1, y: (rect.height - s.height) / 2, width: s.width, height: s.height)

            // Ponto no canto inferior direito, com "anel" recortado no símbolo.
            let d: CGFloat = 7
            let ring: CGFloat = 1.6
            let dotRect = NSRect(x: rect.width - d - 0.5, y: 1, width: d, height: d)
            let cutRect = dotRect.insetBy(dx: -ring, dy: -ring)

            NSGraphicsContext.current?.saveGraphicsState()
            let clip = NSBezierPath(rect: rect)
            clip.appendOval(in: cutRect)
            clip.windingRule = .evenOdd
            clip.addClip()
            symbol.draw(in: symbolRect)
            NSGraphicsContext.current?.restoreGraphicsState()

            dotColor.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        img.isTemplate = false
        img.accessibilityDescription = "BGBar"
        return img
    }
}
