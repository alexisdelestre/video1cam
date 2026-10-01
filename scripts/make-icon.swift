// Draws the app icon (1024 px PNG). Usage: swift make-icon.swift out.png
import AppKit
let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let bg = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.22, alpha: 1),
           ending: NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.10, alpha: 1))!.draw(in: bg, angle: -90)
// "screen"
NSColor(calibratedWhite: 1, alpha: 0.12).setFill()
NSBezierPath(roundedRect: NSRect(x: 210, y: 330, width: 604, height: 420), xRadius: 40, yRadius: 40).fill()
// record dot
NSColor(calibratedRed: 0.95, green: 0.23, blue: 0.23, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 402, y: 430, width: 220, height: 220)).fill()
// camera bubble
NSColor.white.setFill()
NSBezierPath(ovalIn: NSRect(x: 190, y: 190, width: 250, height: 250)).fill()
NSColor(calibratedRed: 0.30, green: 0.55, blue: 0.95, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 205, y: 205, width: 220, height: 220)).fill()
NSColor.white.setFill()
NSBezierPath(ovalIn: NSRect(x: 275, y: 290, width: 80, height: 80)).fill()
NSBezierPath(roundedRect: NSRect(x: 245, y: 215, width: 140, height: 80), xRadius: 40, yRadius: 40).fill()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
