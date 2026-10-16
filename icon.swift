// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors

import AppKit
let folder = URL(fileURLWithPath: CommandLine.arguments[1]); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16,32,64,128,256,512,1024] {
 let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
 NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
 let s = CGFloat(size)
 let inset = s * 0.06
 let path = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s-2*inset, height: s-2*inset), xRadius: s*0.2, yRadius: s*0.2)
 NSGradient(starting: NSColor(red: 0.02, green: 0.68, blue: 0.66, alpha: 1), ending: NSColor(red: 0.03, green: 0.32, blue: 0.47, alpha: 1))!.draw(in: path, angle: -75)
 // Original folded-paper artwork. No SF Symbols glyph is embedded in the app icon.
 func polygon(_ points: [(CGFloat, CGFloat)], color: NSColor) {
  let shape = NSBezierPath(); shape.move(to: NSPoint(x: points[0].0*s, y: points[0].1*s))
  for point in points.dropFirst() { shape.line(to: NSPoint(x: point.0*s, y: point.1*s)) }
  shape.close(); color.setFill(); shape.fill()
 }
 NSGraphicsContext.saveGraphicsState()
 let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.20); shadow.shadowBlurRadius = s*0.04; shadow.shadowOffset = NSSize(width: 0, height: -s*0.025); shadow.set()
 polygon([(0.18,0.67),(0.83,0.62),(0.51,0.24),(0.45,0.46)], color: .white)
 NSGraphicsContext.restoreGraphicsState()
 polygon([(0.18,0.67),(0.83,0.62),(0.45,0.46)], color: .white)
 polygon([(0.45,0.46),(0.83,0.62),(0.51,0.24)], color: NSColor(red:0.70,green:0.93,blue:0.96,alpha:1))
 polygon([(0.45,0.46),(0.83,0.62),(0.57,0.40)], color: NSColor(red:0.42,green:0.80,blue:0.86,alpha:1))
 let trail = NSBezierPath(); trail.lineWidth = s*0.018; trail.lineCapStyle = .round
 trail.move(to: NSPoint(x:s*0.18,y:s*0.29));trail.curve(to:NSPoint(x:s*0.36,y:s*0.40),controlPoint1:NSPoint(x:s*0.10,y:s*0.46),controlPoint2:NSPoint(x:s*0.27,y:s*0.46))
 let dashes:[CGFloat] = [s*0.025,s*0.04];trail.setLineDash(dashes,count:2,phase:0)
 NSColor.white.withAlphaComponent(0.65).setStroke();trail.stroke()
 NSGraphicsContext.restoreGraphicsState()
 let data=bitmap.representation(using:.png,properties:[:])!
 for (base,scale) in [(size,1),(size/2,2)] where base>=16 && base<=512 {try data.write(to:folder.appendingPathComponent("icon_\(base)x\(base)\(scale==2 ? "@2x" : "").png"))}
}
