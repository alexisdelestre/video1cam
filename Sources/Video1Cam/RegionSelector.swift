import AppKit

/// Full-screen overlay on every display: drag to select a region, or click to pick the window under the cursor.
/// Esc cancels.
@MainActor
final class RegionSelector {
    private var windows: [SelectionWindow] = []
    private var completion: ((CaptureRegion?) -> Void)?
    private var keyMonitor: Any?

    var isActive: Bool { completion != nil }

    func begin(completion: @escaping (CaptureRegion?) -> Void) {
        if isActive { finish(nil) }
        self.completion = completion
        let targets = WindowTargets.current()
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let w = SelectionWindow(screen: screen)
            let v = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size), screen: screen, targets: targets)
            v.onDone = { [weak self] rect in
                guard let self else { return }
                self.finish(rect.map { CaptureRegion(displayID: id, rect: $0) })
            }
            w.contentView = v
            w.makeKeyAndOrderFront(nil)
            windows.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
        if let under = windows.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? windows.first {
            under.makeKey()
        }
        NSCursor.crosshair.push()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.finish(nil); return nil } // Esc
            return e
        }
    }

    private func finish(_ region: CaptureRegion?) {
        guard let completion else { return }
        self.completion = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        NSCursor.pop()
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        completion(region)
    }
}

/// On-screen windows of other apps (global Cocoa coords), front to back.
struct WindowTargets {
    var frames: [NSRect]

    static func current() -> WindowTargets {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let mainHeight = NSScreen.screens.first?.frame.height else { return WindowTargets(frames: []) }
        let me = ProcessInfo.processInfo.processIdentifier
        var frames: [NSRect] = []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != me,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"],
                  w >= 80, h >= 60 else { continue }
            // CG coords: origin top-left of the primary display, y down.
            frames.append(NSRect(x: x, y: mainHeight - y - h, width: w, height: h))
        }
        return WindowTargets(frames: frames)
    }

    func frame(at p: NSPoint) -> NSRect? { frames.first { $0.contains(p) } }
}

final class SelectionWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
    override var canBecomeKey: Bool { true }
}

final class SelectionView: NSView {
    var onDone: ((NSRect?) -> Void)?
    private let screenFrame: NSRect
    private let targets: WindowTargets
    private var dragStart: NSPoint?
    private var selection: NSRect?       // local coords
    private var hovered: NSRect?         // local coords
    private var tracking: NSTrackingArea?

    init(frame: NSRect, screen: NSScreen, targets: WindowTargets) {
        screenFrame = screen.frame
        self.targets = targets
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func toLocal(_ global: NSRect) -> NSRect {
        global.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY).intersection(bounds)
    }

    override func mouseMoved(with event: NSEvent) {
        let global = NSEvent.mouseLocation
        hovered = targets.frame(at: global).map(toLocal)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let s = dragStart else { return }
        var p = convert(event.locationInWindow, from: nil)
        p.x = min(max(p.x, 0), bounds.width)
        p.y = min(max(p.y, 0), bounds.height)
        selection = NSRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
        hovered = nil
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        if let sel = selection, sel.width >= 40, sel.height >= 40 {
            onDone?(NSIntegralRect(sel).offsetBy(dx: screenFrame.minX, dy: screenFrame.minY))
            return
        }
        // Simple click: take the window under the cursor.
        if selection == nil || (selection!.width < 5 && selection!.height < 5), let h = hovered, h.width >= 40, h.height >= 40 {
            onDone?(NSIntegralRect(h).offsetBy(dx: screenFrame.minX, dy: screenFrame.minY))
            return
        }
        selection = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        let highlight = selection ?? hovered
        if let r = highlight {
            NSColor.clear.setFill()
            r.fill(using: .copy)
            let path = NSBezierPath(rect: r.insetBy(dx: -1, dy: -1))
            path.lineWidth = 2
            (selection != nil ? NSColor.systemRed : NSColor.systemBlue).setStroke()
            path.stroke()
            let scale = window?.backingScaleFactor ?? 2
            label(String(format: "%.0f × %.0f pt  (%.0f × %.0f px)", r.width, r.height, r.width * scale, r.height * scale),
                  at: NSPoint(x: r.minX, y: max(4, r.minY - 26)))
        }
        if selection == nil {
            label("Glissez pour sélectionner une zone  •  Cliquez sur une fenêtre pour la capturer  •  Échap pour annuler",
                  at: NSPoint(x: bounds.midX, y: bounds.maxY - 90), centered: true, big: true)
        }
    }

    private func label(_ text: String, at p: NSPoint, centered: Bool = false, big: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: big ? 15 : 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        var origin = p
        if centered { origin.x -= size.width / 2 }
        let bg = NSRect(x: origin.x - 8, y: origin.y - 4, width: size.width + 16, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 6, yRadius: 6).fill()
        s.draw(at: origin)
    }
}
