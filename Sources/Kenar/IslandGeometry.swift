import AppKit
import SwiftUI

/// The neck curves into the display boundary; there is no detached capsule.
/// Use the same outline for compact and expanded states on either side.
struct EdgeIslandShape: Shape {
    var edge: PanelEdge
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let neck = min(18, h / 6)
        let radius = min(24, w / 2, (h - neck * 2) / 2)
        let shoulder = min(28, w / 2)
        var p = Path()
        p.move(to: CGPoint(x: w, y: 0))
        p.addCurve(to: CGPoint(x: w - shoulder, y: neck), control1: CGPoint(x: w, y: neck), control2: CGPoint(x: w - shoulder/2, y: neck))
        p.addLine(to: CGPoint(x: radius, y: neck))
        p.addQuadCurve(to: CGPoint(x: 0, y: neck + radius), control: CGPoint(x: 0, y: neck))
        p.addLine(to: CGPoint(x: 0, y: h - neck - radius))
        p.addQuadCurve(to: CGPoint(x: radius, y: h - neck), control: CGPoint(x: 0, y: h - neck))
        p.addLine(to: CGPoint(x: w - shoulder, y: h - neck))
        p.addCurve(to: CGPoint(x: w, y: h), control1: CGPoint(x: w - shoulder/2, y: h - neck), control2: CGPoint(x: w, y: h - neck))
        p.closeSubpath()
        let transform: CGAffineTransform
        switch edge {
        case .right: transform = .identity
        case .left: transform = CGAffineTransform(a: -1,b: 0,c: 0,d: 1,tx: rect.width,ty: 0)
        }
        return p.applying(transform).offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

struct IslandMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow; view.blendingMode = .behindWindow; view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct ProviderGlyph: View {
    let id: String
    var size: CGFloat = 18
    private static let images: [String: NSImage] = {
        var images: [String: NSImage] = [:]
        for name in ["claude","openai","cursor"] {
            if let url = L10n.resources.url(forResource:name,withExtension:"png"),let image = NSImage(contentsOf:url) {
                image.isTemplate = true; images[name] = image
            }
        }
        return images
    }()
    var body: some View {
        Group {
            if id == "gemini" || id == "antigravity" {
                GeminiSparkle().fill(.primary)
            } else if let image = Self.images[id == "codex" ? "openai" : id] {
                Image(nsImage:image)
                    .resizable().renderingMode(.template).scaledToFit()
                    .scaleEffect(id == "cursor" ? 1.65 : 1)
            } else {
                Image(systemName:"circle.dotted").resizable().scaledToFit()
            }
        }.frame(width: size,height: size).accessibilityHidden(true)
    }
}

struct GeminiSparkle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX,y: rect.midY)
        p.move(to: CGPoint(x: c.x,y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX,y: c.y), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x,y: rect.maxY), control: c)
        p.addQuadCurve(to: CGPoint(x: rect.minX,y: c.y), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x,y: rect.minY), control: c)
        p.closeSubpath()
        return p
    }
}
