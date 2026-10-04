import AppKit
import Foundation
import ImageIO

// Convert the committed source image into macOS icon sizes without redrawing
// or replacing the generated artwork. build.sh packages the resulting .icns.
guard CommandLine.arguments.count == 4,
      let image = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
    fputs("Usage: swift Scripts/MakeIcon.swift <source.png> <output.iconset> <output.icns>\n", stderr)
    exit(1)
}
let folder = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for logical in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = logical * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
                   from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(logical)x\(logical)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
    }
}

// PNG-backed ICNS entries preserve each standard and Retina rendition.
// Pack directly so the build does not depend on iconutil being available.
let entries: [(String, String)] = [
    ("icp4", "icon_16x16.png"), ("ic11", "icon_16x16@2x.png"),
    ("icp5", "icon_32x32.png"), ("ic12", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"), ("ic13", "icon_128x128@2x.png"),
    ("ic08", "icon_256x256.png"), ("ic14", "icon_256x256@2x.png"),
    ("ic09", "icon_512x512.png"), ("ic10", "icon_512x512@2x.png")
]
func length(_ value: Int) -> Data {
    var bigEndian = UInt32(value).bigEndian
    return withUnsafeBytes(of: &bigEndian) { Data($0) }
}
var payload = Data()
for (type, file) in entries {
    let png = try Data(contentsOf: folder.appendingPathComponent(file))
    payload.append(Data(type.utf8)); payload.append(length(png.count + 8)); payload.append(png)
}
var family = Data("icns".utf8); family.append(length(payload.count + 8)); family.append(payload)
let output = URL(fileURLWithPath: CommandLine.arguments[3])
try family.write(to: output, options: .atomic)
guard let decoded = CGImageSourceCreateWithURL(output as CFURL, nil), CGImageSourceGetCount(decoded) == 10 else {
    fatalError("macOS could not decode the complete icon family")
}
var sizes = Set<Int>()
for index in 0..<CGImageSourceGetCount(decoded) {
    guard let rendition = CGImageSourceCreateImageAtIndex(decoded, index, nil), rendition.width == rendition.height else {
        fatalError("Invalid icon rendition")
    }
    sizes.insert(rendition.width)
}
guard sizes == Set([16, 32, 64, 128, 256, 512, 1024]) else { fatalError("Missing icon sizes") }
print("Verified 10 macOS icon renditions (16–1024 px)")
