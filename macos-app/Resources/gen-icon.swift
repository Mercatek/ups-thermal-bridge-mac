// Renders a 1024×1024 app icon PNG: a thermal printer with a label (barcode)
// emerging, on a navy squircle with gold accents (Velites palette).
// No UPS branding (trademark-safe).  Usage: swift gen-icon.swift out.png

import AppKit

let S = 1024.0
let navy   = NSColor(red: 0.05, green: 0.17, blue: 0.30, alpha: 1)
let navyHi = NSColor(red: 0.09, green: 0.24, blue: 0.40, alpha: 1)
let gold   = NSColor(red: 0.82, green: 0.68, blue: 0.32, alpha: 1)
let paper  = NSColor(white: 0.98, alpha: 1)
let bodyC  = NSColor(white: 0.93, alpha: 1)
let bodyHi = NSColor(white: 1.00, alpha: 1)

func rr(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}

let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()

// background squircle with vertical gradient
let inset = 80.0
let bgRect = NSRect(x: inset, y: inset, width: S - 2*inset, height: S - 2*inset)
NSGraphicsContext.saveGraphicsState()
rr(inset, inset, S - 2*inset, S - 2*inset, 205).addClip()
NSGradient(starting: navyHi, ending: navy)!.draw(in: bgRect, angle: -90)
NSGraphicsContext.restoreGraphicsState()

// label (white sheet) emerging upward, with a barcode + address lines
let labelX = 360.0, labelW = 304.0
rr(labelX, 452, labelW, 320, 18).fill_(paper)
// barcode
navy.setFill()
var bx = labelX + 34
let widths = [10.0,5,14,7,5,12,16,7,9,5,13,7,18,5,9,6,11]
for w in widths {
    if bx + w > labelX + labelW - 28 { break }
    NSBezierPath(rect: NSRect(x: bx, y: 690, width: w, height: 56)).fill()
    bx += w + 8
}
// address lines
let gray = NSColor(white: 0.78, alpha: 1)
for (i, w) in [232.0, 188.0, 150.0].enumerated() {
    rr(labelX + 34, 648 - Double(i) * 36, w, 16, 8).fill_(gray)
}

// printer body (in front, covering the label's lower edge → paper "emerging")
rr(296, 286, 432, 226, 44).fill_(bodyC)
rr(296, 286, 432, 226, 44).stroke_(navy.withAlphaComponent(0.12), 6)
// top highlight
rr(296, 470, 432, 42, 44).fill_(bodyHi.withAlphaComponent(0.9))
// intake slot (dark)
rr(336, 486, 352, 18, 9).fill_(navy)
// gold control strip + status light
rr(420, 350, 250, 26, 13).fill_(gold)
NSBezierPath(ovalIn: NSRect(x: 344, y: 346, width: 38, height: 38)).fill_(gold)

img.unlockFocus()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")

extension NSBezierPath {
    func fill_(_ c: NSColor) { c.setFill(); self.fill() }
    func stroke_(_ c: NSColor, _ w: Double) { c.setStroke(); self.lineWidth = w; self.stroke() }
}
