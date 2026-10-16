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
 let arrows = NSBezierPath(); arrows.lineWidth = s*0.065; arrows.lineCapStyle = .round; arrows.lineJoinStyle = .round
 arrows.move(to: NSPoint(x:s*0.36,y:s*0.30)); arrows.line(to:NSPoint(x:s*0.36,y:s*0.69)); arrows.move(to:NSPoint(x:s*0.24,y:s*0.57)); arrows.line(to:NSPoint(x:s*0.36,y:s*0.69)); arrows.line(to:NSPoint(x:s*0.48,y:s*0.57))
 arrows.move(to:NSPoint(x:s*0.64,y:s*0.70));arrows.line(to:NSPoint(x:s*0.64,y:s*0.31));arrows.move(to:NSPoint(x:s*0.52,y:s*0.43));arrows.line(to:NSPoint(x:s*0.64,y:s*0.31));arrows.line(to:NSPoint(x:s*0.76,y:s*0.43));NSColor.white.setStroke();arrows.stroke()
 NSGraphicsContext.restoreGraphicsState()
 let data=bitmap.representation(using:.png,properties:[:])!
 for (base,scale) in [(size,1),(size/2,2)] where base>=16 && base<=512 {try data.write(to:folder.appendingPathComponent("icon_\(base)x\(base)\(scale==2 ? "@2x" : "").png"))}
}
