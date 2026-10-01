import AppKit
@preconcurrency import AVFoundation
import Combine
import RecorderCore
import ScreenCaptureKit
import SwiftUI

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let state = AppState()
    private var mainWindow: NSWindow!
    private let bubble = CameraBubble()
    private let regionSelector = RegionSelector()
    private let countdown = Countdown()
    private let regionFrame = RegionFrame()
    private let controlBar = ControlBar()
    private var statusItem: NSStatusItem!
    private var session: RecordingSession?
    private var activity: NSObjectProtocol?
    private var uiTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var postWindows: [NSWindow] = []

    private var accumulated: TimeInterval = 0
    private var segmentStart: Date?
    private var recordingStart = Date()
    private var terminateAfterStop = false

    static let inProgressDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Video1Cam/InProgress", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One instance only: two instances would share (and could recover/delete) the same in-progress files.
        let me = ProcessInfo.processInfo.processIdentifier
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "coop.up.video1cam")
            .first(where: { $0.processIdentifier != me }) {
            other.activate()
            NSApp.terminate(nil)
            return
        }
        buildMainMenu()
        buildMainWindow()
        buildStatusItem()

        HotKeys.register(id: 1, keyCode: 0x0F) { [weak self] in self?.toggleRecording() } // R
        HotKeys.register(id: 2, keyCode: 0x23) { [weak self] in self?.togglePause() }     // P

        bubble.onSizeChange = { [weak self] s in self?.state.bubbleSize = s }
        bubble.onHide = { [weak self] in
            guard let self, !self.state.status.isBusy else { return }
            self.state.cameraEnabled = false
        }
        state.$cameraEnabled.combineLatest(state.$cameraID, state.$bubbleSize)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateBubble() }
            .store(in: &cancellables)

        mainWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateBubble()
        recoverInterruptedRecordings()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !state.status.isBusy { showMainWindow() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch state.status {
        case .idle:
            return .terminateNow
        case .recording, .paused:
            let a = NSAlert()
            a.messageText = "Un enregistrement est en cours"
            a.informativeText = "Voulez-vous l'arrêter et l'enregistrer avant de quitter ?"
            a.addButton(withTitle: "Arrêter, enregistrer et quitter")
            a.addButton(withTitle: "Continuer l'enregistrement")
            if a.runModal() == .alertFirstButtonReturn {
                terminateAfterStop = true
                stopRecording()
                return .terminateCancel // we quit ourselves once the file is safe
            }
            return .terminateCancel
        case .finalizing:
            let a = NSAlert()
            a.messageText = "Finalisation en cours"
            a.informativeText = "Patientez quelques secondes que la vidéo soit enregistrée, puis quittez à nouveau."
            a.runModal()
            return .terminateCancel
        default:
            return .terminateCancel
        }
    }

    // MARK: - Windows & menus

    private func buildMainWindow() {
        let actions = MainActions(
            toggleRecording: { [weak self] in self?.toggleRecording() },
            selectRegion: { [weak self] in self?.selectRegionFromUI() },
            chooseFolder: { [weak self] in self?.chooseFolder() },
            openFolder: { [weak self] in self?.openOutputFolder() },
            openScreenSettings: { Self.openScreenRecordingSettings() }
        )
        let host = NSHostingView(rootView: MainView(state: state, actions: actions))
        let height = min(780, (NSScreen.main?.visibleFrame.height ?? 800) - 40)
        mainWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: height),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        mainWindow.title = "Video1Cam"
        mainWindow.contentView = host
        mainWindow.contentMinSize = NSSize(width: 440, height: 420)
        mainWindow.contentMaxSize = NSSize(width: 440, height: 2000)
        mainWindow.isReleasedWhenClosed = false
        mainWindow.delegate = self
        if !mainWindow.setFrameUsingName("MainWindow") { mainWindow.center() }
        mainWindow.setFrameAutosaveName("MainWindow")
    }

    func showMainWindow() {
        mainWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateBubble()
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if w === mainWindow {
            DispatchQueue.main.async { self.updateBubble() }
        } else {
            postWindows.removeAll { $0 === w }
        }
    }

    func windowDidMiniaturize(_ notification: Notification) { updateBubble() }
    func windowDidDeminiaturize(_ notification: Notification) { updateBubble() }

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "À propos de Video1Cam", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Masquer Video1Cam", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quitter Video1Cam", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Édition")
        edit.addItem(withTitle: "Annuler", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Rétablir", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let winItem = NSMenuItem()
        let win = NSMenu(title: "Fenêtre")
        win.addItem(withTitle: "Fermer", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "Réduire", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = win
        main.addItem(winItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = win
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshStatusItem()
    }

    private func refreshStatusItem() {
        guard let button = statusItem.button else { return }
        switch state.status {
        case .recording, .paused:
            let img = NSImage(systemSymbolName: state.status == .paused ? "pause.circle.fill" : "record.circle.fill", accessibilityDescription: "Enregistrement")
            let config = NSImage.SymbolConfiguration(paletteColors: [state.status == .paused ? .systemOrange : .systemRed])
            button.image = img?.withSymbolConfiguration(config)
            button.image?.isTemplate = false
            button.title = " " + formatDuration(state.elapsed)
        default:
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Video1Cam")
            button.image?.isTemplate = true
            button.title = ""
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let recording = state.status == .recording || state.status == .paused
        let start = NSMenuItem(title: recording ? "Terminer l'enregistrement" : "Démarrer l'enregistrement", action: #selector(menuToggle), keyEquivalent: "r")
        start.keyEquivalentModifierMask = [.command, .option, .shift]
        start.target = self
        start.isEnabled = state.status == .idle || recording
        menu.addItem(start)
        let pause = NSMenuItem(title: state.status == .paused ? "Reprendre" : "Pause", action: #selector(menuPause), keyEquivalent: "p")
        pause.keyEquivalentModifierMask = [.command, .option, .shift]
        pause.target = self
        pause.isEnabled = recording
        menu.addItem(pause)
        menu.addItem(.separator())
        let show = NSMenuItem(title: "Afficher Video1Cam", action: #selector(menuShow), keyEquivalent: "")
        show.target = self
        show.isEnabled = !state.status.isBusy
        menu.addItem(show)
        let folder = NSMenuItem(title: "Ouvrir le dossier des vidéos", action: #selector(menuFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quitter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func menuToggle() { toggleRecording() }
    @objc private func menuPause() { togglePause() }
    @objc private func menuShow() { showMainWindow() }
    @objc private func menuFolder() { openOutputFolder() }

    // MARK: - Camera bubble

    private func updateBubble() {
        bubble.setDiameter(state.bubbleSize.diameter)
        let busy = state.status == .preparing || state.status == .countdown || state.status == .recording || state.status == .paused
        let wanted = state.cameraEnabled && (busy || (mainWindow.isVisible && !mainWindow.isMiniaturized))
        guard wanted else {
            if !busy { bubble.hide() }
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            bubble.show(device: state.cameraDevice)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { _ in
                DispatchQueue.main.async { self.updateBubble() }
            }
        default:
            bubble.hide()
        }
    }

    // MARK: - UI actions

    private func selectRegionFromUI() {
        regionSelector.begin { [weak self] r in
            guard let self else { return }
            if let r { self.state.region = r }
            self.showMainWindow()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choisir"
        panel.message = "Dossier où enregistrer les vidéos (par ex. un dépôt Git)"
        panel.directoryURL = state.outputFolder
        if panel.runModal() == .OK, let url = panel.url { state.outputFolder = url }
    }

    private func openOutputFolder() {
        try? FileManager.default.createDirectory(at: state.outputFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(state.outputFolder)
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func toggleRecording() {
        guard !regionSelector.isActive else { return }
        switch state.status {
        case .idle: startRecording()
        case .recording, .paused: stopRecording()
        case .countdown: countdown.end(false)
        default: break
        }
    }

    // MARK: - Start

    func startRecording() {
        guard state.status == .idle, !regionSelector.isActive else { return }
        state.status = .preparing
        Task { await startFlow() }
    }

    private func abortStart(_ title: String, _ message: String, openSettings: Bool = false) {
        state.status = .idle
        showMainWindow()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = .warning
        if openSettings {
            a.addButton(withTitle: "Ouvrir les Réglages")
            a.addButton(withTitle: "Fermer")
            if a.runModal() == .alertFirstButtonReturn { Self.openScreenRecordingSettings() }
        } else {
            a.runModal()
        }
    }

    private func startFlow() async {
        // 1. Screen recording permission: the real test is fetching shareable content.
        var content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            state.screenPermission = true
        } catch {
            _ = CGRequestScreenCaptureAccess()
            state.screenPermission = false
            abortStart("Autorisation d'enregistrement de l'écran requise",
                       "Activez Video1Cam dans Réglages Système › Confidentialité et sécurité › Enregistrement de l'écran et de l'audio système, puis quittez et relancez l'app.\n\n(\(error.localizedDescription))",
                       openSettings: true)
            return
        }

        // 2. Mic & camera permissions.
        if state.micEnabled, !(await AVCaptureDevice.requestAccess(for: .audio)) {
            abortStart("Accès au micro refusé",
                       "Autorisez Video1Cam dans Réglages Système › Confidentialité et sécurité › Microphone, ou désactivez le micro.")
            return
        }
        if state.cameraEnabled, !(await AVCaptureDevice.requestAccess(for: .video)) {
            abortStart("Accès à la caméra refusé",
                       "Autorisez Video1Cam dans Réglages Système › Confidentialité et sécurité › Caméra, ou désactivez la bulle caméra.")
            return
        }
        if state.cameraEnabled, state.cameraDevice == nil {
            abortStart("Aucune caméra détectée", "Branchez une caméra ou désactivez la bulle caméra.")
            return
        }

        // 3. Target area.
        var region: CaptureRegion?
        if state.mode == .region {
            if state.region == nil || NSScreen.screen(for: state.region!.displayID) == nil {
                mainWindow.orderOut(nil)
                let picked: CaptureRegion? = await withCheckedContinuation { c in
                    regionSelector.begin { c.resume(returning: $0) }
                }
                guard let picked else { state.status = .idle; showMainWindow(); return }
                state.region = picked
            }
            region = state.region
        }
        let displayID = region?.displayID ?? state.displayID
        guard let screen = NSScreen.screen(for: displayID) else {
            abortStart("Écran introuvable", "L'écran choisi n'est plus connecté.")
            return
        }

        // 4. Disk space.
        if let free = try? Self.inProgressDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < 3_000_000_000 {
            let a = NSAlert()
            a.messageText = "Espace disque faible"
            a.informativeText = "Il reste \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)). L'enregistrement pourrait s'interrompre."
            a.addButton(withTitle: "Enregistrer quand même")
            a.addButton(withTitle: "Annuler")
            if a.runModal() != .alertFirstButtonReturn { state.status = .idle; showMainWindow(); return }
        }

        // 5. Camera bubble in place, main window out of the way.
        if state.cameraEnabled {
            bubble.show(device: state.cameraDevice)
            if let region { bubble.moveInside(region.rect) }
            else if !screen.frame.contains(bubble.frame) { bubble.placeDefault(on: screen) }
        }
        mainWindow.orderOut(nil)

        // 6. Filter: whole display minus our own windows, except the camera bubble.
        guard var scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
            abortStart("Écran introuvable", "ScreenCaptureKit ne trouve pas l'écran choisi.")
            return
        }
        var bubbleWindow: SCWindow?
        if state.cameraEnabled {
            for attempt in 0..<15 {
                bubbleWindow = content.windows.first { $0.windowID == CGWindowID(bubble.windowNumber) }
                if bubbleWindow != nil { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
                if attempt < 14, let c = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) {
                    content = c
                    if let d = c.displays.first(where: { $0.displayID == displayID }) { scDisplay = d }
                }
            }
            guard bubbleWindow != nil else {
                abortStart("Bulle caméra introuvable", "Impossible d'inclure la caméra dans la capture. Réessayez.")
                return
            }
        }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }

        // 7. Geometry & encoder settings.
        var sourceRect: CGRect?
        var points = CGSize(width: scDisplay.width, height: scDisplay.height)
        if let region {
            let sf = screen.frame
            var local = CGRect(x: region.rect.minX - sf.minX, y: sf.maxY - region.rect.maxY,
                               width: region.rect.width, height: region.rect.height)
            local = local.intersection(CGRect(origin: .zero, size: sf.size)).integral
            guard local.width >= 40, local.height >= 40 else {
                state.region = nil
                abortStart("Zone invalide", "La zone sélectionnée est hors de l'écran. Sélectionnez-la à nouveau.")
                return
            }
            sourceRect = local
            points = local.size
        }
        let size = OutputSize.compute(points: points, scale: screen.backingScaleFactor, maxLong: state.quality.box.long, maxShort: state.quality.box.short)
        let video = VideoSettings(width: size.width, height: size.height, fps: state.fps, codec: state.codec)
        let rawURL = Self.inProgressDir.appendingPathComponent("rec-\(FileNaming.datePrefix(Date()))-\(UUID().uuidString.prefix(6)).mov")

        let config = RecordingConfig(display: scDisplay, sourceRect: sourceRect, video: video, showClicks: state.showClicks,
                                     systemAudio: state.systemAudioEnabled, microphone: state.micEnabled,
                                     microphoneID: state.micID.isEmpty ? nil : state.micID,
                                     excludedApps: me, includedWindows: bubbleWindow.map { [$0] } ?? [], rawURL: rawURL)
        let newSession: RecordingSession
        do {
            newSession = try RecordingSession(config: config)
        } catch {
            abortStart("Impossible de préparer l'enregistrement", error.localizedDescription)
            return
        }

        // 8. Countdown.
        if state.countdown {
            state.status = .countdown
            let target = region?.rect ?? screen.frame
            let ok: Bool = await withCheckedContinuation { c in countdown.run(centeredOn: target) { c.resume(returning: $0) } }
            if !ok {
                await newSession.cancel()
                state.status = .idle
                showMainWindow()
                return
            }
        }

        // 9. Go.
        newSession.onUnexpectedStop = { [weak self] error in
            guard let self, self.session === newSession,
                  self.state.status == .recording || self.state.status == .paused else { return }
            NSLog("Video1Cam: capture stopped: \(error.localizedDescription)")
            self.stopRecording(reason: error.localizedDescription)
        }
        do {
            try await newSession.start()
        } catch {
            abortStart("L'enregistrement n'a pas pu démarrer", error.localizedDescription)
            return
        }
        if newSession.isStopped {
            await newSession.cancel()
            abortStart("L'enregistrement s'est arrêté immédiatement", "La capture a été interrompue par le système. Réessayez.")
            return
        }
        session = newSession
        recordingStart = Date()
        accumulated = 0
        segmentStart = Date()
        state.elapsed = 0
        state.status = .recording
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled],
                                                         reason: "Enregistrement vidéo")
        controlBar.show(state: state, on: screen,
                        onPauseToggle: { [weak self] in self?.togglePause() },
                        onStop: { [weak self] in self?.stopRecording() },
                        onCancel: { [weak self] in self?.cancelRecording() })
        if let region { regionFrame.show(around: region.rect) }
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        refreshStatusItem()
    }

    private func tick() {
        state.elapsed = accumulated + (segmentStart.map { Date().timeIntervalSince($0) } ?? 0)
        if let session, state.micEnabled { state.micLevel = session.micPeak }
        refreshStatusItem()
    }

    // MARK: - Pause

    func togglePause() {
        guard let session else { return }
        if state.status == .recording {
            session.pause()
            accumulated += segmentStart.map { Date().timeIntervalSince($0) } ?? 0
            segmentStart = nil
            state.status = .paused
            regionFrame.setPaused(true)
        } else if state.status == .paused {
            session.resume()
            segmentStart = Date()
            state.status = .recording
            regionFrame.setPaused(false)
        }
        tick()
    }

    // MARK: - Stop / cancel

    private func tearDownRecordingUI() {
        uiTimer?.invalidate()
        uiTimer = nil
        controlBar.hide()
        regionFrame.hide()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        state.micLevel = 0
    }

    func cancelRecording() {
        guard state.status == .recording || state.status == .paused, let session else { return }
        let wasRecording = state.status == .recording
        if wasRecording { togglePause() }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Supprimer cet enregistrement ?"
        a.informativeText = "La vidéo en cours sera définitivement perdue."
        a.addButton(withTitle: "Supprimer")
        a.addButton(withTitle: "Continuer")
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else {
            if wasRecording, state.status == .paused { togglePause() }
            return
        }
        guard self.session === session else { return }
        self.session = nil
        state.status = .finalizing
        tearDownRecordingUI()
        Task {
            await session.cancel()
            state.status = .idle
            refreshStatusItem()
            showMainWindow()
        }
    }

    func stopRecording(reason: String? = nil) {
        guard state.status == .recording || state.status == .paused, let session else { return }
        self.session = nil
        tick()
        let duration = state.elapsed
        state.status = .finalizing
        tearDownRecordingUI()
        refreshStatusItem()
        updateBubble()

        let model = PostRecordingModel(startDate: recordingStart, duration: duration)
        let window = showPostWindow(model)
        Task {
            var raw: URL?
            do {
                raw = try await session.stop()
                let final = try await finalize(raw: raw!, date: recordingStart) { p in
                    DispatchQueue.main.async { if case .finalizing = model.phase { model.phase = .finalizing(p) } }
                }
                model.phase = .done(final)
                if let reason { model.renameError = "Enregistrement arrêté automatiquement : \(reason)" }
                if !model.title.trimmingCharacters(in: .whitespaces).isEmpty { rename(model) }
            } catch {
                var msg = error.localizedDescription
                if let reason { msg = "L'enregistrement a été interrompu : \(reason)\n\n" + msg }
                // Writer failed while recording: keep what was written (the file is fragmented, hence readable).
                if raw == nil, FileManager.default.fileExists(atPath: session.rawURL.path) {
                    if let kept = rescueRaw(session.rawURL, date: recordingStart, into: state.outputFolder) {
                        msg += "\n\nLa partie enregistrée a été conservée : \(kept.path)"
                    } else {
                        msg += "\n\nLa partie enregistrée est conservée ici : \(session.rawURL.path)"
                    }
                }
                model.phase = .failed(msg)
            }
            state.status = .idle
            refreshStatusItem()
            updateBubble()
            if terminateAfterStop {
                if case .done = model.phase { window.close(); NSApp.terminate(nil) }
                else { terminateAfterStop = false }
            }
        }
    }

    /// Raw .mov → final .mp4 in the output folder. On failure the raw file is moved there instead, so nothing is lost.
    private func finalize(raw: URL, date: Date, progress: @escaping (Double) -> Void) async throws -> URL {
        let tmp = raw.deletingPathExtension().appendingPathExtension("mp4")
        let folder = state.outputFolder
        do {
            try await Finalizer.finalize(input: raw, output: tmp, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            let rescued = rescueRaw(raw, date: date, into: folder)
            throw RecorderError.exportFailed("\(error.localizedDescription)\n\nLe fichier brut a été conservé : \(rescued?.path ?? raw.path)\n(lisible avec QuickTime Player)")
        }
        try? FileManager.default.removeItem(at: raw)
        return try moveFinal(tmp, date: date, suffix: "enregistrement", into: folder)
    }

    private func moveFinal(_ file: URL, date: Date, suffix: String, into folder: URL) throws -> URL {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = FileNaming.uniqueURL(in: folder, base: FileNaming.baseName(date: date, title: suffix), ext: "mp4")
            try FileManager.default.moveItem(at: file, to: dest)
            return dest
        } catch {
            throw RecorderError.exportFailed("Impossible d'écrire dans « \(folder.path) » : \(error.localizedDescription)\n\nLa vidéo est conservée ici : \(file.path)")
        }
    }

    private func rescueRaw(_ raw: URL, date: Date, into folder: URL) -> URL? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = FileNaming.uniqueURL(in: folder, base: FileNaming.baseName(date: date, title: "brut"), ext: "mov")
        return (try? FileManager.default.moveItem(at: raw, to: dest)) != nil ? dest : nil
    }

    // MARK: - Post-recording window

    private func showPostWindow(_ model: PostRecordingModel) -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Enregistrement terminé"
        w.isReleasedWhenClosed = false
        let view = PostRecordingView(
            model: model,
            onSave: { [weak self] in self?.rename(model) },
            onReveal: { [weak self] in
                if let url = self?.currentURL(model) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                else { self?.openOutputFolder() }
            },
            onOpen: { [weak self] in if let url = self?.currentURL(model) { NSWorkspace.shared.open(url) } },
            onCopyPath: { [weak self] in
                guard let url = self?.currentURL(model) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            },
            onTrash: { [weak self, weak w] in
                guard let url = self?.currentURL(model) else { return }
                NSWorkspace.shared.recycle([url]) { _, error in
                    DispatchQueue.main.async {
                        if let error { model.renameError = error.localizedDescription } else { w?.close() }
                    }
                }
            },
            onClose: { [weak w] in w?.close() }
        )
        w.contentView = NSHostingView(rootView: view)
        w.setContentSize(w.contentView!.fittingSize)
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        postWindows.append(w)
        w.delegate = self
        return w
    }

    private func currentURL(_ model: PostRecordingModel) -> URL? {
        if case .done(let url) = model.phase { return url }
        return nil
    }

    private func rename(_ model: PostRecordingModel) {
        guard case .done(let url) = model.phase else { return }
        let dest = FileNaming.uniqueURL(in: url.deletingLastPathComponent(),
                                        base: FileNaming.baseName(date: model.startDate, title: model.title), ext: "mp4", except: url)
        guard dest.standardizedFileURL != url.standardizedFileURL else { return }
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            model.phase = .done(dest)
            model.renameError = nil
        } catch {
            model.renameError = "Renommage impossible : \(error.localizedDescription)"
        }
    }

    // MARK: - Crash recovery

    private func recoverInterruptedRecordings() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.inProgressDir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let raws = files.filter { $0.pathExtension == "mov" }
        // An .mp4 next to its .mov is a partial finalization: redo it from the raw file.
        for r in raws { try? fm.removeItem(at: r.deletingPathExtension().appendingPathExtension("mp4")) }
        let finals = files.filter { $0.pathExtension == "mp4" && !raws.contains($0.deletingPathExtension().appendingPathExtension("mov")) }
        let count = raws.count + finals.count
        guard count > 0, state.status == .idle else { return }
        state.status = .finalizing // blocks new recordings while we deal with this

        let a = NSAlert()
        a.messageText = count == 1 ? "Un enregistrement interrompu a été trouvé" : "\(count) enregistrements interrompus ont été trouvés"
        a.informativeText = "Video1Cam s'est arrêté pendant un enregistrement. Voulez-vous récupérer la vidéo dans votre dossier ?"
        a.addButton(withTitle: "Récupérer")
        a.addButton(withTitle: "Plus tard")
        guard a.runModal() == .alertFirstButtonReturn else { state.status = .idle; return }

        Task {
            var recovered: [URL] = []
            var errors: [String] = []
            func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date() }
            for f in finals {
                do { recovered.append(try moveFinal(f, date: date(f), suffix: "recupere", into: state.outputFolder)) }
                catch { errors.append(error.localizedDescription) }
            }
            for r in raws {
                let tmp = r.deletingPathExtension().appendingPathExtension("mp4")
                do {
                    try await Finalizer.finalize(input: r, output: tmp)
                    try? FileManager.default.removeItem(at: r)
                    recovered.append(try moveFinal(tmp, date: date(r), suffix: "recupere", into: state.outputFolder))
                } catch RecorderError.noVideoTrack {
                    // Crash before the first frame: nothing to recover.
                    try? FileManager.default.removeItem(at: tmp)
                    try? FileManager.default.removeItem(at: r)
                } catch {
                    try? FileManager.default.removeItem(at: tmp)
                    if let kept = rescueRaw(r, date: date(r), into: state.outputFolder) {
                        errors.append("\(r.lastPathComponent) : \(error.localizedDescription). Fichier brut déplacé vers \(kept.path).")
                    } else {
                        errors.append("\(r.lastPathComponent) : \(error.localizedDescription)")
                    }
                }
            }
            state.status = .idle
            let done = NSAlert()
            done.messageText = errors.isEmpty ? "Récupération terminée" : "Récupération partielle"
            done.informativeText = (recovered.map { "✓ \($0.lastPathComponent)" } + errors.map { "✗ \($0)" }).joined(separator: "\n")
            done.addButton(withTitle: "Afficher dans le Finder")
            done.addButton(withTitle: "OK")
            if done.runModal() == .alertFirstButtonReturn {
                if recovered.isEmpty { openOutputFolder() } else { NSWorkspace.shared.activateFileViewerSelecting(recovered) }
            }
        }
    }
}
