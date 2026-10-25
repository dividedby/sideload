import AppKit
import SideloadCore

/// The menu bar icon: the countdown ring (design section 12), a port of the owner's 16x16 SVG paths. An 18 pt drawn
/// image, so it is crisp at @2x; the handler runs at every draw and resolves `labelColor` for the appearance it is drawn
/// in, so the monochrome parts follow the menu bar. Not a template image: it carries system orange, red and blue.
@MainActor
enum StatusIcon {
    nonisolated static let side: CGFloat = 18

    static func image(for icon: MenuIcon) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            draw(icon)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = icon.accessibilityLabel
        return image
    }

    // The SVG viewBox is 16 units; the badge reaches 16.2, so the box is drawn at 1.1x and centred in 18 pt.
    nonisolated private static let scale: CGFloat = 1.1
    nonisolated private static let circumference = 2 * Double.pi * 6

    /// Draws into the current graphics context, an 18 x 18 pt box with the origin at the bottom left.
    nonisolated static func draw(_ icon: MenuIcon) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NSAppearance.currentDrawing().performAsCurrentDrawingAppearance {
            let label = NSColor.labelColor.cgColor
            let faint = NSColor.labelColor.withAlphaComponent(0.22).cgColor
            let orange = NSColor.systemOrange.cgColor
            let red = NSColor.systemRed.cgColor
            let blue = NSColor.systemBlue.cgColor
            let grey = NSColor.systemGray.cgColor

            context.saveGState()
            defer { context.restoreGState() }
            // SVG space: y down, 16 units wide.
            let inset = (side - 16 * scale) / 2
            context.translateBy(x: inset, y: side - inset)
            context.scaleBy(x: scale, y: -scale)
            context.setLineCap(.round)
            context.setLineJoin(.round)

            func ring(_ colour: CGColor, from start: Double = -90, sweep: Double = 360, dash: [CGFloat] = []) {
                context.saveGState()
                context.setStrokeColor(colour)
                context.setLineWidth(2)
                context.setLineDash(phase: 0, lengths: dash)
                // In y-down space an increasing angle runs clockwise on screen.
                context.addArc(
                    center: CGPoint(x: 8, y: 8), radius: 6, startAngle: start * .pi / 180,
                    endAngle: (start + sweep) * .pi / 180, clockwise: false)
                context.strokePath()
                context.restoreGState()
            }
            func stroke(_ colour: CGColor, _ width: CGFloat, _ build: (CGMutablePath) -> Void) {
                let path = CGMutablePath()
                build(path)
                context.saveGState()
                context.setStrokeColor(colour)
                context.setLineWidth(width)
                context.addPath(path)
                context.strokePath()
                context.restoreGState()
            }
            func arrow(_ colour: CGColor) {
                stroke(colour, 1.3) { p in
                    p.move(to: CGPoint(x: 8, y: 5.2))
                    p.addLine(to: CGPoint(x: 8, y: 9.8))
                    p.move(to: CGPoint(x: 6.2, y: 8.2))
                    p.addLine(to: CGPoint(x: 8, y: 10))
                    p.addLine(to: CGPoint(x: 9.8, y: 8.2))
                }
            }
            func cross(_ colour: CGColor, _ width: CGFloat, _ x0: CGFloat, _ y0: CGFloat, _ size: CGFloat) {
                stroke(colour, width) { p in
                    p.move(to: CGPoint(x: x0, y: y0))
                    p.addLine(to: CGPoint(x: x0 + size, y: y0 + size))
                    p.move(to: CGPoint(x: x0 + size, y: y0))
                    p.addLine(to: CGPoint(x: x0, y: y0 + size))
                }
            }
            func dot(_ colour: CGColor, _ width: CGFloat, _ x: CGFloat, _ y: CGFloat) {
                // "v.01" with a round cap: a dot.
                stroke(colour, width) { p in
                    p.move(to: CGPoint(x: x, y: y))
                    p.addLine(to: CGPoint(x: x, y: y + 0.01))
                }
            }
            /// A stroke-width-2 track plus the remaining arc from 12 o'clock, clockwise.
            func countdown(_ colour: CGColor) {
                ring(faint)
                if icon.fraction >= 1 {
                    ring(colour)
                } else if icon.fraction > 0 {
                    ring(colour, sweep: 360 * icon.fraction)
                }
            }

            switch icon.state {
            case .ok:
                countdown(label)
                arrow(label)
            case .due:
                countdown(orange)
                arrow(label)
            case .critical:
                countdown(red)
                arrow(red)
            case .expired:
                ring(red, dash: [1.6, 2.2])
                cross(red, 1.5, 6, 6, 4)
            case .renewing:
                ring(faint)
                ring(blue, from: -20, sweep: 360 * 24 / circumference)
                arrow(blue)
            case .renewFailed:
                countdown(icon.ringIsDue ? orange : label)
                arrow(label)
                // A cut-out the size of the badge's halo, then the badge.
                context.saveGState()
                context.setBlendMode(.clear)
                context.fillEllipse(in: CGRect(x: 12.6 - 3.6, y: 12.6 - 3.6, width: 7.2, height: 7.2))
                context.restoreGState()
                context.setFillColor(red)
                context.fillEllipse(in: CGRect(x: 12.6 - 2.8, y: 12.6 - 2.8, width: 5.6, height: 5.6))
                cross(NSColor.white.cgColor, 0.9, 11.6, 11.6, 2)
            case .certChanged:
                ring(red)
                stroke(red, 1.7) { p in
                    p.move(to: CGPoint(x: 8, y: 4.8))
                    p.addLine(to: CGPoint(x: 8, y: 9))
                }
                dot(red, 1.9, 8, 11.4)
            case .unknown:
                ring(grey, dash: [1.6, 2.2])
                stroke(grey, 1.3) { p in
                    // "M6.4 6.4a1.6 1.6 0 1 1 2.3 1.4c-.5.3-.7.6-.7 1.1": the hook is a 245 degree arc about (8, 6.36).
                    let centre = CGPoint(x: 8, y: 6.362)
                    p.addArc(
                        center: centre, radius: 1.6, startAngle: 178.6 * .pi / 180, endAngle: 424 * .pi / 180,
                        clockwise: false)
                    p.addCurve(
                        to: CGPoint(x: 8, y: 8.9), control1: CGPoint(x: 8.2, y: 8.1), control2: CGPoint(x: 8, y: 8.4))
                }
                dot(grey, 1.5, 8, 11)
            }
        }
    }
}
