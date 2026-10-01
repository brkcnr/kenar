import AppKit
import Foundation

let folder = URL(fileURLWithPath: CommandLine.arguments[1],isDirectory: true)
try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
for logical in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels=logical*scale
        let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let context=NSGraphicsContext(bitmapImageRep:rep)!
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
        context.cgContext.scaleBy(x:CGFloat(pixels)/1024,y:CGFloat(pixels)/1024)
        let shape=NSBezierPath(roundedRect:NSRect(x:64,y:64,width:896,height:896),xRadius:210,yRadius:210)
        NSGradient(starting:NSColor(red:0.08,green:0.15,blue:0.2,alpha:1),ending:NSColor(red:0.13,green:0.27,blue:0.34,alpha:1))!.draw(in:shape,angle:60)
        NSColor(red:0.43,green:0.83,blue:0.82,alpha:1).setFill()
        NSBezierPath(roundedRect:NSRect(x:794,y:220,width:62,height:584),xRadius:31,yRadius:31).fill()
        let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:590,weight:.semibold),.foregroundColor:NSColor.white]
        ("K" as NSString).draw(at:NSPoint(x:178,y:154),withAttributes:attrs)
        NSGraphicsContext.restoreGraphicsState()
        let name="icon_\(logical)x\(logical)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent(name))
    }
}
