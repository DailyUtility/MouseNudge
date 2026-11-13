// Builds the app icon from the Mac's own Mouse settings icon, at every size an .iconset needs.
import Cocoa
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let src = NSWorkspace.shared.icon(forFile: "/System/Library/ExtensionKit/Extensions/MouseExtension.appex")
func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    src.draw(in: NSRect(x: 0, y: 0, width: px, height: px)); NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for b in [16, 32, 128, 256, 512] {
    try! render(b).write(to: URL(fileURLWithPath: "\(out)/icon_\(b)x\(b).png"))
    try! render(b * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(b)x\(b)@2x.png"))
}
