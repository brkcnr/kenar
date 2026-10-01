import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Renders Kenar's actual views with labeled sample data. No screen recording,
/// account requests, or local transcript reads are involved.
@MainActor final class DemoCaption: ObservableObject {
    @Published var step = "Hover to expand"
}

struct DemoDesktop: View {
    @ObservedObject var caption: DemoCaption
    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.075, green: 0.11, blue: 0.17), Color(red: 0.025, green: 0.04, blue: 0.075)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 12) {
                Text("Kenar").font(.system(size: 25, weight: .semibold))
                Text("macOS usage monitor").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(caption.step).font(.system(size: 12, weight: .medium)).padding(.top, 16)
                Spacer()
                Text("Native SwiftUI preview\nSample data").font(.system(size: 9)).foregroundStyle(.secondary)
            }.padding(28).frame(width: 216, height: 560, alignment: .topLeading)
        }.environment(\.colorScheme, .dark)
    }
}

/// A vector pointer for the offscreen renderer, where NSCursor has no image.
final class DemoPointer: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 2, y: 24))
        for point in [NSPoint(x: 2, y: 5), NSPoint(x: 7, y: 10),
                      NSPoint(x: 11, y: 2), NSPoint(x: 15, y: 4),
                      NSPoint(x: 11, y: 12), NSPoint(x: 18, y: 12)] {
            path.line(to: point)
        }
        path.close()
        NSColor.white.setFill(); path.fill()
        NSColor.black.setStroke(); path.lineWidth = 1; path.stroke()
    }
}

@main struct RenderDemo {
    @MainActor static func main() throws {
        guard Preview.isEnabled else { fatalError("Run with KENAR_PREVIEW=1") }
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)
        L10n.override = "en"
        let domain = "Kenar.Demo.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = Settings(defaults: defaults)
        settings.values = Preferences(); settings.values.theme = .dark
        settings.values.language = .english
        let store = UsageStore(providers: [], analytics: nil)
        store.snapshots = Preview.snapshots
        let state = PanelState(), caption = DemoCaption()
        let canvasSize = NSSize(width: 520, height: 560)
        let canvas = NSView(frame: NSRect(origin: .zero, size: canvasSize))
        let desktop = NSHostingView(rootView: DemoDesktop(caption: caption))
        desktop.frame = canvas.bounds; canvas.addSubview(desktop)
        let panel = NSHostingView(rootView: PanelView(store: store, settings: settings, state: state,
            openSettings: {}, openAnalytics: { _ in }, close: {}))
        func frame(_ size: NSSize) -> NSRect {
            DisplayGeometry.frame(edge: .right, visible: canvas.bounds, size: size, expanded: true)
        }
        let compact = frame(NSSize(width: 66, height: 228))
        let expanded = frame(NSSize(width: 300, height: 364))
        let detailed = frame(NSSize(width: 300, height: 522))
        panel.frame = compact; canvas.addSubview(panel)
        let cursor = DemoPointer(frame: NSRect(x: 375, y: 136, width: 20, height: 26))
        canvas.addSubview(cursor)
        let window = NSWindow(contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = canvas; window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = true; window.backgroundColor = NSColor.black
        // Keep the window offscreen: this renders the native view hierarchy only.
        canvas.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        var frames: [(CGImage, Double)] = []
        let scale: CGFloat = 1.5
        func capture(_ duration: Double, settle: Double = 0.04) {
            canvas.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(settle))
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(canvasSize.width * scale), pixelsHigh: Int(canvasSize.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = canvasSize
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            frames.append((rep.cgImage!, duration))
        }
        func pointer(_ point: CGPoint, steps: Int = 7) {
            let start = cursor.frame.origin
            for step in 1...steps {
                let t = Double(step) / Double(steps), eased = t*t*(3-2*t)
                cursor.setFrameOrigin(CGPoint(x: start.x+(point.x-start.x)*eased, y: start.y+(point.y-start.y)*eased))
                capture(0.04)
            }
        }
        func resize(_ target: NSRect) {
            let start = panel.frame
            let steps = Int(PanelInteraction.motionDuration / 0.04)
            for step in 1...steps {
                let t = Double(step) / Double(steps), eased = t*t*(3-2*t)
                panel.frame = NSRect(x: start.minX+(target.minX-start.minX)*eased,
                    y: start.minY+(target.minY-start.minY)*eased,
                    width: start.width+(target.width-start.width)*eased,
                    height: start.height+(target.height-start.height)*eased)
                capture(0.04)
            }
        }
        capture(1.0)
        pointer(CGPoint(x: 492, y: 280)); capture(PanelInteraction.pollInterval)
        state.expanded = true; resize(expanded); capture(1.4, settle: 0.2)
        caption.step = "Click a provider"
        pointer(CGPoint(x: 352, y: 306)); capture(0.25)
        state.selected = "claude"; resize(detailed)
        caption.step = "Inspect quota windows"; capture(2.0, settle: 0.2)
        caption.step = "Move away to collapse"
        pointer(CGPoint(x: 170, y: 154)); capture(PanelInteraction.pollInterval)
        state.selected = nil; state.expanded = false; resize(compact)
        capture(0.8, settle: 0.2)
        caption.step = "Hover to expand"
        pointer(CGPoint(x: 375, y: 136)); capture(0.5)

        let destinationURL = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, UTType.gif.identifier as CFString, frames.count, nil)!
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (frame, duration) in frames {
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: duration]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { fatalError("GIF encoding failed") }
        // Save representative frames beside the scratch path for visual inspection.
        for (name, index) in [("compact", 0), ("expanded", 15), ("detail", 30)] {
            let url = destinationURL.deletingLastPathComponent().appendingPathComponent("demo-\(name).png")
            let png = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(png, frames[min(index, frames.count-1)].0, nil)
            CGImageDestinationFinalize(png)
        }
        print("Rendered \(frames.count) native frames, \(String(format: "%.2f", frames.map(\.1).reduce(0,+))) seconds, 780×840 pixels")
        print(destinationURL.path)
    }
}
