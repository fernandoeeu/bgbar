import AppKit

/// Gera o ícone da barra: símbolo SF + bolinha de saúde colorida.
/// A imagem é não-template (para a cor da bolinha aparecer); o símbolo é pintado
/// com `labelColor`, resolvido na hora do desenho, então acompanha barra clara/escura.
@MainActor
enum StatusIcon {
    private struct Key: Hashable { let health: Health; let count: Int }
    private static var cache: [Key: NSImage] = [:]

    /// `count > 0` desenha o número (agentes Claude rodando) à direita do ícone, na mesma
    /// imagem: o rótulo do `MenuBarExtra` não compõe bem um HStack de imagem + texto.
    static func image(for health: Health, count: Int = 0) -> NSImage {
        let key = Key(health: health, count: max(0, count))
        if let cached = cache[key] { return cached }
        let img = make(health, count: key.count)
        cache[key] = img
        return img
    }

    private static func make(_ health: Health, count: Int) -> NSImage {
        let iconWidth: CGFloat = 22
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let text = count > 0 ? String(count) : ""
        let textWidth = text.isEmpty ? 0 : ceil((text as NSString).size(withAttributes: [.font: font]).width)
        let size = NSSize(width: iconWidth + (text.isEmpty ? 0 : 3 + textWidth), height: 18)
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
            let dotRect = NSRect(x: iconWidth - d - 0.5, y: 1, width: d, height: d)
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

            if !text.isEmpty {
                // labelColor resolvido no desenho: acompanha barra clara/escura.
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
                let h = (text as NSString).size(withAttributes: attrs).height
                (text as NSString).draw(at: NSPoint(x: iconWidth + 3, y: (rect.height - h) / 2), withAttributes: attrs)
            }
            return true
        }
        img.isTemplate = false
        img.accessibilityDescription = count > 0 ? "BGBar, \(count) agentes Claude rodando" : "BGBar"
        return img
    }
}
