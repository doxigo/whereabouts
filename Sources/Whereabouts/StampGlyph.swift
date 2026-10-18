import AppKit

/// The menu-bar status glyph: the app icon's entry stamp, holding the verdict.
/// Quiet states are an inked outline; alarms are a solid stamp with the mark knocked out,
/// so a problem always reads heavier than an all-clear. Marks are drawn on the same
/// proportions as the icon (Branding/brand.py), not borrowed from SF Symbols.
enum StampGlyph {
    enum Mark {
        case admitted, refused, leak, blocked, unknown, offline, checking

        var solid: Bool { self == .refused || self == .leak || self == .blocked }

        var label: String {
            switch self {
            case .admitted: "location allowed"
            case .refused: "location not allowed"
            case .leak: "location leak detected"
            case .blocked: "network blocked by the kill switch"
            case .unknown: "location unknown"
            case .offline: "offline"
            case .checking: "checking location"
            }
        }
    }

    private static let frame = NSRect(x: 2, y: 2, width: 17, height: 12)

    /// `color` nil gives a template image that follows the menu bar's appearance.
    static func image(_ mark: Mark, color: NSColor?) -> NSImage {
        let image = NSImage(size: NSSize(width: 21, height: 16), flipped: false) { bounds in
            let ink = color ?? .black
            // The icon's -7° tilt (AppKit is y-up, so it rotates the other way).
            let tilt = NSAffineTransform()
            tilt.translateX(by: bounds.midX, yBy: bounds.midY)
            tilt.rotate(byDegrees: 7)
            tilt.translateX(by: -bounds.midX, yBy: -bounds.midY)
            tilt.concat()

            let stamp = NSBezierPath(roundedRect: frame.insetBy(dx: 0.8, dy: 0.8), xRadius: 3, yRadius: 3)
            stamp.lineWidth = 1.6
            if mark == .offline { stamp.setLineDash([2.4, 1.6], count: 2, phase: 0) }
            // A check in progress is a half-inked stamp.
            (mark == .checking ? ink.withAlphaComponent(0.45) : ink).set()
            if mark.solid { stamp.fill() } else { stamp.stroke() }

            // Alarm marks are cut out of the solid stamp; calm marks are inked.
            if mark.solid { NSGraphicsContext.current?.compositingOperation = .destinationOut }
            draw(mark)
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            return true
        }
        image.isTemplate = color == nil
        image.accessibilityDescription = "Whereabouts: \(mark.label)"
        return image
    }

    private static func draw(_ mark: Mark) {
        let cx = frame.midX, cy = frame.midY
        switch mark {
        case .admitted:  // the brand mark: an entry arrow arriving at a point
            let thick = frame.height * 0.17, dot = frame.height * 0.15
            let x0 = frame.minX + frame.width * 0.17, x1 = frame.maxX - frame.width * 0.15
            let tip = x1 - dot * 2 - frame.height * 0.06, shaftEnd = tip - thick * 1.65
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: x0, y: cy - thick / 2))
            arrow.line(to: NSPoint(x: shaftEnd, y: cy - thick / 2))
            arrow.line(to: NSPoint(x: shaftEnd, y: cy - thick * 1.3))
            arrow.line(to: NSPoint(x: tip, y: cy))
            arrow.line(to: NSPoint(x: shaftEnd, y: cy + thick * 1.3))
            arrow.line(to: NSPoint(x: shaftEnd, y: cy + thick / 2))
            arrow.line(to: NSPoint(x: x0, y: cy + thick / 2))
            arrow.close()
            arrow.fill()
            NSBezierPath(ovalIn: NSRect(x: x1 - dot * 2, y: cy - dot, width: dot * 2, height: dot * 2)).fill()
        case .refused:  // "!"
            NSBezierPath(rect: NSRect(x: cx - 1.05, y: 7.3, width: 2.1, height: 4.3)).fill()
            NSBezierPath(ovalIn: NSRect(x: cx - 1.1, y: 4.3, width: 2.2, height: 2.2)).fill()
        case .leak:  // a drop: location escaping by another route
            let drop = NSBezierPath()
            drop.move(to: NSPoint(x: cx, y: 11.8))
            drop.line(to: NSPoint(x: cx + 2.06, y: 7.62))
            drop.appendArc(withCenter: NSPoint(x: cx, y: 6.6), radius: 2.3, startAngle: 26.2, endAngle: 153.8, clockwise: true)
            drop.close()
            drop.fill()
        case .blocked:  // "×"
            let cross = NSBezierPath()
            cross.move(to: NSPoint(x: cx - 2.5, y: cy - 2.5)); cross.line(to: NSPoint(x: cx + 2.5, y: cy + 2.5))
            cross.move(to: NSPoint(x: cx - 2.5, y: cy + 2.5)); cross.line(to: NSPoint(x: cx + 2.5, y: cy - 2.5))
            cross.lineWidth = 2.1
            cross.stroke()
        case .unknown:  // "?"
            let hook = NSBezierPath()
            hook.appendArc(withCenter: NSPoint(x: cx, y: 9.2), radius: 1.8, startAngle: 165, endAngle: -30, clockwise: true)
            hook.line(to: NSPoint(x: cx, y: 7.3))
            hook.line(to: NSPoint(x: cx, y: 6.6))
            hook.lineWidth = 1.6
            hook.stroke()
            NSBezierPath(ovalIn: NSRect(x: cx - 0.9, y: 4.1, width: 1.8, height: 1.8)).fill()
        case .offline, .checking:  // an empty stamp: nothing to attest yet
            break
        }
    }
}
