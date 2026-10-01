import AppKit
import SwiftUI

// MARK: - Countdown

@MainActor
final class Countdown {
    private var window: NSWindow?
    private var timer: Timer?
    private var completion: ((Bool) -> Void)?

    /// Shows 3‑2‑1 centred on `rect`. Calls completion(true) at the end, (false) if cancelled (Esc / click).
    func run(centeredOn rect: NSRect, seconds: Int = 3, completion: @escaping (Bool) -> Void) {
        self.completion = completion
        let size = NSSize(width: 180, height: 180)
        let w = ClickablePanel(contentRect: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let label = NSTextField(labelWithString: "\(seconds)")
        label.font = .systemFont(ofSize: 96, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        let box = NSView(frame: NSRect(origin: .zero, size: size))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        box.layer?.cornerRadius = 36
        label.frame = NSRect(x: 0, y: (size.height - 120) / 2, width: size.width, height: 120)
        box.addSubview(label)
        let hint = NSTextField(labelWithString: "Échap pour annuler")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = NSColor.white.withAlphaComponent(0.7)
        hint.alignment = .center
        hint.frame = NSRect(x: 0, y: 12, width: size.width, height: 16)
        box.addSubview(hint)
        w.contentView = box
        w.onClick = { [weak self] in self?.end(false) }
        w.orderFrontRegardless()
        window = w

        // Esc as a temporary system-wide hotkey: works even when another app is frontmost,
        // without Accessibility permission. Released as soon as the countdown ends.
        HotKeys.register(id: 99, keyCode: 53, modifiers: 0) { [weak self] in self?.end(false) }
        var remaining = seconds
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                remaining -= 1
                if remaining <= 0 { self?.end(true) } else { label.stringValue = "\(remaining)" }
            }
        }
    }

    func end(_ ok: Bool) {
        guard let completion else { return }
        self.completion = nil
        timer?.invalidate()
        timer = nil
        HotKeys.unregister(id: 99)
        window?.orderOut(nil)
        window = nil
        completion(ok)
    }
}

final class ClickablePanel: NSPanel {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override var canBecomeKey: Bool { false }
}

// MARK: - Region frame shown around the recorded area (outside of it, never captured)

@MainActor
final class RegionFrame {
    private var window: NSWindow?

    func show(around rect: NSRect) {
        let t: CGFloat = 3
        let outer = rect.insetBy(dx: -t, dy: -t)
        let w = NSWindow(contentRect: outer, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.isReleasedWhenClosed = false
        let v = FrameView(frame: NSRect(origin: .zero, size: outer.size))
        v.thickness = t
        w.contentView = v
        w.orderFrontRegardless()
        window = w
    }

    func setPaused(_ paused: Bool) {
        (window?.contentView as? FrameView)?.paused = paused
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }

    private final class FrameView: NSView {
        var thickness: CGFloat = 3
        var paused = false { didSet { needsDisplay = true } }
        override func draw(_ dirtyRect: NSRect) {
            (paused ? NSColor.systemOrange : NSColor.systemRed).setFill()
            let inner = bounds.insetBy(dx: thickness, dy: thickness)
            let path = NSBezierPath(rect: bounds)
            path.append(NSBezierPath(rect: inner).reversed)
            path.fill()
        }
    }
}

// MARK: - Control bar

@MainActor
final class ControlBar {
    private var panel: NSPanel?

    func show(state: AppState, on screen: NSScreen, onPauseToggle: @escaping () -> Void, onStop: @escaping () -> Void, onCancel: @escaping () -> Void) {
        let view = ControlBarView(state: state, onPauseToggle: onPauseToggle, onStop: onStop, onCancel: onCancel)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let vf = screen.visibleFrame
        let p = BarPanel(contentRect: NSRect(x: vf.midX - size.width / 2, y: vf.minY + 24, width: size.width, height: size.height),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.contentView = host
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.orderFrontRegardless()
        panel = p
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    private final class BarPanel: NSPanel {
        override var canBecomeKey: Bool { false }
    }
}

struct ControlBarView: View {
    @ObservedObject var state: AppState
    let onPauseToggle: () -> Void
    let onStop: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(state.status == .paused ? Color.orange : Color.red)
                .frame(width: 10, height: 10)
            Text(formatDuration(state.elapsed))
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(minWidth: 56, alignment: .leading)
            if state.micEnabled {
                MicMeter(level: state.micLevel)
                    .help("Niveau du micro")
            }
            Divider().frame(height: 18).overlay(Color.white.opacity(0.3))
            barButton(state.status == .paused ? "play.fill" : "pause.fill",
                      help: state.status == .paused ? "Reprendre (⌥⇧⌘P)" : "Pause (⌥⇧⌘P)", action: onPauseToggle)
            barButton("stop.fill", help: "Terminer (⌥⇧⌘R)", tint: .red, action: onStop)
            barButton("trash", help: "Annuler et supprimer", action: onCancel)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.82)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.15)))
        .fixedSize()
    }

    private func barButton(_ symbol: String, help: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct MicMeter: View {
    let level: Float
    var body: some View {
        // Log-ish scale so normal speech shows clearly.
        let db = 20 * log10(max(Double(level), 0.000_01))
        let v = min(1, max(0, (db + 50) / 50))
        HStack(spacing: 2) {
            ForEach(0..<8) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Double(i) / 8 < v ? (i >= 6 ? Color.orange : Color.green) : Color.white.opacity(0.18))
                    .frame(width: 3, height: 6 + CGFloat(i) * 1.5)
            }
        }
        .frame(height: 18, alignment: .bottom)
    }
}

func formatDuration(_ t: TimeInterval) -> String {
    let s = Int(t)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
}
