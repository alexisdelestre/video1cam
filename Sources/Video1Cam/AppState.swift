import AppKit
@preconcurrency import AVFoundation
import Combine
import RecorderCore

struct DeviceInfo: Identifiable, Hashable {
    let id: String
    let name: String
}

struct ScreenInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
}

/// A selected region, in global Cocoa screen coordinates (bottom-left origin).
struct CaptureRegion: Equatable {
    var displayID: CGDirectDisplayID
    var rect: NSRect
}

enum CaptureMode: String, CaseIterable, Identifiable {
    case fullScreen, region
    var id: String { rawValue }
    var label: String { self == .fullScreen ? "Plein écran" : "Zone / fenêtre" }
}

enum Quality: String, CaseIterable, Identifiable {
    case p1080, p1440, p2160
    var id: String { rawValue }
    var label: String {
        switch self {
        case .p1080: return "1080p (léger)"
        case .p1440: return "1440p"
        case .p2160: return "4K"
        }
    }
    var box: (long: Int, short: Int) {
        switch self {
        case .p1080: return (1920, 1080)
        case .p1440: return (2560, 1440)
        case .p2160: return (3840, 2160)
        }
    }
}

enum BubbleSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var label: String { self == .small ? "S" : self == .medium ? "M" : "L" }
    var diameter: CGFloat { self == .small ? 140 : self == .medium ? 200 : 280 }
}

enum RecorderStatus: Equatable {
    case idle, preparing, countdown, recording, paused, finalizing
    var isBusy: Bool { self != .idle }
}

@MainActor
final class AppState: ObservableObject {
    private let d = UserDefaults.standard

    @Published var mode: CaptureMode { didSet { d.set(mode.rawValue, forKey: "mode") } }
    @Published var displayID: CGDirectDisplayID { didSet { d.set(Int(displayID), forKey: "displayID") } }
    @Published var region: CaptureRegion?

    @Published var cameraEnabled: Bool { didSet { d.set(cameraEnabled, forKey: "cameraEnabled") } }
    @Published var cameraID: String { didSet { d.set(cameraID, forKey: "cameraID") } }
    @Published var bubbleSize: BubbleSize { didSet { d.set(bubbleSize.rawValue, forKey: "bubbleSize") } }

    @Published var micEnabled: Bool { didSet { d.set(micEnabled, forKey: "micEnabled") } }
    @Published var micID: String { didSet { d.set(micID, forKey: "micID") } }
    @Published var systemAudioEnabled: Bool { didSet { d.set(systemAudioEnabled, forKey: "systemAudioEnabled") } }

    @Published var quality: Quality { didSet { d.set(quality.rawValue, forKey: "quality") } }
    @Published var fps: Int { didSet { d.set(fps, forKey: "fps") } }
    @Published var codec: VideoSettings.Codec { didSet { d.set(codec.rawValue, forKey: "codec") } }
    @Published var showClicks: Bool { didSet { d.set(showClicks, forKey: "showClicks") } }
    @Published var countdown: Bool { didSet { d.set(countdown, forKey: "countdown") } }
    @Published var outputFolder: URL { didSet { d.set(outputFolder.path, forKey: "outputFolder") } }

    @Published var status: RecorderStatus = .idle
    @Published var elapsed: TimeInterval = 0
    @Published var micLevel: Float = 0

    @Published var cameras: [DeviceInfo] = []
    @Published var microphones: [DeviceInfo] = []
    @Published var screens: [ScreenInfo] = []
    @Published var screenPermission = CGPreflightScreenCaptureAccess()

    private var observers: [NSObjectProtocol] = []

    init() {
        mode = CaptureMode(rawValue: d.string(forKey: "mode") ?? "") ?? .fullScreen
        displayID = CGDirectDisplayID(d.integer(forKey: "displayID"))
        cameraEnabled = d.object(forKey: "cameraEnabled") as? Bool ?? true
        cameraID = d.string(forKey: "cameraID") ?? ""
        bubbleSize = BubbleSize(rawValue: d.string(forKey: "bubbleSize") ?? "") ?? .medium
        micEnabled = d.object(forKey: "micEnabled") as? Bool ?? true
        micID = d.string(forKey: "micID") ?? ""
        systemAudioEnabled = d.object(forKey: "systemAudioEnabled") as? Bool ?? true
        quality = Quality(rawValue: d.string(forKey: "quality") ?? "") ?? .p1080
        let savedFps = d.integer(forKey: "fps")
        fps = savedFps == 60 ? 60 : 30
        codec = VideoSettings.Codec(rawValue: d.string(forKey: "codec") ?? "") ?? .h264
        showClicks = d.object(forKey: "showClicks") as? Bool ?? true
        countdown = d.object(forKey: "countdown") as? Bool ?? true
        if let p = d.string(forKey: "outputFolder"), !p.isEmpty {
            outputFolder = URL(fileURLWithPath: p, isDirectory: true)
        } else {
            outputFolder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Video1Cam", isDirectory: true)
        }

        refreshDevices()
        refreshScreens()
        let nc = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDevices() }
            })
        }
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshScreens() }
        })
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenPermission = CGPreflightScreenCaptureAccess() }
        })
    }

    func refreshDevices() {
        let cams = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                    mediaType: .video, position: .unspecified).devices
        cameras = cams.map { DeviceInfo(id: $0.uniqueID, name: $0.localizedName) }
        let mics = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                    mediaType: .audio, position: .unspecified).devices
        microphones = mics.map { DeviceInfo(id: $0.uniqueID, name: $0.localizedName) }
        if !cameraID.isEmpty, !cameras.contains(where: { $0.id == cameraID }) { cameraID = "" }
        if !micID.isEmpty, !microphones.contains(where: { $0.id == micID }) { micID = "" }
    }

    func refreshScreens() {
        screens = NSScreen.screens.compactMap { s in
            guard let id = s.displayID else { return nil }
            return ScreenInfo(id: id, name: s.localizedName)
        }
        if !screens.contains(where: { $0.id == displayID }), let first = screens.first { displayID = first.id }
        if let r = region, NSScreen.screen(for: r.displayID) == nil { region = nil }
    }

    /// Resolved camera device (explicit choice or system default).
    var cameraDevice: AVCaptureDevice? {
        if !cameraID.isEmpty, let dev = AVCaptureDevice(uniqueID: cameraID) { return dev }
        return AVCaptureDevice.default(for: .video)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == id }
    }
}
