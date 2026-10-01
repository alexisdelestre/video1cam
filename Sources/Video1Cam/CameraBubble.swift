import AppKit
@preconcurrency import AVFoundation

/// Round, draggable, always-on-top webcam preview. It is a real on-screen window,
/// so it gets captured with the screen (like Loom).
@MainActor
final class CameraBubble {
    private let panel: BubblePanel
    private let view: BubbleView
    private let previewLayer: AVCaptureVideoPreviewLayer
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "coop.up.video1cam.camera")
    private var currentDeviceID: String?
    private(set) var diameter: CGFloat = 200

    var onSizeChange: ((BubbleSize) -> Void)?
    var onHide: (() -> Void)?

    var isVisible: Bool { panel.isVisible }
    var windowNumber: Int { panel.windowNumber }
    var frame: NSRect { panel.frame }

    init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        view = BubbleView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.masksToBounds = true
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        view.layer?.borderWidth = 3
        previewLayer.frame = view.bounds
        previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(previewLayer)

        panel = BubblePanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.title = "Video1Cam — caméra"

        let menu = NSMenu()
        for size in BubbleSize.allCases {
            let item = NSMenuItem(title: "Taille \(size.label)", action: #selector(BubbleView.menuAction(_:)), keyEquivalent: "")
            item.representedObject = size.rawValue
            item.target = view
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let hide = NSMenuItem(title: "Désactiver la caméra", action: #selector(BubbleView.menuAction(_:)), keyEquivalent: "")
        hide.representedObject = "hide"
        hide.target = view
        menu.addItem(hide)
        view.menu = menu
        view.onMenu = { [weak self] value in
            if value == "hide" { self?.onHide?() }
            else if let s = BubbleSize(rawValue: value) { self?.onSizeChange?(s) }
        }
        setDiameter(200)
        placeDefault(on: NSScreen.main)
    }

    func setDiameter(_ d: CGFloat) {
        diameter = d
        var f = panel.frame
        let center = NSPoint(x: f.midX, y: f.midY)
        f.size = NSSize(width: d, height: d)
        f.origin = NSPoint(x: center.x - d / 2, y: center.y - d / 2)
        panel.setFrame(f, display: true)
        view.layer?.cornerRadius = d / 2
        if let screen = panel.screen ?? NSScreen.main { keepOnScreen(screen.visibleFrame) }
    }

    func placeDefault(on screen: NSScreen?) {
        guard let vf = (screen ?? NSScreen.main)?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: vf.minX + 32, y: vf.minY + 32))
    }

    /// Ensures the bubble sits fully inside `rect` (global coords); moves it to the bottom-left corner otherwise.
    func moveInside(_ rect: NSRect) {
        let f = panel.frame
        if rect.contains(f) { return }
        let margin: CGFloat = min(24, max(0, (rect.width - f.width) / 2))
        panel.setFrameOrigin(NSPoint(x: rect.minX + margin, y: rect.minY + min(24, max(0, (rect.height - f.height) / 2))))
    }

    private func keepOnScreen(_ vf: NSRect) {
        var f = panel.frame
        f.origin.x = min(max(f.origin.x, vf.minX), vf.maxX - f.width)
        f.origin.y = min(max(f.origin.y, vf.minY), vf.maxY - f.height)
        panel.setFrameOrigin(f.origin)
    }

    func show(device: AVCaptureDevice?) {
        configure(device: device)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure(device: AVCaptureDevice?) {
        guard let device else { return }
        let id = device.uniqueID
        let needsReconfigure = id != currentDeviceID
        currentDeviceID = id
        sessionQueue.async { [session, weak self] in
            if needsReconfigure {
                session.beginConfiguration()
                for input in session.inputs { session.removeInput(input) }
                if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                    session.addInput(input)
                }
                if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
                session.commitConfiguration()
            }
            if !session.isRunning { session.startRunning() }
            DispatchQueue.main.async {
                guard let self, let conn = self.previewLayer.connection, conn.isVideoMirroringSupported else { return }
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = true
            }
        }
    }
}

final class BubblePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class BubbleView: NSView {
    var onMenu: ((String) -> Void)?
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc func menuAction(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? String { onMenu?(v) }
    }
}
